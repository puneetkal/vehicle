module Vehicle.Compile.Print.Error
  ( UserError (..),
    VehicleError (..),
    MeaningfulError (..),
    logCompileError,
  )
where

import Control.Monad.Except (ExceptT, runExceptT)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Monoid (Endo (..))
import Data.Text (Text, pack)
import Prettyprinter (list)
import System.FilePath
import Vehicle.Compile.Error
import Vehicle.Compile.Normalise.Quote (unnormalise)
import Vehicle.Compile.Prelude
import Vehicle.Compile.Print
import Vehicle.Compile.Type.Core
import Vehicle.Data.Builtin.Linearity
import Vehicle.Data.Builtin.Polarity
import Vehicle.Data.Builtin.Standard.Core
import Vehicle.Data.DSL
import Vehicle.Data.DeBruijn (substDBInto)
import Vehicle.Data.Expr.Interface
import Vehicle.Data.Expr.Normalised
import Vehicle.Data.QuantifiedVariable (prettyUnderConstrainedVariables)
import Vehicle.Libraries.StandardLibrary.Definitions (pattern TensorIdent)
import Vehicle.Syntax.Parse (ParseError (..))
import Prelude hiding (pi)

--------------------------------------------------------------------------------
-- User errors

-- | Errors that are the user's responsibility to fix.
data UserError = UserError
  { provenance :: Provenance,
    problem :: UnAnnDoc,
    fix :: Maybe UnAnnDoc
  }

-- | Errors from external code that we have no control over.
--  These may be either user or developer errors but in general we
--  can't distinguish between the two.
newtype ExternalError = ExternalError Text

data VehicleError
  = UError UserError
  | EError ExternalError
  | DError (Doc ())

instance Pretty VehicleError where
  pretty (UError (UserError p prob probFix)) =
    unAnnotate $
      "Error in"
        <+> pretty p
        <> ":"
          <+> prob
        <> maybe "" (\fix -> line <> fixText fix) probFix
  pretty (EError (ExternalError text)) = pretty text
  pretty (DError text) = unAnnotate text

fixText :: Doc ann -> Doc ann
fixText t = "Fix:" <+> t

logCompileError ::
  (MonadLogger m) =>
  ExceptT CompileError m a ->
  m (Either CompileError a)
logCompileError x = do
  e' <- runExceptT x
  case e' of
    Left err -> logDebug MinDetail (pretty (details err))
    Right _ -> return ()
  return e'

--------------------------------------------------------------------------------
-- Meaningful error classes

class MeaningfulError e where
  details :: e -> VehicleError

