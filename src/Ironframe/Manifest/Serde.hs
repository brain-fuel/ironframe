-- | The manifest's types read from and written to JSON values as the Rust
-- implementation's derived Deserialize and Serialize do, following the serde
-- attributes of manifest.rs: field names and order, defaults, denied unknown
-- fields, enum tagging, flatten, and the fields skipped when empty. Reading
-- gives serde_json's from_value messages. ref:DEC-haskell-wasm-core
module Ironframe.Manifest.Serde
  ( -- * Reading
    decodeManifest
  , manifestDecoder
  , decodeDependencyDecl
  , decodeEnvironment
  , decodeRuntime
  , decodeProtocol
  , decodeCloud
  , decodeBinding
  , decodeReal
  , decodeTwin
  , decodeConformance
  , decodeConformanceSource
  , decodeFault
  , decodeAdmin
  , decodeSyncTarget
  , decodeEnvFileTarget
  , decodeAwsAppConfigTarget
  , decodeGcpParameterTarget
  , decodeAzureAppConfigurationTarget
  , decodeConfigService
    -- * Writing
  , encodeManifest
  , encodeDependencyDecl
  , encodeEnvironment
  , encodeRuntime
  , encodeProtocol
  , encodeCloud
  , encodeBinding
  , encodeReal
  , encodeTwin
  , encodeConformance
  , encodeConformanceSource
  , encodeFault
  , encodeAdmin
  , encodeSyncTarget
  , encodeConfigService
  ) where

import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Ironframe.Json
import Ironframe.Json.Serde
import Ironframe.Manifest.Types
import Prelude hiding (Real)

------------------------------------------------------------------------------
-- Reading

-- | @serde_json::from_value::<Manifest>@.
decodeManifest :: Value -> Either Text Manifest
decodeManifest = decodeWith manifestDecoder

-- | @Manifest@: version, project, dependencies and environments, all needed.
manifestDecoder :: Decoder Manifest
manifestDecoder =
  struct "Manifest" True $
    Manifest
      <$> required "version" u32
      <*> required "project" string
      <*> required "dependencies" (textMap decodeDependencyDecl)
      <*> required "environments" (textMap decodeEnvironment)

-- | @DependencyDecl@.
decodeDependencyDecl :: Decoder DependencyDecl
decodeDependencyDecl =
  struct "DependencyDecl" True $
    DependencyDecl
      <$> optional "description" string
      <*> required "settings" (textMap string)

-- | @Environment@.
decodeEnvironment :: Decoder Environment
decodeEnvironment =
  struct "Environment" True $
    Environment
      <$> required "runtime" decodeRuntime
      <*> optional "cloud" decodeCloud
      <*> required "dependencies" (textMap decodeBinding)
      <*> defaulted "sync" [] (vec decodeSyncTarget)
      <*> optional "config_service" decodeConfigService

-- | @Runtime@, lowercase unit variants.
decodeRuntime :: Decoder Runtime
decodeRuntime = unitVariants "Runtime" [(runtimeWord r, r) | r <- [minBound .. maxBound]]

-- | @Protocol@, lowercase unit variants.
decodeProtocol :: Decoder Protocol
decodeProtocol = unitVariants "Protocol" [("http", Http), ("tcp", Tcp)]

-- | @Cloud@: @modules@, and every other key flattened into the inputs. It
-- denies nothing, and reads only from an object, as a struct with a
-- flattened field does.
decodeCloud :: Decoder Cloud
decodeCloud = mapDecoder $ \case
  Object pairs -> do
    let modulesDecoder = option string
    modules <- case lookup "modules" pairs of
      Just v -> decodeWith modulesDecoder v
      Nothing -> Right Nothing
    pure (Cloud modules (Map.fromList [(k, v) | (k, v) <- pairs, k /= "modules"]))
  v -> Left (invalidType v "struct Cloud")

-- | @Binding@, externally tagged: @real@ or @twin@.
decodeBinding :: Decoder Binding
decodeBinding = externallyTagged "Binding" [("real", BindReal <$> decodeReal), ("twin", BindTwin <$> decodeTwin)]

-- | @Real@.
decodeReal :: Decoder Real
decodeReal =
  struct "Real" True $
    Real
      <$> required "endpoint" string
      <*> optional "credentials" string
      <*> optional "image" string
      <*> defaulted "ports" [] (vec u16)
      <*> defaulted "env" Map.empty (textMap string)

-- | @Twin@; its report is skipped, so it reads as absent.
decodeTwin :: Decoder Twin
decodeTwin =
  struct "Twin" True $
    Twin
      <$> required "image" string
      <*> required "version" string
      <*> optional "config" value
      <*> required "conformance" decodeConformance
      <*> required "ports" (vec u16)
      <*> defaulted "env" Map.empty (textMap string)
      <*> optional "endpoint" string
      <*> optional "credentials" string
      <*> optional "seed" u64
      <*> optional "contract" string
      <*> optional "state" value
      <*> defaulted "faults" [] (vec decodeFault)
      <*> optional "admin" decodeAdmin
      <*> optional "protocol" decodeProtocol
      <*> optional "advertise_variable" string
      <*> pure Nothing

