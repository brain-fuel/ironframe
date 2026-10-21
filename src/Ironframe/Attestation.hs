-- | The environment attestation, version 1: which endpoint each dependency of
-- one run reached, and whether it was the real dependency or a stand-in. Any
-- tool may write it and any tool may read it, so nothing in it names
-- Ironframe, LawSpec or LawTwin. The schema is schema/attestation-v1.schema.json.
-- ref:DEC-attestation-format
module Ironframe.Attestation
  ( Attestation (..)
  , Run (..)
  , Producer (..)
  , DependencyRecord (..)
  , Kind (..)
  , StandIn (..)
  , ArchitectureRef (..)
  , ContractRef (..)
  , Implementation (..)
  , ApplicationRef (..)
  , ExecutionStatus (..)
  , Execution (..)
  , Completed (..)
  , formatWord
  , formatVersion
  , newAttestation
  , emptyStandIn
  , emptyRecord
  , isHistoryDigest
  , validate
  , fromJson
  , toJson
  , encodeAttestation
  , encodeStandIn
  , encodeContractRef
  , decodeContractRef
  , decodeAttestationValue
  ) where

import Data.Char (isDigit)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Ironframe.Json
import Ironframe.Json.Serde
import Ironframe.Rust (debugStr)
import Ironframe.Time

-- | The value of @format@ in every attestation.
formatWord :: Text
formatWord = "environment-attestation"

-- | The one version written and read.
formatVersion :: Integer
formatVersion = 1

data Attestation = Attestation
  { attFormat :: Text
  , attVersion :: Integer
  , attEnvironment :: Text
  , attRun :: Run
  , attProducer :: Maybe Producer
  , attDependencies :: [DependencyRecord]
  , attArchitecture :: Maybe ArchitectureRef
  , attApplication :: Maybe ApplicationRef
  , attExecution :: Maybe Execution
  }
  deriving (Show, Eq)

data Run = Run {runId :: Text, runStartedAt :: Timestamp, runRecordedAt :: Timestamp}
  deriving (Show, Eq)

data Producer = Producer {producerName :: Text, producerVersion :: Text}
  deriving (Show, Eq)

data Kind = KindReal | KindStandIn
  deriving (Show, Eq)

data DependencyRecord = DependencyRecord
  { depName :: Text
  , depEndpoint :: Text
  , depReached :: Bool
  , depKind :: Kind
  , depStandIn :: Maybe StandIn
  , depNode :: Maybe Text
  , depEdge :: Maybe Text
  , depContract :: Maybe ContractRef
  , depImplementation :: Maybe Implementation
  , depCompleted :: Maybe Completed
  }
  deriving (Show, Eq)

data StandIn = StandIn
  { standProduct :: Text
  , standVersion :: Text
  , standConformance :: Text
  , standSeed :: Maybe Integer
  , standHistoryDigest :: Maybe Text
  , standHistoryEntries :: Maybe Integer
  , standStandsInFor :: Maybe ContractRef
  }
  deriving (Show, Eq)

data ArchitectureRef = ArchitectureRef
  { refDocument :: Text
  , refDigest :: Text
  , refUniqueId :: Maybe Text
  , refDecorators :: Maybe Text
  , refDecoratorsDigest :: Maybe Text
  , refTopologyDigest :: Maybe Text
  , refElements :: [Text]
  }
  deriving (Show, Eq)

data ContractRef = ContractRef {contractPackage :: Text, contractVersion :: Text, contractAbilities :: [Text]}
  deriving (Show, Eq)

data Implementation = Implementation
  { implKind :: Text
  , implProduct :: Text
  , implVersion :: Text
  , implCommit :: Maybe Text
  , implImageDigest :: Maybe Text
  }
  deriving (Show, Eq)

data ApplicationRef = ApplicationRef {appNode :: Text, appContract :: ContractRef, appImplementation :: Implementation}
  deriving (Show, Eq)

data ExecutionStatus = Wired | Running | CompletedRun
  deriving (Show, Eq)

data Execution = Execution
  { execStatus :: ExecutionStatus
  , execCommand :: [Text]
  , execExitCode :: Maybe Integer
  , execFinishedAt :: Maybe Timestamp
  , execEnvironmentRun :: Maybe Text
  }
  deriving (Show, Eq)

