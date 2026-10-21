-- | Syncing an environment's settings into the places applications already
-- read configuration from: a dotenv file, AWS AppConfig, GCP Parameter
-- Manager and Azure App Configuration. Each cloud is reached through calls the
-- host makes with the cloud's official SDK; the decisions, what to create,
-- when to write a version and when to leave things alone, are made here.
-- ref:DEC-config-sync
module Ironframe.Sync
  ( SyncOutcome (..)
  , SyncError (..)
  , renderSyncError
  , renderOutcome
  , describeTarget
  , settingsJson
  , versionId
  , defaultStrategy
  , ConnectionString (..)
  , parseConnectionString
  , CloudClients (..)
  , realClouds
  , recordedClouds
  , syncEnvFile
  , syncAws
  , syncGcp
  , syncAzure
  , envFileHeader
  ) where

import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Char (toLower)
import Data.Text (Text)
import qualified Data.Text as T
import Ironframe.Digest (versionId)
import Ironframe.Effect
import Ironframe.Json
import Ironframe.Manifest
import qualified Ironframe.Path as Path
import Ironframe.Rust (debugStr)
import Ironframe.Settings (renderDotenv)

data SyncOutcome = Unchanged | Updated Text
  deriving (Show, Eq)

renderOutcome :: SyncOutcome -> Text
renderOutcome = \case
  Unchanged -> "unchanged"
  Updated detail -> "updated (" <> detail <> ")"

data SyncError = SyncError {syncTarget :: Text, syncReason :: Text}
  deriving (Show, Eq)

renderSyncError :: SyncError -> Text
renderSyncError (SyncError target reason) = "sync to " <> target <> " failed: " <> reason

-- | A one-line name for a target.
describeTarget :: SyncTarget -> Text -> Text
describeTarget target environment = case target of
  SyncEnvFile t -> "env file " <> Path.display (envFilePath t)
  SyncAws t ->
    "AWS AppConfig " <> awsApplication t <> "/" <> maybe environment id (awsEnvironment t) <> "/" <> awsProfile t <> " in " <> awsRegion t
  SyncGcp t -> "GCP Parameter Manager projects/" <> gcpProject t <> "/locations/" <> gcpLocation t <> "/parameters/" <> gcpParameter t
  SyncAzure t -> "Azure App Configuration " <> azureEndpoint t <> " label " <> maybe environment id (azureLabel t)

-- | The settings as the JSON document AppConfig and Parameter Manager hold.
settingsJson :: Map Text Text -> Text
settingsJson settings = encodePretty (fromTextMap settings) <> "\n"

-- | AppConfig's predefined all-at-once strategy.
defaultStrategy :: Text
defaultStrategy = "AppConfig.AllAtOnce"

-- | The parts of an App Configuration connection string.
data ConnectionString = ConnectionString {csEndpoint :: Text, csId :: Text, csSecret :: Text}

parseConnectionString :: Text -> Either Text ConnectionString
parseConnectionString text = do
  parts <- mapM part (filter (not . T.null . T.strip) (T.splitOn ";" text))
  let m = Map.fromList parts
      take' k = maybe (Left ("connection string has no " <> k)) Right (Map.lookup k m)
  ConnectionString <$> take' "endpoint" <*> take' "id" <*> take' "secret"
  where
    part p = case T.breakOn "=" p of
      (_, "") -> Left ("connection string part " <> debugStr p <> " has no =")
      (k, v) -> Right (T.map lowerAscii (T.strip k), T.strip (T.drop 1 v))
    lowerAscii c = if c >= 'A' && c <= 'Z' then toLower c else c

-- | How a sync reaches each cloud's client before calling it: the real one
-- checks what the client needs; a recorded one needs nothing.
newtype CloudClients = CloudClients
  { azureClient :: AzureAppConfigurationTarget -> Eff (Either Text ())
  }

realClouds :: CloudClients
realClouds = CloudClients $ \t -> do
  text <- getEnv (azureConnectionStringEnv t)
  pure $ case text of
    Nothing -> Left ("set " <> azureConnectionStringEnv t <> " to the store's connection string")
    Just conn -> () <$ parseConnectionString conn

recordedClouds :: CloudClients
recordedClouds = CloudClients (const (pure (Right ())))

envFileHeader :: Text -> Text -> Text
envFileHeader project environment =
  "Settings of environment " <> environment <> " of " <> project
    <> ", written by ironframe from the manifest or architecture.\nEdits are overwritten; change those instead."

-- | Writes the settings to a dotenv file relative to the manifest's directory.
syncEnvFile :: EnvFileTarget -> Text -> Text -> Text -> Map Text Text -> Eff (Either SyncError SyncOutcome)
syncEnvFile target manifestDir project environment settings = do
  let path = Path.join manifestDir (envFilePath target)
  r <- writeAtomically path (renderDotenv (envFileHeader project environment) settings)
  pure $ case r of
    Right True -> Right (Updated (Path.display path))
    Right False -> Right Unchanged
    Left e -> Left (SyncError ("env file " <> Path.display path) (ioMessage e))

