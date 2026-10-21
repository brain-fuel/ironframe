-- | The YAML corpus: every recorded serde_yaml read and write, replayed.
-- ref:DEC-haskell-wasm-core
module Ironframe.YamlSpec (spec) where

import Control.Monad (forM_)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Ironframe.Json (Value (..), decode, encode, key, textAt)
import Ironframe.Yaml (decodeYaml, encodeYaml)
import Test.Hspec

-- | The corpus cases, numbered in file order.
loadCases :: IO [(Int, Value)]
loadCases = do
  raw <- BS.readFile "corpus/libs-yaml.json"
  case decode (TE.decodeUtf8 raw) of
    Right (Array cases) -> pure (zip [0 ..] cases)
    Right _ -> fail "corpus/libs-yaml.json is not an array"
    Left e -> fail (T.unpack e)

-- | A short label for a case.
label :: Int -> Text -> String
label i t = show i ++ ": " ++ take 60 (show t)

spec :: Spec
spec = do
  cases <- runIO loadCases
  describe "yaml.decode" $
    forM_ cases $ \(i, c) ->
      case (textAt "method" c, key "input" c >>= textAt "text", key "expected" c) of
        (Just "yaml.decode", Just text, Just expected) ->
          it (label i text) $ case (textAt "ok" expected, textAt "error" expected) of
            (Just ok, _) -> fmap encode (decodeYaml text) `shouldBe` Right ok
            (_, Just err) -> decodeYaml text `shouldBe` Left err
            _ -> expectationFailure "expected holds neither ok nor error"
        _ -> pure ()
  describe "yaml.encode" $
    forM_ cases $ \(i, c) ->
      case (textAt "method" c, key "input" c >>= key "value", key "expected" c) of
        (Just "yaml.encode", Just value, Just (String expected)) ->
          it (label i (encode value)) $ encodeYaml value `shouldBe` expected
        _ -> pure ()
