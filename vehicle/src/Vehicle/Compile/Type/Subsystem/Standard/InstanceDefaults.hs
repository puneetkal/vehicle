{-# OPTIONS_GHC -Wno-orphans #-}

module Vehicle.Compile.Type.Subsystem.Standard.InstanceDefaults where

import Vehicle.Compile.Error
import Vehicle.Compile.Prelude
import Vehicle.Compile.Type.Constraint.Core (parseInstanceGoal)
import Vehicle.Compile.Type.Constraint.InstanceDefaultSolver
import Vehicle.Compile.Type.Core
import Vehicle.Compile.Type.Subsystem.Standard.Core
import Vehicle.Data.BuiltinInterface.ASTInterface
import Vehicle.Data.NormalisedExpr

instance HasInstanceDefaults StandardTypingBuiltin where
  getCandidatesFromConstraint = getCandidates
  compareCandidates = compareCandidate

--------------------------------------------------------------------------------
-- Default solutions to type-class constraints

compareCandidate :: Candidate StandardTypingBuiltin -> Candidate StandardTypingBuiltin -> Maybe Ordering
compareCandidate c1 c2 = do
  let f1 = familyOf (candidateTypeClass c1)
  let f2 = familyOf (candidateTypeClass c2)
  if not (sameFamily f1 f2)
    then Nothing
    else
      if f1 > f2
        then Just GT
        else
          if f1 < f2
            then Just LT
            else Just EQ

-- This is some pretty ugly code. There must be a way of making this process
-- more elegant....

data NumericType
  = NatT
  | IntT
  | RatT
  deriving (Eq, Ord)

data DefaultFamily
  = NumericFamily NumericType Bool
  | ContainerFamily Bool
  | BooleanFamily
  | Other
  deriving (Eq, Ord)

sameFamily :: DefaultFamily -> DefaultFamily -> Bool
sameFamily NumericFamily {} NumericFamily {} = True
sameFamily ContainerFamily {} ContainerFamily {} = True
sameFamily BooleanFamily {} BooleanFamily {} = True
sameFamily _ _ = False

familyOf :: StandardTypingBuiltin -> DefaultFamily
familyOf = \case
  StandardBuiltin b -> case b of
    TypeClass HasQuantifier {} -> BooleanFamily
    TypeClass HasEq {} -> NumericFamily NatT False
    TypeClass HasOrd {} -> NumericFamily NatT False
    TypeClass HasAdd -> NumericFamily NatT True
    TypeClass HasSub -> NumericFamily IntT True
    TypeClass HasMul -> NumericFamily NatT True
    TypeClass HasDiv -> NumericFamily RatT True
    TypeClass HasNeg -> NumericFamily IntT True
    TypeClass HasNatLits -> NumericFamily NatT False
    TypeClass HasRatLits -> NumericFamily RatT False
    TypeClass HasVecLits {} -> ContainerFamily True
    TypeClass HasMap -> ContainerFamily False
    TypeClass HasFold -> ContainerFamily False
    TypeClass HasQuantifierIn {} -> ContainerFamily False
    NatInDomainConstraint -> NumericFamily NatT False
    _ -> Other

-- _ -> Other

getCandidates ::
  forall m.
  (MonadCompile m) =>
  ConstraintContext StandardTypingBuiltin ->
  InstanceConstraint StandardTypingBuiltin ->
  m [Candidate StandardTypingBuiltin]
getCandidates ctx (Resolve origin _ _ expr) = do
  InstanceGoal {..} <- parseInstanceGoal expr
  let defaults = case (goalHead, goalSpine) of
        (StandardBuiltin (TypeClass HasOrd {}), [tArg1, tArg2, _tRes]) -> Just (INatType mempty, [tArg1, tArg2])
        (StandardBuiltin (TypeClass HasNeg), [tArg, _tRes]) -> Just (IRatType mempty, [tArg])
        (StandardBuiltin (TypeClass HasMul), [tArg1, tArg2, _tRes]) -> Just (INatType mempty, [tArg1, tArg2])
        (StandardBuiltin (TypeClass HasDiv), [tArg1, tArg2, _tRes]) -> Just (IRatType mempty, [tArg1, tArg2])
        (StandardBuiltin (TypeClass HasNatLits), [t]) -> Just (INatType mempty, [t])
        (StandardBuiltin (TypeClass HasRatLits), [t]) -> Just (IRatType mempty, [t])
        (StandardBuiltin (TypeClass HasVecLits), [_n, t]) -> Just (IRawListType mempty, [t])
        (StandardBuiltin (TypeClass HasMap), [t]) -> Just (IRawListType mempty, [t])
        (StandardBuiltin (TypeClass HasFold), [t]) -> Just (IRawListType mempty, [t])
        (StandardBuiltin NatInDomainConstraint, [n, t]) -> case argExpr t of
          IIndexType _ size -> do
            let succN = case argExpr n of
                  INatLiteral p x -> INatLiteral p (x + 1)
                  n' -> IAdd AddNat n' (INatLiteral mempty 1)
            Just (succN, [Arg mempty (Implicit False) Irrelevant size])
          _ -> Nothing
        _ -> Nothing

  return $ case defaults of
    Nothing -> []
    Just (defaultValue, defaultArgs) ->
      getCandidatesFromArgs (ctx, origin) goalHead defaultValue defaultArgs

getCandidatesFromArgs ::
  InstanceConstraintInfo StandardTypingBuiltin ->
  StandardTypingBuiltin ->
  WHNFValue StandardTypingBuiltin ->
  WHNFSpine StandardTypingBuiltin ->
  [Candidate StandardTypingBuiltin]
getCandidatesFromArgs info tc solution ts = map mkCandidate (filter (isNMeta . argExpr) ts)
  where
    mkCandidate t =
      Candidate
        { candidateTypeClass = tc,
          candidateMetaExpr = argExpr t,
          candidateInfo = info,
          candidateSolution = solution
        }
