module Ironframe.RustSpec (spec) where

import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Ironframe.Json
import Ironframe.Rust
import Test.Hspec

-- | Checks Rust's Debug quoting of strings against the recorded corpus.
spec :: Spec
spec = describe "Ironframe.Rust" $ do
  cases <- runIO (corpus "corpus/libs-debug.json")
  mapM_ check (zip [1 :: Int ..] cases)

check :: (Int, Value) -> Spec
check (n, c) = it (show n <> " " <> show text) $
  case method c of
    "rust.debugStr" -> String (debugStr text) `shouldBe` keyOr "expected" c
    other -> expectationFailure ("unknown method " <> T.unpack other)
  where
    text = maybe "" id (textAt "text" (keyOr "input" c))

method :: Value -> Text
method = maybe "" id . textAt "method"

corpus :: FilePath -> IO [Value]
corpus path = do
  bytes <- B.readFile path
  case decode (TE.decodeUtf8 bytes) of
    Right (Array cases) -> pure cases
    Right _ -> fail (path <> ": not an array")
    Left e -> fail (path <> ": " <> T.unpack e)
