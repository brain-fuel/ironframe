module Ironframe.TimeSpec (spec) where

import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Ironframe.Json (Number (..), Value (..), decode, key, textAt)
import Ironframe.Time
import Test.Hspec

-- | Checks RFC 3339 parsing and formatting against the recorded time corpus.
spec :: Spec
spec = describe "Ironframe.Time" $ do
  cases <- runIO (corpus "corpus/libs-time.json")
  mapM_ check cases
  it "orders by instant and keeps the second of equal instants" $ do
    let a = fromUnix 3600 0
        b = (fromUnix 0 0) {tsHour = 2, tsOffsetMinutes = 60}
    compareInstant a b `shouldBe` EQ
    tsOffsetMinutes (maxInstant a b) `shouldBe` 60
    unixNanos (maxInstant (fromUnix 5 1) a) `shouldBe` 3600000000000

check :: Value -> Spec
check c = case method c of
  "time.rfc3339" -> it ("time.rfc3339 " <> show text) $ actualParse `shouldBe` expected
  "time.format" -> it ("time.format " <> show (seconds, nanos)) $
    String (formatRfc3339 (fromUnix seconds nanos)) `shouldBe` expected
  other -> it (T.unpack other) $ expectationFailure ("unknown method " <> T.unpack other)
  where
    input = maybe Null id (key "input" c)
    text = maybe "" id (textAt "text" input)
    seconds = intAt "seconds"
    nanos = intAt "nanos"
    intAt k = case key k input of
      Just (Number (I n)) -> n
      _ -> 0
    expected = maybe Null id (key "expected" c)
    actualParse = case parseRfc3339 text of
      Right t -> Object [("ok", String (formatRfc3339 t)), ("unixNanos", String (T.pack (show (unixNanos t))))]
      Left e -> Object [("error", String e)]

method :: Value -> Text
method = maybe "" id . textAt "method"

corpus :: FilePath -> IO [Value]
corpus path = do
  bytes <- B.readFile path
  case decode (TE.decodeUtf8 bytes) of
    Right (Array cases) -> pure cases
    Right _ -> fail (path <> ": not an array")
    Left e -> fail (path <> ": " <> T.unpack e)
