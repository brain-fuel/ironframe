-- | Podman for local environments: finding it, checking its compose provider,
-- making sure every image is present before anything starts, and bringing the
-- compose project up and down. An image that cannot be found or pulled stops
-- @up@ before a single container runs. ref:DEC-podman-compose
-- ref:REQ-missing-image-fails-clearly
module Ironframe.Podman
  ( podmanFallbacks
  , MissingImage (..)
  , PodmanError (..)
  , renderPodmanError
  , Podman (..)
  , locatePodman
  , checkCompose
  , ensureImages
  , imageLabels
  , imageDigest
  , hasImage
  , buildImage
  , composeUp
  , composeDown
  , ContainerState (..)
  , containers
  , parsePs
  ) where

import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as T
import Ironframe.Compose (labelDependency, labelEnvironment, labelKind, labelProject)
import Ironframe.Effect
import Ironframe.Json.FromStr (Expect (..), fromStr)
import Ironframe.Json.Serde
import Ironframe.Process (lastLine)

-- | Where podman is looked for after @IRONFRAME_PODMAN@ and PATH.
podmanFallbacks :: [Text]
podmanFallbacks = ["/opt/podman/bin/podman"]

data MissingImage = MissingImage {missingNeededBy :: Text, missingImage :: Text, missingReason :: Text}

data PodmanError
  = PodmanNotInstalled
  | ComposeUnavailable Text
  | ImagesUnavailable [MissingImage]
  | PodmanFailed Text Text
  | PodmanIo Text Text

renderPodmanError :: PodmanError -> Text
renderPodmanError = \case
  PodmanNotInstalled ->
    "podman is required for a podman environment but was not found: set IRONFRAME_PODMAN, put podman on PATH, or install it from https://podman.io (the macOS installer puts it at /opt/podman/bin/podman)"
  ComposeUnavailable reason ->
    "`podman compose` does not work: " <> reason <> "; install podman-compose or docker-compose, which podman compose runs"
  ImagesUnavailable missing ->
    T.pack (show (length missing)) <> " image(s) the environment needs are not available, so nothing was started:"
      <> T.concat
        [ "\n  - " <> missingNeededBy m <> " needs " <> missingImage m <> ": not present locally, and pulling it failed: " <> missingReason m
        | m <- missing
        ]
      <> "\nBuild or pull each image, or bind the dependency to something else in the manifest."
  PodmanFailed command reason -> "`podman " <> command <> "` failed: " <> reason
  PodmanIo program reason -> "cannot run podman at " <> program <> ": " <> reason

newtype Podman = Podman {podmanProgram :: Text}

-- | Finds podman: @IRONFRAME_PODMAN@, then PATH, then the fallbacks.
locatePodman :: Eff (Either PodmanError Podman)
locatePodman = maybe (Left PodmanNotInstalled) (Right . Podman) <$> locate "IRONFRAME_PODMAN" ["podman"] podmanFallbacks

run :: Podman -> [Text] -> Bool -> Eff (Either PodmanError ProcessOutput)
run p args stream = either (Left . PodmanIo (podmanProgram p) . ioMessage) Right <$> runProcess (podmanProgram p) args stream

runChecked :: Podman -> [Text] -> Bool -> Eff (Either PodmanError ProcessOutput)
runChecked p args stream = do
  r <- run p args stream
  pure $ case r of
    Right out
      | procSuccess out -> Right out
      | otherwise -> Left (PodmanFailed (T.unwords args) (if stream then "see the output above" else lastLine (procStderr out)))
    Left e -> Left e

-- | Checks that @podman compose@ has a provider to run.
checkCompose :: Podman -> Eff (Either PodmanError ())
checkCompose p = do
  r <- run p ["compose", "version"] False
  pure $ case r of
    Right out
      | procSuccess out -> Right ()
      | otherwise -> Left (ComposeUnavailable (lastLine (procStderr out)))
    Left e -> Left e

