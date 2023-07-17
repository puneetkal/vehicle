module Vehicle.Expr.Normalisable where

import Data.Hashable (Hashable)
import Data.Serialize
import GHC.Generics
import Vehicle.Expr.Normalised
import Vehicle.Prelude
import Vehicle.Syntax.AST

-------------------------------------------------------------------------------
-- Data type

data NormalisableBuiltin types
  = CConstructor BuiltinConstructor
  | CFunction BuiltinFunction
  | CType types
  deriving (Eq, Ord, Show, Generic)

instance (Pretty types) => Pretty (NormalisableBuiltin types) where
  pretty = \case
    CConstructor f -> pretty f
    CFunction c -> pretty c
    CType t -> pretty t

instance (Serialize types) => Serialize (NormalisableBuiltin types)

instance (Hashable types) => Hashable (NormalisableBuiltin types)

-------------------------------------------------------------------------------
-- Patterns

pattern VBuiltinFunction :: BuiltinFunction -> Spine (NormalisableBuiltin builtin) -> Value (NormalisableBuiltin builtin)
pattern VBuiltinFunction f spine = VBuiltin (CFunction f) spine

pattern VConstructor :: BuiltinConstructor -> Spine (NormalisableBuiltin builtin) -> Value (NormalisableBuiltin builtin)
pattern VConstructor c args = VBuiltin (CConstructor c) args

pattern VNullaryConstructor :: BuiltinConstructor -> Value (NormalisableBuiltin builtin)
pattern VNullaryConstructor c <- VConstructor c []
  where
    VNullaryConstructor c = VConstructor c []

pattern VUnitLiteral :: Value (NormalisableBuiltin builtin)
pattern VUnitLiteral = VNullaryConstructor LUnit

pattern VBoolLiteral :: Bool -> Value (NormalisableBuiltin builtin)
pattern VBoolLiteral x = VNullaryConstructor (LBool x)

pattern VIndexLiteral :: Int -> Value (NormalisableBuiltin builtin)
pattern VIndexLiteral x = VNullaryConstructor (LIndex x)

pattern VNatLiteral :: Int -> Value (NormalisableBuiltin builtin)
pattern VNatLiteral x = VNullaryConstructor (LNat x)

pattern VIntLiteral :: Int -> Value (NormalisableBuiltin builtin)
pattern VIntLiteral x = VNullaryConstructor (LInt x)

pattern VRatLiteral :: Rational -> Value (NormalisableBuiltin builtin)
pattern VRatLiteral x = VNullaryConstructor (LRat x)

-- TODO should definitely be `isRelevant`
pattern VVecLiteral :: [VArg (NormalisableBuiltin builtin)] -> Value (NormalisableBuiltin builtin)
pattern VVecLiteral xs <- VConstructor (LVec _) (filter isExplicit -> xs)

pattern VNil :: Value (NormalisableBuiltin builtin)
pattern VNil <- VConstructor Nil _

-- TODO should definitely be `isRelevant`
pattern VCons :: [VArg (NormalisableBuiltin builtin)] -> Value (NormalisableBuiltin builtin)
pattern VCons xs <- VConstructor Cons (filter isExplicit -> xs)

mkVList :: [Value (NormalisableBuiltin builtin)] -> Value (NormalisableBuiltin builtin)
mkVList = foldr cons nil
  where
    nil = VConstructor Nil []
    cons y ys = VConstructor Cons (RelevantExplicitArg mempty <$> [y, ys])

mkVLVec :: [Value (NormalisableBuiltin builtin)] -> Value (NormalisableBuiltin builtin)
mkVLVec xs = VConstructor (LVec (length xs)) (RelevantImplicitArg mempty VUnitLiteral : (RelevantExplicitArg mempty <$> xs))

getNatLiteral :: Value (NormalisableBuiltin builtin) -> Maybe Int
getNatLiteral = \case
  VNatLiteral d -> Just d
  _ -> Nothing

getRatLiteral :: Value (NormalisableBuiltin builtin) -> Maybe Rational
getRatLiteral = \case
  VRatLiteral d -> Just d
  _ -> Nothing
