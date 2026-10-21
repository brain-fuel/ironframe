-- | The host protocol: one JSON request in, one JSON response out. A request
-- names a method, its parameters and the results of the effects performed so
-- far; the response is the method's result, the next effect to perform, or
-- why it failed. ref:DEC-host-protocol
module Ironframe.Api (call, callValue, dispatch, version, resolvedJson) where

import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Ironframe.Attestation as A
import Ironframe.Calm.Export (mermaidProblems, settingsProblems, tofuProblems)
import Ironframe.Calm.Model
import Ironframe.Calm.Resolve (Resolution (..))
import Ironframe.Calm.Run (loadAndResolve)
import Ironframe.Cli (cli)
import Ironframe.Compose (composeFile)
import Ironframe.ConfigService (encodeResponse, handle)
import qualified Ironframe.Corpus as Corpus
import Ironframe.Effect
import Ironframe.Json
import Ironframe.Json.Serde (decodeWith, string, textMap)
import Ironframe.Library (libraryMethod)
import Ironframe.Manifest
import Ironframe.Manifest.Serde (decodeSyncTarget, encodeFault, encodeManifest)
import Ironframe.Rust (debugStr)
import Ironframe.Settings
import Ironframe.Sync
import Ironframe.Tofu
import Ironframe.Twin

version :: Text
version = "0.1.0"

-- | Answers one request, as JSON text.
call :: Text -> Text
call input = encode $ case decode input of
  Left e -> object ["error" .= String ("the request is not JSON: " <> e)]
  Right request -> callValue request

-- | Answers one request.
callValue :: Value -> Value
callValue request =
  let method = case keyOr "method" request of
        String m -> m
        _ -> ""
      params = keyOr "params" request
      results = case key "effects" request of
        Just (Array rs) -> rs
        _ -> []
   in case dispatch method params of
        Nothing -> object ["error" .= String ("no such method " <> debugStr method)]
        Just program -> case runEff program results of
          Need effect -> object ["effect" .= effect, "index" .= Number (I (toInteger (length results)))]
          Done (Right v) -> object ["done" .= v]
          Done (Left e) -> object ["failed" .= String e]

text' :: Text -> Value -> Text
text' k v = case keyOr k v of
  String t -> t
  _ -> ""

textMapAt :: Text -> Value -> Map.Map Text Text
textMapAt k v = either (const Map.empty) id (decodeWith (textMap string) (keyOr k v))

okOr :: Either Text Value -> Value
okOr = either (\e -> Object ["error" .= String e]) (\v -> Object ["ok" .= v])

texts :: Value -> [Text]
texts = \case
  Array xs -> [t | String t <- xs]
  _ -> []

