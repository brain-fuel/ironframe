-- | Writing the environment attestation of a run: each dependency's endpoint,
-- whether it answered, and for a twin the stand-in it was, with its seed and
-- the digest of its history. @up@ writes it and @attest@ writes it again for
-- the same run. ref:DEC-attestation-format
module Ironframe.Attest
  ( RunRecord (..)
  , startRun
  , encodeRunRecord
  , decodeRunRecord
  , attest
  , tcpReachable
  , waitReachable
  , nowTimestamp
  ) where

import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import Ironframe.Attestation
import Ironframe.Effect
import Ironframe.Json
import Ironframe.Json.Serde
import Ironframe.Settings
import Ironframe.Time
import Ironframe.Twin (Observation (..), TwinRecord (..))

-- | The run an environment is in: started by @up@ and kept in its working
-- directory.
data RunRecord = RunRecord {recordId :: Text, recordStartedAt :: Timestamp}

nowTimestamp :: Eff Timestamp
nowTimestamp = uncurry fromUnix <$> now

-- | A new run starting now, with a random id.
startRun :: Eff RunRecord
startRun = do
  rid <- newUuid
  RunRecord rid <$> nowTimestamp

encodeRunRecord :: RunRecord -> Value
encodeRunRecord r = Object ["id" .= String (recordId r), "started_at" .= String (formatRfc3339 (recordStartedAt r))]

decodeRunRecord :: Decoder RunRecord
decodeRunRecord =
  struct "RunRecord" False $
    RunRecord <$> required "id" string <*> required "started_at" (mapDecoder (\v -> decodeWith string v >>= parseRfc3339))

-- | The attestation of an environment in a run, recorded at @recorded@. For
-- each twin, @observed@ gives what its control plane reported and @records@
-- what @up@ learnt of it.
attest :: ResolvedEnvironment -> RunRecord -> Timestamp -> (Text -> Bool) -> Map Text Observation -> Map Text TwinRecord -> Attestation
attest environment run recorded reached observed records =
  (newAttestation (reEnvironment environment) (Run (recordId run) (recordStartedAt run) (maxInstant recorded (recordStartedAt run))))
    { attProducer = Just (Producer "ironframe" "0.2.0")
    , attDependencies = map record (reDependencies environment)
    , attExecution = Just (Execution Wired [] Nothing Nothing Nothing)
    }
  where
    record d =
      emptyRecord
        { depName = rdName d
        , depEndpoint = rdEndpoint d
        , depReached = reached (rdEndpoint d)
        , depKind = if rdKind d == KindRealBinding then KindReal else KindStandIn
        , depStandIn = fmap (standIn d) (rdStandIn d)
        }
    standIn d s =
      let record' = Map.lookup (rdName d) records
          observation = Map.lookup (rdName d) observed
          level = record' >>= trConformance
       in s
            { standConformance = maybe (standConformance s) id level
            , standSeed = firstJust [observation >>= obsSeed, record' >>= trSeed, standSeed s]
            , standHistoryDigest = observation >>= obsHistoryDigest
            , standHistoryEntries = observation >>= obsHistoryEntries
            }
    firstJust xs = case [x | Just x <- xs] of
      (x : _) -> Just x
      [] -> Nothing

-- | Whether an endpoint's host and port accept a connection and keep it open;
-- an endpoint without a port counts as not reached.
tcpReachable :: Text -> Int -> Eff Bool
tcpReachable endpoint timeoutMs = case splitEndpoint endpoint of
  (host, Just port) -> tcpProbe endpoint host (fromInteger port) timeoutMs
  (_, Nothing) -> pure False

-- | Waits until the endpoint is reachable or the deadline passes, trying
-- every half second.
waitReachable :: Text -> Integer -> Eff Bool
waitReachable endpoint seconds = do
  start <- monotonicMs
  let until' = start + seconds * 1000
      loop = do
        ok <- tcpReachable endpoint 1000
        if ok
          then pure True
          else do
            t <- monotonicMs
            if t >= until' then pure False else sleepMs 500 >> loop
  loop
