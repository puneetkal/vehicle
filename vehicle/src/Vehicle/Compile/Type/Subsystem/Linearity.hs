{-# OPTIONS_GHC -Wno-orphans #-}

module Vehicle.Compile.Type.Subsystem.Linearity
  ( module Core,
  )
where

import Vehicle.Compile.Error (MonadCompile, compilerDeveloperError)
import Vehicle.Compile.Prelude
import Vehicle.Compile.Print
import Vehicle.Compile.Type.Core
import Vehicle.Compile.Type.Monad
import Vehicle.Compile.Type.Monad.Class (freshMeta)
import Vehicle.Compile.Type.Subsystem.InputOutputInsertion
import Vehicle.Compile.Type.Subsystem.Linearity.AnnotationRestrictions (assertConstantLinearity, checkNetworkType)
import Vehicle.Compile.Type.Subsystem.Linearity.Core as Core
import Vehicle.Compile.Type.Subsystem.Linearity.LinearitySolver
import Vehicle.Compile.Type.Subsystem.Linearity.Type
import Vehicle.Expr.DeBruijn
import Vehicle.Expr.Normalised
import Vehicle.Syntax.Builtin hiding (Builtin (..))
import Vehicle.Syntax.Builtin qualified as S

instance PrintableBuiltin LinearityBuiltin where
  convertBuiltin = convertFromLinearityTypes

convertFromLinearityTypes :: Provenance -> LinearityBuiltin -> Expr var S.Builtin
convertFromLinearityTypes p = \case
  BuiltinConstructor c -> Builtin p (S.BuiltinConstructor c)
  BuiltinFunction f -> Builtin p (S.BuiltinFunction f)
  b -> FreeVar p $ Identifier StdLib (layoutAsText $ pretty b)

instance TypableBuiltin LinearityBuiltin where
  convertFromStandardTypes = convertToLinearityTypes
  useDependentMetas _ = False
  typeBuiltin = typeLinearityBuiltin
  restrictNetworkType = checkNetworkType
  restrictDatasetType = assertConstantLinearity
  restrictParameterType = const assertConstantLinearity
  restrictPropertyType _ _ = return ()
  handleTypingError = handleLinearityTypingError
  solveInstance = solveLinearityConstraint
  addAuxiliaryInputOutputConstraints = addFunctionAuxiliaryInputOutputConstraints (LinearityRelation . FunctionLinearity)
  generateDefaultConstraint = const $ return False

handleLinearityTypingError :: (MonadCompile m) => TypingError LinearityBuiltin -> m a
handleLinearityTypingError b =
  compilerDeveloperError $ "Linearity type system should not be throwing error:" <+> pretty b

freshLinearityMeta :: (MonadTypeChecker LinearityBuiltin m) => Provenance -> m (GluedExpr LinearityBuiltin)
freshLinearityMeta p = snd <$> freshMeta p (TypeUniverse p 0) mempty

convertToLinearityTypes ::
  forall m.
  (MonadTypeChecker LinearityBuiltin m) =>
  BuiltinUpdate m Ix S.Builtin LinearityBuiltin
convertToLinearityTypes p1 p2 b args = case b of
  S.BuiltinFunction f -> return $ normAppList p1 (Builtin p2 (BuiltinFunction f)) args
  S.BuiltinConstructor c -> return $ normAppList p1 (Builtin p2 (BuiltinConstructor c)) args
  S.BuiltinType s -> case s of
    Unit -> return $ Builtin p2 $ Linearity Constant
    Bool -> unnormalised <$> freshLinearityMeta p2
    Index -> unnormalised <$> freshLinearityMeta p2
    Nat -> unnormalised <$> freshLinearityMeta p2
    Int -> unnormalised <$> freshLinearityMeta p2
    Rat -> unnormalised <$> freshLinearityMeta p2
    List -> case args of
      [tElem] -> return $ argExpr tElem
      _ -> monomorphisationError "List"
    Vector -> case args of
      [tElem] -> return $ argExpr tElem
      _ -> monomorphisationError "Vector"
  S.TypeClass {} -> monomorphisationError "TypeClass"
  S.TypeClassOp {} -> monomorphisationError "TypeClassOp"
  S.NatInDomainConstraint -> monomorphisationError "IndexConstraints"
  where
    monomorphisationError :: Doc () -> m a
    monomorphisationError name =
      compilerDeveloperError $
        "Monomorphisation should have got rid of" <+> squotes name <+> "s but found" <+> prettyVerbose args
