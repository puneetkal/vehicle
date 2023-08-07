module Vehicle.Syntax.BNFC.Elaborate.Internal
  ( elab,
  )
where

import Control.Monad.Except (MonadError (..))
import Control.Monad.Reader (MonadReader (..))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric (readFloat)
import Prettyprinter (Pretty (..), (<+>))
import Vehicle.Syntax.AST qualified as V
import Vehicle.Syntax.AST.Name
import Vehicle.Syntax.AST.Provenance
import Vehicle.Syntax.AST.Relevance
import Vehicle.Syntax.AST.Visibility
import Vehicle.Syntax.BNFC.Utils
import Vehicle.Syntax.Builtin qualified as V
import Vehicle.Syntax.Internal.Abs as B
import Vehicle.Syntax.Parse.Error (ParseError (..))
import Vehicle.Syntax.Parse.Token (IsToken, Token (..), tkSymbol, toToken)
import Vehicle.Syntax.Prelude (developerError, readNat, readRat)

--------------------------------------------------------------------------------
-- Conversion from BNFC AST
--
-- We convert from the simple AST generated automatically by BNFC to our
-- more complicated internal version of the AST which allows us to annotate
-- terms with sort-dependent types.
--
-- While doing this, we
--
--   1) extract the positions from the tokens generated by BNFC and convert them
--   into `Provenance` annotations.
--
--   2) convert the builtin strings into `Builtin`s

class Elab vf vc where
  elab :: (MonadElab m) => vf -> m vc

instance Elab B.Prog (V.Prog V.Name V.Builtin) where
  elab (B.Main ds) = V.Main <$> traverse elab ds

instance Elab B.Decl (V.Decl V.Name V.Builtin) where
  elab = \case
    B.DeclNetw n t -> elabDefAbstract n t V.NetworkDef
    B.DeclData n t -> elabDefAbstract n t V.DatasetDef
    B.DeclParam n t -> elabDefAbstract n t (V.ParameterDef V.NonInferable)
    B.DeclImplParam n t -> elabDefAbstract n t (V.ParameterDef V.Inferable)
    B.DeclPost n t -> elabDefAbstract n t V.PostulateDef
    B.DefFun n t e -> V.DefFunction <$> mkProvenance n <*> elab n <*> pure mempty <*> elab t <*> elab e

elabDefAbstract :: (MonadElab m) => NameToken -> B.Expr -> V.DefAbstractSort -> m (V.Decl V.Name V.Builtin)
elabDefAbstract n t r = V.DefAbstract <$> mkProvenance n <*> elab n <*> pure r <*> elab t

instance Elab B.Expr (V.Expr V.Name V.Builtin) where
  elab = \case
    B.Type l -> convType l
    B.Hole name -> V.Hole <$> mkProvenance name <*> pure (tkSymbol name)
    B.Ann term typ -> op2 V.Ann <$> elab term <*> elab typ
    B.Pi binder expr -> op2 V.Pi <$> elab binder <*> elab expr
    B.Lam binder e -> op2 V.Lam <$> elab binder <*> elab e
    B.Let binder e1 e2 -> op3 V.Let <$> elab e1 <*> elab binder <*> elab e2
    B.LVec es -> elabVec <$> traverse elab es
    B.Builtin c -> V.Builtin <$> mkProvenance c <*> lookupBuiltin c
    B.Var n -> V.BoundVar <$> mkProvenance n <*> pure (tkSymbol n)
    B.App fun arg -> do
      fun' <- elab fun
      arg' <- elab arg
      let p = fillInProvenance (provenanceOf fun' :| [provenanceOf arg'])
      return $ V.App p fun' (arg' :| [])

