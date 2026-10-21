-- | The working directory of an environment, @.ironframe/<environment>/@
-- beside the manifest, where Ironframe keeps what it generates and what a run
-- leaves behind. It is ignored by git; the manifest is the only source.
-- ref:DEC-manifest-shape
module Ironframe.Workdir
  ( WorkDir (..)
  , workDir
  , composePath
  , tofuPath
  , settingsPath
  , endpointsPath
  , runPath
  , attestationPath
  , twinsPath
  , historyPath
  , readEndpoints
  , readTwins
  ) where

import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import Ironframe.Effect
import Ironframe.Json.FromStr (Expect (..), fromStr)
import Ironframe.Json.Serde (string, textMap)
import qualified Ironframe.Path as Path
import Ironframe.Twin (TwinRecord, decodeTwinRecord)

newtype WorkDir = WorkDir {workRoot :: Text}

workDir :: Text -> Text -> WorkDir
workDir manifestDir environment = WorkDir (Path.join (Path.join manifestDir ".ironframe") environment)

composePath, tofuPath, settingsPath, endpointsPath, runPath, attestationPath, twinsPath :: WorkDir -> Text
composePath w = Path.join (workRoot w) "compose.yaml"
tofuPath w = Path.join (workRoot w) "tofu"
settingsPath w = Path.join (workRoot w) "settings.json"
endpointsPath w = Path.join (workRoot w) "endpoints.json"
runPath w = Path.join (workRoot w) "run.json"
attestationPath w = Path.join (workRoot w) "attestation.json"
twinsPath w = Path.join (workRoot w) "twins.json"

historyPath :: WorkDir -> Text -> Text
historyPath w dependency = Path.join (Path.join (workRoot w) "history") (dependency <> ".jsonl")

-- | The endpoints a cloud deployment reported, or none before one.
readEndpoints :: WorkDir -> Eff (Either Text (Map Text Text))
readEndpoints w = do
  r <- readFileE (endpointsPath w)
  pure $ case r of
    Left e | ioNotFound e -> Right Map.empty
    Left e -> Left (ioMessage e)
    Right text -> fromStr ExpectMap (textMap string) text

-- | What @up@ learnt of each twin, or nothing before an @up@.
readTwins :: WorkDir -> Eff (Either Text (Map Text TwinRecord))
readTwins w = do
  r <- readFileE (twinsPath w)
  pure $ case r of
    Left e | ioNotFound e -> Right Map.empty
    Left e -> Left (ioMessage e)
    Right text -> fromStr ExpectMap (textMap decodeTwinRecord) text