instance MeaningfulError CompileError where
  details = \case
    ----------------------
    -- Developer errors --
    ----------------------

    DevError text -> DError text
    -------------
    -- Parsing --
    -------------

    ParseError _module parseError -> case parseError of
      RawParseError text ->
        EError $
          ExternalError
            -- TODO need to revamp this error, BNFC must provide some more
            -- information than a simple string surely?
            (pack text)
      UnannotatedAbstractDef p name ->
        UError $
          UserError
            { provenance = p,
              problem =
                "no definition provided for the declaration"
                  <+> quotePretty name
                  <> ".",
              fix =
                Just $
                  "either provide a definition for"
                    <+> quotePretty name
                    <+> "or mark it as an external resource by adding an appropriate annotation, i.e."
                    <+> pretty NetworkDef
                    <> ","
                      <+> pretty DatasetDef
                      <+> "or"
                      <+> pretty (ParameterDef NonInferable)
                    <> "."
            }
      MultiplyAnnotatedAbstractDef p name ann1 ann2 ->
        UError $
          UserError
            { provenance = p,
              problem =
                "abstract declaration"
                  <+> quotePretty name
                  <+> "cannot simulataneously be annotated with both"
                  <+> quotePretty ann1
                  <+> "and"
                  <+> quotePretty ann2
                  <> ".",
              fix =
                Just "remove one of annotations."
            }
      AbstractDefWithNonAbstractAnnotation p name ann ->
        case ann of
          AnnProperty ->
            UError $
              UserError
                { provenance = p,
                  problem = "missing definition for property" <+> quotePretty name <> ".",
                  fix = Just $ "add a definition for" <+> quotePretty name <+> "."
                }
      NonAbstractDefWithAbstractAnnotation p name resource ->
        UError $
          UserError
            { provenance = p,
              problem =
                "The declaration"
                  <+> quotePretty name
                  <+> "should not have a definition"
                  <+> "as it has been marked with a"
                  <+> quotePretty resource
                  <+> "annotation.",
              fix =
                Just $
                  "either remove the definition for"
                    <+> quotePretty name
                    <+> "or remove the"
                    <+> quotePretty resource
                    <+> "annotation."
            }
      AnnotationWithNoDef p name ->
        UError $
          UserError
            { provenance = p,
              problem = "unattached annotation" <+> quotePretty name,
              fix = Just "either attach the annotation to a declaration or remove it entirely"
            }
      FunctionWithMismatchedNames p name1 name2 ->
        UError $
          UserError
            { provenance = p,
              problem = "mismatch in function declaration names:" <+> quotePretty name1 <+> "and" <+> quotePretty name2 <> ".",
              fix = Just "ensure the function definition has the same name as the declaration it follows."
            }
      MissingVariables p symbol ->
        UError $
          UserError
            { provenance = p,
              problem = "expected at least one variable name after" <+> quotePretty symbol,
              fix = Just $ "add one or more names after" <+> quotePretty symbol
            }
      UnchainableOrders p prevOrder currentOrder ->
        UError $
          UserError
            { provenance = p,
              problem =
                "cannot chain"
                  <+> quotePretty prevOrder
                  <+> "and"
                  <+> quotePretty currentOrder,
              fix = Just "split chained orders into a conjunction"
            }
      InvalidAnnotationOption p annotationName parameterName suggestions ->
        UError $
          UserError
            { provenance = p,
              problem =
                "unknown option"
                  <+> quotePretty parameterName
                  <+> "for"
                  <+> quotePretty annotationName
                  <+> "annotation.",
              fix =
                case suggestions of
                  [] -> Nothing
                  (s : _) -> Just $ "did you mean" <+> quotePretty s <> "?"
            }
      InvalidAnnotationOptionValue parameterName parameterValue ->
        UError $
          UserError
            { provenance = provenanceOf parameterValue,
              problem =
                "unable to parse the value"
                  <+> squotes (prettyFriendly parameterValue)
                  <+> "for option"
                  <+> quotePretty parameterName,
              fix = Nothing
            }
      DuplicateAnnotationOption p annotation name ->
        UError $
          UserError
            { provenance = p,
              problem =
                "the annotation"
                  <+> quotePretty annotation
                  <+> "has multiple copies of the option"
                  <+> quotePretty name,
              fix = Just $ "remove all but one of the instances of" <+> quotePretty name
            }
      MissingAnnotationOption p annotation name ->
        UError $
          UserError
            { provenance = p,
              problem =
                "the annotation"
                  <+> quotePretty annotation
                  <+> "is missing the option"
                  <+> quotePretty name,
              fix = Just $ "add a value for the option" <+> quotePretty name
            }
      UnknownBuiltin p symbol ->
        UError $
          UserError
            { provenance = p,
              problem = "Unknown symbol" <+> quotePretty symbol,
              fix =
                Just $
                  "Please consult the documentation for a description"
                    <+> "of Vehicle syntax"
            }
    -------------
    -- Scoping --
    -------------
    MissingPrunedName name ->
      UError $
        UserError
          { provenance = mempty,
            -- TODO can use Levenschtein distance to search contexts/builtins
            problem =
              "Was asked to compile declaration"
                <+> quotePretty name
                <+> "but no declaration exists with that name in the specification.",
            fix =
              Just $
                "check the spelling of"
                  <+> quotePretty name
                  <+> "or that the"
                  <+> "right specification is being used."
          }
    UnboundName p name ->
      UError $
        UserError
          { provenance = p,
            -- TODO can use Levenschtein distance to search contexts/builtins
            problem = "The name" <+> quotePretty name <+> "is not in scope",
            fix = Nothing
          }
    DeclarationDeclarationShadowing p name _matching ->
      UError $
        UserError
          { provenance = p,
            problem = "multiple declarations found with the name" <+> quotePretty name,
            fix = Just "remove or rename the duplicate definitions"
          }
    DeclarationBoundShadowing p name ->
      UError $
        UserError
          { provenance = p,
            problem =
              "cannot re-use the name"
                <+> quotePretty name
                <+> "as a local variable because there is already a declaration with that name.",
            fix = Just "rename either the original declaration or this variable"
          }
    ------------
    -- Typing --
    ------------

    TypingError (FunctionTypeMismatch ctx fun _originalArgs nonPiType args :: TypingError builtin) ->
      UError $
        UserError
          { provenance = p,
            problem =
              "expected"
                -- <+> squotes (prettyFriendly $ WithContext fun ctx)
                <+> squotes (prettyVerbose fun)
                <+> "to have something of type"
                <+> squotes (prettyFriendly $ WithContext expectedType ctx)
                <+> "but inferred type"
                <+> squotes (prettyFriendly $ WithContext nonPiType ctx),
            fix = Nothing
          }
      where
        p = provenanceOf fun

        mkRes :: [Endo (DSLExpr builtin)]
        mkRes =
          [ Endo $ \tRes -> pi Nothing (visibilityOf arg) (relevanceOf arg) (tHole ("arg" <> pack (show i))) (const tRes)
            | (i, arg) <- zip [0 :: Int ..] args
          ]

        expectedType :: Expr Ix builtin
        expectedType = fromDSL p (appEndo (mconcat mkRes) (tHole "res"))
    UnresolvedHole p name ->
      UError $
        UserError
          { provenance = p,
            problem = "the type of" <+> squotes (pretty name) <+> "could not be resolved",
            fix = Nothing
          }
    TypingError (FailedUnificationConstraints cs) ->
      UError $
        UserError
          { provenance = provenanceOf ctx,
            problem =
              constraintOriginMessage
                <> "."
                  <+> "In particular"
                  <+> squotes (prettyFriendly (WithContext e1 boundCtx))
                  <+> "is not equal to"
                  <+> squotes (prettyFriendly (WithContext e2 boundCtx))
                <> ".",
            fix = Just "check your types"
          }
      where
        WithContext (Unify origin e1 e2) ctx = NonEmpty.head cs
        boundCtx = namedBoundCtxOf ctx

        constraintOriginMessage = case origin of
          CheckingExprType CheckingExpr {..} ->
            "expected"
              <+> squotes (prettyUnificationConstraintOriginExpr ctx checkedExpr)
              <+> "to be of type"
              <+> squotes (prettyFriendly (WithContext checkedExprExpectedType boundCtx))
              <+> "but was found to be of type"
              <+> squotes (prettyFriendly (WithContext checkedExprActualType boundCtx))
          CheckingBinderType CheckingBinder {..} ->
            "expected the variable"
              <+> quotePretty checkedBinderName
              <+> "to be of type"
              <+> squotes (prettyFriendly $ WithContext checkedBinderExpectedType boundCtx)
              <+> "but was found to be of type"
              <+> squotes (prettyFriendly $ WithContext checkedBinderActualType boundCtx)
          CheckingInstanceType InstanceConstraintOrigin {..} ->
            "unable to find a consistent type for the overloaded expression"
              <+> squotes (prettyTypeClassConstraintOriginExpr ctx checkedInstanceOp checkedInstanceOpArgs)
          CheckingAuxiliary ->
            developerError "Auxiliary constraints should not be unsolved."
    TypingError (UnsolvedConstraints cs) ->
      UError $
        UserError
          { provenance = provenanceOf ctx,
            problem = constraintOriginMessage <> ".", -- <+>
            -- "In particular unable to solve the constraint:" <+>
            --  prettyFriendlyDB nameCtx constraint
            fix = Just "try adding more type annotations"
          }
      where
        WithContext constraint ctx = NonEmpty.head cs
        nameCtx = namedBoundCtxOf ctx

        constraintOriginMessage = case constraint of
          UnificationConstraint (Unify origin _ _) -> case origin of
            CheckingExprType CheckingExpr {..} ->
              "expected"
                <+> squotes (prettyUnificationConstraintOriginExpr ctx checkedExpr)
                <+> "to be of type"
                <+> squotes (prettyFriendly $ WithContext checkedExprExpectedType nameCtx)
                <+> "but was unable to prove it."
            CheckingBinderType CheckingBinder {..} ->
              "expected the variable"
                <+> squotes (pretty checkedBinderName)
                <+> "to be of type"
                <+> squotes (prettyFriendly $ WithContext checkedBinderActualType nameCtx)
                <+> "but was unable to prove it."
            CheckingInstanceType InstanceConstraintOrigin {..} ->
              "insufficient information to find a valid type for the overloaded expression"
                <+> squotes (prettyTypeClassConstraintOriginExpr ctx checkedInstanceOp checkedInstanceOpArgs)
            CheckingAuxiliary ->
              developerError "Auxiliary constraints should not be unsolved."
          InstanceConstraint (Resolve InstanceConstraintOrigin {..} _ _ _) ->
            "insufficient information to find a valid type for the overloaded expression"
              <+> squotes (prettyTypeClassConstraintOriginExpr ctx checkedInstanceOp checkedInstanceOpArgs)
    UnsolvedMetas ms ->
      UError $
        UserError
          { provenance = p,
            problem = "Unable to infer type of bound variable",
            fix = Just "add more type annotations"
          }
      where
        (_, p) = NonEmpty.head ms
    TypingError (MissingExplicitArgument ctx argBinder arg) ->
      UError $
        UserError
          { provenance = provenanceOf arg,
            problem =
              "expected an"
                <+> pretty Explicit
                <+> "argument of type"
                <+> argTypeDoc
                <+> "but instead found"
                <+> pretty (visibilityOf arg)
                <+> "argument"
                <+> squotes (prettyFriendly $ WithContext (argExpr arg) ctx),
            fix = Just $ "try inserting an argument of type" <+> argTypeDoc
          }
      where
        argTypeDoc = prettyFriendly $ WithContext (typeOf argBinder) ctx
    TypingError (FailedInstanceConstraint ctx origin _goal candidates :: TypingError builtin) ->
      UError $
        UserError
          { provenance = provenanceOf ctx,
            problem =
              "unable to work out a valid type for the overloaded expression"
                <+> originExpr
                <> "."
                <> line
                <> "Type checking has deduced that it is of type:"
                <> line
                <> indent 2 deducedType
                <> line
                <> "but"
                  <+> originExpr
                  <+> "has only the following valid types:"
                <> line
                <> indent 2 (vsep (fmap calculateCandidateType candidates)),
            fix = Nothing
          }
      where
        InstanceConstraintOrigin tcOp tcOpArgs tcOpType tc = origin

        deducedType = calculateOpType (namedBoundCtxOf ctx) $ case tc of
          App _ as -> NonEmpty.toList as
          _ -> []

        originExpr :: Doc a
        originExpr = squotes (prettyTypeClassConstraintOriginExpr ctx tcOp tcOpArgs)

        calculateOpType :: NamedBoundCtx -> [Arg Ix builtin] -> Doc a
        calculateOpType dbCtx args = do
          let argsToSubst = fmap argExpr args <> [IUnitLiteral mempty]
          let inferedOpType = instantiateTelescope tcOpType argsToSubst
          prettyFriendly (WithContext inferedOpType dbCtx)

        calculateCandidateType :: WithContext (InstanceCandidate builtin) -> Doc a
        calculateCandidateType (WithContext candidate typingCtx) =
          go typingCtx (candidateExpr candidate)
          where
            go :: BoundCtx (Expr Ix builtin) -> Expr Ix builtin -> Doc a
            go dbCtx = \case
              App (Builtin _ _tc) args ->
                calculateOpType (toNamedBoundCtx dbCtx) (NonEmpty.toList args)
              Pi _ binder result ->
                go (binder : dbCtx) result
              _ -> "UNSUPPORTED PRINTING"

        instantiateTelescope :: Expr Ix builtin -> [Expr Ix builtin] -> Expr Ix builtin
        instantiateTelescope expr arguments = case (expr, arguments) of
          (_, []) -> expr
          (Pi _ _binder body, arg : args) -> do
            let body' = arg `substDBInto` body
            instantiateTelescope body' args
          _ -> developerError "Malformed type-class operation type"
    TypingError (FailedIndexConstraintTooBig ctx v n) ->
      UError $
        UserError
          { provenance = provenanceOf ctx,
            problem =
              "the value"
                <+> squotes (pretty v)
                <+> "is too big to"
                <+> "be used as an index of size"
                <+> squotes (pretty n)
                <> ".",
            fix = Nothing
          }
    TypingError (FailedIndexConstraintUnknown ctx v t) ->
      UError $
        UserError
          { provenance = provenanceOf ctx,
            problem =
              "unable to determine if"
                <+> squotes (prettyFriendly (WithContext v (namedBoundCtxOf ctx)))
                <+> "is a valid index of size"
                <+> squotes (prettyFriendly (WithContext t (namedBoundCtxOf ctx)))
                <> ".",
            fix = Nothing
          }
    RelevantUseOfIrrelevantVariable p name ->
      UError $
        UserError
          { provenance = p,
            problem = "cannot use irrelevant variable" <+> quotePretty name <+> "in an relevant context",
            fix = Nothing
          }
    QuantifiedIfCondition ctx ->
      UError $
        UserError
          { provenance = provenanceOf ctx,
            problem = "cannot currently use quantifiers in `if` conditions.",
            fix = Just $ implementationLimitation Nothing
          }
    ---------------
    -- Resources --
    ---------------

    ResourceNotProvided (ident, p) resourceType ->
      UError $
        UserError
          { provenance = p,
            problem =
              "No"
                <+> entity
                <+> "was provided for the"
                <+> prettyResource resourceType ident
                <> ".",
            fix =
              Just $
                "provide it via the command line using"
                  <+> squotes
                    ( "--"
                        <> pretty resourceType
                          <+> pretty (nameOf ident :: Name)
                        <> ":"
                        <> var
                    )
          }
      where
        (entity, var) = case resourceType of
          Parameter -> ("value", "VALUE")
          _ -> ("file", "FILEPATH")
    UnsupportedResourceFormat (ident, p) resourceType fileExtension ->
      UError $
        UserError
          { provenance = p,
            problem =
              "The"
                <+> quotePretty fileExtension
                <+> "format of the file provided"
                <+> "for the"
                <+> prettyResource resourceType ident
                <+> "is not currently supported by Vehicle.",
            fix =
              Just $
                "use one of the supported formats"
                  <+> pretty (supportedFileFormats resourceType)
                  <+> ", or open an issue on Github ("
                  <> githubIssues
                  <> ") to discuss adding support."
          }
    ResourceIOError (ident, p) resourceType ioException ->
      UError $
        UserError
          { provenance = p,
            problem =
              "The following exception occured when trying to read the file"
                <+> "provided for"
                <+> prettyResource resourceType ident
                <> ":"
                <> line
                <> indent 2 (pretty (show ioException)),
            fix = Nothing
          }
    UnableToParseResource (ident, p) resourceType value ->
      UError $
        UserError
          { provenance = p,
            problem =
              "Unable to parse the"
                <+> entity
                <+> squotes (pretty value)
                <+> "provided for the"
                <+> prettyResource resourceType ident,
            fix = Nothing
          }
      where
        entity = if resourceType == Parameter then "value" else "file"

    -- Network errors

    NetworkTypeIsNotAFunction (ident, _p) networkType ->
      UError $
        UserError
          { provenance = provenanceOf networkType,
            problem =
              unsupportedAnnotationTypeDescription (pretty NetworkDef) ident networkType
                <+> "as it is not a function.",
            fix =
              Just $
                supportedNetworkTypeDescription
                  <+> "Provide both an input type and output type for your network."
          }
    NetworkTypeIsNotOverTensors (ident, _p) networkType nonTensorType io ->
      UError $
        UserError
          { provenance = provenanceOf networkType,
            problem =
              unsupportedAnnotationTypeDescription (pretty NetworkDef) ident networkType
                <+> "as the"
                <+> pretty io
                <+> squotes (prettyFriendlyEmptyCtx nonTensorType)
                <+> "is not one of"
                <+> list [pretty Vector, pretty (identifierName TensorIdent)]
                <> ".",
            fix =
              Just $
                supportedNetworkTypeDescription
                  <+> "Ensure the"
                  <+> pretty io
                  <+> "of the network is a Tensor"
          }
    NetworkTypeHasNonExplicitArguments (ident, _p) networkType binder ->
      UError $
        UserError
          { provenance = provenanceOf binder,
            problem =
              unsupportedAnnotationTypeDescription (pretty NetworkDef) ident networkType
                <+> "as it contains the non-explicit argument of type"
                <+> squotes (prettyFriendlyEmptyCtx (typeOf binder))
                <> ".",
            fix =
              Just $
                supportedNetworkTypeDescription
                  <+> "Remove the non-explicit argument."
          }
    NetworkTypeHasUnsupportedElementType (ident, _p) networkType elementType io ->
      UError $
        UserError
          { provenance = provenanceOf networkType,
            problem =
              unsupportedAnnotationTypeDescription (pretty NetworkDef) ident networkType
                <+> "as"
                <+> pretty io
                <> "s of type"
                  <+> squotes (prettyFriendlyEmptyCtx elementType)
                  <+> "are not currently supported.",
            fix =
              Just $
                supportedNetworkTypeDescription
                  <+> "Ensure that the network"
                  <+> pretty io
                  <+> "uses"
                  <+> "supported types."
          }
    NetworkTypeHasVariableSizeTensor (ident, _p) networkType tDim io ->
      UError $
        UserError
          { provenance = provenanceOf networkType,
            problem =
              unsupportedAnnotationTypeDescription (pretty NetworkDef) ident networkType
                <+> "as the size of the"
                <+> pretty io
                <+> "tensor"
                <+> squotes (prettyFriendlyEmptyCtx tDim)
                <+> "is not a constant.",
            fix =
              Just $
                supportedNetworkTypeDescription
                  <+> "ensure that the size of the"
                  <+> pretty io
                  <+> "tensor is constant."
          }
    NetworkTypeHasImplicitSizeTensor (ident, p) networkType implIdent _io ->
      UError $
        UserError
          { provenance = p,
            problem =
              unsupportedAnnotationTypeDescription (pretty NetworkDef) ident networkType
                <+> "as the use of the inferable parameter"
                <+> quotePretty implIdent
                <+> "in the type of network declarations is not currently supported.",
            fix =
              Just $
                "instanstiate inferable parameter"
                  <+> quotePretty implIdent
                  <+> "to an explicit value"
          }
    -- Dataset errors

    DatasetTypeUnsupportedContainer (ident, p) datasetType ->
      UError $
        UserError
          { provenance = p,
            problem =
              unsupportedAnnotationTypeDescription (pretty DatasetDef) ident datasetType
                <> "."
                  <+> "Only the following types are allowed for"
                  <+> pretty Dataset
                <> "s:"
                <> line
                <> indent 2 (prettyAllowedBuiltins supportedTypes),
            fix =
              Just $
                "change the type of"
                  <+> prettyIdentName ident
                  <+> "to a supported type."
          }
      where
        supportedTypes = map pretty [List, Vector] <> [pretty (identifierName TensorIdent)]
    DatasetTypeUnsupportedElement (ident, p) datasetType elementType ->
      UError $
        UserError
          { provenance = p,
            problem =
              unsupportedAnnotationTypeDescription (pretty DatasetDef) ident datasetType
                <+> "as it has elements of an unsupported type:"
                <> line
                <> indent 2 (prettyFriendlyEmptyCtx elementType)
                <> line
                <> "Only the following element types are allowed for"
                  <+> pretty Dataset
                <> "s:"
                <> line
                <> indent 2 (prettyAllowedBuiltins supportedTypes),
            fix =
              Just $
                "change the element type of"
                  <+> prettyIdentName ident
                  <+> "to a supported type."
          }
      where
        supportedTypes = map pretty [Index, Nat, Rat]
    DatasetVariableSizeTensor (ident, p) datasetType variableDim ->
      UError $
        UserError
          { provenance = p,
            problem =
              unsupportedAnnotationTypeDescription (pretty (ParameterDef NonInferable)) ident datasetType
                <+> "as the dimension size"
                <> line
                <> indent 2 (prettyFriendlyEmptyCtx variableDim)
                <> line
                <> "is not a constant.",
            fix = Just "make sure the dimensions of the dataset are all constants."
          }
    DatasetDimensionsMismatch (ident, p) file expectedType actualDims ->
      UError $
        UserError
          { provenance = p,
            problem =
              "Mismatch in the dimensions of"
                <+> prettyResource Dataset ident
                <> "."
                <> line
                <> "According to the specification it should be"
                  <+> pretty (dimensionsOf (normalised expectedType))
                <> "-dimensional"
                  <+> "but was actually found to be"
                  <+> pretty (length actualDims)
                <> "-dimensional"
                  <+> "when reading"
                  <+> quotePretty file
                <> ".",
            fix = Just $ datasetDimensionsFix "dimensions" ident file
          }
      where
        dimensionsOf :: WHNFType Builtin -> Int
        dimensionsOf = \case
          IListType _ t -> 1 + dimensionsOf t
          IVectorType _ t _ -> 1 + dimensionsOf t
          _ -> 0
    DatasetDimensionSizeMismatch (ident, p) file expectedSize actualSize allDimensions visitedDimensions ->
      UError $
        UserError
          { provenance = p,
            problem =
              "Mismatch in the size of"
                <+> dimension
                <+> "of"
                <+> prettyResource Dataset ident
                <> "."
                <> line
                <> "According to the specification it should be"
                  <+> quotePretty expectedSize
                  <+> "but was actually found to be"
                  <+> quotePretty actualSize
                  <+> "when reading"
                  <+> quotePretty file
                <> ".",
            fix = Just $ datasetDimensionsFix "dimensions" ident file
          }
      where
        numberOfCorrectDimensions = length allDimensions - length visitedDimensions
        dimension = prettyOrdinal "dimension" (numberOfCorrectDimensions + 1) Nothing
    DatasetInvalidNat (ident, p) file v ->
      UError $
        UserError
          { provenance = p,
            problem =
              "Mismatch in the type of elements of"
                <+> prettyResource Dataset ident
                <> "."
                <> line
                <> "Expected elements of type"
                  <+> quotePretty Nat
                  <+> "but found value"
                  <+> quotePretty v
                  <+> "when reading"
                  <+> quotePretty file
                <> ".",
            fix = Just $ datasetDimensionsFix "type" ident file
          }
    DatasetInvalidIndex (ident, p) file v n ->
      UError $
        UserError
          { provenance = p,
            problem =
              "Mismatch in the type of elements of"
                <+> prettyResource Dataset ident
                <> "."
                <> line
                <> "Expected elements of type"
                  <+> squotes (pretty Index <+> pretty n)
                  <+> "but found value"
                  <+> quotePretty v
                  <+> "when reading"
                  <+> quotePretty file
                <> ".",
            fix = Just $ datasetDimensionsFix "type" ident file
          }
    DatasetTypeMismatch (ident, p) file _datasetType expectedType actualType ->
      UError $
        UserError
          { provenance = p,
            problem =
              "Mismatch in the type of elements of"
                <+> prettyResource Dataset ident
                <> "."
                <> line
                <> "Expected elements of type"
                  <+> squotes (prettyFriendlyEmptyCtx expectedType)
                  <+> "but found elements of type"
                  <+> squotes actualType
                  <+> "when reading"
                  <+> quotePretty file
                <> ".",
            fix = Just $ datasetDimensionsFix "type" ident file
          }
    -- Parameter errors

    ParameterTypeUnsupported (ident, p) expectedType ->
      UError $
        UserError
          { provenance = p,
            problem =
              unsupportedAnnotationTypeDescription (pretty (ParameterDef NonInferable)) ident expectedType
                <> "."
                  <+> "Only the following types are allowed for"
                  <+> pretty Parameter
                <> "s:"
                <> line
                <> indent 2 (prettyAllowedBuiltins supportedTypes),
            fix =
              Just $
                "change the element type of"
                  <+> prettyIdentName ident
                  <+> "to a supported type."
          }
      where
        supportedTypes = map pretty [Bool, Index, Nat, Rat]
    ParameterValueUnparsable (ident, p) value expectedType ->
      UError $
        UserError
          { provenance = p,
            problem =
              "The value"
                <+> squotes (pretty value)
                <+> "provided for"
                <+> prettyResource Parameter ident
                <+> "could not be parsed as"
                <+> prettyBuiltinType expectedType
                <> ".",
            fix =
              Just $
                "either change the type of"
                  <+> prettyIdentName ident
                  <+> "in the specification or change the value provided."
          }
    ParameterTypeVariableSizeIndex (ident, p) parameterType ->
      UError $
        UserError
          { provenance = p,
            problem =
              unsupportedAnnotationTypeDescription (pretty (ParameterDef NonInferable)) ident parameterType
                <+> "as the size of the"
                <+> pretty Index
                <+> "type is not a known constant.",
            fix = Just "make sure the dimensions of the indices are all constants."
          }
    ParameterValueInvalidIndex (ident, p) value n ->
      UError $
        UserError
          { provenance = p,
            problem =
              "Mismatch in the type of"
                <+> prettyResource Parameter ident
                <> "."
                <> line
                <> "Expected something of type"
                  <+> squotes (pretty Index <+> pretty n)
                  <+> "but was provided the value"
                  <+> quotePretty value
                <> ".",
            fix =
              Just $
                "either change the size of the index or ensure the value"
                  <+> "provided is in the range"
                  <+> squotes ("0..." <> pretty (n - 1))
                  <+> "(inclusive)."
          }
    ParameterValueInvalidNat (ident, p) value ->
      UError $
        UserError
          { provenance = p,
            problem =
              "Mismatch in the type of"
                <+> prettyResource Parameter ident
                <> "."
                <> line
                <> "Expected something of type"
                  <+> quotePretty Nat
                  <+> "but was provided the value"
                  <+> quotePretty value
                <> ".",
            fix =
              Just $
                "either change the type of"
                  <+> prettyIdentName ident
                  <+> "or ensure the value provided is non-negative."
          }
    ParameterTypeInferableParameterIndex (ident, p) _varIndent ->
      UError $
        UserError
          { provenance = p,
            problem =
              "The use of an inferable parameter for the size of an"
                <+> pretty Index
                <+> "in the type of"
                <+> prettyResource Parameter ident
                <+> "is not currently supported.",
            fix =
              Just $
                "either replace the inferable parameter with a concrete value or"
                  <+> "open an issue on the Github tracker to request support."
          }
    InferableParameterTypeUnsupported (ident, p) expectedType ->
      UError $
        UserError
          { provenance = p,
            problem =
              unsupportedAnnotationTypeDescription (pretty (ParameterDef Inferable)) ident expectedType
                <> "."
                  <+> "Inferable parameters must be of type 'Nat'.",
            fix =
              Just $
                "either change the type of"
                  <+> prettyIdentName ident
                  <+> "or make the parameter non-inferable and provide the value manually."
          }
    InferableParameterContradictory ident ((ident1, _p1), r1, v1) ((ident2, p2), r2, v2) ->
      UError $
        UserError
          { provenance = p2,
            problem =
              "Found contradictory values for inferable parameter"
                <+> quotePretty ident
                <> "."
                <> "Inferred the value"
                  <+> squotes (pretty v1)
                  <+> "from"
                  <+> prettyResource r1 ident1
                <> "but inferred the value"
                  <+> squotes (pretty v2)
                  <+> "from"
                  <+> prettyResource r2 ident2
                <> ".",
            fix = Just "make sure the provided resources are consistent with each other."
          }
    InferableParameterUninferrable (ident, p) ->
      UError $
        UserError
          { provenance = p,
            problem =
              "Unable to infer the value of"
                <+> prettyResource Parameter ident
                <> ".",
            fix =
              Just $
                "For a parameter's value to be inferable, it must"
                  <+> "be used as the dimension of a dataset"
                  <+> "(networks will be supported later)."
          }
    PropertyTypeUnsupported (ident, p) actualType ->
      UError $
        UserError
          { provenance = p,
            problem =
              unsupportedAnnotationTypeDescription (pretty AnnProperty) ident actualType
                <> "."
                  <+> "Only the following types are allowed for"
                  <+> quotePretty AnnProperty
                <> "s:"
                <> line
                <> indent 2 (prettyAllowedBuiltins supportedTypes),
            fix =
              Just $
                "either change the type of"
                  <+> prettyIdentName ident
                  <+> "to a supported type or remove the"
                  <+> quotePretty AnnProperty
                  <+> "annotation."
          }
      where
        supportedTypes = ["Bool", "Vector Bool n", "Tensor Bool ns"]

    --------------------
    -- Backend errors --
    --------------------

    UnsupportedAlternatingQuantifiers queryFormat (ident, p) cause ->
      UError $
        UserError
          { provenance = p,
            problem =
              "The property"
                <+> prettyIdentName ident
                <+> "contains"
                <+> "alternating"
                <+> quotePretty Forall
                <+> "and"
                <+> quotePretty Exists
                <+> "quantifiers which is not supported by the"
                <+> pretty queryFormat
                <> "."
                <> line
                <> causeDoc,
            fix = Just "try simplifying the specification to avoid the alternating quantifiers."
          }
      where
        causeDoc :: Doc a
        causeDoc = case cause of
          Left err -> errorInSubsystemMessage "locate the original source of the alternating quantifiers" err
          Right (q, pq, pp) ->
            "In particular:"
              <> line
              <> indent 2 (prettyPolarityProvenance pq q pp)
    UnsupportedNonLinearConstraint queryFormat (ident, p) cause ->
      UError $
        UserError
          { provenance = p,
            problem =
              "The property"
                <+> prettyIdentName ident
                <+> "contains"
                <+> "a non-linear constraint which is not supported by the"
                <+> pretty queryFormat
                <> "."
                <> line
                <> causeDoc,
            fix =
              Just "try rewriting the specification to avoid the non-linearity."
          }
      where
        causeDoc :: Doc a
        causeDoc = case cause of
          Left err -> errorInSubsystemMessage "locate the original source of the non-linearity" err
          Right source -> case source of
            LinearTimesLinear opProv lhs rhs ->
              "In particular the multiplication in"
                <+> pretty opProv
                <+> "involves"
                <> prettyLinearityProvenance lhs "left hand side of the multiplication"
                <> "and"
                <> prettyLinearityProvenance rhs "right hand side of the multiplication"
            DivideByLinear opProv rhs ->
              "In particular the division in"
                <+> pretty opProv
                <+> "involves"
                <> prettyLinearityProvenance rhs "denominator of the division"
            PowLinearBase opProv lhs ->
              "In particular the power in"
                <+> pretty opProv
                <+> "involves"
                <> prettyLinearityProvenance lhs "base of the power"
            PowLinearExponent opProv lhs ->
              "In particular the power in"
                <+> pretty opProv
                <+> "involves"
                <> prettyLinearityProvenance lhs "exponent of the power"
    UnsupportedVariableType (ident, _) p name problemType baseType supportedTypes ->
      UError $
        UserError
          { provenance = p,
            problem =
              "Property"
                <+> prettyIdentName ident
                <+> "contains a quantified variable"
                <+> quotePretty name
                <+> "of type"
                <+> squotes (prettyFriendlyEmptyCtx baseType)
                <+> "which is not currently supported"
                <> "."
                <> ( if baseType == problemType
                       then ""
                       else
                         " In particular the element type"
                           <+> squotes (prettyFriendlyEmptyCtx problemType)
                           <+> "is not supported."
                   ),
            fix =
              Just $
                "try switching the variable to one of the following supported types:"
                  <+> pretty supportedTypes
          }
    UnsupportedInequality queryFormat (identifier, p) ->
      UError $
        UserError
          { provenance = p,
            problem =
              "After compilation, property"
                <+> prettyIdentName identifier
                <+> "contains a `!=` which is not current supported by the"
                <+> pretty queryFormat
                <> ". ",
            fix = Just (implementationLimitation (Just 74))
          }
    UnsupportedPolymorphicEquality target p typeName ->
      UError $
        UserError
          { provenance = p,
            problem =
              "The use of equality over the unknown type"
                <+> quotePretty typeName
                <+> "is not currently supported"
                <+> "when compiling to"
                <+> pretty target,
            fix =
              Just $
                "try avoiding it, otherwise open an issue on the"
                  <+> "Vehicle issue tracker describing the use case."
          }
    NoPropertiesFound ->
      UError $
        UserError
          { provenance = mempty,
            problem = "No properties found in file.",
            fix = Just $ "an expression is labelled as a property by giving it type" <+> squotes (pretty Bool) <+> "."
          }
    UnsupportedIfOperation _declProv ifProv ->
      UError $
        UserError
          { provenance = ifProv,
            problem =
              "Loss functions do not yet support compilation of"
                <+> quotePretty If
                <+> ".",
            fix = Just "choose a different differential logic"
          }
    DuplicateQuantifierNames (identifier, p) name ->
      UError $
        UserError
          { provenance = p,
            problem =
              "The property"
                <+> quotePretty identifier
                <+> "contains multiple quantified variables with the name"
                <+> quotePretty name
                <> ".",
            fix = Just "change the specification so that all quantified variables have unique names"
          }
    HigherOrderVectors (ident, p) ctx vecTyp elemTyp ->
      UError $
        UserError
          { provenance = p,
            problem =
              "The property"
                <+> quotePretty (nameOf ident)
                <+> "cannot be compiled to tensor code as it contains"
                <+> "the vector type:"
                <> line
                  <+> indent 2 (prettyFriendly (WithContext vecTyp ctx))
                <> line
                <> "Vectors with elements of type" <+> squotes (prettyFriendly (WithContext elemTyp ctx)) <+> "cannot currently be compiled:",
            fix = Nothing
          }
    NoQuantifierDomainFound (ident, _p) binder maybeUnboundedVariables ->
      UError $
        UserError
          { provenance = provenanceOf binder,
            problem =
              "The property"
                <+> quotePretty ident
                <+> "cannot be compiled to tensor code as the variable"
                <+> quotePretty (nameOf binder)
                <+> case maybeUnboundedVariables of
                  Nothing -> "has no bounds at all on it's value."
                  Just unboundedVariables -> "is missing the following bounds:" <> line <> prettyUnderConstrainedVariables unboundedVariables,
            fix = Just "Add inequalities that restrict the value of the variable both below and above."
          }

