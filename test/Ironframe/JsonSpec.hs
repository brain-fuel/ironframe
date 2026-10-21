module Ironframe.JsonSpec (spec) where

import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Float (castWord64ToDouble)
import Ironframe.Json
import Test.Hspec

-- | Checks reading and writing JSON against the recorded serde_json corpus.
spec :: Spec
spec = describe "Ironframe.Json" $ do
  cases <- runIO (corpus "corpus/libs-json.json")
  mapM_ check (zip [1 :: Int ..] cases)

check :: (Int, Value) -> Spec
check (n, c) = it (show n <> " " <> T.unpack (method c) <> " " <> show (input c)) $
  case method c of
    "json.decode" ->
      let actual = case decode (maybe "" id (textAt "text" (input c))) of
            Right v -> Object [("compact", String (encode v)), ("pretty", String (encodePretty v))]
            Left e -> Object [("error", String e)]
       in actual `shouldBe` expected c
    "json.formatDouble" ->
      let bits = read (T.unpack (maybe "" id (textAt "bits" (input c))))
       in String (formatDouble (castWord64ToDouble bits)) `shouldBe` expected c
    other -> expectationFailure ("unknown method " <> T.unpack other)

method :: Value -> Text
method = maybe "" id . textAt "method"

input :: Value -> Value
input = keyOr "input"

expected :: Value -> Value
expected = keyOr "expected"

corpus :: FilePath -> IO [Value]
corpus path = do
  bytes <- B.readFile path
  case decode (TE.decodeUtf8 bytes) of
    Right (Array cases) -> pure cases
    Right _ -> fail (path <> ": not an array")
    Left e -> fail (path <> ": " <> T.unpack e)
