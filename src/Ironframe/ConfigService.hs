-- | The configuration service: serves each environment's connection
-- settings, the same settings Ironframe writes to env files and syncs into
-- the clouds. It reads its settings document on every request, so a new
-- @ironframe up@ is visible at once, and it never writes. The Node server only
-- passes each request here. ref:DEC-config-service
module Ironframe.ConfigService (Response (..), handle, encodeResponse) where

import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as T
import Ironframe.Effect
import Ironframe.Json
import Ironframe.Json.FromStr (Expect (..), fromStr)
import Ironframe.Json.Serde
import qualified Ironframe.Path as Path
import Ironframe.Rust (debugStr)
import Ironframe.Settings
import qualified Ironframe.Revision as Revision

-- | An answer: status, content type, body.
data Response = Response {responseStatus :: Int, responseType :: Maybe Text, responseBody :: Text}

encodeResponse :: Response -> Value
encodeResponse r =
  Object
    [ "status" .= Number (I (toInteger (responseStatus r)))
    , "contentType" .= maybe Null String (responseType r)
    , "body" .= String (responseBody r)
    ]

json :: Int -> Value -> Response
json status v = Response status (Just "application/json") (encode v)

plain :: Text -> Response
plain = Response 200 (Just "text/plain; charset=utf-8")

failure :: Int -> Text -> Response
failure status message = json status (Object ["error" .= String message])

-- | Answers one request for the settings document at a path.
handle :: Text -> Text -> Text -> Eff Response
handle settingsPath method path = case T.splitOn "/" (T.drop 1 path) of
  ["healthz"] -> get (pure (plain "ok\n"))
  ["v1", "environments"] -> get $ withDocument $ \d ->
    pure (json 200 (Object ["project" .= String (docProject d), "environments" .= Array (map String (Map.keys (docEnvironments d)))]))
  ["v1", "environments", name] | not (T.null name) -> get $ withEnvironment (decodePath name) $ \settings -> pure (json 200 (fromTextMap settings))
  ["v1", "environments", name, "env"] | not (T.null name) -> get $ withEnvironment (decodePath name) $ \settings ->
    pure (plain (renderDotenv ("Settings of environment " <> decodePath name) settings))
  ["v1", "environments", name, "bindings", node] | not (T.null name) && not (T.null node) -> get $
    withEnvironment (decodePath name) $ \_ -> do
      let root = Path.join (maybe "." id (Path.parent settingsPath)) "revisions"
      current <- readFileE (Path.join root "current.json")
      case current >>= either (Left . (\message -> IoError message False)) Right . decode of
        Left problem -> pure (failure 503 (ioMessage problem))
        Right state -> case textAt "desired" state >>= T.stripPrefix "sha256:" of
          Just hash | T.length hash == 64 && T.all (`elem` ("0123456789abcdef" :: String)) hash -> do
            raw <- readFileE (Path.join root (hash <> ".json"))
            pure $ case raw >>= either (Left . (\message -> IoError message False)) Right . decode of
              Left problem -> failure 503 (ioMessage problem)
              Right configuration
                | textAt "environment" (keyOr "payload" configuration) /= Just (decodePath name) -> failure 404 "revision belongs to another environment"
                | otherwise -> either (failure 503) (json 200) (Revision.binding configuration state (decodePath node))
          _ -> pure (failure 503 "no configuration revision has been selected")
  ["v1", "environments", name, "settings", k] | not (T.null name) && not (T.null k) -> get $ withEnvironment (decodePath name) $ \settings ->
    pure $ case Map.lookup (decodePath k) settings of
      Just v -> plain v
      Nothing -> failure 404 ("environment " <> debugStr (decodePath name) <> " has no setting " <> decodePath k)
  _ -> pure (Response 404 Nothing "")
  where
    get answer = if method == "GET" || method == "HEAD" then answer else pure (Response 405 Nothing "")
    withDocument k = do
      r <- readFileE settingsPath
      case r of
        Left e -> pure (failure 503 ("cannot read " <> Path.display settingsPath <> ": " <> ioMessage e))
        Right text -> case fromStr (ExpectStruct "SettingsDocument") document text of
          Left e -> pure (failure 503 (Path.display settingsPath <> " is not a settings document: " <> e))
          Right d -> k d
    withEnvironment name k = withDocument $ \d -> case Map.lookup name (docEnvironments d) of
      Just settings -> k settings
      Nothing -> pure (failure 404 ("no environment " <> debugStr name <> "; this service has " <> T.intercalate ", " (Map.keys (docEnvironments d))))
    document :: Decoder SettingsDocument
    document = struct "SettingsDocument" False (SettingsDocument <$> required "project" string <*> required "environments" (textMap (textMap string)))

-- | Percent-decoding of one path segment, as axum's Path extractor does.
decodePath :: Text -> Text
decodePath t = case T.breakOn "%" t of
  (before, "") -> before
  (before, rest) -> case T.unpack (T.take 2 (T.drop 1 rest)) of
    [a, b] | isHex a && isHex b -> before <> T.singleton (toEnum (hex a * 16 + hex b)) <> decodePath (T.drop 3 rest)
    _ -> before <> "%" <> decodePath (T.drop 1 rest)
  where
    isHex c = c `elem` ("0123456789abcdefABCDEF" :: String)
    hex c
      | c >= '0' && c <= '9' = fromEnum c - fromEnum '0'
      | c >= 'a' && c <= 'f' = fromEnum c - fromEnum 'a' + 10
      | otherwise = fromEnum c - fromEnum 'A' + 10

_unusedMap :: Map Text Text
_unusedMap = Map.empty
