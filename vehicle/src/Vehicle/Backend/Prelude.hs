module Vehicle.Backend.Prelude where

import Control.Monad.IO.Class
import Data.Text.IO qualified as TIO
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)
import Vehicle.Prelude
import Vehicle.Verify.Core

--------------------------------------------------------------------------------
-- Differentiable logics

-- | Different ways of translating from the logical constraints to loss functions.
data DifferentiableLogic
  = DL2
  | Godel
  | Lukasiewicz
  | Product
  | Yager
  | STL
  deriving (Eq, Show, Read, Bounded, Enum)

instance Pretty DifferentiableLogic where
  pretty = pretty . show

--------------------------------------------------------------------------------
-- Interactive theorem provers

data ITP
  = Agda
  deriving (Eq, Show, Read, Bounded, Enum)

instance Pretty ITP where
  pretty = \case
    Agda -> "Agda"

--------------------------------------------------------------------------------
-- Different type-checking modes

data TypingSystem
  = Standard
  | Polarity
  | Linearity
  deriving (Eq, Show, Bounded, Enum)

instance Read TypingSystem where
  readsPrec _d x = case x of
    "Standard" -> [(Standard, [])]
    "Linearity" -> [(Linearity, [])]
    "Polarity" -> [(Polarity, [])]
    _ -> []

--------------------------------------------------------------------------------
-- Action

data Target
  = ITP ITP
  | JSON
  | VerifierQueries QueryFormatID
  | LossFunction DifferentiableLogic
  deriving (Eq, Show)

instance Pretty Target where
  pretty = \case
    ITP x -> pretty $ show x
    JSON -> "JSON"
    VerifierQueries x -> pretty x
    LossFunction _ -> "LossFunction"

instance Read Target where
  readsPrec _d x = case x of
    "JSON" -> [(JSON, [])]
    "MarabouQueries" -> [(VerifierQueries MarabouQueryFormat, [])]
    "LossFunction" -> [(LossFunction DL2, [])]
    "LossFunction-DL2" -> [(LossFunction DL2, [])]
    "LossFunction-Godel" -> [(LossFunction Godel, [])]
    "LossFunction-Lukasiewicz" -> [(LossFunction Lukasiewicz, [])]
    "LossFunction-Product" -> [(LossFunction Product, [])]
    "LossFunction-Yager" -> [(LossFunction Yager, [])]
    "LossFunction-STL" -> [(LossFunction STL, [])]
    "Agda" -> [(ITP Agda, [])]
    _ -> []

-- | Generate the file header given the token used to start comments in the
--  target language
prependfileHeader :: Doc a -> Maybe ExternalOutputFormat -> Doc a
prependfileHeader doc format = case format of
  Nothing -> doc
  Just ExternalOutputFormat {..} ->
    vsep
      ( map
          (commentToken <+>)
          [ "WARNING: This file was generated automatically by Vehicle",
            "and should not be modified manually!",
            "Metadata:",
            " -" <+> formatName <> " version:" <+> targetVersion,
            " - Vehicle version:" <+> pretty impreciseVehicleVersion
          ]
      )
      <> line
      -- Marabou query format doesn't current support empty lines.
      -- See https://github.com/NeuralNetworkVerification/Marabou/issues/625
      <> (if emptyLines then line else "")
      <> doc
    where
      targetVersion = maybe "unknown" pretty formatVersion

writeResultToFile ::
  (MonadIO m, MonadLogger m) =>
  Maybe ExternalOutputFormat ->
  Maybe FilePath ->
  Doc a ->
  m ()
writeResultToFile target filepath doc = do
  logDebug MaxDetail $ "Creating file:" <+> pretty filepath
  let text = layoutAsText $ prependfileHeader doc target
  liftIO $ case filepath of
    Nothing -> TIO.putStrLn text
    Just outputFilePath -> do
      createDirectoryIfMissing True (takeDirectory outputFilePath)
      TIO.writeFile outputFilePath text
