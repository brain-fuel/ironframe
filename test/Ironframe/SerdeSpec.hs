module Ironframe.SerdeSpec (spec) where

import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Ironframe.Json
import Ironframe.Json.Serde (Decoder, decodeWith)
import Ironframe.Manifest.Serde
import Test.Hspec

-- | Checks serde's reading of the manifest's types against the recorded
-- serde_json corpus, and every manifest the Rust implementation accepted
-- against its pretty serialisation.
spec :: Spec
spec = describe "Ironframe.Json.Serde" $ do
  cases <- runIO (corpus "corpus/libs-serde.json")
  describe "libs-serde" $ mapM_ check (zip [1 :: Int ..] cases)
  manifests <- runIO (corpus "corpus/manifest.json")
  yamls <- runIO (corpus "corpus/libs-yaml.json")
  let decoded = [(t, e) | y <- yamls, method y == "yaml.decode", Just t <- [textAt "text" (keyOr "input" y)], let e = keyOr "expected" y]
  describe "manifest.parse" $
    mapM_
      (checkManifest decoded)
      [m | m <- manifests, method m == "manifest.parse", Just _ <- [key "ok" (keyOr "expected" m)]]

check :: (Int, Value) -> Spec
check (n, c) = it (show n <> " " <> T.unpack (method c) <> " " <> T.unpack (encode input)) $
  case method c of
    "serde.twin" -> run decodeTwin encodeTwin
    "serde.real" -> run decodeReal encodeReal
    "serde.fault" -> run decodeFault encodeFault
    "serde.admin" -> run decodeAdmin encodeAdmin
    other -> expectationFailure ("unknown method " <> T.unpack other)
  where
    input = keyOr "value" (keyOr "input" c)
    run :: Decoder a -> (a -> Value) -> Expectation
    run d e =
      let actual = case decodeWith d input of
            Right x -> Object [("ok", String (encode (e x)))]
            Left err -> Object [("error", String err)]
       in actual `shouldBe` keyOr "expected" c

checkManifest :: [(Text, Value)] -> Value -> Spec
checkManifest decoded m = it (T.unpack (maybe "" id (textAt "name" m))) $
  case lookup text decoded of
    Nothing -> expectationFailure "no yaml.decode case for this manifest"
    Just y -> case textAt "ok" y of
      Nothing -> expectationFailure "the manifest's YAML did not decode"
      Just json -> case decode json of
        Left e -> expectationFailure (T.unpack e)
        Right v -> (encodePretty . encodeManifest <$> decodeManifest v) `shouldBe` Right expected
  where
    text = maybe "" id (textAt "text" (keyOr "input" m))
    expected = maybe "" id (textAt "ok" (keyOr "expected" m))

method :: Value -> Text
method = maybe "" id . textAt "method"

corpus :: FilePath -> IO [Value]
corpus path = do
  bytes <- B.readFile path
  case decode (TE.decodeUtf8 bytes) of
    Right (Array cases) -> pure cases
    Right _ -> fail (path <> ": not an array")
    Left e -> fail (path <> ": " <> T.unpack e)
