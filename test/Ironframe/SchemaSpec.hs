-- | Checks the schema validator against the errors jsonschema-rs recorded.
-- Each corpus case names a schema; every error must match in order.
-- ref:DEC-haskell-wasm-core
module Ironframe.SchemaSpec (spec) where

import Control.Monad (forM_)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Ironframe.Json (Value (..), decode)
import Ironframe.Json.Schema
import qualified Ironframe.Regex as Regex
import Test.Hspec

-- | Reads and decodes a JSON file.
readJson :: FilePath -> IO Value
readJson path = do
  bytes <- BS.readFile path
  either (fail . T.unpack) pure (decode (TE.decodeUtf8 bytes))

calmMeta :: Text
calmMeta = "https://calm.finos.org/release/1.2/meta/"

-- | Compiles every schema the corpus names.
schemas :: IO [(Text, Schema)]
schemas = do
  manifest <- readJson "schema/ironframe-v1.schema.json"
  attestation <- readJson "schema/attestation-v1.schema.json"
  calm <- mapM (\n -> (,) (calmMeta <> T.pack n) <$> readJson ("schema/calm/1.2/" ++ n)) ["core.json", "control.json", "flow.json", "interface.json", "decorators.json"]
  typed <- mapM (\k -> (,) (T.pack ("ironframe-" ++ k)) <$> readJson ("schema/calm/ironframe-" ++ k ++ ".decorator.schema.json")) ["contract", "binding", "environment"]
  let decorators = snd (calm !! 4)
      base = case decorators of
        Object kv | Just (Object defs) <- lookup "defs" kv, Just d <- lookup "decorator" defs -> d
        _ -> Null
      build name resources root = either (fail . T.unpack . ((name <> ": ") <>)) (pure . (,) name) (compile resources root)
  sequence $
    [ build "manifest" [] manifest
    , build "attestation" [] attestation
    , build "calm-core" calm (snd (calm !! 0))
    , build "calm-decorator" [] base
    ]
      ++ [build n [] v | (n, v) <- typed]

field :: Text -> Value -> Value
field k (Object kv) = maybe Null id (lookup k kv)
field _ _ = Null

text :: Value -> Text
text (String t) = t
text _ = ""

expectedErrors :: Value -> [SchemaError]
expectedErrors v = case field "expected" v of
  Array es -> [SchemaError (text (field "path" e)) (text (field "schemaPath" e)) (text (field "message" e)) | e <- es]
  _ -> []

spec :: Spec
spec = do
  describe "Ironframe.Regex" $ do
    let ok p t = either (const False) (`Regex.match` t) (Regex.compile p)
    it "searches unanchored" $ ok "^https://" "https://x" `shouldBe` True
    it "anchors both ends" $ ok "^[a-z][a-z0-9_-]{0,39}$" "Shop" `shouldBe` False
    it "repeats groups" $ ok "^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)*$" "shop.adoptions" `shouldBe` True
    it "bounds repetition" $ ok "^sha256:[0-9a-f]{64}$" ("sha256:" <> T.replicate 63 "a") `shouldBe` False
    it "alternates" $ ok "^(env|file|vault):.+$" "file:x" `shouldBe` True
    it "refuses look-around" $ either (const True) (const False) (Regex.compile "(?=a)") `shouldBe` True
  describe "Ironframe.Json.Schema" $ do
    compiled <- runIO schemas
    corpus <- runIO (readJson "corpus/libs-schema.json")
    let cases = case corpus of
          Array cs -> cs
          _ -> []
    forM_ (zip [0 :: Int ..] cases) $ \(i, c) -> do
      let input = field "input" c
          name = text (field "schema" input)
      it ("case " ++ show i ++ " (" ++ T.unpack name ++ ")") $ case lookup name compiled of
        Nothing -> expectationFailure ("no schema " ++ T.unpack name)
        Just s -> do
          let instance' = field "instance" input
          validate s instance' `shouldBe` expectedErrors c
          isValid s instance' `shouldBe` null (expectedErrors c)