datasetDimensionsFix :: Doc a -> Identifier -> FilePath -> Doc a
datasetDimensionsFix feature ident file =
  "change the"
    <+> feature
    <+> "of"
    <+> prettyIdentName ident
    <+> "in the specification"
    <+> "or check that"
    <+> quotePretty (takeFileName file)
    <+> "is in the format you were expecting."

unsupportedAnnotationTypeDescription ::
  (PrintableBuiltin builtin) =>
  Doc a ->
  Identifier ->
  GluedType builtin ->
  Doc a
unsupportedAnnotationTypeDescription annotation ident resourceType =
  "The type of"
    <+> annotation
    <+> quotePretty (nameOf ident :: Text)
    <> ":"
    <> line
    <> indent 2 (prettyFriendlyEmptyCtx unreducedResourceType)
    <> line
    <> ( if reducedResourceType == unreducedResourceType
           then ""
           else
             "which reduces to:"
               <> line
               <> indent 2 (prettyFriendlyEmptyCtx reducedResourceType)
               <> line
       )
    <> "is not supported"
  where
    unreducedResourceType = unnormalised resourceType
    reducedResourceType = unnormalise 0 (normalised resourceType)

supportedNetworkTypeDescription :: Doc a
supportedNetworkTypeDescription =
  "Only networks of the following types are allowed:"
    <> line
    <> indent 2 "Tensor Rat [a_1, ..., a_n] -> Tensor Rat [b_1, ..., b_n]"
    <> line
    <> "where 'a_i' and 'b_i' are all constants."

