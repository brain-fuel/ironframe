-- | Retain the exact fixture history observed when an application run completed.
-- A later test sharing that fixture cannot replace this run's history snapshot.
module Ironframe.Evidence.Histories (retain) where

import Control.Monad (forM)
import Data.Text (Text)
import qualified Ironframe.Attestation as A
import Ironframe.Digest (digestOf)
import Ironframe.Effect
import Ironframe.Json
import Ironframe.Workdir

retain :: Text -> A.Attestation -> Text -> Eff ()
retain base attestation path = do
  let work = workDir base (A.attEnvironment attestation)
  histories <- forM [dependency | dependency <- A.attDependencies attestation, A.depKind dependency == A.KindStandIn] $ \dependency -> do
    let name = maybe (A.depName dependency) id (A.depNode dependency)
    found <- readFileE (historyPath work name)
    let record = case found of
          Right raw | Just completed <- A.depCompleted dependency, Just expected <- A.completedHistoryDigest completed, digestOf raw == expected ->
            Object ["status" .= String "retained","digest" .= String expected,"raw" .= String raw]
          _ -> Object ["status" .= String "incomplete","reason" .= String "exact completed history is missing or changed"]
    pure (name,record)
  let snapshot = Object ["format" .= String "ironframe-run-histories","version" .= Number (I 1),"run" .= String (A.runId (A.attRun attestation)),"dependencies" .= object histories]
  _ <- writeAtomically path (encodePretty snapshot <> "\n") >>= either (failWith . ioMessage) pure
  pure ()
