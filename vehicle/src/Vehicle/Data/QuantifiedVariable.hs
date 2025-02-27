module Vehicle.Data.QuantifiedVariable where

import Control.DeepSeq (NFData)
import Data.Aeson (FromJSON, FromJSONKey, ToJSON, ToJSONKey)
import Data.Char.SScript
import Data.Hashable (Hashable)
import Data.Map (Map)
import Data.Map qualified as Map
import GHC.Generics (Generic)
import Numeric (showFFloat)
import Prettyprinter (brackets)
import Vehicle.Data.DeBruijn
import Vehicle.Data.Expr.Interface
import Vehicle.Data.Expr.Normalised
import Vehicle.Data.Tensor (RationalTensor)
import Vehicle.Prelude
import Vehicle.Syntax.AST
import Vehicle.Syntax.Builtin

--------------------------------------------------------------------------------
-- User tensor variables

data OriginalUserVariable = OriginalUserVariable
  { userTensorVarName :: Name,
    userTensorVarDimensions :: TensorShape
  }
  deriving (Show, Eq, Ord, Generic)

instance NFData OriginalUserVariable

instance ToJSON OriginalUserVariable

instance FromJSON OriginalUserVariable

instance Hashable OriginalUserVariable

instance Pretty OriginalUserVariable where
  pretty = pretty . userTensorVarName

--------------------------------------------------------------------------------
-- Network tensor variables

-- | Network input and output variables
data OriginalNetworkVariable = OriginalNetworkVariable
  { -- | The name of the network this variable belongs to.
    networkName :: Name,
    -- | Whether its an input or an output variable
    inputOrOutput :: InputOrOutput,
    -- | The dimensions of the variable
    networkTensorVarDimensions :: TensorShape,
    -- | The position in the list of applications of `networkName`
    application :: Int,
    -- | Index starting
    startingIndex :: Int
  }
  deriving (Show, Eq, Ord, Generic)

instance NFData OriginalNetworkVariable

instance ToJSON OriginalNetworkVariable

instance FromJSON OriginalNetworkVariable

instance Hashable OriginalNetworkVariable

instance Pretty OriginalNetworkVariable where
  pretty OriginalNetworkVariable {..} =
    pretty networkName
      <> pretty (fmap subscript (show application))
      <> brackets (pretty inputOrOutput)

--------------------------------------------------------------------------------
-- Reduced variables

data ReducedVariable variable = ReducedVariable
  { originalVar :: variable,
    tensorIndices :: TensorIndices
  }
  deriving (Show, Eq, Ord, Generic)

instance (NFData variable) => NFData (ReducedVariable variable)

instance (Pretty variable) => Pretty (ReducedVariable variable) where
  pretty ReducedVariable {..} =
    pretty originalVar <> pretty (showTensorIndices tensorIndices)

instance (FromJSON variable) => FromJSON (ReducedVariable variable)

instance (FromJSON variable) => FromJSONKey (ReducedVariable variable)

instance (ToJSON variable) => ToJSON (ReducedVariable variable)

instance (ToJSON variable) => ToJSONKey (ReducedVariable variable)

instance (Hashable variable) => Hashable (ReducedVariable variable)

reduceVariable ::
  forall variable.
  (variable -> TensorShape) ->
  Lv ->
  variable ->
  ([(Lv, ReducedVariable variable)], WHNFValue Builtin)
reduceVariable varDims dbLevel var
  | null (varDims var) = createRatVar [] dbLevel
  | otherwise = do
      let (vars, expr) = runSupply (go (varDims var) []) [dbLevel ..]
      (reverse vars, expr)
  where
    createRatVar :: TensorIndices -> Lv -> ([(Lv, ReducedVariable variable)], WHNFValue Builtin)
    createRatVar indices lv = ([(lv, ReducedVariable var indices)], VBoundVar lv [])

    go ::
      TensorShape ->
      TensorIndices ->
      Supply Lv ([(Lv, ReducedVariable variable)], WHNFValue Builtin)
    go dims indices = case dims of
      [] -> createRatVar (reverse indices) <$> demand
      d : ds -> do
        -- Use the list monad to create a nested list of all possible indices into the tensor
        let allIndices = [0 .. d - 1]

        -- Generate the corresponding names from the indices
        (elementUserVars, subexprs) <- unzip <$> traverse (\i -> go ds (i : indices)) allIndices
        let userVars = concat elementUserVars
        return (userVars, mkVecExpr subexprs)

--------------------------------------------------------------------------------
-- Reduced user variables

-- | Variables entered by the user
type UserRationalVariable = ReducedVariable OriginalUserVariable

type NetworkRationalVariable = ReducedVariable OriginalNetworkVariable