-- | Makes sure every image is present, pulling those that are not, and
-- reports every one that stays missing.
ensureImages :: Podman -> [(Text, Text)] -> Eff (Either PodmanError ())
ensureImages p images = go [] images
  where
    go missing [] = pure (if null missing then Right () else Left (ImagesUnavailable (reverse missing)))
    go missing ((neededBy, image) : rest) = do
      exists <- run p ["image", "exists", image] False
      case exists of
        Left e -> pure (Left e)
        Right out
          | procSuccess out -> go missing rest
          | otherwise -> do
              pulled <- run p ["pull", "--quiet", image] False
              case pulled of
                Left e -> pure (Left e)
                Right o
                  | procSuccess o -> go missing rest
                  | otherwise -> go (MissingImage neededBy image (lastLine (procStderr o)) : missing) rest

-- | The labels of an image that is present.
imageLabels :: Podman -> Text -> Eff (Either PodmanError (Map Text Text))
imageLabels p image = do
  r <- runChecked p ["image", "inspect", "--format", "{{json .Config.Labels}}", image] False
  pure $ do
    out <- r
    let text = T.strip (procStdout out)
    if T.null text || text == "null"
      then Right Map.empty
      else either (Left . PodmanFailed ("image inspect " <> image)) Right (fromStr ExpectMap (textMap string) text)

-- | The digest of an image that is present, @sha256:<hex>@.
imageDigest :: Podman -> Text -> Eff (Maybe Text)
imageDigest p image = do
  r <- run p ["image", "inspect", "--format", "{{.Digest}}", image] False
  pure $ case r of
    Right out
      | procSuccess out, let d = T.strip (procStdout out), "sha256:" `T.isPrefixOf` d -> Just d
    _ -> Nothing

hasImage :: Podman -> Text -> Eff Bool
hasImage p image = either (const False) procSuccess <$> run p ["image", "exists", image] False

-- | Builds an image from a context directory.
buildImage :: Podman -> Text -> Maybe Text -> Text -> Eff (Either PodmanError ())
buildImage p context containerfile tag =
  fmap (() <$) (runChecked p (["build", "-t", tag] ++ maybe [] (\f -> ["-f", f]) containerfile ++ [context]) True)

composeUp :: Podman -> Text -> Text -> Eff (Either PodmanError ())
composeUp p file project = fmap (() <$) (runChecked p ["compose", "-f", file, "-p", project, "up", "-d"] True)

composeDown :: Podman -> Text -> Text -> Eff (Either PodmanError ())
composeDown p file project = fmap (() <$) (runChecked p ["compose", "-f", file, "-p", project, "down"] True)

-- | One container of an environment as podman reports it.
data ContainerState = ContainerState
  { csDependency :: Text
  , csKind :: Text
  , csName :: Text
  , csImage :: Text
  , csState :: Text
  }

-- | The containers of one environment, found by their labels.
containers :: Podman -> Text -> Text -> Eff (Either PodmanError [ContainerState])
containers p project environment = do
  r <-
    runChecked
      p
      [ "ps"
      , "-a"
      , "--filter"
      , "label=" <> labelProject <> "=" <> project
      , "--filter"
      , "label=" <> labelEnvironment <> "=" <> environment
      , "--format"
      , "json"
      ]
      False
  pure (r >>= parsePs . procStdout)

data PsEntry = PsEntry [Text] Text Text (Maybe (Map Text Text))

-- | Reads @podman ps --format json@.
parsePs :: Text -> Either PodmanError [ContainerState]
parsePs text
  | T.null (T.strip text) = Right []
  | otherwise = case fromStr ExpectSeq (vec entry) text of
      Left e -> Left (PodmanFailed "ps --format json" e)
      Right entries -> Right (map toState entries)
  where
    entry =
      struct "PsEntry" False $
        PsEntry
          <$> defaulted "Names" [] (vec string)
          <*> defaulted "Image" "" string
          <*> defaulted "State" "" string
          <*> optional "Labels" (textMap string)
    toState (PsEntry names image state labels) =
      let ls = maybe Map.empty id labels
       in ContainerState
            { csDependency = Map.findWithDefault "" labelDependency ls
            , csKind = Map.findWithDefault "" labelKind ls
            , csName = case names of
                (n : _) -> n
                [] -> ""
            , csImage = image
            , csState = state
            }
