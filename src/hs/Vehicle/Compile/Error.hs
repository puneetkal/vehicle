{-# OPTIONS_GHC -Wno-deferred-out-of-scope-variables #-}

module Vehicle.Compile.Error where

import Control.Monad.Except ( MonadError )
import Data.List.NonEmpty (NonEmpty)
import Prettyprinter (list)

import Vehicle.Compile.Type.Constraint
import Vehicle.Backend.Prelude (OutputTarget)
import Vehicle.Compile.Prelude

--------------------------------------------------------------------------------
-- Compilation monad

type MonadCompile m =
  ( MonadLogger m
  , MonadError CompileError m
  )

--------------------------------------------------------------------------------
-- Compilation errors

data CompileError
  -- Parse errors
  = BNFCParseError String

  -- Errors thrown when elaborating from Core
  | UnknownBuiltin     Token
  | MalformedPiBinder  Token
  | MalformedLamBinder InputExpr

  -- Errors thrown when elaborating from Frontend
  | MissingDefFunType    Provenance Symbol
  | MissingDefFunExpr    Provenance Symbol
  | DuplicateName        (NonEmpty Provenance) Symbol
  | MissingVariables     Provenance Symbol

  -- Errors thrown by scope checking.
  | UnboundName Symbol Provenance

  -- Errors thrown while type checking
  | UnresolvedHole
    Provenance              -- The location of the hole
    Symbol                  -- The name of the hole
  | TypeMismatch
    Provenance              -- The location of the mismatch.
    BoundCtx                -- The context at the time of the failure
    CheckedExpr             -- The possible inferred types.
    CheckedExpr             -- The expected type.
  | FailedConstraints
    (NonEmpty Constraint)
  | UnsolvedConstraints
    (NonEmpty Constraint)
  | MissingExplicitArg
    BoundCtx                -- The context at the time of the failure
    UncheckedArg            -- The non-explicit argument
    CheckedExpr             -- Expected type of the argument

  -- Network typing errors
  | NetworkTypeIsNotAFunction              Identifier CheckedExpr
  | NetworkTypeWithNonExplicitArguments    Identifier CheckedExpr CheckedBinder
  | NetworkTypeWithHeterogeneousInputTypes Identifier CheckedExpr CheckedExpr CheckedExpr
  | NetworkTypeHasMultidimensionalTensor   Identifier CheckedExpr CheckedExpr InputOrOutput
  | NetworkTypeHasVariableSizeTensor       Identifier CheckedExpr CheckedExpr InputOrOutput
  | NetworkTypeUnsupportedElementType      Identifier CheckedExpr CheckedExpr InputOrOutput

  -- Backend errors
  | NoPropertiesFound
  | UnsupportedDecl                OutputTarget Provenance Identifier DeclType
  | UnsupportedQuantifierSequence  OutputTarget Provenance Identifier Quantifier
  | UnsupportedQuantifierPosition  OutputTarget Provenance Identifier Quantifier Symbol
  | UnsupportedVariableType        OutputTarget Provenance Identifier Symbol OutputExpr [Builtin]
  | UnsupportedRelation            OutputTarget Provenance Builtin
  | UnsupportedPolymorphicEquality OutputTarget Provenance Symbol
  | UnsupportedBuiltin             OutputTarget Provenance Builtin
  | NonLinearConstraint            OutputTarget Provenance Identifier OutputExpr OutputExpr
  | NoNetworkUsedInProperty        OutputTarget Provenance Identifier
  | LookupInVariableDimTensor      OutputTarget Provenance OutputExpr
  | LookupInEmptyTensor            OutputTarget Provenance
  | TensorIndexOutOfBounds         Provenance Int Int
  deriving (Show)

--------------------------------------------------------------------------------
-- Some useful developer errors

unexpectedExprError :: Doc a -> Doc a -> Doc a
unexpectedExprError pass name =
  "encountered unexpected expression" <+> squotes name <+>
  "during" <+> pass <> "."

normalisationError :: Doc a -> Doc a -> b
normalisationError pass name = developerError $
  unexpectedExprError pass name <+> "We should have normalised this out."

typeError :: Doc a -> Doc a -> b
typeError pass name = developerError $
  unexpectedExprError pass name <+> "We should not be compiling types."

visibilityError :: Doc a -> Doc a -> b
visibilityError pass name = developerError $
  unexpectedExprError pass name <+> "Should not be present as explicit arguments"

resolutionError :: Doc a -> Doc a -> b
resolutionError pass name = developerError $
  unexpectedExprError pass name <+> "We should have resolved this during type-checking."

caseError :: Doc a -> Doc a -> [Doc a] -> b
caseError pass name cases = developerError $
  unexpectedExprError pass name <+> "This should already have been caught by the" <+>
  "following cases:" <+> list cases