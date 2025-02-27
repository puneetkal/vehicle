{-# OPTIONS_GHC -Wno-orphans #-}

module Vehicle.Syntax.BNFC.Elaborate.External
  ( PartiallyParsedProg,
    PartiallyParsedDecl,
    UnparsedExpr (..),
    partiallyElabProg,
    elaborateDecl,
    elaborateExpr,
  )
where

import Control.Monad (foldM_)
import Control.Monad.Except (MonadError (..), throwError)
import Control.Monad.Reader (runReaderT)
import Data.Bitraversable (bitraverse)
import Data.Either (partitionEithers)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map (Map)
import Data.Map qualified as Map (insert, lookup)
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set (fromList, notMember, toList)
import Data.Text (Text, unpack)
import Data.These (These (..))
import Prettyprinter
import Vehicle.Syntax.AST qualified as V
import Vehicle.Syntax.BNFC.Utils
  ( MonadElab,
    ParseLocation,
    getModule,
    mkProvenance,
    tokArrow,
    tokDot,
    tokForallT,
    tokLambda,
    tokType,
    pattern InferableOption,
  )
import Vehicle.Syntax.Builtin qualified as V
import Vehicle.Syntax.External.Abs qualified as B
import Vehicle.Syntax.Parse.Error (ParseError (..))
import Vehicle.Syntax.Parse.Token
import Vehicle.Syntax.Prelude (developerError, readNat, readRat)

--------------------------------------------------------------------------------
-- Public interface

type PartiallyParsedProg = V.GenericProg UnparsedExpr

type PartiallyParsedDecl = V.GenericDecl UnparsedExpr

newtype UnparsedExpr = UnparsedExpr B.Expr

--------------------------------------------------------------------------------
-- Partially elaborating declarations

-- | We partially elaborate from the simple AST generated automatically by BNFC
-- to our more complicated internal version of the AST. We stop when we get
-- to the expression level. In theory this should allow us to read the
-- declaration signatures from the file without actually having to parse their
-- types and definitions.
partiallyElabProg ::
  (MonadError ParseError m) =>
  ParseLocation ->
  B.Prog ->
  m PartiallyParsedProg
partiallyElabProg file (B.Main decls) = flip runReaderT file $ do
  V.Main <$> partiallyElabDecls decls

partiallyElabDecls :: (MonadElab m) => [B.Decl] -> m [PartiallyParsedDecl]
partiallyElabDecls = \case
  [] -> return []
  decl : decls -> do
    (d', ds) <- elabDeclGroup [] (decl :| decls)
    ds' <- partiallyElabDecls ds
    return $ d' : ds'

type Annotation = (B.TokAnnotation, B.DeclAnnOpts)

elabDeclGroup ::
  (MonadElab m) =>
  [Annotation] ->
  NonEmpty B.Decl ->
  m (PartiallyParsedDecl, [B.Decl])
elabDeclGroup anns = \case
  -- Type definition.
  B.DefType n bs t :| ds -> do
    d' <- elabTypeDef anns n bs t
    return (d', ds)

  -- Function declaration and body.
  B.DefFunType typeName _ t :| B.DefFunExpr exprName bs e : ds -> do
    d' <- elabDefFun anns typeName exprName t bs e
    return (d', ds)

  -- Function body without a declaration.
  B.DefFunExpr n bs e :| ds -> do
    let unknownType = constructUnknownDefType n bs
    d' <- elabDefFun anns n n unknownType bs e
    return (d', ds)

  -- Abstract function declaration with no body
  B.DefFunType n _tk t :| ds -> do
    abstractType <- elabDefAbstractSort n anns
    d' <- elabDefAbstract n t abstractType
    return (d', ds)

  -- Standalone postulate annotation
  B.DefPostulate tk annOpts :| ds -> case anns of
    [] -> do
      d' <- elabPostulate tk annOpts
      return (d', ds)
    (annTk, _) : _ -> do
      p <- mkProvenance annTk
      throwError $ AnnotationWithNoDef p (tkSymbol annTk)

  -- Annotation declaration.
  B.DefAnn ann annOpts :| (d : ds) -> do
    elabDeclGroup ((ann, annOpts) : anns) (d :| ds)

  -- ERROR: Annotation with no body
  B.DefAnn ann _annOpts :| [] -> do
    p <- mkProvenance ann
    throwError $ AnnotationWithNoDef p (tkSymbol ann)

elabDefAbstractSort ::
  (MonadElab m) =>
  B.Name ->
  [Annotation] ->
  m V.DefAbstractSort
elabDefAbstractSort defName anns = do
  (sorts, annotations) <- partitionEithers <$> traverse parseAnnotation anns
  case annotations of
    ann : _ -> do
      p <- mkProvenance defName
      throwError $ AbstractDefWithNonAbstractAnnotation p (tkSymbol defName) ann
    [] -> case sorts of
      [] -> do
        p <- mkProvenance defName
        throwError $ UnannotatedAbstractDef p (tkSymbol defName)
      [ann] -> return ann
      ann1 : ann2 : _ -> do
        p <- mkProvenance defName
        throwError $ MultiplyAnnotatedAbstractDef p (tkSymbol defName) ann1 ann2

elabPostulate ::
  (MonadElab m) =>
  B.TokPostulate ->
  B.DeclAnnOpts ->
  m (V.GenericDecl UnparsedExpr)
elabPostulate tok opts = do
  let allowedOptions = Set.fromList ["name", "standard", "polarity", "linearity"]
  optsMap <- validateOpts tok allowedOptions opts
  (name, standardType, linearityType, polarityType) <- elabPostulateOptions tok optsMap
  abstractSort <- V.PostulateDef <$> traverse elabExpr linearityType <*> traverse elabExpr polarityType
  elabDefAbstract name standardType abstractSort

elabDefAbstract ::
  (MonadElab m) =>
  B.Name ->
  B.Expr ->
  V.DefAbstractSort ->
  m (V.GenericDecl UnparsedExpr)
elabDefAbstract n t r =
  V.DefAbstract <$> mkProvenance n <*> elabName n <*> pure r <*> pure (UnparsedExpr t)

elabTypeDef ::
  (MonadElab m) =>
  [Annotation] ->
  B.Name ->
  [B.NameBinder] ->
  B.Expr ->
  m (V.GenericDecl UnparsedExpr)
elabTypeDef anns n binders e = do
  let typeTyp
        | null binders = tokType 0
        | otherwise = B.ForallT tokForallT binders tokDot (tokType 0)
  let typeBody
        | null binders = e
        | otherwise = B.Lam tokLambda binders tokArrow e
  elabDefFun anns n n typeTyp binders typeBody

elabDefFun :: (MonadElab m) => [Annotation] -> B.Name -> B.Name -> B.Expr -> [B.NameBinder] -> B.Expr -> m (V.GenericDecl UnparsedExpr)
elabDefFun anns n1 n2 t binders e
  | tkSymbol n1 /= tkSymbol n2 = do
      p <- mkProvenance n1
      throwError $ FunctionWithMismatchedNames p (tkSymbol n1) (tkSymbol n2)
  | otherwise = do
      p <- mkProvenance n1
      name <- elabName n1
      -- This is a bit evil, we don't normally store possibly empty set of
      -- binders, but we will use this to indicate the set of LHS variables.
      let body = B.Lam tokLambda binders tokArrow e
      annotations <- elabDefFunctionAnnotations n1 anns
      return $ V.DefFunction p name annotations (UnparsedExpr t) (UnparsedExpr body)

elabDefFunctionAnnotations ::
  (MonadElab m) =>
  B.Name ->
  [Annotation] ->
  m [V.Annotation]
elabDefFunctionAnnotations defName anns = do
  (abstractSorts, annotations) <- partitionEithers <$> traverse parseAnnotation anns
  case abstractSorts of
    s : _ -> do
      p <- mkProvenance defName
      throwError $ NonAbstractDefWithAbstractAnnotation p (tkSymbol defName) s
    [] -> return annotations

parseAnnotation :: (MonadElab m) => Annotation -> m (Either V.DefAbstractSort V.Annotation)
parseAnnotation (tkName, opts) = do
  case tkSymbol tkName of
    "@network" -> do
      validateEmptyOpts tkName opts
      return $ Left V.NetworkDef
    "@dataset" -> do
      validateEmptyOpts tkName opts
      return $ Left V.DatasetDef
    "@parameter" -> do
      let allowedOptions = Set.fromList [InferableOption]
      optsList <- validateOpts tkName allowedOptions opts
      Left <$> elabParameterOptions optsList
    "@property" -> do
      validateEmptyOpts tkName opts
      return $ Right V.AnnProperty
    name -> developerError $ "Unknown annotation found" <+> squotes (pretty name)

validateOpts :: forall m token. (MonadElab m, IsToken token) => token -> Set Text -> B.DeclAnnOpts -> m [B.DeclAnnOption]
validateOpts _token _allowedNames B.DeclAnnWithoutOpts = return mempty
validateOpts token allowedNames (B.DeclAnnWithOpts opts) = do
  foldM_ processOpt mempty opts
  return opts
  where
    processOpt :: Map Text (V.Expr V.Name V.Builtin) -> B.DeclAnnOption -> m (Map Text (V.Expr V.Name V.Builtin))
    processOpt found opt = do
      let mkEntry tk value = (,tkSymbol tk,value) <$> mkProvenance tk

      (prov, name, value) <- case opt of
        B.NameAnnOption tk value -> mkEntry tk (B.Var value)
        B.InferAnnOption tk value -> mkEntry tk value
        B.TypeAnnOption tk expr -> mkEntry tk expr

      let nameTxt = name
      value' <- elabExpr value
      if Set.notMember nameTxt allowedNames
        then throwError $ InvalidAnnotationOption prov (tkSymbol token) nameTxt (Set.toList allowedNames)
        else case Map.lookup nameTxt found of
          Just {} -> throwError $ DuplicateAnnotationOption prov (tkSymbol token) nameTxt
          Nothing -> return $ Map.insert nameTxt value' found

validateEmptyOpts :: (MonadElab m, IsToken token) => token -> B.DeclAnnOpts -> m ()
validateEmptyOpts name opts = do _ <- validateOpts name mempty opts; return ()

elabParameterOptions :: (MonadElab m) => [B.DeclAnnOption] -> m V.DefAbstractSort
elabParameterOptions opts =
  V.ParameterDef <$> case mapMaybe getInferOption opts of
    [] -> return V.NonInferable
    (_, expr) : _ -> do
      expr' <- elabExpr expr
      case expr' of
        V.Builtin _ (V.BuiltinConstructor (V.LBool infer))
          | infer -> return V.Inferable
          | otherwise -> return V.NonInferable
        _ -> do
          throwError $ InvalidAnnotationOptionValue InferableOption expr'

elabPostulateOptions :: (MonadElab m) => B.TokPostulate -> [B.DeclAnnOption] -> m (B.Name, B.Expr, Maybe B.Expr, Maybe B.Expr)
elabPostulateOptions tokPostulate opts = do
  name <- case mapMaybe getNameOption opts of
    [] -> do
      p <- mkProvenance tokPostulate
      throwError $ MissingAnnotationOption p (tkSymbol tokPostulate) "name"
    (_, nameValue) : _ -> return nameValue

  let typeOpts = mapMaybe getTypeOption opts
  standardType <- case find (\(a, _b) -> tkSymbol a == "standard") typeOpts of
    Nothing -> do
      p <- mkProvenance tokPostulate
      throwError $ MissingAnnotationOption p (tkSymbol tokPostulate) "standard type"
    Just (_, standardType) -> return standardType

  let linearityType = snd <$> find (\(n, _) -> tkSymbol n == "linearity") typeOpts
  let polarityType = snd <$> find (\(n, _) -> tkSymbol n == "polarity") typeOpts
  return (name, standardType, linearityType, polarityType)

getNameOption :: B.DeclAnnOption -> Maybe (B.TokAnnNameOpt, B.Name)
getNameOption = \case
  B.NameAnnOption optTk name -> Just (optTk, name)
  _ -> Nothing

getInferOption :: B.DeclAnnOption -> Maybe (B.TokAnnInferOpt, B.Expr)
getInferOption = \case
  B.InferAnnOption optTk name -> Just (optTk, name)
  _ -> Nothing

getTypeOption :: B.DeclAnnOption -> Maybe (B.Name, B.Expr)
getTypeOption = \case
  B.TypeAnnOption optTk altType -> Just (optTk, altType)
  _ -> Nothing

--------------------------------------------------------------------------------
-- Full elaboration

elaborateDecl ::
  (MonadError ParseError m) =>
  ParseLocation ->
  PartiallyParsedDecl ->
  m (V.Decl V.Name V.Builtin)
elaborateDecl file decl = flip runReaderT file $ case decl of
  V.DefAbstract p n r t -> V.DefAbstract p n r <$> elabDeclType t
  V.DefFunction p n b t e -> V.DefFunction p n b <$> elabDeclType t <*> elabDeclBody e

elabDeclType ::
  (MonadElab m) =>
  UnparsedExpr ->
  m (V.Expr V.Name V.Builtin)
elabDeclType (UnparsedExpr expr) = elabExpr expr

elabDeclBody ::
  (MonadElab m) =>
  UnparsedExpr ->
  m (V.Expr V.Name V.Builtin)
elabDeclBody (UnparsedExpr expr) = case expr of
  B.Lam tk binders _ body -> do
    binders' <- traverse (elabNameBinder True) binders
    body' <- elabExpr body
    p <- mkProvenance tk
    return $ foldr (V.Lam p) body' binders'
  _ -> developerError "Invalid declaration body - no lambdas found"

elaborateExpr ::
  (MonadError ParseError m) =>
  ParseLocation ->
  UnparsedExpr ->
  m (V.Expr V.Name V.Builtin)
elaborateExpr file (UnparsedExpr expr) = runReaderT (elabExpr expr) file

elabExpr :: (MonadElab m) => B.Expr -> m (V.Expr V.Name V.Builtin)
elabExpr = \case
  B.Type t -> V.Universe <$> mkProvenance t <*> pure (V.UniverseLevel 0)
  B.Var n -> V.BoundVar <$> mkProvenance n <*> pure (tkSymbol n)
  B.Hole n -> V.mkHole <$> mkProvenance n <*> pure (tkSymbol n)
  B.Literal l -> elabLiteral l
  B.Fun t1 tk t2 -> op2 V.Pi tk (elabTypeBinder False t1) (elabExpr t2)
  B.VecLiteral tk1 es _tk2 -> elabVecLiteral tk1 es
  B.App e1 e2 -> elabApp e1 e2
  B.Let tk1 ds e -> elabLet tk1 ds e
  B.ForallT tk1 ns _tk2 t -> elabForallT tk1 ns t
  B.Lam tk1 ns _tk2 e -> elabLam tk1 ns e
  B.Forall tk1 ns _tk2 e -> elabQuantifier tk1 V.Forall ns e
  B.Exists tk1 ns _tk2 e -> elabQuantifier tk1 V.Exists ns e
  B.ForallIn tk1 ns e1 _tk2 e2 -> elabQuantifierIn tk1 V.Forall ns e1 e2
  B.ExistsIn tk1 ns e1 _tk2 e2 -> elabQuantifierIn tk1 V.Exists ns e1 e2
  B.Foreach tk1 ns _tk2 e -> elabForeach tk1 ns e
  B.Unit tk -> builtinType V.Unit tk []
  B.Bool tk -> builtinType V.Bool tk []
  B.Index tk -> builtinType V.Index tk []
  B.Nat tk -> builtinType V.Nat tk []
  B.Rat tk -> builtinType V.Rat tk []
  B.List tk -> builtinType V.List tk []
  B.Vector tk -> builtinType V.Vector tk []
  B.Nil tk -> constructor V.Nil tk []
  B.Cons e1 tk e2 -> constructor V.Cons tk [e1, e2]
  B.Indices tk -> builtinFunction V.Indices tk []
  B.Not tk e -> builtinFunction V.Not tk [e]
  B.Impl e1 tk e2 -> builtinFunction V.Implies tk [e1, e2]
  B.And e1 tk e2 -> builtinFunction V.And tk [e1, e2]
  B.Or e1 tk e2 -> builtinFunction V.Or tk [e1, e2]
  B.If tk1 e1 _ e2 _ e3 -> builtinFunction V.If tk1 [e1, e2, e3]
  B.Eq e1 tk e2 -> builtin (V.TypeClassOp $ V.EqualsTC V.Eq) tk [e1, e2]
  B.Neq e1 tk e2 -> builtin (V.TypeClassOp $ V.EqualsTC V.Neq) tk [e1, e2]
  B.Le e1 tk e2 -> elabOrder V.Le tk e1 e2
  B.Lt e1 tk e2 -> elabOrder V.Lt tk e1 e2
  B.Ge e1 tk e2 -> elabOrder V.Ge tk e1 e2
  B.Gt e1 tk e2 -> elabOrder V.Gt tk e1 e2
  B.Add e1 tk e2 -> builtin (V.TypeClassOp V.AddTC) tk [e1, e2]
  B.Sub e1 tk e2 -> builtin (V.TypeClassOp V.SubTC) tk [e1, e2]
  B.Mul e1 tk e2 -> builtin (V.TypeClassOp V.MulTC) tk [e1, e2]
  B.Div e1 tk e2 -> builtin (V.TypeClassOp V.DivTC) tk [e1, e2]
  B.Neg tk e -> builtin (V.TypeClassOp V.NegTC) tk [e]
  B.At e1 tk e2 -> builtinFunction V.At tk [e1, e2]
  B.Map tk -> builtin (V.TypeClassOp V.MapTC) tk []
  B.Fold tk -> builtin (V.TypeClassOp V.FoldTC) tk []
  B.ZipWith tk -> builtinFunction V.ZipWithVector tk []
  B.HasEq tk -> builtinTypeClass (V.HasEq V.Eq) tk []
  B.HasNotEq tk -> builtinTypeClass (V.HasEq V.Neq) tk []
  B.HasLeq tk -> builtinTypeClass (V.HasOrd V.Le) tk []
  B.HasAdd tk -> builtinTypeClass V.HasAdd tk []
  B.HasSub tk -> builtinTypeClass V.HasSub tk []
  B.HasMul tk -> builtinTypeClass V.HasMul tk []
  B.HasMap tk -> builtinTypeClass V.HasMap tk []
  B.HasFold tk -> builtinTypeClass V.HasFold tk []
  -- NOTE: we reverse the arguments to make it well-typed.
  B.Ann e tk t -> elabExpr (B.App (B.App (B.Var (B.Name (tkLocation tk, "typeAnn"))) (B.ExplicitArg t)) (B.ExplicitArg e))

elabArg :: (MonadElab m) => B.Arg -> m (V.Arg V.Name V.Builtin)
elabArg = \case
  B.ExplicitArg e -> mkArg V.Explicit <$> elabExpr e
  B.ImplicitArg e -> mkArg (V.Implicit False) <$> elabExpr e
  B.InstanceArg e -> mkArg (V.Instance False) <$> elabExpr e

elabName :: (MonadElab m) => B.Name -> m V.Identifier
elabName n = do
  modl <- getModule
  return $ V.Identifier modl $ tkSymbol n

elabBasicBinder :: (MonadElab m) => Bool -> B.BasicBinder -> m (V.Binder V.Name V.Builtin)
elabBasicBinder folded = \case
  B.ExplicitBinder m n _tk typ -> mkBinder folded (mkRelevance m) V.Explicit . These n =<< elabExpr typ
  B.ImplicitBinder m n _tk typ -> mkBinder folded (mkRelevance m) (V.Implicit False) . These n =<< elabExpr typ
  B.InstanceBinder m n _tk typ -> mkBinder folded (mkRelevance m) (V.Instance False) . These n =<< elabExpr typ

elabNameBinder :: (MonadElab m) => Bool -> B.NameBinder -> m (V.Binder V.Name V.Builtin)
elabNameBinder folded = \case
  B.ExplicitNameBinder m n -> mkBinder folded (mkRelevance m) V.Explicit (This n)
  B.ImplicitNameBinder m n -> mkBinder folded (mkRelevance m) (V.Implicit False) (This n)
  B.InstanceNameBinder m n -> mkBinder folded (mkRelevance m) (V.Instance False) (This n)
  B.BasicNameBinder b -> elabBasicBinder folded b

elabTypeBinder :: (MonadElab m) => Bool -> B.TypeBinder -> m (V.Binder V.Name V.Builtin)
elabTypeBinder folded = \case
  B.ExplicitTypeBinder t -> mkBinder folded V.Relevant V.Explicit . That =<< elabExpr t
  B.ImplicitTypeBinder t -> mkBinder folded V.Relevant (V.Implicit False) . That =<< elabExpr t
  B.InstanceTypeBinder t -> mkBinder folded V.Relevant (V.Instance False) . That =<< elabExpr t
  B.BasicTypeBinder b -> elabBasicBinder folded b

mkRelevance :: [B.Modality] -> V.Relevance
mkRelevance ms
  | null ms = V.Relevant
  | otherwise = V.Irrelevant

mkArg :: V.Visibility -> V.Expr V.Name V.Builtin -> V.Arg V.Name V.Builtin
mkArg v e = V.Arg (V.expandByArgVisibility v (V.provenanceOf e)) v V.Relevant e

mkBinder :: (MonadElab m) => V.BinderFoldingForm -> V.Relevance -> V.Visibility -> These B.Name (V.Expr V.Name V.Builtin) -> m (V.Binder V.Name V.Builtin)
mkBinder folded r v nameTyp = do
  (exprProv, form, typ) <- case nameTyp of
    This nameTk -> do
      p <- mkProvenance nameTk
      let name = tkSymbol nameTk
      let typ = V.mkHole p $ "typeOf[" <> name <> "]"
      let naming = V.OnlyName name
      return (p, naming, typ)
    That typ -> do
      let naming = V.OnlyType
      return (V.provenanceOf typ, naming, typ)
    These nameTk typ -> do
      nameProv <- mkProvenance nameTk
      let p = V.fillInProvenance ((nameProv :: V.Provenance) :| [V.provenanceOf typ])
      let name = tkSymbol nameTk
      let naming = V.NameAndType name
      return (p, naming, typ)

  let prov = V.expandByArgVisibility v exprProv
  let displayForm = V.BinderDisplayForm form folded
  return $ V.Binder prov displayForm v r typ

elabLetDecl :: (MonadElab m) => B.LetDecl -> m (V.Binder V.Name V.Builtin, V.Expr V.Name V.Builtin)
elabLetDecl (B.LDecl b e) = bitraverse (elabNameBinder False) elabExpr (b, e)

elabLiteral :: (MonadElab m) => B.Lit -> m (V.Expr V.Name V.Builtin)
elabLiteral = \case
  B.UnitLiteral -> return $ V.Builtin mempty $ V.BuiltinConstructor V.LUnit
  B.BoolLiteral t -> do
    p <- mkProvenance t
    let b = elabBoolLiteral t
    return $ V.Builtin p $ V.BuiltinConstructor $ V.LBool b
  B.NatLiteral t -> do
    p <- mkProvenance t
    let n = readNat (tkSymbol t)
    let fromNat = V.Builtin p (V.TypeClassOp V.FromNatTC)
    return $ app fromNat [V.Builtin p $ V.BuiltinConstructor $ V.LNat n]
  B.RatLiteral t -> do
    p <- mkProvenance t
    let r = readRat (tkSymbol t)
    let fromRat = V.Builtin p (V.TypeClassOp V.FromRatTC)
    return $ app fromRat [V.Builtin p $ V.BuiltinConstructor $ V.LRat r]

elabBoolLiteral :: B.Boolean -> Bool
elabBoolLiteral t = read (unpack $ tkSymbol t)

op2 ::
  (MonadElab m, V.HasProvenance a, V.HasProvenance b, IsToken token) =>
  (V.Provenance -> a -> b -> c) ->
  token ->
  m a ->
  m b ->
  m c
op2 mk t e1 e2 = do
  ce1 <- e1
  ce2 <- e2
  tProv <- mkProvenance t
  let p = V.fillInProvenance (tProv :| [V.provenanceOf ce1, V.provenanceOf ce2])
  return $ mk p ce1 ce2

builtin :: (MonadElab m, IsToken token) => V.Builtin -> token -> [B.Expr] -> m (V.Expr V.Name V.Builtin)
builtin b t args = do
  tProv <- mkProvenance t
  app (V.Builtin tProv b) <$> traverse elabExpr args

constructor :: (MonadElab m, IsToken token) => V.BuiltinConstructor -> token -> [B.Expr] -> m (V.Expr V.Name V.Builtin)
constructor b = builtin (V.BuiltinConstructor b)

builtinType :: (MonadElab m, IsToken token) => V.BuiltinType -> token -> [B.Expr] -> m (V.Expr V.Name V.Builtin)
builtinType b = builtin (V.BuiltinType b)

builtinTypeClass :: (MonadElab m, IsToken token) => V.TypeClass -> token -> [B.Expr] -> m (V.Expr V.Name V.Builtin)
builtinTypeClass b = builtin (V.TypeClass b)

builtinFunction :: (MonadElab m, IsToken token) => V.BuiltinFunction -> token -> [B.Expr] -> m (V.Expr V.Name V.Builtin)
builtinFunction b = builtin (V.BuiltinFunction b)

app :: V.Expr V.Name V.Builtin -> [V.Expr V.Name V.Builtin] -> V.Expr V.Name V.Builtin
app fun argExprs = V.normAppList fun args
  where
    args = fmap (mkArg V.Explicit) argExprs

elabVecLiteral :: (MonadElab m, IsToken token) => token -> [B.Expr] -> m (V.Expr V.Name V.Builtin)
elabVecLiteral tk xs = do
  let n = length xs
  p <- mkProvenance tk
  xs' <- traverse elabExpr xs
  let lit = app (V.Builtin p $ V.BuiltinConstructor $ V.LVec n) xs'
  return $ app (V.Builtin p (V.TypeClassOp V.FromVecTC)) [lit]

elabApp :: (MonadElab m) => B.Expr -> B.Arg -> m (V.Expr V.Name V.Builtin)
elabApp fun arg = do
  fun' <- elabExpr fun
  arg' <- elabArg arg
  return $ V.normAppList fun' [arg']

elabOrder :: (MonadElab m, IsToken token) => V.OrderOp -> token -> B.Expr -> B.Expr -> m (V.Expr V.Name V.Builtin)
elabOrder order tk e1 e2 = do
  let Tk tkDetails@(tkPos, _) = toToken tk
  let chainedOrder = case e1 of
        B.Le _ _ e -> Just (V.Le, e)
        B.Lt _ _ e -> Just (V.Lt, e)
        B.Ge _ _ e -> Just (V.Ge, e)
        B.Gt _ _ e -> Just (V.Gt, e)
        _ -> Nothing

  case chainedOrder of
    Nothing -> builtin (V.TypeClassOp $ V.OrderTC order) tk [e1, e2]
    Just (prevOrder, e)
      | not (V.chainable prevOrder order) -> do
          p <- mkProvenance tk
          throwError $ UnchainableOrders p prevOrder order
      | otherwise -> elabExpr $ B.And e1 (B.TokAnd (tkPos, "and")) $ case order of
          V.Le -> B.Le e (B.TokLe tkDetails) e2
          V.Lt -> B.Lt e (B.TokLt tkDetails) e2
          V.Ge -> B.Ge e (B.TokGe tkDetails) e2
          V.Gt -> B.Gt e (B.TokGt tkDetails) e2

-- | Unfolds a list of binders into a consecutative forall expressions
elabForallT :: (MonadElab m) => B.TokForallT -> [B.NameBinder] -> B.Expr -> m (V.Expr V.Name V.Builtin)
elabForallT tk binders body = do
  p <- mkProvenance tk
  binders' <- elabNamedBinders tk binders
  body' <- elabExpr body
  return $ foldr (V.Pi p) body' binders'

elabLam :: (MonadElab m) => B.TokLambda -> [B.NameBinder] -> B.Expr -> m (V.Expr V.Name V.Builtin)
elabLam tk binders body = do
  p <- mkProvenance tk
  binders' <- elabNamedBinders tk binders
  body' <- elabExpr body
  return $ foldr (V.Lam p) body' binders'

elabQuantifier ::
  (MonadElab m, IsToken token) =>
  token ->
  V.Quantifier ->
  [B.NameBinder] ->
  B.Expr ->
  m (V.Expr V.Name V.Builtin)
elabQuantifier tk q binders body = do
  p <- mkProvenance tk
  let quantBuiltin = V.Builtin p $ V.TypeClassOp $ V.QuantifierTC q

  binders' <- elabNamedBinders tk binders
  body' <- elabExpr body

  let mkQuantifier binder newBody =
        V.normAppList
          quantBuiltin
          [ mkArg V.Explicit (V.Lam (V.provenanceOf binder) binder newBody)
          ]

  return $ foldr mkQuantifier body' binders'

elabQuantifierIn ::
  (MonadElab m, IsToken token) =>
  token ->
  V.Quantifier ->
  B.NameBinder ->
  B.Expr ->
  B.Expr ->
  m (V.Expr V.Name V.Builtin)
elabQuantifierIn tk q binder container body = do
  p <- mkProvenance tk
  let quantBuiltin = V.BoundVar p $ case q of
        V.Forall -> "forallIn"
        V.Exists -> "existsIn"

  binder' <- elabNameBinder False binder
  container' <- elabExpr container
  body' <- elabExpr body

  let p' = V.provenanceOf binder'
  return $
    V.normAppList
      quantBuiltin
      [ mkArg V.Explicit (V.Lam p' binder' body'),
        mkArg V.Explicit container'
      ]

elabForeach ::
  (MonadElab m, IsToken token) =>
  token ->
  B.NameBinder ->
  B.Expr ->
  m (V.Expr V.Name V.Builtin)
elabForeach tk binder body = do
  p <- mkProvenance tk
  let foreachBuiltin = V.BoundVar p "foreachIndex"

  binder' <- elabNameBinder False binder
  body' <- elabExpr body

  let p' = V.provenanceOf binder'
  return $
    V.normAppList
      foreachBuiltin
      [ mkArg V.Explicit (V.mkHole p "n"),
        mkArg V.Explicit (V.Lam p' binder' body')
      ]

elabLet :: (MonadElab m) => B.TokLet -> [B.LetDecl] -> B.Expr -> m (V.Expr V.Name V.Builtin)
elabLet tk decls body = do
  p <- mkProvenance tk
  decls' <- traverse elabLetDecl decls
  body' <- elabExpr body
  return $ foldr (insertLet p) body' decls'
  where
    insertLet :: V.Provenance -> (V.Binder V.Name V.Builtin, V.Expr V.Name V.Builtin) -> V.Expr V.Name V.Builtin -> V.Expr V.Name V.Builtin
    insertLet p (binder, bound) = V.Let p bound binder

elabNamedBinders :: (MonadElab m, IsToken token) => token -> [B.NameBinder] -> m (NonEmpty (V.Binder V.Name V.Builtin))
elabNamedBinders tk binders = case binders of
  [] -> do
    p <- mkProvenance tk
    throwError $ MissingVariables p (tkSymbol tk)
  (d : ds) -> do
    d' <- elabNameBinder False d
    ds' <- traverse (elabNameBinder True) ds
    return (d' :| ds')

-- | Constructs a pi type filled with an appropriate number of holes for
--  a definition which has no accompanying type.
constructUnknownDefType :: B.Name -> [B.NameBinder] -> B.Expr
constructUnknownDefType n binders
  | null binders = returnType
  | otherwise = B.ForallT tokForallT binders tokDot returnType
  where
    returnType :: B.Expr
    returnType = B.Hole $ mkToken B.HoleToken (typifyName (tkSymbol n))

    typifyName :: Text -> Text
    typifyName x = "typeOf_" <> x
