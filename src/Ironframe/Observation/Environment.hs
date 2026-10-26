-- | Attach the currently owned observation session to a native invocation.
-- The application still owns SDK instrumentation and ForceFlush reporting.
module Ironframe.Observation.Environment (forExecution) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Ironframe.Effect
import Ironframe.Json
import qualified Ironframe.Path as Path

forExecution :: Text -> Text -> Eff [(Text,Text)]
forExecution node execution = getEnv "IRONFRAME_OBSERVATION_CONFIG" >>= \case
  Nothing -> pure []
  Just path -> do
    raw <- readFileE path >>= either (failWith . ioMessage) pure
    config <- either failWith pure (decode raw)
    producer <- maybe (failWith (node <> ": no producer in observation session")) pure (key node (keyOr "producers" config))
    let value name document = fromMaybe "" (textAt name document)
        attributes = [("lawtwin.producer.id",node),("ironframe.run.id",value "runId" config)
          ,("ironframe.execution.id",execution),("ironframe.topology.digest",value "topologyDigest" config)
          ,("ironframe.node.id",value "node" producer),("service.version",value "implementation" producer)
          ,("ironframe.configuration.revision",value "revision" producer)]
    if any (\(_,v) -> T.null v || T.any (`elem` (",=" :: String)) v) attributes
      then failWith "observation resource identities are empty or cannot be encoded as OTEL_RESOURCE_ATTRIBUTES"
      else pure [("OTEL_RESOURCE_ATTRIBUTES",T.intercalate "," [k <> "=" <> v | (k,v) <- attributes])
        ,("IRONFRAME_OBSERVATION_COUNTS_FILE",Path.join (maybe "." id (Path.parent path)) (node <> "-" <> execution <> ".counts.jsonl"))]
