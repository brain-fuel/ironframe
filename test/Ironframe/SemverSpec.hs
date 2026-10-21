module Ironframe.SemverSpec (spec) where

import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Ironframe.Json (Value (..), decode, key, textAt)
import Ironframe.Semver
import Test.Hspec

-- | Checks versions and requirements against the recorded semver corpus.
spec :: Spec
spec = describe "Ironframe.Semver" $ do
  cases <- runIO (corpus "corpus/libs-semver.json")
  let versions = [t | c <- cases, method c == "semver.version", Just t <- [inputText c]]
  mapM_ (check versions) cases

check :: [Text] -> Value -> Spec
check versions c = it (T.unpack (method c <> " " <> T.pack (show text))) $
  case method c of
    "semver.version" -> actualVersion `shouldBe` expected
    "semver.requirement" -> actualReq `shouldBe` expected
    other -> expectationFailure ("unknown method " <> T.unpack other)
  where
    text = maybe "" id (inputText c)
    expected = maybe Null id (key "expected" c)
    actualVersion = case parseVersion text of
      Right v -> Object [("ok", String (renderVersion v))]
      Left e -> Object [("error", String e)]
    actualReq = case parseReq text of
      Right r ->
        Object
          [ ("ok", String (renderReq r))
          , ("matches", Array [Array [String v, Bool (matches r ver)] | v <- versions, Right ver <- [parseVersion v]])
          ]
      Left e -> Object [("error", String e)]

method :: Value -> Text
method = maybe "" id . textAt "method"

inputText :: Value -> Maybe Text
inputText c = key "input" c >>= textAt "text"

corpus :: FilePath -> IO [Value]
corpus path = do
  bytes <- B.readFile path
  case decode (TE.decodeUtf8 bytes) of
    Right (Array cases) -> pure cases
    Right _ -> fail (path <> ": not an array")
    Left e -> fail (path <> ": " <> T.unpack e)