call :: (Text -> SyncError) -> Text -> [(Text, Value)] -> Eff (Either SyncError Value)
call failed name fields = either (Left . failed) Right <$> cloudCall name fields

-- | Syncs settings into an AppConfig hosted configuration profile.
syncAws :: AwsAppConfigTarget -> Text -> Map Text Text -> Eff (Either SyncError SyncOutcome)
syncAws t environment settings = do
  let failed = SyncError (describeTarget (SyncAws t) environment)
      region = "region" .= String (awsRegion t)
      environmentName = maybe environment id (awsEnvironment t)
      ensure findName createName extra name = do
        found <- call failed findName ([region] ++ extra ++ ["name" .= String name])
        case found of
          Left e -> pure (Left e)
          Right (String i) -> pure (Right i)
          Right _ -> do
            created <- call failed createName ([region] ++ extra ++ ["name" .= String name])
            pure (created >>= asText)
      asText = \case
        String i -> Right i
        other -> Right (encode other)
  result <- ensure "aws.findApplication" "aws.createApplication" [] (awsApplication t)
  case result of
    Left e -> pure (Left e)
    Right application -> do
      let app = "application" .= String application
      envId <- ensure "aws.findEnvironment" "aws.createEnvironment" [app] environmentName
      case envId of
        Left e -> pure (Left e)
        Right environmentId -> do
          profileId <- ensure "aws.findProfile" "aws.createProfile" [app] (awsProfile t)
          case profileId of
            Left e -> pure (Left e)
            Right profile -> do
              let content = settingsJson settings
                  prof = "profile" .= String profile
              latest <- call failed "aws.latestVersion" [region, app, prof]
              case latest of
                Left e -> pure (Left e)
                Right v
                  | Just (String c) <- key "content" v, c == content -> pure (Right Unchanged)
                  | otherwise -> do
                      created <- call failed "aws.createVersion" [region, app, prof, "content" .= String content]
                      case created of
                        Left e -> pure (Left e)
                        Right version -> do
                          deployed <-
                            call
                              failed
                              "aws.deploy"
                              [ region
                              , app
                              , "environment" .= String environmentId
                              , prof
                              , "version" .= version
                              , "strategy" .= String (maybe defaultStrategy id (awsDeploymentStrategy t))
                              ]
                          pure $ do
                            deployment <- deployed
                            Right (Updated ("version " <> encode version <> ", deployment " <> encode deployment))

-- | Syncs settings into a Parameter Manager parameter, one version per
-- distinct content.
syncGcp :: GcpParameterTarget -> Text -> Map Text Text -> Eff (Either SyncError SyncOutcome)
syncGcp t environment settings = do
  let failed = SyncError (describeTarget (SyncGcp t) environment)
      parent = "projects/" <> gcpProject t <> "/locations/" <> gcpLocation t
      name = parent <> "/parameters/" <> gcpParameter t
  exists <- call failed "gcp.parameterExists" ["name" .= String name]
  case exists of
    Left e -> pure (Left e)
    Right present -> do
      made <-
        if present == Bool True
          then pure (Right Null)
          else call failed "gcp.createParameter" ["parent" .= String parent, "id" .= String (gcpParameter t)]
      case made of
        Left e -> pure (Left e)
        Right _ -> do
          let content = settingsJson settings
              vid = versionId content
          created <- call failed "gcp.createVersion" ["parameter" .= String name, "id" .= String vid, "data" .= String content]
          pure $ case created of
            Left e -> Left e
            Right (String "exists") -> Right Unchanged
            Right _ -> Right (Updated ("version " <> vid))

-- | Syncs settings into an App Configuration store, writing only the keys
-- whose value differs.
syncAzure :: AzureAppConfigurationTarget -> Text -> Map Text Text -> Eff (Either SyncError SyncOutcome)
syncAzure t environment settings = go [] (Map.toAscList settings)
  where
    failed = SyncError (describeTarget (SyncAzure t) environment)
    label = maybe environment id (azureLabel t)
    common k = ["endpoint" .= String (azureEndpoint t), "connectionStringEnv" .= String (azureConnectionStringEnv t), "key" .= String k, "label" .= String label]
    go written [] = pure (Right (if null written then Unchanged else Updated (T.intercalate ", " (reverse written))))
    go written ((k0, v) : rest) = do
      let k = azurePrefix t <> k0
      current <- call failed "azure.get" (common k)
      case current of
        Left e -> pure (Left e)
        Right (String existing) | existing == v -> go written rest
        Right _ -> do
          put <- call failed "azure.put" (common k ++ ["value" .= String v])
          case put of
            Left e -> pure (Left e)
            Right _ -> go (k : written) rest
