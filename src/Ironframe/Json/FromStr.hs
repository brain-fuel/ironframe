-- | Reading typed JSON from text as serde_json's @from_str@ does: a top-level
-- value of the wrong kind is refused at its first character, before the rest
-- is parsed, and a typed error names the line and column.
-- ref:DEC-haskell-wasm-core
module Ironframe.Json.FromStr (Expect (..), fromStr) where

import Data.Text (Text)
import qualified Data.Text as T
import Ironframe.Json
import Ironframe.Json.Serde (Decoder, decodeWith)

-- | What the top-level type accepts: a map, a sequence, or a struct (either).
data Expect = ExpectMap | ExpectSeq | ExpectStruct Text

fromStr :: Expect -> Decoder a -> Text -> Either Text a
fromStr expect decoder text =
  let (line, column, rest) = skip 1 0 (T.unpack text)
      wrong unexpected' = Left ("invalid type: " <> unexpected' <> ", expected " <> expected <> " at line " <> tshow line <> " column " <> tshow column)
      expected = case expect of
        ExpectMap -> "a map"
        ExpectSeq -> "a sequence"
        ExpectStruct name -> "struct " <> name
   in case (expect, rest) of
        (ExpectMap, '[' : _) -> wrong "sequence"
        (ExpectSeq, '{' : _) -> wrong "map"
        _ -> case decode text of
          Left e -> Left e
          Right v -> case decodeWith decoder v of
            Left e -> Left (e <> " at line " <> tshow endLine <> " column " <> tshow endColumn)
            Right a -> Right a
  where
    tshow = T.pack . show
    skip l _ (x : xs) | x == '\n' = skip (l + 1) 0 xs
    skip l c (x : xs) | x `elem` (" \t\r" :: String) = skip l (c + 1) xs
    skip l c xs = (l, c :: Int, xs) :: (Int, Int, String)
    trimmed = T.dropWhileEnd (`elem` (" \t\r\n" :: String)) text
    endLine = 1 + T.count "\n" trimmed
    endColumn = T.length (last (T.splitOn "\n" trimmed))
