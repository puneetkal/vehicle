module Vehicle.Compile.ExpandResources.Network
  ( checkNetwork,
  )
where

import Control.Monad.Except (MonadError (..))
import Data.Map qualified as Map
import Vehicle.Compile.Error
import Vehicle.Compile.ExpandResources.Core
import Vehicle.Compile.Prelude
import Vehicle.Compile.Print
import Vehicle.Compile.Resource
import Vehicle.Data.Builtin.Standard
import Vehicle.Data.Expr.Interface
import Vehicle.Data.Expr.Normalised
import Vehicle.Verify.Core (NetworkContextInfo (..))

--------------------------------------------------------------------------------
-- Network typing

checkNetwork ::
  forall m.
  (MonadReadResources m) =>
  NetworkLocations ->
  DeclProvenance ->
  GluedType Builtin ->
  m NetworkContextInfo
checkNetwork networkLocations decl@(ident, _) networkType = do
  case Map.lookup (identifierName ident) networkLocations of
    Nothing -> throwError $ ResourceNotProvided decl Network
    Just location -> do
      typ <- getNetworkType decl networkType
      return $ NetworkContextInfo location typ

-- | Decomposes the Pi types in a network type signature, checking that the
--  binders are explicit and their types are equal.
getNetworkType ::
  forall m.
  (MonadReadResources m) =>
  DeclProvenance ->
  GluedType Builtin ->
  m NetworkType
getNetworkType decl networkType = case normalised networkType of
  VPi binder result
    | visibilityOf binder /= Explicit -> typingError
    | otherwise -> do
        inputDetails <- getTensorType Input (typeOf binder)
        outputDetails <- getTensorType Output result
        let networkDetails = NetworkType inputDetails outputDetails
        return networkDetails
  _ -> compilerDeveloperError "Should have caught the fact that the network type is not a function during type-checking"
  where
    getTensorType :: InputOrOutput -> WHNFType Builtin -> m NetworkTensorType
    getTensorType io tensorType = do
      (baseType, dims) <- go True tensorType
      return $ NetworkTensorType baseType dims
      where
        go :: Bool -> WHNFType Builtin -> m (NetworkBaseType, TensorShape)
        go topLevel = \case
          IVectorType _ tElem dim -> do
            d <- getTensorDimension io dim
            (baseType, ds) <- go False tElem
            return (baseType, d : ds)
          t ->
            if topLevel
              then typingError
              else do
                elemType <- getElementType t
                return (elemType, [])

    getTensorDimension :: InputOrOutput -> WHNFType Builtin -> m Int
    getTensorDimension io dim = case dim of
      INatLiteral _ n -> return n
      VFreeVar varIdent _ -> do
        implicitParameters <- getInferableParameterContext
        case Map.lookup varIdent implicitParameters of
          Just (_, _, Nothing) -> throwError $ NetworkTypeHasImplicitSizeTensor decl networkType varIdent io
          Just (_, _, Just (_, _, d)) -> return d
          Nothing -> do
            explicitParameters <- getExplicitParameterContext
            case Map.lookup varIdent explicitParameters of
              Nothing -> throwError $ NetworkTypeHasVariableSizeTensor decl networkType dim io
              Just value -> getTensorDimension io value
      _ -> throwError $ NetworkTypeHasVariableSizeTensor decl networkType dim io

    getElementType :: WHNFType Builtin -> m NetworkBaseType
    getElementType = \case
      IRatType {} -> return NetworkRatType
      _ -> typingError

    typingError :: m a
    typingError =
      compilerDeveloperError $
        "Invalid network type"
          <+> squotes (prettyVerbose $ normalised networkType)
          <+> "should have been caught during type-checking"