data Completed = Completed {completedReached :: Bool, completedHistoryDigest :: Maybe Text, completedHistoryEntries :: Maybe Integer}
  deriving (Show, Eq)

newAttestation :: Text -> Run -> Attestation
newAttestation environment run = Attestation formatWord formatVersion environment run Nothing [] Nothing Nothing Nothing

emptyStandIn :: StandIn
emptyStandIn = StandIn "" "" "" Nothing Nothing Nothing Nothing

emptyRecord :: DependencyRecord
emptyRecord = DependencyRecord "" "" False KindReal Nothing Nothing Nothing Nothing Nothing Nothing

-- | Whether a digest is @sha256:@ and 64 lowercase hexadecimal digits.
isHistoryDigest :: Text -> Bool
isHistoryDigest d = case T.stripPrefix "sha256:" d of
  Just hex -> T.length hex == 64 && T.all (\c -> isDigit c || (c >= 'a' && c <= 'f')) hex
  Nothing -> False

-- | The rules the schema cannot state.
validate :: Attestation -> Either Text ()
validate a
  | attFormat a /= formatWord = Left ("format is " <> debugStr (attFormat a) <> ", expected " <> debugStr formatWord)
  | attVersion a /= formatVersion = Left (unsupported (attVersion a))
  | T.null (attEnvironment a) = Left "environment must not be empty"
  | T.null (runId (attRun a)) = Left "run.id must not be empty"
  | compareInstant (runRecordedAt (attRun a)) (runStartedAt (attRun a)) == LT = Left "run.recorded_at is before run.started_at"
  | otherwise = do
      dependencies Set.empty (attDependencies a)
      case attExecution a of
        Just e -> do
          let completed = execStatus e == CompletedRun
          if completed /= (execExitCode e /= Nothing) || completed /= (execFinishedAt e /= Nothing)
            then Left "execution: exit_code and finished_at are present exactly when the run completed"
            else Right ()
          case execFinishedAt e of
            Just f | compareInstant f (runStartedAt (attRun a)) == LT -> Left "execution: finished_at is before run.started_at"
            _ -> Right ()
        Nothing -> Right ()
  where
    completedRun = maybe False ((== CompletedRun) . execStatus) (attExecution a)
    dependencies _ [] = Right ()
    dependencies seen (d : ds)
      | T.null (depName d) = Left "dependencies[].name must not be empty"
      | depName d `Set.member` seen = Left ("dependency " <> debugStr (depName d) <> " is recorded twice")
      | T.null (depEndpoint d) = Left ("dependency " <> debugStr (depName d) <> " endpoint must not be empty")
      | (depKind d == KindStandIn) /= (depStandIn d /= Nothing) =
          Left ("dependency " <> debugStr (depName d) <> ": stand_in must be present exactly when kind is \"stand-in\"")
      | Just digest <- depStandIn d >>= standHistoryDigest, not (isHistoryDigest digest) = badDigest d
      | Just _ <- depCompleted d, not completedRun =
          Left ("execution: dependency " <> debugStr (depName d) <> " records what was observed after the run, but the run has not completed")
      | Just digest <- depCompleted d >>= completedHistoryDigest, not (isHistoryDigest digest) = badDigest d
      | otherwise = dependencies (Set.insert (depName d) seen) ds
    badDigest d = Left ("dependency " <> debugStr (depName d) <> ": stand_in.history_digest must be sha256: followed by 64 lowercase hex digits")

unsupported :: Integer -> Text
unsupported v = "attestation version " <> T.pack (show v) <> " is not supported; this reader knows version 1"

-- | Reads and validates an attestation from JSON text; unknown fields are ignored.
fromJson :: Text -> Either Text Attestation
fromJson text = do
  value <- either (Left . malformed) Right (decode text)
  case key "format" value of
    Just (String f) | f /= formatWord -> Left ("format is " <> debugStr f <> ", expected " <> debugStr formatWord)
    _ -> Right ()
  case key "version" value of
    Just (Number (I v)) | v >= 0 && v /= formatVersion -> Left (unsupported (min v 4294967295))
    _ -> Right ()
  attestation <- either (Left . malformed) Right (decodeAttestationValue value)
  validate attestation
  pure attestation
  where
    malformed e = "not an environment attestation: " <> e

