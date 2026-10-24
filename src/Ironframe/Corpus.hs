-- | The parity check against the golden corpus the Rust implementation
-- recorded. Each case runs through the same programs the host runs, with a
-- scripted host: files in memory, and every process, HTTP request and cloud
-- call answered from what the Rust run recorded, checked in order. It runs
-- natively under hspec and in WASM under Node, so both builds are held to the
-- same oracle. ref:DEC-haskell-wasm-core ref:DEC-host-protocol
module Ironframe.Corpus (check, normalise, deliberateDifferences) where

import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Ironframe.Attest as Attest
import qualified Ironframe.Attestation as A
import Ironframe.Calm.Export
import Ironframe.Calm.Model
import Ironframe.Calm.Resolve
import Ironframe.ConfigService (encodeResponse, handle)
import Ironframe.Effect
import Ironframe.Json
import Ironframe.Json.Serde (decodeWith, textMap)
import qualified Ironframe.Json.Serde
import Ironframe.Manifest
import Ironframe.Manifest.Serde (encodeManifest)
import Ironframe.Ops
import Ironframe.Settings
import Ironframe.Sync
import Ironframe.Time (fromUnix, parseRfc3339)
import Ironframe.Tofu (renderTofuError, rootModule)
import Ironframe.Twin

-- | The methods whose output differs from the Rust behaviour on purpose,
-- with the reason; none at present. The other deliberate differences, such
-- as Azure signing by the SDK, sit outside the core and the corpus.
deliberateDifferences :: [(Text, Text)]
deliberateDifferences = []

-- The scripted host.

data Script = Script
  { sFiles :: Map Text Text
  , sEnv :: Map Text Text
  , sProcesses :: [Value]
  , sHttp :: [Value]
  , sClouds :: [Value]
  , sProbes :: Map Text Bool
  , sClock :: Integer
  , sStdout :: [Text]
  , sStderr :: [Text]
  , sProgress :: [Text]
  , sMismatches :: [Text]
  , sFixtures :: Map Text Text
  }

emptyScript :: Script
emptyScript = Script Map.empty Map.empty [] [] [] Map.empty 0 [] [] [] [] Map.empty