errorInSubsystemMessage :: Doc a -> CompileError -> Doc a
errorInSubsystemMessage task err =
  line
    <> "Unfortunately while trying to"
      <+> task
    <> ","
      <+> "the following error was encountered:"
    <> line
    <> indent 2 (pretty (details err))
    <> line
    <> "Please report this as an issue on Github"
      <+> parens githubIssues
    <> line

githubIssues :: Doc a
githubIssues = "https://github.com/vehicle-lang/vehicle/issues/"

implementationLimitation :: Maybe Int -> Doc a
implementationLimitation issue =
  "This is a limitation of the current implementation rather than a fundamental problem."
    <+> case issue of
      Nothing -> "If you would like this to be fixed, please open an issue at" <+> squotes githubIssues
      Just issueNumber ->
        "If you would like this to be fixed, please comment at"
          <+> squotes (githubIssues <+> pretty issueNumber)
          <> "."

prettyResource :: ExternalResource -> Identifier -> Doc a
prettyResource resourceType ident =
  pretty resourceType <+> prettyIdentName ident

prettyBuiltinType :: BuiltinType -> Doc a
prettyBuiltinType t = article <+> squotes (pretty t)
  where
    article :: Doc a
    article = case t of
      Index -> "an"
      _ -> "a"

prettyQuantifierArticle :: Quantifier -> Doc a
prettyQuantifierArticle q =
  (if q == Forall then "a" else "an") <+> squotes (pretty q)