instance Elab B.Binder (V.Binder V.Name V.Builtin) where
  elab = \case
    B.RelevantExplicitBinder n e -> mkBinder n Explicit Relevant e
    B.RelevantImplicitBinder n e -> mkBinder n (Implicit False) Relevant e
    B.RelevantInstanceBinder n e -> mkBinder n (Instance False) Relevant e
    B.IrrelevantExplicitBinder n e -> mkBinder n Explicit Irrelevant e
    B.IrrelevantImplicitBinder n e -> mkBinder n (Implicit False) Irrelevant e
    B.IrrelevantInstanceBinder n e -> mkBinder n (Instance False) Irrelevant e
    where
      mkBinder :: (MonadElab m) => B.NameToken -> V.Visibility -> V.Relevance -> B.Expr -> m (V.Binder V.Name V.Builtin)
      mkBinder n v r e = do
        let form = V.BinderDisplayForm (V.NameAndType (tkSymbol n)) False
        p <- mkProvenance n
        V.Binder p form v r <$> elab e

instance Elab B.Arg (V.Arg V.Name V.Builtin) where
  elab = \case
    B.RelevantExplicitArg e -> mkArg Explicit Relevant <$> elab e
    B.RelevantImplicitArg e -> mkArg (Implicit False) Relevant <$> elab e
    B.RelevantInstanceArg e -> mkArg (Instance False) Relevant <$> elab e
    B.IrrelevantExplicitArg e -> mkArg Explicit Irrelevant <$> elab e
    B.IrrelevantImplicitArg e -> mkArg (Implicit False) Irrelevant <$> elab e
    B.IrrelevantInstanceArg e -> mkArg (Instance False) Irrelevant <$> elab e
    where
      mkArg :: V.Visibility -> V.Relevance -> V.Expr V.Name V.Builtin -> V.Arg V.Name V.Builtin
      mkArg v r e = V.Arg (expandByArgVisibility v (provenanceOf e)) v r e

instance Elab B.Lit V.BuiltinConstructor where
  elab = \case
    B.UnitLiteral -> return V.LUnit
    B.BoolLiteral b -> return $ V.LBool (read (Text.unpack $ tkSymbol b))
    B.RatLiteral r -> return $ V.LRat (readRat (tkSymbol r))
    B.NatLiteral n -> return $ V.LNat (readNat (tkSymbol n))

instance Elab B.NameToken V.Identifier where
  elab n = do
    mod <- ask
    return $ Identifier mod $ tkSymbol n

lookupBuiltin :: (MonadElab m) => B.BuiltinToken -> m V.Builtin
lookupBuiltin (BuiltinToken tk) = case V.builtinFromSymbol (tkSymbol tk) of
  Just v -> return v
  Nothing -> do
    let token = toToken tk
    p <- mkProvenance token
    throwError $ UnknownBuiltin p (tkSymbol token)

op1 ::
  (V.HasProvenance a) =>
  (V.Provenance -> a -> b) ->
  a ->
  b
op1 mk t = mk (provenanceOf t) t

op2 ::
  (V.HasProvenance a, V.HasProvenance b) =>
  (V.Provenance -> a -> b -> c) ->
  a ->
  b ->
  c
op2 mk t1 t2 = mk (provenanceOf t1 <> provenanceOf t2) t1 t2

op3 ::
  (V.HasProvenance a, V.HasProvenance b, V.HasProvenance c) =>
  (V.Provenance -> a -> b -> c -> d) ->
  a ->
  b ->
  c ->
  d
op3 mk t1 t2 t3 = mk (provenanceOf t1 <> provenanceOf t2 <> provenanceOf t3) t1 t2 t3

elabVec :: [V.Expr V.Name V.Builtin] -> V.Expr V.Name V.Builtin
elabVec xs = do
  let vecConstructor = V.Builtin mempty (V.BuiltinConstructor $ V.LVec (length xs))
  V.normAppList mempty vecConstructor (V.RelevantExplicitArg mempty <$> xs)

-- | Elabs the type token into a Type expression.
-- Doesn't run in the monad as if something goes wrong with this, we've got
-- the grammar wrong.
convType :: (MonadElab m) => TypeToken -> m (V.Expr V.Name V.Builtin)
convType tk = case Text.unpack (tkSymbol tk) of
  ('T' : 'y' : 'p' : 'e' : l) -> do
    p <- mkProvenance tk
    return $ V.Universe p (V.UniverseLevel (read l))
  t -> developerError $ "Malformed type token" <+> pretty t
