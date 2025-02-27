{-# LANGUAGE ViewPatterns #-}

module Vehicle.Syntax.Sugar
  ( BinderFoldTarget (..),
    FoldableBinderType (..),
    FoldableBuiltin (..),
    foldBinders,
    foldLetBinders,
    LetBinder,
  )
where

import Data.Bifunctor (Bifunctor (..))
import Data.List.NonEmpty (NonEmpty (..))
import Vehicle.Syntax.AST
import Vehicle.Syntax.Builtin

-- This module deals with all the unfolding and folding of syntactic
-- sugar in the external language. The unfolding is designed so that it should
-- be 100% reversible.

--------------------------------------------------------------------------------
-- Pi/Fun/Forall declarations

class FoldableBuiltin builtin where
  getQuant ::
    Expr var builtin ->
    Maybe (Quantifier, Binder var builtin, Expr var builtin)

instance FoldableBuiltin Builtin where
  getQuant = \case
    QuantifierExpr binder body q -> Just (q, binder, body)
    _ -> Nothing

data FoldableBinderType
  = PiFold
  | LamFold
  | QuantFold Quantifier
  deriving (Eq)

data BinderFoldTarget var builtin
  = FoldableBinder FoldableBinderType (Binder var builtin)
  | FunFold

pattern QuantifierExpr :: Binder var Builtin -> Expr var Builtin -> Quantifier -> Expr var Builtin
pattern QuantifierExpr binder body q <-
  App (Builtin _ (TypeClassOp (QuantifierTC q))) (RelevantExplicitArg _ (Lam _ binder body) :| [])

foldBinders ::
  forall var builtin.
  (Show (Binder var builtin), FoldableBuiltin builtin) =>
  BinderFoldTarget var builtin ->
  Expr var builtin ->
  ([Binder var builtin], Expr var builtin)
foldBinders foldTarget = go
  where
    go :: Expr var builtin -> ([Binder var builtin], Expr var builtin)
    go expr = do
      let result = case expr of
            Pi _ binder body -> processBinder binder body PiFold
            Lam _ binder body -> processBinder binder body LamFold
            (getQuant -> Just (q, binder, body)) -> processBinder binder body (QuantFold q)
            _ -> Nothing

      case result of
        Nothing -> ([], expr)
        Just (binder, body) -> first (binder :) (go body)

    processBinder ::
      Binder var builtin ->
      Expr var builtin ->
      FoldableBinderType ->
      Maybe (Binder var builtin, Expr var builtin)
    processBinder binder body candidateBinderType
      | shouldFold binder candidateBinderType = Just (binder, body)
      | otherwise = Nothing

    shouldFold :: Binder var builtin -> FoldableBinderType -> Bool
    shouldFold binder candidateType = case foldTarget of
      FoldableBinder targetType targetBinder ->
        targetType == candidateType
          && canFold binder targetBinder
          && wantsToFold binder
      FunFold -> case candidateType of
        LamFold -> wantsToFold binder
        _ -> False

    canFold :: Binder var builtin -> Binder var builtin -> Bool
    canFold leadBinder binder =
      visibilityMatches leadBinder binder
        && binderNamingForm leadBinder == binderNamingForm binder

--------------------------------------------------------------------------------
-- Let declarations

type LetBinder var builtin = (Binder var builtin, Expr var builtin)

-- | Collapses consecutative let expressions into a list of let declarations
foldLetBinders :: Expr var builtin -> ([LetBinder var builtin], Expr var builtin)
foldLetBinders = \case
  Let _ bound binder body
    | wantsToFold binder -> first ((binder, bound) :) (foldLetBinders body)
  expr -> ([], expr)