-- | Validates and writes indented JSON with a trailing newline.
toJson :: Attestation -> Either Text Text
toJson a = do
  validate a
  pure (encodePretty (encodeAttestation a) <> "\n")

-- Writing, field by field as the Rust types serialise.

opt :: Text -> (a -> Value) -> Maybe a -> [(Text, Value)]
opt k f = maybe [] (\x -> [(k, f x)])

encodeAttestation :: Attestation -> Value
encodeAttestation a =
  Object $
    [ "format" .= String (attFormat a)
    , "version" .= Number (I (attVersion a))
    , "environment" .= String (attEnvironment a)
    , "run" .= encodeRun (attRun a)
    ]
      ++ opt "producer" (\p -> Object ["name" .= String (producerName p), "version" .= String (producerVersion p)]) (attProducer a)
      ++ ["dependencies" .= Array (map encodeRecord (attDependencies a))]
      ++ opt "architecture" encodeArchitecture (attArchitecture a)
      ++ opt "application" encodeApplication (attApplication a)
      ++ opt "execution" encodeExecution (attExecution a)

encodeRun :: Run -> Value
encodeRun r =
  Object
    [ "id" .= String (runId r)
    , "started_at" .= String (formatRfc3339 (runStartedAt r))
    , "recorded_at" .= String (formatRfc3339 (runRecordedAt r))
    ]

encodeRecord :: DependencyRecord -> Value
encodeRecord d =
  Object $
    [ "name" .= String (depName d)
    , "endpoint" .= String (depEndpoint d)
    , "reached" .= Bool (depReached d)
    , "kind" .= String (if depKind d == KindReal then "real" else "stand-in")
    ]
      ++ opt "stand_in" encodeStandIn (depStandIn d)
      ++ opt "node" String (depNode d)
      ++ opt "edge" String (depEdge d)
      ++ opt "contract" encodeContractRef (depContract d)
      ++ opt "implementation" encodeImplementation (depImplementation d)
      ++ opt "completed" encodeCompleted (depCompleted d)

encodeStandIn :: StandIn -> Value
encodeStandIn s =
  Object $
    [ "product" .= String (standProduct s)
    , "version" .= String (standVersion s)
    , "conformance" .= String (standConformance s)
    ]
      ++ opt "seed" (Number . I) (standSeed s)
      ++ opt "history_digest" String (standHistoryDigest s)
      ++ opt "history_entries" (Number . I) (standHistoryEntries s)
      ++ opt "stands_in_for" encodeContractRef (standStandsInFor s)

encodeContractRef :: ContractRef -> Value
encodeContractRef c =
  Object $
    ["package" .= String (contractPackage c), "version" .= String (contractVersion c)]
      ++ ["abilities" .= Array (map String (contractAbilities c)) | not (null (contractAbilities c))]

encodeImplementation :: Implementation -> Value
encodeImplementation i =
  Object $
    ["kind" .= String (implKind i), "product" .= String (implProduct i), "version" .= String (implVersion i)]
      ++ opt "commit" String (implCommit i)
      ++ opt "image_digest" String (implImageDigest i)

encodeArchitecture :: ArchitectureRef -> Value
encodeArchitecture r =
  Object $
    ["document" .= String (refDocument r), "digest" .= String (refDigest r)]
      ++ opt "unique_id" String (refUniqueId r)
      ++ opt "decorators" String (refDecorators r)
      ++ opt "decorators_digest" String (refDecoratorsDigest r)
      ++ opt "topology_digest" String (refTopologyDigest r)
      ++ ["elements" .= Array (map String (refElements r)) | not (null (refElements r))]

encodeApplication :: ApplicationRef -> Value
encodeApplication r =
  Object
    [ "node" .= String (appNode r)
    , "contract" .= encodeContractRef (appContract r)
    , "implementation" .= encodeImplementation (appImplementation r)
    ]

