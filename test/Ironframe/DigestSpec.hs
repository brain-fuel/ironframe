module Ironframe.DigestSpec (spec) where

import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Ironframe.Digest
import Ironframe.Json (Value (..), decode, key, textAt)
import Test.Hspec

-- | Checks history digests and version ids against the recorded corpus.
spec :: Spec
spec = describe "Ironframe.Digest" $ do
  attestation <- runIO (corpus "corpus/attestation.json")
  sync <- runIO (corpus "corpus/sync.json")
  mapM_ (check "attestation.historyDigest" "history" digestOf) attestation
  mapM_ (check "gcp.versionId" "content" versionId) sync
  it "writes lowercase hex" $
    sha256Hex "abc" `shouldBe` "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

check :: Text -> Text -> (Text -> Text) -> Value -> Spec
check wanted field f c
  | textAt "method" c == Just wanted =
      it (T.unpack (maybe wanted id (textAt "name" c))) $
        String (f (maybe "" id (key "input" c >>= textAt field))) `shouldBe` maybe Null id (key "expected" c)
  | otherwise = pure ()

corpus :: FilePath -> IO [Value]
corpus path = do
  bytes <- B.readFile path
  case decode (TE.decodeUtf8 bytes) of
    Right (Array cases) -> pure cases
    Right _ -> fail (path <> ": not an array")
    Left e -> fail (path <> ": " <> T.unpack e)