prettyPolarityProvenance :: Provenance -> Quantifier -> PolarityProvenance -> Doc a
prettyPolarityProvenance topQuantifierProv topQuantifier bottomQuantifierProvenance =
  let bottomQuantifier = neg topQuantifier
   in numberedList $ reverse (finalLine : go bottomQuantifier bottomQuantifierProvenance)
  where
    go :: Quantifier -> PolarityProvenance -> [Doc a]
    go q = \case
      QuantifierProvenance p ->
        ["the inner quantifier is the" <+> quotePretty q <+> "located in" <+> pretty p]
      NegateProvenance p pp ->
        transform p ("the" <+> quotePretty Not) : go (neg q) pp
      LHSImpliesProvenance p pp ->
        transform p ("being on the LHS of the" <+> quotePretty Implies) : go (neg q) pp
      EqProvenance p pp eq ->
        transform p ("being involved in the" <+> quotePretty (EqualsTC eq)) : go (neg q) pp
      PolFunctionProvenance p pp position ->
        surround p (prettyAuxiliaryFunctionProvenance position) : go q pp
      where
        surround p x =
          "which is" <+> x <+> "in" <+> pretty p

        transform p x =
          surround p ("turned into" <+> prettyQuantifierArticle q <+> "by" <+> x)

    finalLine :: Doc a
    finalLine =
      "which alternates with the outer"
        <+> quotePretty topQuantifier
        <+> "in"
        <+> pretty topQuantifierProv