-- | @Conformance@, untagged: a level word, or where to read it.
decodeConformance :: Decoder Conformance
decodeConformance = untagged "Conformance" [Level <$> string, Sourced <$> decodeConformanceSource]

-- | @ConformanceSource@.
decodeConformanceSource :: Decoder ConformanceSource
decodeConformanceSource =
  struct "ConformanceSource" True $
    ConformanceSource
      <$> optional "level" string
      <*> optional "report" pathBuf
      <*> optional "image_label" string

-- | @Fault@.
decodeFault :: Decoder Fault
decodeFault =
  struct "Fault" True $
    Fault
      <$> required "name" string
      <*> defaulted "params" Map.empty (textMap value)

-- | @Admin@.
decodeAdmin :: Decoder Admin
decodeAdmin =
  struct "Admin" True $
    Admin
      <$> optional "port" u16
      <*> defaulted "container_port" defaultAdminContainerPort u16
      <*> optional "url" string

-- | @SyncTarget@, externally tagged in snake case.
decodeSyncTarget :: Decoder SyncTarget
decodeSyncTarget =
  externallyTagged
    "SyncTarget"
    [ ("env_file", SyncEnvFile <$> decodeEnvFileTarget)
    , ("aws_appconfig", SyncAws <$> decodeAwsAppConfigTarget)
    , ("gcp_parameter_manager", SyncGcp <$> decodeGcpParameterTarget)
    , ("azure_app_configuration", SyncAzure <$> decodeAzureAppConfigurationTarget)
    ]

-- | @EnvFileTarget@.
decodeEnvFileTarget :: Decoder EnvFileTarget
decodeEnvFileTarget = struct "EnvFileTarget" True (EnvFileTarget <$> required "path" pathBuf)

-- | @AwsAppConfigTarget@.
decodeAwsAppConfigTarget :: Decoder AwsAppConfigTarget
decodeAwsAppConfigTarget =
  struct "AwsAppConfigTarget" True $
    AwsAppConfigTarget
      <$> required "region" string
      <*> required "application" string
      <*> optional "environment" string
      <*> required "profile" string
      <*> optional "deployment_strategy" string

-- | @GcpParameterTarget@; the location is @global@ when absent.
decodeGcpParameterTarget :: Decoder GcpParameterTarget
decodeGcpParameterTarget =
  struct "GcpParameterTarget" True $
    GcpParameterTarget
      <$> required "project" string
      <*> defaulted "location" "global" string
      <*> required "parameter" string

-- | @AzureAppConfigurationTarget@.
decodeAzureAppConfigurationTarget :: Decoder AzureAppConfigurationTarget
decodeAzureAppConfigurationTarget =
  struct "AzureAppConfigurationTarget" True $
    AzureAppConfigurationTarget
      <$> required "endpoint" string
      <*> optional "label" string
      <*> defaulted "prefix" "" string
      <*> defaulted "connection_string_env" "AZURE_APPCONFIG_CONNECTION_STRING" string

-- | @ConfigService@.
decodeConfigService :: Decoder ConfigService
decodeConfigService =
  struct "ConfigService" True $
    ConfigService
      <$> defaulted "image" defaultConfigServiceImage string
      <*> defaulted "port" defaultConfigServicePort u16

------------------------------------------------------------------------------
-- Writing

-- | An object of the fields in order, those given as Nothing skipped.
fields :: [(Text, Maybe Value)] -> Value
fields pairs = Object [(k, v) | (k, Just v) <- pairs]

-- | A field that is always written.
always :: Value -> Maybe Value
always = Just

-- | A string value.
text :: Text -> Value
text = String

-- | A whole number value.
int :: Integer -> Value
int = Number . I

-- | A BTreeMap as an object in key order.
textMapValue :: (a -> Value) -> Map Text a -> Value
textMapValue f m = Object [(k, f v) | (k, v) <- Map.toAscList m]

-- | A map, skipped when empty.
unlessEmptyMap :: (a -> Value) -> Map Text a -> Maybe Value
unlessEmptyMap f m = if Map.null m then Nothing else Just (textMapValue f m)

-- | A list, skipped when empty.
unlessEmptyList :: (a -> Value) -> [a] -> Maybe Value
unlessEmptyList f xs = if null xs then Nothing else Just (Array (map f xs))

-- | @Manifest@ as Serialize writes it.
encodeManifest :: Manifest -> Value
encodeManifest m =
  fields
    [ ("version", always (int (manifestVersion m)))
    , ("project", always (text (manifestProject m)))
    , ("dependencies", always (textMapValue encodeDependencyDecl (manifestDependencies m)))
    , ("environments", always (textMapValue encodeEnvironment (manifestEnvironments m)))
    ]

-- | @DependencyDecl@.
encodeDependencyDecl :: DependencyDecl -> Value
encodeDependencyDecl d =
  fields
    [ ("description", text <$> declDescription d)
    , ("settings", always (textMapValue text (declSettings d)))
    ]

