module Vehicle.Compile.Type.WeakHeadNormalForm
  ( WHNFable(..)
  , whnfWithMetas
  ) where

import Control.Monad
import Control.Monad.Reader (MonadReader, runReaderT, ask)
import Control.Monad.State (MonadState(..))
import Data.Map qualified as Map (lookup)
import Data.List.NonEmpty (NonEmpty(..))

import Vehicle.Compile.Prelude
import Vehicle.Compile.Type.Meta
import Vehicle.Compile.Error

--------------------------------------------------------------------------------
-- Normalisation to weak-head normal form

-- This only deals with normalisation required during type-checking.
-- For full normalisation including builtins see `Vehicle.Compile.Normalise`.

norm :: MonadReader VariableCtx m => CheckedExpr -> m CheckedExpr
norm (TensorType _ tElem (SeqExpr _ _ _ [])) = norm tElem
norm e@(App ann fun (arg :| args))      = do
  normFun  <- norm fun
  case normFun of
    Lam _ _ body -> do
      nfBody <- norm (argExpr arg `substInto` body)
      return $ normAppList ann nfBody args
    _            -> return e
norm e@(Var _ v) = do
  VariableCtx{..} <- ask
  case v of
    Free ident -> case Map.lookup ident declCtx of
      Just (_, Just res) -> return res
      _                  -> return e
    Bound index -> case boundCtx !!? index of
      Just (_, _, Just res) -> return res
      _                     -> return e

norm (Let _ bound _ body) = norm (bound `substInto` body)
norm (Ann _ body _)       = norm body
norm e                    = return e

--------------------------------------------------------------------------------
-- WHNF combined with meta variable subsitution

whnfWithMetas :: MonadState MetaCtx m => VariableCtx -> CheckedExpr -> m CheckedExpr
whnfWithMetas ctx e = do
  subst <- getMetaSubstitution
  let e' = substMetas subst e
  runReaderT (norm e') ctx

--------------------------------------------------------------------------------
-- Recursively go through a check program and convert all implicit argument
-- types to whnf. This is needed because we pattern match on implicit args to
-- do type-directed compilation.

class WHNFable a where
  convertImplicitArgsToWHNF :: MonadCompile m => a -> m a

instance WHNFable CheckedProg where
  convertImplicitArgsToWHNF p = runReaderT (whnfProg p) emptyVariableCtx

instance WHNFable CheckedExpr where
  convertImplicitArgsToWHNF e = runReaderT (whnfExpr e) emptyVariableCtx

whnfProg :: (MonadCompile m, MonadReader VariableCtx m) => CheckedProg -> m CheckedProg
whnfProg (Main ds) = Main <$> whnfDecls ds

whnfDecls :: (MonadCompile m, MonadReader VariableCtx m) => [CheckedDecl] -> m [CheckedDecl]
whnfDecls [] = return []
whnfDecls (d : ds) = do
  let ident = identifierOf d

  (decl, checkedDeclBody, checkedDeclType) <- case d of
    DefResource ann r _ t -> do
      t' <- whnfExpr t
      let checkedDecl = DefResource ann r ident t'
      return (checkedDecl, Nothing, t')

    DefFunction ann usage _ t body -> do
      t' <- whnfExpr t
      e' <- whnfExpr body
      let checkedDecl = DefFunction ann usage ident t' e'
      return (checkedDecl, Just e', t')

  decls <- addToDeclCtx ident checkedDeclType checkedDeclBody $ whnfDecls ds
  return $ decl : decls

whnfExpr :: (MonadCompile m, MonadReader VariableCtx m) => CheckedExpr -> m CheckedExpr
whnfExpr expr = do
  res <- case expr of
    Meta{} -> resolutionError currentPhase "Meta"
    Hole{} -> resolutionError currentPhase "Hole"

    Type{}     -> return expr
    Literal{}  -> return expr
    Builtin{}  -> return expr
    Ann{}      -> return expr
    PrimDict{} -> return expr
    Var{}      -> return expr

    Pi ann binder resultType -> Pi ann binder <$> whnfExpr resultType
    LSeq ann d es            -> LSeq ann d <$> traverse whnfExpr es
    App p fun args           -> App p <$> whnfExpr fun <*> traverse whnfArg args

    Let ann e1 binder e2 -> do
      -- Check the type of the bound expression against the provided type
      e1' <- whnfExpr e1
      e2' <- addToBoundCtx (nameOf binder) (typeOf binder) (Just e1') $ whnfExpr e2
      return (Let ann e1' binder e2')

    Lam ann binder body -> do
      body' <- addToBoundCtx (nameOf binder) (typeOf binder) Nothing $ whnfExpr body
      return $ Lam ann binder body'

  -- showInferExit res
  return res

whnfArg :: (MonadCompile m, MonadReader VariableCtx m) => CheckedArg -> m CheckedArg
whnfArg arg
  | visibilityOf arg == Implicit = traverseArgExpr (whnfExpr <=< norm) arg
  | otherwise = traverseArgExpr whnfExpr arg

currentPhase :: Doc ()
currentPhase = "normalisation of inserted implicit types"