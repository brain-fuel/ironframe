-- | The manifest's types, @ironframe.yaml@: the dependencies an application
-- reads from its configuration, and for each environment whether each one is
-- the real dependency or a twin. Maps are keyed and ordered by name, as the
-- Rust implementation's BTreeMaps were. ref:DEC-manifest-shape
module Ironframe.Manifest.Types
  ( Manifest (..)
  , DependencyDecl (..)
  , Environment (..)
  , Runtime (..)
  , runtimeWord
  , Protocol (..)
  , Cloud (..)
  , Binding (..)
  , Real (..)
  , Twin (..)
  , Conformance (..)
  , ConformanceSource (..)
  , ConformanceReport (..)
  , Fault (..)
  , Admin (..)
  , SyncTarget (..)
  , EnvFileTarget (..)
  , AwsAppConfigTarget (..)
  , GcpParameterTarget (..)
  , AzureAppConfigurationTarget (..)
  , ConfigService (..)
  , defaultAdminContainerPort
  , defaultConfigServiceImage
  , defaultConfigServicePort
  ) where

import Data.Map.Strict (Map)
import Prelude hiding (Real)
import Data.Text (Text)
import Ironframe.Json (Value)

-- | A whole manifest.
data Manifest = Manifest
  { manifestVersion :: Integer
  , manifestProject :: Text
  , manifestDependencies :: Map Text DependencyDecl
  , manifestEnvironments :: Map Text Environment
  }
  deriving (Show, Eq)

-- | A dependency as the application sees it: the settings it reads.
data DependencyDecl = DependencyDecl
  { declDescription :: Maybe Text
  , declSettings :: Map Text Text
  }
  deriving (Show, Eq)

-- | One environment.
data Environment = Environment
  { envRuntime :: Runtime
  , envCloud :: Maybe Cloud
  , envDependencies :: Map Text Binding
  , envSync :: [SyncTarget]
  , envConfigService :: Maybe ConfigService
  }
  deriving (Show, Eq)

-- | Where an environment's containers run.
data Runtime = Podman | Aws | Gcp | Azure
  deriving (Show, Eq, Ord, Enum, Bounded)

runtimeWord :: Runtime -> Text
runtimeWord = \case
  Podman -> "podman"
  Aws -> "aws"
  Gcp -> "gcp"
  Azure -> "azure"

-- | What a twin serves on its first port.
data Protocol = Http | Tcp
  deriving (Show, Eq)

-- | A cloud environment's inputs: the module source, and every other key in
-- name order.
data Cloud = Cloud
  { cloudModules :: Maybe Text
  , cloudInputs :: Map Text Value
  }
  deriving (Show, Eq)

data Binding = BindReal Real | BindTwin Twin
  deriving (Show, Eq)

data Real = Real
  { realEndpoint :: Text
  , realCredentials :: Maybe Text
  , realImage :: Maybe Text
  , realPorts :: [Integer]
  , realEnv :: Map Text Text
  }
  deriving (Show, Eq)

data Twin = Twin
  { twinImage :: Text
  , twinVersion :: Text
  , twinConfig :: Maybe Value
  , twinConformance :: Conformance
  , twinPorts :: [Integer]
  , twinEnv :: Map Text Text
  , twinEndpoint :: Maybe Text
  , twinCredentials :: Maybe Text
  , twinSeed :: Maybe Integer
  , twinContract :: Maybe Text
  , twinState :: Maybe Value
  , twinFaults :: [Fault]
  , twinAdmin :: Maybe Admin
  , twinProtocol :: Maybe Protocol
  , twinAdvertiseVariable :: Maybe Text
  , -- | The conformance report named by @conformance.report@, read when the
    -- manifest was loaded; never serialised.
    twinReport :: Maybe ConformanceReport
  }
  deriving (Show, Eq)

data Conformance = Level Text | Sourced ConformanceSource
  deriving (Show, Eq)

data ConformanceSource = ConformanceSource
  { sourceLevel :: Maybe Text
  , sourceReport :: Maybe Text
  , sourceImageLabel :: Maybe Text
  }
  deriving (Show, Eq)

data ConformanceReport = ConformanceReport
  { reportLevel :: Text
  , reportNumber :: Maybe Integer
  , reportRelease :: Maybe Text
  , reportTwin :: Maybe Text
  , reportContract :: Maybe Text
  }
  deriving (Show, Eq)

-- | A fault and its parameters, by name.
data Fault = Fault
  { faultName :: Text
  , faultParams :: Map Text Value
  }
  deriving (Show, Eq)

data Admin = Admin
  { adminPort :: Maybe Integer
  , adminContainerPort :: Integer
  , adminUrl :: Maybe Text
  }
  deriving (Show, Eq)

data SyncTarget
  = SyncEnvFile EnvFileTarget
  | SyncAws AwsAppConfigTarget
  | SyncGcp GcpParameterTarget
  | SyncAzure AzureAppConfigurationTarget
  deriving (Show, Eq)

newtype EnvFileTarget = EnvFileTarget {envFilePath :: Text}
  deriving (Show, Eq)

data AwsAppConfigTarget = AwsAppConfigTarget
  { awsRegion :: Text
  , awsApplication :: Text
  , awsEnvironment :: Maybe Text
  , awsProfile :: Text
  , awsDeploymentStrategy :: Maybe Text
  }
  deriving (Show, Eq)

data GcpParameterTarget = GcpParameterTarget
  { gcpProject :: Text
  , gcpLocation :: Text
  , gcpParameter :: Text
  }
  deriving (Show, Eq)

data AzureAppConfigurationTarget = AzureAppConfigurationTarget
  { azureEndpoint :: Text
  , azureLabel :: Maybe Text
  , azurePrefix :: Text
  , azureConnectionStringEnv :: Text
  }
  deriving (Show, Eq)

data ConfigService = ConfigService
  { configServiceImage :: Text
  , configServicePort :: Integer
  }
  deriving (Show, Eq)

defaultAdminContainerPort :: Integer
defaultAdminContainerPort = 9644

defaultConfigServiceImage :: Text
defaultConfigServiceImage = "localhost/ironframe-config-service:0.1.0"

defaultConfigServicePort :: Integer
defaultConfigServicePort = 8700