-- | The program a method runs, if there is such a method.
dispatch :: Text -> Value -> Maybe (Eff Value)
dispatch method p = case method of
  "version" -> Just (pure (String version))
  "cli" -> Just $ do
    code <- cli (texts (keyOr "argv" p)) (text' "cwd" p)
    pure (Object ["exitCode" .= Number (I code)])
  "configService.handle" -> Just (encodeResponse <$> handle (text' "settingsPath" p) (fromMaybe "GET" (textAt "method" p)) (text' "path" p))
  "corpus.check" -> Just (pure (Corpus.check dispatch (corpusCase p) (keyOr "fixtures" p)))
  "calm.problems" -> Just $ do
    resolution <- loadAndResolve (text' "architecture" p) (textAt "decorators" p) (text' "environment" p) >>= either (failWith . renderCalmError) pure
    let topology = resTopology resolution
        textMapOf t = either (const Map.empty) id (decode t >>= decodeWith (textMap string))
    pure $
      Object
        [ "mermaid" .= Array (map String (maybe [] (mermaidProblems topology) (textAt "mermaid" p)))
        , "tofu" .= Array (map String (maybe [] (either (const ["the root is not JSON"]) (tofuProblems topology) . decode) (textAt "tofu" p)))
        , "settings" .= Array (map String (maybe [] (settingsProblems topology (text' "app" p) . textMapOf) (textAt "settings" p)))
        ]
  "manifest.parse" -> Just (pure (manifestResult (parseManifest (text' "text" p))))
  "manifest.load" -> Just (manifestResult <$> loadManifest (text' "path" p))
  "manifest.environment" -> Just $ pure $ case parseManifest (text' "text" p) of
    Left e -> Object ["error" .= String (renderManifestError e)]
    Right m -> either (\e -> Object ["error" .= String (renderManifestError e)]) (const (Object ["ok" .= Bool True])) (environmentOf m (text' "environment" p))
  "manifest.placeholders" -> Just (pure (okOr (Array . map String <$> placeholders (text' "template" p))))
  "settings.resolve" -> Just $ pure $ withManifest $ \m ->
    okOr (either (Left . renderResolveError) (Right . resolvedJson) (resolve m (text' "environment" p) (textMapAt "deployed" p)))
  "endpoint.split" -> Just $ pure $
    let (host, port) = splitEndpoint (text' "endpoint" p)
     in Object ["host" .= String host, "port" .= maybe Null (Number . I) port]
  "image.qualify" -> Just (pure (String (qualifyImage (text' "image" p))))
  "dotenv.render" -> Just (pure (String (renderDotenv (text' "header" p) (textMapAt "settings" p))))
  "dotenv.parse" -> Just (pure (fromTextMap (parseDotenv (text' "text" p))))
  "compose.file" -> Just $ pure $ withManifest $ \m ->
    case resolve m (text' "environment" p) Map.empty of
      Left e -> Object ["error" .= String (renderResolveError e)]
      Right resolved ->
        let service = case keyOr "configService" p of
              o@(Object _) -> Just (ConfigService (text' "image" o) (case keyOr "port" o of Number (I n) -> n; _ -> 0), text' "settingsPath" p)
              _ -> Nothing
         in String (composeFile resolved service)
  "tofu.root" -> Just $ pure $ withManifest $ \m ->
    okOr (either (Left . renderTofuError) (\r -> Right (String (encodePretty r <> "\n"))) (rootModule m (text' "environment" p) (text' "manifestDir" p)))
  "tofu.moduleSource" -> Just (pure (String (moduleSource (text' "base" p) (text' "module" p) (text' "manifestDir" p))))
  "tofu.deploymentName" -> Just (pure (String (deploymentName (text' "project" p) (text' "environment" p) (text' "dependency" p))))
  "sync.settingsJson" -> Just (pure (String (settingsJson (textMapAt "settings" p))))
  "gcp.versionId" -> Just (pure (String (versionId (text' "content" p))))
  "sync.describe" -> Just $ pure $ case decodeWith decodeSyncTarget (keyOr "target" p) of
    Right t -> String (describeTarget t (text' "environment" p))
    Left e -> Object ["error" .= String e]
  "azure.connectionString" -> Just $ pure $ case parseConnectionString (text' "text" p) of
    Right c -> Object ["ok" .= Object ["endpoint" .= String (csEndpoint c), "id" .= String (csId c), "secretLength" .= Number (I (toInteger (T.length (csSecret c))))]]
    Left e -> Object ["error" .= String e]
  "attestation.fromJson" -> Just (pure (okOr (A.fromJson (text' "text" p) >>= fmap String . A.toJson)))
  "attestation.historyDigest" -> Just (pure (String (historyDigest (text' "history" p))))
  "attestation.isHistoryDigest" -> Just (pure (Bool (A.isHistoryDigest (text' "digest" p))))
  "calm.parseArchitecture" -> Just $ pure $ case parseArchitecture (text' "text" p) of
    Left e -> Object ["error" .= String (renderCalmError e)]
    Right a ->
      Object
        [ "ok"
            .= Object
              [ "digest" .= String (archDigest a)
              , "unique_id" .= maybe Null String (archUniqueId a)
              , "nodes" .= Number (I (toInteger (length (archNodes a))))
              , "relationships" .= Number (I (toInteger (length (archRelationships a))))
              , "element_ids" .= Array (map String (elementIds a))
              ]
        ]
  "twin.parseFault" -> Just $ pure $ case parseFault (text' "name" p) (texts (keyOr "params" p)) of
    Right f -> Object ["ok" .= encodeFault f]
    Left e -> Object ["error" .= String (renderTwinError e)]
  "twin.pretty" -> Just (pure (String (pretty (text' "body" p))))
  "twin.replyOk" -> Just $ pure $ case replyOk (Reply (case keyOr "status" p of Number (I n) -> fromInteger n; _ -> 0) (text' "body" p)) of
    Right t -> Object ["ok" .= String t]
    Left e -> Object ["error" .= String (renderTwinError e), "code" .= Number (I (toInteger (twinExitCode e)))]
  "conformance.parse" -> Just $ pure $ case parseReport (text' "text" p) of
    Left e -> Object ["error" .= String e]
    Right r ->
      let opt = maybe Null String
       in Object
            [ "ok"
                .= Object
                  [ "level" .= String (reportLevel r)
                  , "number" .= maybe Null (Number . I) (reportNumber r)
                  , "release" .= opt (reportRelease r)
                  , "twin" .= opt (reportTwin r)
                  , "contract" .= opt (reportContract r)
                  , "describe" .= String (reportDescribe r)
                  , "matches" .= Array [Array [String d, Bool (reportMatches r d)] | d <- ["answers", "Answers", "3", "3-answers", "3-ANSWERS", " answers ", "exact", "conformant", "4"]]
                  ]
            ]
  _ -> libraryMethod method p
  where
    withManifest k = case parseManifest (text' "text" p) of
      Left e -> Object ["error" .= String (renderManifestError e)]
      Right m -> k m

-- | The case to check: given as a value, or as the text of a corpus file and
-- an index, which keeps its keys in their written order whatever the host's
-- JSON does with them.
corpusCase :: Value -> Value
corpusCase p = case (keyOr "corpusText" p, keyOr "index" p) of
  (String text, Number (I i)) -> case decode text of
    Right (Array cases) | i >= 0 && fromInteger i < length cases -> cases !! fromInteger i
    _ -> Null
  _ -> keyOr "case" p

manifestResult :: Either ManifestError Manifest -> Value
manifestResult = \case
  Right m ->
    Object
      [ "ok" .= String (encodePretty (encodeManifest m))
      , "levels"
          .= Object
            [ (environment <> "." <> dependency, String (conformanceLevel twin))
            | (environment, declared) <- Map.toAscList (manifestEnvironments m)
            , (dependency, BindTwin twin) <- Map.toAscList (envDependencies declared)
            ]
      ]
  Left e ->
    Object
      [ "error" .= String (renderManifestError e)
      , "problems" .= Array [Object ["at" .= String (problemPath pr), "message" .= String (problemMessage pr)] | pr <- errorProblems e]
      ]

-- | The resolved environment as the corpus records it.
resolvedJson :: ResolvedEnvironment -> Value
resolvedJson e =
  Object
    [ "project" .= String (reProject e)
    , "environment" .= String (reEnvironment e)
    , "runtime" .= String (runtimeWord (reRuntime e))
    , "stack_name" .= String (stackName e)
    , "settings" .= fromTextMap (environmentSettings e)
    , "dependencies"
        .= Array
          [ Object
              [ "name" .= String (rdName d)
              , "kind" .= String (kindWord (rdKind d))
              , "endpoint" .= String (rdEndpoint d)
              , "image" .= maybe Null String (rdImage d)
              , "ports" .= Array (map (Number . I) (rdPorts d))
              , "container_env" .= fromTextMap (rdContainerEnv d)
              , "stand_in" .= maybe Null A.encodeStandIn (rdStandIn d)
              , "credentials" .= maybe Null String (rdCredentials d)
              , "settings" .= fromTextMap (rdSettings d)
              , "admin_url" .= maybe Null String (rdAdminUrl d)
              , "admin_port" .= maybe Null (\(h, c) -> Array [Number (I h), Number (I c)]) (rdAdminPort d)
              , "twin" .= Bool (rdTwin d /= Nothing)
              ]
          | d <- reDependencies e
          ]
    ]