computeAbsoluteIndex :: NetworkRationalVariable -> Int
computeAbsoluteIndex ReducedVariable {..} = do
  let offset = startingIndex originalVar
  offset + computeFlatIndex (networkTensorVarDimensions originalVar) tensorIndices

--------------------------------------------------------------------------------
-- All variables

-- | Both user and network variables
data RationalVariable
  = UserRationalVar UserRationalVariable
  | NetworkRationalVar NetworkRationalVariable
  deriving (Show, Eq, Ord, Generic)

instance NFData RationalVariable

instance ToJSON RationalVariable

instance FromJSON RationalVariable

instance ToJSONKey RationalVariable

instance FromJSONKey RationalVariable

instance Pretty RationalVariable where
  pretty = \case
    UserRationalVar v -> pretty v
    NetworkRationalVar v -> pretty v

--------------------------------------------------------------------------------
-- Tensor variables

-- | Both user and network variables
data TensorVariable
  = UserTensorVar OriginalUserVariable
  | NetworkTensorVar OriginalNetworkVariable
  deriving (Show, Eq, Ord, Generic)

instance NFData TensorVariable

instance ToJSON TensorVariable

instance FromJSON TensorVariable

instance ToJSONKey TensorVariable

instance FromJSONKey TensorVariable

instance Pretty TensorVariable where
  pretty = \case
    UserTensorVar v -> pretty v
    NetworkTensorVar v -> pretty v

tensorVariableDims :: TensorVariable -> TensorShape
tensorVariableDims = \case
  UserTensorVar v -> userTensorVarDimensions v
  NetworkTensorVar v -> networkTensorVarDimensions v

--------------------------------------------------------------------------------
-- Tensor variables

-- | Both user and network variables
data Variable
  = RationalVar RationalVariable
  | TensorVar TensorVariable
  deriving (Show, Eq, Ord, Generic)

instance ToJSON Variable

instance FromJSON Variable

instance ToJSONKey Variable

instance FromJSONKey Variable

instance Pretty Variable where
  pretty = \case
    RationalVar v -> pretty v
    TensorVar v -> pretty v

--------------------------------------------------------------------------------
-- Constants

prettyRationalAsFloat :: Rational -> Doc a
prettyRationalAsFloat p = do
  let f = realToFrac p :: Double
  pretty $ showFFloat Nothing f ""

--------------------------------------------------------------------------------
-- Network assignments

-- | A (satisfying) assignment to a set of reduced network-level variables.
newtype NetworkVariableAssignment
  = NetworkVariableAssignment (Map NetworkRationalVariable Rational)

instance Pretty NetworkVariableAssignment where
  pretty (NetworkVariableAssignment assignment) = do
    vsep (prettyVariable <$> Map.toList assignment)
    where
      prettyVariable :: (NetworkRationalVariable, Rational) -> Doc a
      prettyVariable (var, value) = "x" <> pretty var <> ":" <+> pretty value

--------------------------------------------------------------------------------
-- User variable assignments

-- | A (satisfying) assignment to a set of user-level variables.
newtype UserVariableAssignment
  = UserVariableAssignment [(OriginalUserVariable, RationalTensor)]
  deriving (Generic)

instance ToJSON UserVariableAssignment

instance FromJSON UserVariableAssignment

instance Pretty UserVariableAssignment where
  pretty (UserVariableAssignment assignment) =
    vsep (fmap pretty assignment)

--------------------------------------------------------------------------------
-- Variable status

data UnderConstrainedVariableStatus
  = Unconstrained
  | BoundedAbove
  | BoundedBelow
  deriving (Show, Eq, Ord)

instance Pretty UnderConstrainedVariableStatus where
  pretty = \case
    Unconstrained -> "Unconstrained"
    BoundedAbove -> "BoundedAbove"
    BoundedBelow -> "BoundedBelow"

instance Semigroup UnderConstrainedVariableStatus where
  Unconstrained <> r = r
  r <> Unconstrained = r
  BoundedAbove <> r = r
  r <> BoundedAbove = r
  BoundedBelow <> BoundedBelow = BoundedBelow

prettyUnderConstrainedVariables :: (Pretty var) => [(var, UnderConstrainedVariableStatus)] -> Doc a
prettyUnderConstrainedVariables vars =
  indent 2 (vsep $ fmap prettyUnderConstrainedVariable vars)

prettyUnderConstrainedVariable :: (Pretty var) => (var, UnderConstrainedVariableStatus) -> Doc a
prettyUnderConstrainedVariable (var, constraint) =
  pretty var <+> "-" <+> case constraint of
    Unconstrained -> "no lower or upper bound"
    BoundedAbove -> "no lower bound"
    BoundedBelow -> "no upper bound"