prettyLinearityProvenance :: forall a. LinearityProvenance -> Doc a -> Doc a
prettyLinearityProvenance lp location =
  line <> indent 2 (numberedList $ reverse (finalLine : go lp)) <> line
  where
    go :: LinearityProvenance -> [Doc a]
    go = \case
      QuantifiedVariableProvenance p v ->
        ["the quantified variable" <+> quotePretty v <+> "introduced in" <+> pretty p]
      NetworkOutputProvenance p networkName ->
        ["the output of network" <+> squotes (pretty networkName) <+> "in" <+> pretty p]
      LinFunctionProvenance p pp position ->
        (prettyAuxiliaryFunctionProvenance position <+> "in" <+> pretty p) : go pp

    finalLine :: Doc a
    finalLine = "which is used in the" <+> location

prettyAuxiliaryFunctionProvenance :: FunctionPosition -> Doc a
prettyAuxiliaryFunctionProvenance = \case
  FunctionInput n _ -> "which is used as an input to the function" <+> quotePretty n
  FunctionOutput n -> "which is returned as an output of the function" <+> quotePretty n

prettyAllowedBuiltins :: [Doc b] -> Doc b
prettyAllowedBuiltins = commaSep

prettyOrdinal :: Doc b -> Int -> Maybe Int -> Doc b
prettyOrdinal object argNo argTotal
  | argTotal == Just 1 = "the" <+> object
  | argNo > 9 = object <+> pretty argNo
  | otherwise = "the" <+> prettyOrd argNo <+> object
  where
    prettyOrd :: Int -> Doc b
    prettyOrd = \case
      1 -> "first"
      2 -> "second"
      3 -> "third"
      4 -> "fourth"
      5 -> "fifth"
      6 -> "sixth"
      7 -> "seventh"
      8 -> "eighth"
      9 -> "ninth"
      _ -> developerError "Cannot convert ordinal"

prettyTypeClassConstraintOriginExpr ::
  (PrintableBuiltin builtin) =>
  ConstraintContext builtin ->
  Expr Ix builtin ->
  [Arg Ix builtin] ->
  Doc a
prettyTypeClassConstraintOriginExpr ctx fun args = do
  let expr = case fun of
        -- We don't want to print out the actual coercion functions as the user is
        -- oblivious to them. Instead we want to print out what they are applied to.
        Builtin _ b | isCoercion b -> argExpr $ last args
        _ -> fun
  prettyFriendly $ WithContext expr (namedBoundCtxOf ctx)

prettyUnificationConstraintOriginExpr ::
  (PrintableBuiltin builtin) =>
  ConstraintContext builtin ->
  Expr Ix builtin ->
  Doc a
prettyUnificationConstraintOriginExpr ctx expr =
  prettyFriendly $ WithContext expr (namedBoundCtxOf ctx)

prettyIdentName :: Identifier -> Doc a
prettyIdentName ident = quotePretty (nameOf ident :: Name)