runScripted :: Script -> Eff a -> (Either Text a, Script)
runScripted s0 program = loop s0 []
  where
    loop s results = case runEff program results of
      Done r -> (r, s)
      Need e ->
        if length results > 20000
          then (Left "the program asked for too many effects", s)
          else
            let (r, s') = answer s e
             in loop s' (results ++ [r])

ok :: Value -> Value
ok v = Object ["ok" .= v]

notFound :: Value
notFound = Object ["error" .= String "No such file or directory (os error 2)", "notFound" .= Bool True]

text' :: Text -> Value -> Text
text' k v = case keyOr k v of
  String t -> t
  _ -> ""

answer :: Script -> Value -> (Value, Script)
answer s e = case text' "effect" e of
  "readFile" -> case lookupFile (text' "path" e) of
    Just t -> (ok (String t), s)
    Nothing -> (notFound, s)
  "writeAtomically" ->
    let path = text' "path" e
        new = text' "text" e
     in if Map.lookup path (sFiles s) == Just new then (ok (Bool False), s) else (ok (Bool True), s {sFiles = Map.insert path new (sFiles s)})
  "writeFile" -> (ok Null, s {sFiles = Map.insert (text' "path" e) (text' "text" e) (sFiles s)})
  "removeFile" ->
    if Map.member (text' "path" e) (sFiles s)
      then (ok Null, s {sFiles = Map.delete (text' "path" e) (sFiles s)})
      else (notFound, s)
  "removeTree" -> (ok Null, s {sFiles = Map.filterWithKey (\k _ -> not ((text' "path" e <> "/") `T.isPrefixOf` k)) (sFiles s)})
  "createDir" -> (ok Null, s)
  "canonicalize" -> (ok (String (text' "path" e)), s)
  "cwd" -> (ok (String "/work"), s)
  "env" -> (ok (maybe Null String (Map.lookup (text' "name" e) (sEnv s))), s)
  "locate" -> (ok (maybe Null String (Map.lookup (text' "variable" e) (sEnv s) >>= \v -> if T.null v then Nothing else Just v)), s)
  "run" -> case sProcesses s of
    (expected : rest) ->
      let same = keyOr "program" expected == keyOr "program" e && keyOr "args" expected == keyOr "args" e && keyOr "stream" expected == keyOr "stream" e
          s' = s {sProcesses = rest, sMismatches = sMismatches s ++ ["process: expected " <> encode (picked expected) <> ", got " <> encode (picked e) | not same]}
          success = keyOr "success" expected
       in ( ok (Object ["success" .= success, "code" .= Number (I (if success == Bool True then 0 else 1)), "stdout" .= keyOr "stdout" expected, "stderr" .= keyOr "stderr" expected])
          , s'
          )
    [] -> (Object ["error" .= String "No such file or directory (os error 2)"], s {sMismatches = sMismatches s ++ ["process: unexpected " <> encode (picked e)]})
  "http" -> case sHttp s of
    (expected : rest) ->
      let url = text' "url" e
          path = fromMaybe url (T.stripPrefix "http://twin.test" url)
          same = text' "method" expected == text' "method" e && text' "path" expected == path && bodyOf expected == bodyOf e
          s' = s {sHttp = rest, sMismatches = sMismatches s ++ ["http: expected " <> text' "method" expected <> " " <> text' "path" expected <> " " <> bodyOf expected <> ", got " <> text' "method" e <> " " <> path <> " " <> bodyOf e | not same]}
       in (ok (Object ["status" .= keyOr "status" expected, "body" .= keyOr "response" expected]), s')
    [] -> (Object ["error" .= String "Connection refused (os error 61)"], s)
  "tcpProbe" -> (ok (Bool (Map.findWithDefault False (text' "endpoint" e) (sProbes s))), s)
  "sleep" -> (ok Null, s)
  "now" -> (ok (Object ["seconds" .= Number (I 1791547200), "nanos" .= Number (I 0)]), s)
  "monotonic" -> (ok (Number (I (sClock s + 1000))), s {sClock = sClock s + 1000})
  "uuid" -> (ok (String "00000000-0000-4000-8000-000000000000"), s)
  "print" ->
    if text' "stream" e == "stdout"
      then (ok Null, s {sStdout = sStdout s ++ [text' "text" e]})
      else (ok Null, s {sStderr = sStderr s ++ [text' "text" e]})
  "progress" -> (ok Null, s {sProgress = sProgress s ++ [text' "text" e]})
  "readStdin" -> (ok (String ""), s)
  "tempDir" -> (ok (String "/tmp"), s)
  "processId" -> (ok (Number (I 1)), s)
  name
    | any (`T.isPrefixOf` name) ["aws.", "gcp.", "azure."] -> case sClouds s of
        (expected : rest) ->
          let fields v = Map.delete "result" (Map.delete "effect" (toMap v))
              same = text' "effect" expected == name && fields expected == fields e
              s' = s {sClouds = rest, sMismatches = sMismatches s ++ ["cloud: expected " <> encode expected <> ", got " <> encode e | not same]}
              result = keyOr "result" expected
           in case (key "Ok" result, key "Err" result) of
                (Just v, _) -> (ok v, s')
                (_, Just err) -> (Object ["error" .= err], s')
                _ -> (ok result, s')
        [] -> (Object ["error" .= String "no recorded cloud call"], s {sMismatches = sMismatches s ++ ["cloud: unexpected " <> encode e]})
  other -> (Object ["error" .= String ("unknown effect " <> other)], s {sMismatches = sMismatches s ++ ["unknown effect " <> other]})
  where
    picked v = Object [(k, keyOr k v) | k <- ["program", "args", "stream"]]
    bodyOf v = case keyOr "body" v of
      String b -> b
      _ -> ""
    lookupFile path = case Map.lookup path (sFiles s) of
      Just t -> Just t
      Nothing -> case T.stripPrefix "/work/architecture/" path of
        Just rest -> Map.lookup ("examples/calm-shop/architecture/" <> rest) (sFixtures s)
        Nothing -> Nothing

-- | Replaces UUIDs with @<uuid>@ and RFC 3339 times with @<time>@, as the
-- capture did.
normalise :: Text -> Text
normalise = times . uuids . producerVersion
  where
    uuids t = T.pack (goU (T.unpack t) ' ')
    goU [] _ = []
    goU s@(c : rest) prev
      | not (isAlnum prev), Just after <- uuidAt s = "<uuid>" ++ goU after '>'
      | otherwise = c : goU rest c
    uuidAt s = groups [8, 4, 4, 4, 12] s
    groups [n] s = let (h, r) = splitAt n s in if length h == n && all isLowerHex h then Just r else Nothing
    groups (n : ns) s = case splitAt n s of
      (h, '-' : r) | length h == n && all isLowerHex h -> groups ns r
      _ -> Nothing
    groups [] _ = Nothing
    isLowerHex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
    isAlnum c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
    times t = T.pack (goT (T.unpack t))
    goT [] = []
    goT s@(c : rest) = case timeAt s of
      Just after -> "<time>" ++ goT after
      Nothing -> c : goT rest
    digit c = c >= '0' && c <= '9'
    timeAt s = case s of
      (a : b : c' : d : '-' : e : f : '-' : g : h : 'T' : i : j : ':' : k : l : ':' : m : n : more)
        | all digit [a, b, c', d, e, f, g, h, i, j, k, l, m, n] ->
            let more1 = case more of
                  ('.' : ds) -> dropWhile digit ds
                  _ -> more
             in Just $ case more1 of
                  ('Z' : r) -> r
                  (sign : x : y : ':' : z : w : r) | sign `elem` ("+-" :: String) && digit x && digit y -> const r (z, w)
                  _ -> more1
      _ -> Nothing

-- | Historical parity ignores only the release producer version, not provider versions.
producerVersion :: Text -> Text
producerVersion = T.replace "ironframe 0.2.1" "ironframe 0.1.0"
  . T.replace "\"name\": \"ironframe\",\n    \"version\": \"0.2.1\"" "\"name\": \"ironframe\",\n    \"version\": \"0.1.0\""

releaseVersions :: Value -> Value
releaseVersions (String value) = String (producerVersion value)
releaseVersions (Array values) = Array (map releaseVersions values)
releaseVersions (Object values) = Object [(name,releaseVersions value) | (name,value) <- values]
releaseVersions value = value

normaliseValue :: Value -> Value
normaliseValue = \case
  String t -> String (normalise t)
  Array xs -> Array (map normaliseValue xs)
  Object ps -> Object [(normalise k, normaliseValue v) | (k, v) <- ps]
  other -> other

-- | Checks one case: @{"pass": true}@, or @{"pass": false, "diff": ...}@.
check :: (Text -> Value -> Maybe (Eff Value)) -> Value -> Value -> Value
check dispatch c fixtures =
  let method = text' "method" c
      input = keyOr "input" c
      expected = keyOr "expected" c
      fixtureMap = either (const Map.empty) id (decodeWith (textMap Ironframe.Json.Serde.string) fixtures)
      base = emptyScript {sFixtures = fixtureMap}
      compareTo got = verdict method expected got
   in case method of
        "cli" -> Object ["pass" .= Bool True, "note" .= String "run by the CLI corpus tests"]
        "manifest.load" ->
          let files = either (const Map.empty) id (decodeWith (textMap Ironframe.Json.Serde.string) (keyOr "files" input))
           in runMethod dispatch method input base {sFiles = files} compareTo
        "configService.get" ->
          let path = text' "settingsPath" input
              files = case keyOr "document" input of
                String d -> Map.singleton path d
                _ -> Map.empty
              (r, _) = runScripted base {sFiles = files} (encodeResponse <$> handle path "GET" (text' "path" input))
           in either (failure . ("failed: " <>)) compareTo r
        "calm.resolve" -> calmCase base input expected
        "sync.flow" -> syncFlow base input expected
        "sync.envFile" -> envFileCase base input expected
        "attest.build" -> attestBuild input expected
        "twin.setUp" -> twinSetUp base input expected
        "twin.commands" -> twinCommands base expected
        "twin.unreachableMessage" ->
          let (r, _) = runScripted base (describe (controlPlane (text' "url" input)))
           in compareTo (String (either id (either renderTwinError (const "answered")) r))
        "ops.up" -> opsUp base input expected
        "ops.upThenAttest" -> opsUpThenAttest base input expected
        m | m `elem` ["ops.down", "ops.plan", "ops.status"] -> opsSimple base m input expected
        "ops.attest" -> opsAttest base input expected
        "ops.controlPlane" ->
          withManifest input $ \manifest ->
            let (r, _) = runScripted base (cpUrl <$> controlPlaneFor manifest "/work" (text' "environment" input) (text' "dependency" input))
             in compareTo (either (\e -> Object ["error" .= String e]) (\u -> Object ["ok" .= String u]) r)
        "azure.connectionString" ->
          let secret = T.concat ["MDEyMzQ1Njc4OWFi", "Y2RlZjAxMjM0NTY3", "ODlhYmNkZWY="]
              input' = insert "text" (String (T.replace "<secret>" secret (text' "text" input))) input
           in runMethod dispatch method input' base compareTo
        _ -> runMethod dispatch method input base compareTo

runMethod :: (Text -> Value -> Maybe (Eff Value)) -> Text -> Value -> Script -> (Value -> Value) -> Value
runMethod dispatch method input script k = case dispatch method input of
  Nothing -> failure ("no such method " <> method)
  Just program -> case runScripted script program of
    (Left e, _) -> failure ("failed: " <> e)
    (Right v, _) -> k v

failure :: Text -> Value
failure d = Object ["pass" .= Bool False, "diff" .= String d]

pass :: Value
pass = Object ["pass" .= Bool True]

verdict :: Text -> Value -> Value -> Value
verdict method expected got
  | releaseVersions expected == releaseVersions got = pass
  | Just reason <- lookup method deliberateDifferences = Object ["pass" .= Bool True, "deliberate" .= String reason]
  | otherwise = failure ("expected " <> encode expected <> "\n     got " <> encode got)

-- | Compares named parts; the first that differs is reported.
parts :: [(Text, Value, Value)] -> Value
parts xs = case [(n, e, g) | (n, e, g) <- xs, releaseVersions e /= releaseVersions g] of
  [] -> pass
  ((n, e, g) : _) -> failure (n <> ": expected " <> encode e <> "\n     got " <> encode g)

withManifest :: Value -> (Manifest -> Value) -> Value
withManifest input k = case parseManifest (text' "text" input) of
  Left e -> failure ("the manifest does not parse: " <> renderManifestError e)
  Right m -> k m

filesUnder :: Text -> Map Text Text -> Value
filesUnder root files =
  Object [(rel, String (normalise t)) | (path, t) <- Map.toAscList files, Just rel <- [T.stripPrefix (root <> "/") path]]

leftover :: Script -> [(Text, Value, Value)]
leftover s =
  [ ("mismatches", Array [], Array (map String (sMismatches s)))
  , ("unconsumed processes", Array [], Array (sProcesses s))
  , ("unconsumed cloud calls", Array [], Array (sClouds s))
  ]

envOf :: Value -> Map Text Text
envOf input = either (const Map.empty) id (decodeWith (textMap Ironframe.Json.Serde.string) (keyOr "env" input))

probesOf :: Value -> Map Text Bool
probesOf input = case keyOr "probes" input of
  Object ps -> Map.fromList [(k, b) | (k, Bool b) <- ps]
  _ -> Map.empty

arrayOf :: Value -> [Value]
arrayOf = \case
  Array xs -> xs
  _ -> []

calmCase :: Script -> Value -> Value -> Value
calmCase base input expected =
  let textOrFixture k name = case keyOr "text" (keyOr k input) of
        String t -> Just t
        _ -> Map.lookup ("examples/calm-shop/architecture/" <> name) (sFixtures base)
      environment = text' "environment" input
   in case (textOrFixture "architecture" "shop.calm.json", textOrFixture "decorators" "shop.decorators.json") of
        (Just architectureText, Just decoratorsText) ->
          let program = do
                architecture <- either (failWith . renderCalmError) pure (parseArchitecture architectureText)
                decorators <- either (failWith . renderCalmError) pure (parseDecorators decoratorsText)
                resolveCalm
                  architecture {archPath = Just "/work/architecture/shop.calm.json"}
                  decorators {decsPath = Just "/work/architecture/shop.decorators.json"}
                  environment
                  "/work/architecture"
              got = case runScripted base program of
                (Left e, _) -> Object ["error" .= String e]
                (Right (Left e), _) -> Object ["error" .= String (renderCalmError e)]
                (Right (Right resolution), _) -> exportsOf resolution environment
           in verdict "calm.resolve" expected got
        _ -> failure "the calm-shop fixtures were not given"

exportsOf :: Resolution -> Text -> Value
exportsOf resolution environment =
  let topology = resTopology resolution
      diagram = mermaid topology
      settings = either (\e -> "error: " <> renderResolveError e) (\s -> encodePretty (Object [(k, fromTextMap v) | (k, v) <- Map.toAscList s]) <> "\n") (applicationSettings resolution Map.empty)
      tofu = either (\e -> "error: " <> renderTofuError e) (\r -> encodePretty r <> "\n") (rootModule (resManifest resolution) environment "/work/architecture")
      tampered = T.replace "adoptions_audit -->" "%% " (T.replace ":::twin" ":::real" diagram)
      extra = either (const []) (\r -> tofuProblems topology (insert "module" (insert "twin_extra" (Object []) (keyOr "module" r)) r)) (rootModule (resManifest resolution) environment "/w")
   in Object
        [ "topology" .= String (encodePretty (encodeTopology topology) <> "\n")
        , "digest" .= String (topologyDigest topology)
        , "manifest" .= String (encodePretty (encodeManifest (resManifest resolution)))
        , "mermaid" .= String diagram
        , "dot" .= String (dot topology)
        , "annotated" .= String (encodePretty (annotatedArchitecture (archDocument (resArchitecture resolution)) topology) <> "\n")
        , "settings" .= String settings
        , "tofu" .= String tofu
        , "mermaidProblems" .= Array (map String (mermaidProblems topology diagram))
        , "tamperedProblems" .= Array (map String (mermaidProblems topology tampered))
        , "tofuProblems" .= Array (map String extra)
        , "settingsProblems" .= Array (map String (settingsProblems topology "adoptions-audit" (Map.singleton "PETSTORE_URL" "x")))
        ]

outcomeJson :: SyncOutcome -> Value
outcomeJson = \case
  Unchanged -> Object ["unchanged" .= Bool True]
  Updated d -> Object ["updated" .= String d]

syncFlow :: Script -> Value -> Value -> Value
syncFlow base input expected = withManifest input $ \manifest ->
  let steps = arrayOf (keyOr "steps" expected)
      script0 = base {sClouds = arrayOf (keyOr "effects" expected)}
      run1 (results, s) step =
        let bootstrap = text' "KAFKA_BOOTSTRAP_SERVERS" (keyOr "settings" step)
            program = do
              environment <- either (failWith . renderResolveError) pure (resolve manifest "staging" Map.empty)
              let environment' =
                    environment
                      { reDependencies =
                          [ if rdName d == "kafka" then d {rdSettings = Map.insert "KAFKA_BOOTSTRAP_SERVERS" bootstrap (rdSettings d)} else d
                          | d <- reDependencies environment
                          ]
                      }
              syncEnvironment recordedClouds manifest "/work" environment'
            (r, s') = runScripted s program
         in (results ++ [either (\e -> Object ["error" .= String e]) (\done -> Array [Object ["target" .= String t, "outcome" .= outcomeJson o] | (t, o) <- done]) r], s')
      (outcomes, final) = foldl run1 ([], script0) steps
   in parts ([("step " <> T.pack (show i), keyOr "outcomes" step, got) | (i, step, got) <- zip3 [1 :: Int ..] steps outcomes] ++ leftover final)

envFileCase :: Script -> Value -> Value -> Value
envFileCase base input expected = withManifest input $ \manifest ->
  let program = do
        environment <- either (failWith . renderResolveError) pure (resolve manifest "local" Map.empty)
        first <- syncEnvironment recordedClouds manifest "/work" environment
        second <- syncEnvironment recordedClouds manifest "/work" environment
        pure (first, second)
      shown done = Array [Object ["target" .= String (normalise t), "outcome" .= normaliseValue (outcomeJson o)] | (t, o) <- done]
   in case runScripted base program of
        (Left e, _) -> failure e
        (Right (first, second), s) ->
          parts
            [ ("first", keyOr "first" expected, shown first)
            , ("second", keyOr "second" expected, shown second)
            , ("files", keyOr "files" expected, filesUnder "/work" (sFiles s))
            ]

attestBuild :: Value -> Value -> Value
attestBuild input expected = withManifest input $ \manifest ->
  let deployed = either (const Map.empty) id (decodeWith (textMap Ironframe.Json.Serde.string) (keyOr "deployed" input))
      run = keyOr "run" input
      reached = case keyOr "reached" input of
        Object ps -> Map.fromList [(k, b) | (k, Bool b) <- ps]
        _ -> Map.empty
      observed = case keyOr "observed" input of
        Object ps ->
          Map.fromList
            [ (k, Observation (int "seed" o) (textAt "history_digest" o) (int "history_entries" o) Nothing)
            | (k, o) <- ps
            ]
        _ -> Map.empty
      int k o = case keyOr k o of
        Number (I n) -> Just n
        _ -> Nothing
      records = either (const Map.empty) id (decodeWith (textMap decodeTwinRecord) (keyOr "records" input))
   in case (resolve manifest (text' "environment" input) deployed, parseRfc3339 (text' "started_at" run)) of
        (Right environment, Right started) ->
          let attestation =
                Attest.attest environment (Attest.RunRecord (text' "id" run) started) (fromUnix 1791547200 0) (\e -> Map.findWithDefault False e reached) observed records
           in verdict "attest.build" expected (either (String . ("error: " <>)) String (A.toJson attestation))
        _ -> failure "the case does not resolve"

twinSetUp :: Script -> Value -> Value -> Value
twinSetUp base input expected = withManifest input $ \manifest ->
  case Map.lookup "local" (manifestEnvironments manifest) >>= Map.lookup (text' "dependency" input) . envDependencies of
    Just (BindTwin twin) ->
      let script = base {sHttp = arrayOf (keyOr "http" expected)}
          (r, s) = runScripted script (setUp (controlPlane "http://twin.test") twin (text' "manifestDir" input))
          got = case r of
            Right (Right record) -> String (encode (encodeTwinRecord record))
            Right (Left e) -> String ("error: " <> renderTwinError e)
            Left e -> String ("failed: " <> e)
       in parts ([("record", keyOr "record" expected, got), ("unconsumed http", Array [], Array (sHttp s))] ++ leftover s)
    _ -> failure "no twin to set up"

twinCommands :: Script -> Value -> Value
twinCommands base expected =
  let script = base {sHttp = arrayOf (keyOr "http" expected)}
      cp = controlPlane "http://twin.test"
      program = do
        forced <- force cp "{\"impossible\": true}"
        raised <- either (const (pure (Left (Input "bad fault")))) (raise cp) (parseFault "undeclared" [])
        pure [("force-refused", forced), ("raise-undeclared", raised)]
      shown (n, r) =
        Object
          [ "name" .= String n
          , "result" .= case r of
              Right t -> Object ["Ok" .= String t]
              Left e -> Object ["Err" .= Object ["error" .= String (renderTwinError e), "code" .= Number (I (toInteger (twinExitCode e)))]]
          ]
   in case runScripted script program of
        (Right results, s) -> parts [("results", keyOr "results" expected, Array (map shown results)), ("unconsumed http", Array [], Array (sHttp s))]
        (Left e, _) -> failure e

opsScript :: Script -> Value -> Value -> Script
opsScript base input expected =
  let prepared = either (const Map.empty) id (decodeWith (textMap Ironframe.Json.Serde.string) (keyOr "files" input))
   in base
        { sEnv = envOf input
        , sProbes = probesOf input
        , sProcesses = arrayOf (keyOr "processes" expected)
        , sClouds = arrayOf (keyOr "clouds" expected)
        , sFiles = Map.fromList [("/work/" <> k, v) | (k, v) <- Map.toAscList prepared]
        }

upOptions :: Value -> UpOptions
upOptions input = UpOptions (keyOr "sync" input /= Bool False) (case keyOr "waitSeconds" input of Number (I n) -> n; _ -> 0)

opsUp :: Script -> Value -> Value -> Value
opsUp base input expected = withManifest input $ \manifest ->
  let script = opsScript base input expected
      (r, s) = runScripted script (up recordedClouds manifest "/work" (text' "environment" input) (upOptions input) progress)
      result = case r of
        Left e -> Object ["error" .= String (normalise e)]
        Right report ->
          Object
            [ "ok"
                .= Object
                  [ "unreached" .= Array (map String (reportUnreached report))
                  , "synced" .= Array [Object ["target" .= String (normalise t), "outcome" .= normaliseValue (outcomeJson o)] | (t, o) <- reportSynced report]
                  , "attestationPath" .= String (reportAttestationPath report)
                  ]
            ]
   in parts
        ( [ ("result", keyOr "result" expected, result)
          , ("progress", keyOr "progress" expected, Array (map String (sProgress s)))
          , ("files", keyOr "files" expected, filesUnder "/work" (sFiles s))
          ]
            ++ leftover s
        )

opsUpThenAttest :: Script -> Value -> Value -> Value
opsUpThenAttest base input expected = withManifest input $ \manifest ->
  let upExpected = keyOr "up" expected
      attestExpected = keyOr "attest" expected
      script = (opsScript base input upExpected) {sHttp = arrayOf (keyOr "http" upExpected)}
      (r1, s1) = runScripted script (up recordedClouds manifest "/work" (text' "environment" input) (upOptions input) progress)
      s1' = s1 {sHttp = arrayOf (keyOr "http" attestExpected)}
      (r2, s2) = runScripted s1' (attestNow manifest "/work" (text' "environment" input) Nothing)
      upFiles = filesUnder "/work" (sFiles s1)
   in case (r1, r2) of
        (Right report, Right (attestation, _)) ->
          parts
            ( [ ("up progress", keyOr "progress" upExpected, Array (map String (sProgress s1)))
              , ("up unreached", keyOr "unreached" upExpected, Array (map String (reportUnreached report)))
              , ("up files", keyOr "files" upExpected, upFiles)
              , ("up http left", Array [], Array (sHttp s1))
              , ("attest files", keyOr "files" attestExpected, filesUnder "/work" (sFiles s2))
              , ("attestation", keyOr "attestation" attestExpected, String (normalise (either id id (A.toJson attestation))))
              , ("attest http left", Array [], Array (sHttp s2))
              ]
                ++ leftover s2
            )
        (Left e, _) -> failure ("up failed: " <> e)
        (_, Left e) -> failure ("attest failed: " <> e)

opsSimple :: Script -> Text -> Value -> Value -> Value
opsSimple base method input expected = withManifest input $ \manifest ->
  let script = opsScript base input expected
      environment = text' "environment" input
      program = case method of
        "ops.down" -> Null <$ down manifest "/work" environment
        "ops.plan" -> String <$> plan manifest "/work" environment
        _ -> Array . map encodeStatus <$> status manifest "/work" environment
      (r, s) = runScripted script program
      result = either (\e -> Object ["error" .= String (normalise e)]) (\v -> Object ["ok" .= v]) r
   in parts ([("result", keyOr "result" expected, result), ("files", keyOr "files" expected, filesUnder "/work" (sFiles s))] ++ leftover s)

opsAttest :: Script -> Value -> Value -> Value
opsAttest base input expected = withManifest input $ \manifest ->
  let script = opsScript base input expected
      output = textAt "output" input
      (r, s) = runScripted script (attestNow manifest "/work" (text' "environment" input) output)
   in case r of
        Left e -> failure e
        Right (attestation, path) ->
          parts
            [ ("attestation", keyOr "attestation" expected, String (normalise (either id id (A.toJson attestation))))
            , ("path", keyOr "path" expected, String path)
            , ("files", keyOr "files" expected, filesUnder "/work" (sFiles s))
            ]
