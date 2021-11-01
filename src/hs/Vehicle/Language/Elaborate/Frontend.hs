{-# OPTIONS_GHC -Wno-orphans #-}

module Vehicle.Language.Elaborate.Frontend
  ( runElab
  ) where

import Control.Monad.Except (MonadError, throwError)
import Data.List.NonEmpty (NonEmpty(..))
import Data.Foldable (fold)
import Data.List.NonEmpty qualified as NonEmpty (groupBy1, head, toList)

import Vehicle.Frontend.Abs qualified as B

import Vehicle.Language.AST qualified as V
import Vehicle.Prelude

runElab :: (MonadLogger m, MonadError ElabError m) => B.Prog -> m V.InputProg
runElab = elab

--------------------------------------------------------------------------------
-- Errors

data ElabError
  = MissingDefFunType    Provenance Symbol
  | MissingDefFunExpr    Provenance Symbol
  | DuplicateName        (NonEmpty Provenance) Symbol
  | MissingVariables     Provenance Symbol

instance MeaningfulError ElabError where
  details (MissingDefFunType p name) = UError $ UserError
    { problem    = "missing type for the declaration" <+> squotes (pretty name)
    , provenance = p
    , fix        = "add a type for the declaration, e.g."
                   <> line <> line
                   <> "addOne :: Int -> Int    <-----   type declaration" <> line
                   <> "addOne x = x + 1"
    }

  details (MissingDefFunExpr p name) = UError $ UserError
    { problem    = "missing definition for the declaration" <+> squotes (pretty name)
    , provenance = p
    , fix        = "add a definition for the declaration, e.g."
                   <> line <> line
                   <> "addOne :: Int -> Int" <> line
                   <> "addOne x = x + 1     <-----   declaration definition"
    }

  details (DuplicateName p name) = UError $ UserError
    { problem    = "multiple definitions found with the name" <+> squotes (pretty name)
    , provenance = fold p
    , fix        = "remove or rename the duplicate definitions"
    }

  details (MissingVariables p symbol) = UError $ UserError
    { problem    = "expected at least one variable name after" <+> squotes (pretty symbol)
    , provenance = p
    , fix        = "add one or more names after" <+> squotes (pretty symbol)
    }

--------------------------------------------------------------------------------
-- Conversion from BNFC AST
--
-- We convert from the simple AST generated automatically by BNFC to our
-- more complicated internal version of the AST which allows us to annotate
-- terms with sort-dependent types.
--
-- While doing this we:
--  1. extract the positions from the tokens generated by BNFC and convert them
--     into `Provenance` annotations.
--  2. combine function types and expressions into a single AST node

-- | Constraint for the monad stack used by the elaborator.
type MonadElab m = MonadError ElabError m

-- * Provenance

-- | A slightly shorter name for `tkProvenance`
tkProv :: IsToken a => a -> Provenance
tkProv = tkProvenance

-- * Elaboration

class Elab vf vc where
  elab :: MonadElab m => vf -> m vc

instance Elab B.Arg V.InputArg where
  elab (B.ExplicitArg e) = V.Arg Explicit <$> elab e
  elab (B.ImplicitArg e) = V.Arg Implicit <$> elab e
  elab (B.InstanceArg _) = developerError "User specified type classes not yet supported"

instance Elab B.Name V.Identifier where
  elab n = return $ V.Identifier $ tkSymbol n

instance Elab B.Binder V.InputBinder where
  elab = let name = V.User . tkSymbol in \case
    B.ExplicitBinder    n         -> return $ V.Binder (tkProv n) Explicit (name n) (V.Hole (tkProv n) ("_"))
    B.ImplicitBinder    n         -> return $ V.Binder (tkProv n) Implicit (name n) (V.Hole (tkProv n) ("_"))
    B.ExplicitBinderAnn n _tk typ -> V.Binder (tkProv n) Explicit (name n) <$> elab typ
    B.ImplicitBinderAnn n _tk typ -> V.Binder (tkProv n) Implicit (name n) <$> elab typ

instance Elab B.Lit V.InputExpr where
  elab = \case
    B.LitTrue  p -> return $ V.LitBool (tkProv p) True
    B.LitFalse p -> return $ V.LitBool (tkProv p) False
    B.LitReal  x -> return $ V.LitReal mempty x
    B.LitInt   n -> return $ if n >= 0
      then V.LitNat mempty (fromIntegral n)
      else V.LitInt mempty (fromIntegral n)

instance Elab B.TypeClass V.InputExpr where
  elab = \case
    B.TCEq    tk e1 e2 -> builtin V.HasEq          (tkProv tk) [e1, e2]
    B.TCOrd   tk e1 e2 -> builtin V.HasOrd         (tkProv tk) [e1, e2]
    B.TCCont  tk e1 e2 -> builtin V.IsContainer    (tkProv tk) [e1, e2]
    B.TCTruth tk e     -> builtin V.IsTruth        (tkProv tk) [e]
    B.TCQuant tk e     -> builtin V.IsQuantifiable (tkProv tk) [e]
    B.TCNat   tk e     -> builtin V.IsNatural      (tkProv tk) [e]
    B.TCInt   tk e     -> builtin V.IsIntegral     (tkProv tk) [e]
    B.TCRat   tk e     -> builtin V.IsRational     (tkProv tk) [e]
    B.TCReal  tk e     -> builtin V.IsReal         (tkProv tk) [e]

instance Elab B.Expr V.InputExpr where
  elab = \case
    B.Type l                  -> return $ V.Type (fromIntegral l)
    B.Var  n                  -> return $ V.Var  (tkProv n) (V.User $ tkSymbol n)
    B.Hole n                  -> return $ V.Hole (tkProv n) (tkSymbol n)
    B.Literal l               -> elab l
    B.TypeC   tc              -> elab tc

    B.Ann e tk t              -> op2 V.Ann (tkProv tk) (elab e) (elab t)
    B.Fun t1 tk t2            -> op2 V.Pi  (tkProv tk) (elabFunInputType t1) (elab t2)
    B.Seq tk1 es _tk2         -> op1 V.Seq (tkProv tk1) (traverse elab es)

    B.App e1 e2               -> convApp e1 e2
    -- It is really bad not to have provenance for let tokens here, see issue #6
    B.Let ds e                -> convLetDecls mempty ds e
    B.Forall tk1 ns _tk2 t    -> do checkNonEmpty tk1 ns; convBinders (tkProv tk1) V.Pi ns t
    B.Lam tk1 ns _tk2 e       -> do checkNonEmpty tk1 ns; convBinders (tkProv tk1) V.Lam ns e

    B.Bool tk                 -> builtin V.Bool   (tkProv tk) []
    B.Prop tk                 -> builtin V.Prop   (tkProv tk) []
    B.Real tk                 -> builtin V.Real   (tkProv tk) []
    B.Int tk                  -> builtin V.Int    (tkProv tk) []
    B.Nat tk                  -> builtin V.Nat    (tkProv tk) []
    B.List tk t               -> builtin V.List   (tkProv tk) [t]
    B.Tensor tk t1 t2         -> builtin V.Tensor (tkProv tk) [t1, t2]

    B.If tk1 e1 _ e2 _ e3     -> builtin V.If   (tkProv tk1)[e1, e2, e3]
    B.Impl e1 tk e2           -> builtin V.Impl (tkProv tk) [e1, e2]
    B.And e1 tk e2            -> builtin V.And  (tkProv tk) [e1, e2]
    B.Or e1 tk e2             -> builtin V.Or   (tkProv tk) [e1, e2]
    B.Not tk e                -> builtin V.Not  (tkProv tk) [e]

    B.Eq e1 tk e2             -> builtin V.Eq           (tkProv tk) [e1, e2]
    B.Neq e1 tk e2            -> builtin V.Neq          (tkProv tk) [e1, e2]
    B.Le e1 tk e2             -> builtin (V.Order V.Le) (tkProv tk) [e1, e2]
    B.Lt e1 tk e2             -> builtin (V.Order V.Lt) (tkProv tk) [e1, e2]
    B.Ge e1 tk e2             -> builtin (V.Order V.Ge) (tkProv tk) [e1, e2]
    B.Gt e1 tk e2             -> builtin (V.Order V.Gt) (tkProv tk) [e1, e2]

    B.Mul e1 tk e2            -> builtin V.Mul (tkProv tk) [e1, e2]
    B.Div e1 tk e2            -> builtin V.Div (tkProv tk) [e1, e2]
    B.Add e1 tk e2            -> builtin V.Add (tkProv tk) [e1, e2]
    B.Sub e1 tk e2            -> builtin V.Sub (tkProv tk) [e1, e2]
    B.Neg tk e                -> builtin V.Neg (tkProv tk) [e]

    B.Cons e1 tk e2           -> builtin V.Cons (tkProv tk) [e1, e2]
    B.At e1 tk e2             -> builtin V.At   (tkProv tk) [e1, e2]
    B.Map tk e1 e2            -> builtin V.Map  (tkProv tk) [e1, e2]
    B.Fold tk e1 e2 e3        -> builtin V.Fold (tkProv tk) [e1, e2, e3]

    B.Every   tk1 ns    _tk2 e  -> do checkNonEmpty tk1 ns; convQuantifier (tkProv tk1) V.All ns e
    B.Some    tk1 ns    _tk2 e  -> do checkNonEmpty tk1 ns; convQuantifier (tkProv tk1) V.Any ns e
    B.EveryIn tk1 ns e1 _tk2 e2 -> convQuantifierIn (tkProv tk1) V.All ns e1 e2
    B.SomeIn  tk1 ns e1 _tk2 e2 -> convQuantifierIn (tkProv tk1) V.Any ns e1 e2

-- |Elaborate declarations.
instance Elab (NonEmpty B.Decl) V.InputDecl where
  elab = \case
    -- Elaborate a network declaration.
    (B.DeclNetw n _tk t :| []) -> V.DeclNetw (tkProv n) <$> elab n <*> elab t

    -- Elaborate a dataset declaration.
    (B.DeclData n _tk t :| []) -> V.DeclData (tkProv n) <$> elab n <*> elab t

    -- Elaborate a type definition.
    (B.DefType n ns e :| []) -> do
      t' <- foldr (\b -> V.Pi (prov b) b) V.Type0 <$> traverse elab ns
      e' <- convBinders (tkProv n) V.Lam ns e
      return $ V.DefFun (tkProv n) (V.Identifier $ tkSymbol n) t' e'

    -- Elaborate a function definition.
    (B.DefFunType n1 _tk t  :| [B.DefFunExpr n2 ns e]) ->
      V.DefFun (tkProv n1) <$> elab n1 <*> elab t <*> convBinders (tkProv n2) V.Lam ns e

    -- Why did you write the signature AFTER the function?
    (e1@B.DefFunExpr {} :| [e2@B.DefFunType {}]) ->
      elab (e2 :| [e1])

    -- Missing type or expression declaration.
    (B.DefFunType n _tk _t :| []) ->
      throwError $ MissingDefFunExpr (tkProv n) (tkSymbol n)

    (B.DefFunExpr n _ns _e :| []) ->
      throwError $ MissingDefFunType (tkProv n) (tkSymbol n)

    -- Multiple type of expression declarations with the same n.
    ds ->
      throwError $ DuplicateName provs symbol
        where
          symbol = tkSymbol $ declName $ NonEmpty.head ds
          provs  = fmap (tkProv . declName) ds

-- |Elaborate programs.
instance Elab B.Prog V.InputProg where
  elab (B.Main decls) = V.Main <$> groupDecls decls

op1 :: (MonadElab m, HasProvenance a)
    => (Provenance -> a -> b)
    -> Provenance -> m a -> m b
op1 mk p t = do
  ct <- t
  return $ mk (p <> prov ct) ct

op2 :: (MonadElab m, HasProvenance a, HasProvenance b)
    => (Provenance -> a -> b -> c)
    -> Provenance -> m a -> m b -> m c
op2 mk p t1 t2 = do
  ct1 <- t1
  ct2 <- t2
  return $ mk (p <> prov ct1 <> prov ct2) ct1 ct2

builtin :: MonadElab m => V.Builtin -> Provenance -> [B.Expr] -> m V.InputExpr
builtin b ann args = builtin' b ann <$> traverse elab args

builtin' :: V.Builtin -> Provenance -> [V.InputExpr] -> V.InputExpr
builtin' b p args = V.normAppList p' (V.Builtin p b) (fmap (V.Arg Explicit) args)
  where p' = fillInProvenance (p : map prov args)

elabFunInputType :: MonadElab m => B.Expr -> m V.InputBinder
elabFunInputType t = do
  t' <- elab t
  return $ V.Binder (prov t') Explicit V.Machine t'

convApp :: MonadElab m => B.Expr -> B.Arg -> m V.InputExpr
convApp fun arg = do
  fun' <- elab fun
  arg' <- elab arg
  let p = fillInProvenance [prov fun', prov arg']
  return $ V.normAppList p fun' [arg']

-- |Elaborate a let binding with /multiple/ bindings to a series of let
--  bindings with a single binding each.
convLetDecls :: MonadElab m => Provenance -> [B.LetDecl] -> B.Expr -> m V.InputExpr
convLetDecls p ds body = do
  result <- foldr elabLetDecl (elab body) ds
  checkNonEmpty' (prov result) "let" ds
  return result
  where
    elabLetDecl :: MonadElab m => B.LetDecl -> m V.InputExpr -> m V.InputExpr
    elabLetDecl (B.LDecl binder e) res = V.Let p <$> elab e <*> elab binder <*> res

convQuantifier :: MonadElab m => Provenance -> V.Quantifier -> [B.Binder] -> B.Expr -> m V.InputExpr
convQuantifier p q = convBinders p (\_ b e -> builtin' (V.Quant q) p [V.Lam p b e])

convQuantifierIn :: MonadElab m => Provenance -> V.Quantifier -> [B.Binder] -> B.Expr -> B.Expr -> m V.InputExpr
convQuantifierIn p q binders container body = do
  container' <- elab container
  convBinders p (\_ b e -> builtin' (V.QuantIn q) p [V.Lam p b e, container']) binders body

-- |Takes a list of declarations, and groups type and expression
--  declarations by their name.
groupDecls :: MonadElab m => [B.Decl] -> m [V.InputDecl]
groupDecls []       = return []
groupDecls (d : ds) = NonEmpty.toList <$> traverse elab (NonEmpty.groupBy1 cond (d :| ds))
  where
    cond :: B.Decl -> B.Decl -> Bool
    cond d1 d2 = isDefFun d1 && isDefFun d2 && tkSymbol (declName d1) == tkSymbol (declName d2)

    isDefFun :: B.Decl -> Bool
    isDefFun (B.DefFunType _name _args _exp) = True
    isDefFun (B.DefFunExpr _ann _name _typ)  = True
    isDefFun _                               = False

convBinders :: MonadElab m
            => Provenance
            -> (Provenance -> V.InputBinder -> V.InputExpr -> V.InputExpr)
            -> [B.Binder]
            -> B.Expr
            -> m V.InputExpr
convBinders p fn binders body = do
  body' <- elab body
  let p' = fillInProvenance [p, prov body']
  foldr (fn p') body' <$> traverse elab binders

-- |Get the name for any declaration.
declName :: B.Decl -> B.Name
declName (B.DeclNetw   n _ _) = n
declName (B.DeclData   n _ _) = n
declName (B.DefType    n _ _) = n
declName (B.DefFunType n _ _) = n
declName (B.DefFunExpr n _ _) = n

checkNonEmpty :: (MonadElab m, IsToken token) => token -> [a] -> m ()
checkNonEmpty tk = checkNonEmpty' (tkProv tk) (tkSymbol tk)

checkNonEmpty' :: (MonadElab m) => Provenance -> Symbol -> [a] -> m ()
checkNonEmpty' p s []      = throwError $ MissingVariables p s
checkNonEmpty' _ _ (_ : _) = return ()