encodeExecution :: Execution -> Value
encodeExecution e =
  Object $
    ["status" .= String (statusWord (execStatus e))]
      ++ ["command" .= Array (map String (execCommand e)) | not (null (execCommand e))]
      ++ opt "exit_code" (Number . I) (execExitCode e)
      ++ opt "finished_at" (String . formatRfc3339) (execFinishedAt e)
      ++ opt "environment_run" String (execEnvironmentRun e)

statusWord :: ExecutionStatus -> Text
statusWord = \case
  Wired -> "wired"
  Running -> "running"
  CompletedRun -> "completed"

encodeCompleted :: Completed -> Value
encodeCompleted c =
  Object $
    ["reached" .= Bool (completedReached c)]
      ++ opt "history_digest" String (completedHistoryDigest c)
      ++ opt "history_entries" (Number . I) (completedHistoryEntries c)

-- Reading, as serde reads the Rust types.

timestamp :: Decoder Timestamp
timestamp = mapDecoder $ \v -> decodeWith string v >>= parseRfc3339

decodeAttestationValue :: Value -> Either Text Attestation
decodeAttestationValue = decodeWith attestationD

attestationD :: Decoder Attestation
attestationD =
  struct "Attestation" False $
    Attestation
      <$> required "format" string
      <*> required "version" u32
      <*> required "environment" string
      <*> required "run" runD
      <*> optional "producer" producerD
      <*> required "dependencies" (vec recordD)
      <*> optional "architecture" architectureD
      <*> optional "application" applicationD
      <*> optional "execution" executionD

runD :: Decoder Run
runD = struct "Run" False $ Run <$> required "id" string <*> required "started_at" timestamp <*> required "recorded_at" timestamp

producerD :: Decoder Producer
producerD = struct "Producer" False $ Producer <$> required "name" string <*> required "version" string

recordD :: Decoder DependencyRecord
recordD =
  struct "DependencyRecord" False $
    DependencyRecord
      <$> required "name" string
      <*> required "endpoint" string
      <*> required "reached" bool
      <*> required "kind" (unitVariants "Kind" [("real", KindReal), ("stand-in", KindStandIn)])
      <*> optional "stand_in" standInD
      <*> optional "node" string
      <*> optional "edge" string
      <*> optional "contract" decodeContractRef
      <*> optional "implementation" implementationD
      <*> optional "completed" completedD

standInD :: Decoder StandIn
standInD =
  struct "StandIn" False $
    StandIn
      <$> required "product" string
      <*> required "version" string
      <*> required "conformance" string
      <*> optional "seed" u64
      <*> optional "history_digest" string
      <*> optional "history_entries" u64
      <*> optional "stands_in_for" decodeContractRef

decodeContractRef :: Decoder ContractRef
decodeContractRef =
  struct "ContractRef" False $
    ContractRef <$> required "package" string <*> required "version" string <*> defaulted "abilities" [] (vec string)

implementationD :: Decoder Implementation
implementationD =
  struct "Implementation" False $
    Implementation
      <$> required "kind" string
      <*> required "product" string
      <*> required "version" string
      <*> optional "commit" string
      <*> optional "image_digest" string

architectureD :: Decoder ArchitectureRef
architectureD =
  struct "ArchitectureRef" False $
    ArchitectureRef
      <$> required "document" string
      <*> required "digest" string
      <*> optional "unique_id" string
      <*> optional "decorators" string
      <*> optional "decorators_digest" string
      <*> optional "topology_digest" string
      <*> defaulted "elements" [] (vec string)

applicationD :: Decoder ApplicationRef
applicationD =
  struct "ApplicationRef" False $
    ApplicationRef <$> required "node" string <*> required "contract" decodeContractRef <*> required "implementation" implementationD

executionD :: Decoder Execution
executionD =
  struct "Execution" False $
    Execution
      <$> required "status" (unitVariants "ExecutionStatus" [("wired", Wired), ("running", Running), ("completed", CompletedRun)])
      <*> defaulted "command" [] (vec string)
      <*> optional "exit_code" i32
      <*> optional "finished_at" timestamp
      <*> optional "environment_run" string

completedD :: Decoder Completed
completedD =
  struct "Completed" False $
    Completed <$> required "reached" bool <*> optional "history_digest" string <*> optional "history_entries" u64