-- | @Environment@.
encodeEnvironment :: Environment -> Value
encodeEnvironment e =
  fields
    [ ("runtime", always (encodeRuntime (envRuntime e)))
    , ("cloud", encodeCloud <$> envCloud e)
    , ("dependencies", always (textMapValue encodeBinding (envDependencies e)))
    , ("sync", unlessEmptyList encodeSyncTarget (envSync e))
    , ("config_service", encodeConfigService <$> envConfigService e)
    ]

-- | @Runtime@ as its word.
encodeRuntime :: Runtime -> Value
encodeRuntime = text . runtimeWord

-- | @Protocol@ as its word.
encodeProtocol :: Protocol -> Value
encodeProtocol = \case
  Http -> text "http"
  Tcp -> text "tcp"

-- | @Cloud@: @modules@ first, then the inputs flattened in name order.
encodeCloud :: Cloud -> Value
encodeCloud c =
  Object (catMaybes [(,) "modules" . text <$> cloudModules c] ++ Map.toAscList (cloudInputs c))

-- | @Binding@: @{"real": ...}@ or @{"twin": ...}@.
encodeBinding :: Binding -> Value
encodeBinding = \case
  BindReal r -> Object [("real", encodeReal r)]
  BindTwin t -> Object [("twin", encodeTwin t)]

-- | @Real@.
encodeReal :: Real -> Value
encodeReal r =
  fields
    [ ("endpoint", always (text (realEndpoint r)))
    , ("credentials", text <$> realCredentials r)
    , ("image", text <$> realImage r)
    , ("ports", unlessEmptyList int (realPorts r))
    , ("env", unlessEmptyMap text (realEnv r))
    ]

-- | @Twin@; the report is never written.
encodeTwin :: Twin -> Value
encodeTwin t =
  fields
    [ ("image", always (text (twinImage t)))
    , ("version", always (text (twinVersion t)))
    , ("config", twinConfig t)
    , ("conformance", always (encodeConformance (twinConformance t)))
    , ("ports", always (Array (map int (twinPorts t))))
    , ("env", unlessEmptyMap text (twinEnv t))
    , ("endpoint", text <$> twinEndpoint t)
    , ("credentials", text <$> twinCredentials t)
    , ("seed", int <$> twinSeed t)
    , ("contract", text <$> twinContract t)
    , ("state", twinState t)
    , ("faults", unlessEmptyList encodeFault (twinFaults t))
    , ("admin", encodeAdmin <$> twinAdmin t)
    , ("protocol", encodeProtocol <$> twinProtocol t)
    , ("advertise_variable", text <$> twinAdvertiseVariable t)
    ]

-- | @Conformance@, untagged.
encodeConformance :: Conformance -> Value
encodeConformance = \case
  Level l -> text l
  Sourced s -> encodeConformanceSource s

-- | @ConformanceSource@.
encodeConformanceSource :: ConformanceSource -> Value
encodeConformanceSource s =
  fields
    [ ("level", text <$> sourceLevel s)
    , ("report", text <$> sourceReport s)
    , ("image_label", text <$> sourceImageLabel s)
    ]

-- | @Fault@.
encodeFault :: Fault -> Value
encodeFault f =
  fields
    [ ("name", always (text (faultName f)))
    , ("params", unlessEmptyMap id (faultParams f))
    ]

-- | @Admin@.
encodeAdmin :: Admin -> Value
encodeAdmin a =
  fields
    [ ("port", int <$> adminPort a)
    , ("container_port", always (int (adminContainerPort a)))
    , ("url", text <$> adminUrl a)
    ]

-- | @SyncTarget@, externally tagged in snake case.
encodeSyncTarget :: SyncTarget -> Value
encodeSyncTarget = \case
  SyncEnvFile e -> Object [("env_file", fields [("path", always (text (envFilePath e)))])]
  SyncAws a ->
    Object
      [ ( "aws_appconfig"
        , fields
            [ ("region", always (text (awsRegion a)))
            , ("application", always (text (awsApplication a)))
            , ("environment", text <$> awsEnvironment a)
            , ("profile", always (text (awsProfile a)))
            , ("deployment_strategy", text <$> awsDeploymentStrategy a)
            ]
        )
      ]
  SyncGcp g ->
    Object
      [ ( "gcp_parameter_manager"
        , fields
            [ ("project", always (text (gcpProject g)))
            , ("location", always (text (gcpLocation g)))
            , ("parameter", always (text (gcpParameter g)))
            ]
        )
      ]
  SyncAzure z ->
    Object
      [ ( "azure_app_configuration"
        , fields
            [ ("endpoint", always (text (azureEndpoint z)))
            , ("label", text <$> azureLabel z)
            , ("prefix", if azurePrefix z == "" then Nothing else Just (text (azurePrefix z)))
            , ("connection_string_env", always (text (azureConnectionStringEnv z)))
            ]
        )
      ]

-- | @ConfigService@.
encodeConfigService :: ConfigService -> Value
encodeConfigService c =
  fields
    [ ("image", always (text (configServiceImage c)))
    , ("port", always (int (configServicePort c)))
    ]
