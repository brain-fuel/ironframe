-- | Small facts about the tools Ironframe drives: where a tool's reason for a
-- failure is, and how a failure is worded. ref:DEC-podman-compose
module Ironframe.Process (lastLine) where

import Data.Text (Text)
import qualified Data.Text as T

-- | The last non-empty line of a tool's error output, where podman and
-- OpenTofu put the reason.
lastLine :: Text -> Text
lastLine text = case filter (not . T.null) (map T.strip (reverse (T.lines text))) of
  (l : _) -> l
  [] -> "no output"
