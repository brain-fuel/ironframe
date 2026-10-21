-- | Paths as text, with the meaning Rust's std::path gives them on Unix:
-- joining, parents, file names and stems, without touching the file system.
-- ref:DEC-haskell-wasm-core
module Ironframe.Path
  ( join
  , parent
  , display
  , fileName
  , fileStem
  , withFileName
  , isAbsolute
  , components
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | Rust's @Path::join@: an absolute path replaces the base.
join :: Text -> Text -> Text
join base rel
  | isAbsolute rel = rel
  | T.null base = rel
  | "/" `T.isSuffixOf` base = base <> rel
  | otherwise = base <> "/" <> rel

isAbsolute :: Text -> Bool
isAbsolute = T.isPrefixOf "/"

display :: Text -> Text
display = id

-- | The components as Rust reads them: repeated and trailing separators
-- dropped, and @.@ dropped except at the start.
components :: Text -> [Text]
components p =
  let rooted = isAbsolute p
      parts = filter (not . T.null) (T.splitOn "/" p)
      body = case parts of
        (first : rest) -> first : filter (/= ".") rest
        [] -> []
      body' = if rooted then filter (/= ".") body else body
   in (if rooted then ("/" :) else id) body'

-- | Rust's @Path::parent@: the path without its last component; none for a
-- root or an empty path.
parent :: Text -> Maybe Text
parent p = case components p of
  [] -> Nothing
  ["/"] -> Nothing
  cs -> Just (render (init cs))
  where
    render [] = ""
    render ("/" : rest) = "/" <> T.intercalate "/" rest
    render cs = T.intercalate "/" cs

-- | The last component, unless it is @..@.
fileName :: Text -> Maybe Text
fileName p = case components p of
  [] -> Nothing
  cs -> case last cs of
    "/" -> Nothing
    ".." -> Nothing
    "." -> Nothing
    name -> Just name

-- | The file name without its extension: a leading dot does not start one.
fileStem :: Text -> Maybe Text
fileStem p = stem <$> fileName p
  where
    stem name
      | name == ".." = name
      | otherwise = case T.breakOnEnd "." name of
          ("", _) -> name
          (before, _) ->
            let s = T.dropEnd 1 before
             in if T.null s then name else s

-- | Rust's @Path::with_file_name@.
withFileName :: Text -> Text -> Text
withFileName p name = case parent p of
  Just dir -> join dir name
  Nothing -> name
