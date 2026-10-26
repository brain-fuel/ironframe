-- | Bracket a disposable LawTwin observation receiver around a test runner.
-- The receiver is sealed and evidence retained before its owned process stops.
-- SDK flush/count checkpoints are the runner's responsibility; absent ones fail.
module Ironframe.Observation (observe, retainHistories) where

import Control.Monad (forM_, unless, when)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Ironframe.Calm.Resolve
import Ironframe.Effect
import Ironframe.Json
import Ironframe.Ops (controlPlaneFor)
import qualified Ironframe.Path as Path
import qualified Ironframe.Revision as Revision
import qualified Ironframe.Twin as Twin

text :: Text -> Value -> Text
text name = fromMaybe "" . textAt name

jsonFile :: Text -> Value -> Eff ()
jsonFile path value = writeAtomically path (encodePretty value <> "\n") >>= either (failWith . ioMessage) (const (pure ()))

request :: Text -> Text -> Maybe Text -> Eff Value
request method url body = do
  response <- httpRequest method url [("content-type","application/json")] body 30000 >>= either failWith pure
  unless (replyStatus response >= 200 && replyStatus response < 300) (failWith (url <> ": " <> replyBody response))
  either failWith pure (decode (replyBody response))

-- | Called before an integration's owned dependencies are torn down, including
-- failed runs. Failed history exports are retained as failures, never empty data.
retainHistories :: Resolution -> Text -> Eff ()
retainHistories resolution folder = forM_ (rtDependencies (resTopology resolution)) $ \dependency ->
  when (rnKind dependency == BoundTwin) $ do
    let path = Path.join folder ("history-" <> rnNode dependency <> ".json")
    existing <- readFileE path
    result <- catchError
      (do plane <- controlPlaneFor (resManifest resolution) (resDir resolution) (rtEnvironment (resTopology resolution)) (rnNode dependency)
          history <- Twin.history plane Nothing Nothing True >>= either (failWith . Twin.renderTwinError) pure
          parsed <- either failWith pure (decode history)
          pure (Object ["status" .= String "retained", "history" .= parsed]))
      (\message -> pure (Object ["status" .= String "incomplete", "reason" .= String message]))
    case existing of
      Right _ -> pure () -- A pre-teardown snapshot survives later unreachable fixtures.
      Left _ -> jsonFile path result

observe :: Resolution -> Value -> [Text] -> Eff Integer
observe resolution options invocation = do
  (program,args) <- case invocation of
    p:rest -> pure (p,rest)
    _ -> failWith "observe requires the test runner command after --"
  revisionPath <- maybe (failWith "observe requires --revision <prepared configuration file>") pure (textAt "revision" options)
  source <- readFileE revisionPath >>= either (failWith . ioMessage) pure
  configuration <- either failWith pure (decode source)
  payload <- either failWith pure (Revision.validateRevision configuration)
  fresh <- Revision.prepare resolution
  unless (keyOr "revision" configuration == keyOr "revision" fresh) (failWith "observation revision differs from resolved implementation or bindings")
  identity <- newUuid
  let topology = resTopology resolution
      folder0 = fromMaybe (Path.join (resDir resolution) (".ironframe/" <> rtEnvironment topology <> "/observations/" <> identity)) (textAt "output" options)
  when (rtObservation topology == Nothing) (failWith "observe requires the environment's observation declaration and its CALM telemetry relationships")
  createDirE folder0 >>= either (failWith . ioMessage) pure
  folder <- canonicalize folder0 >>= either (failWith . ioMessage) pure
  claimed <- compareAndSwap (Path.join folder "session.json") Nothing (encode (Object ["runId" .= String identity]))
  unless claimed (failWith "observation output directory already belongs to a run")
  let listen = fromMaybe "127.0.0.1:4318" (textAt "listen" options)
      adminListen = fromMaybe "127.0.0.1:9646" (textAt "admin-listen" options)
      endpoint = fromMaybe ("http://" <> listen) (textAt "endpoint" options)
      admin = "http://" <> adminListen
      collector = fromMaybe "lawtwin-observation" (textAt "observer" options)
      applications = case keyOr "applications" payload of Object entries -> entries; _ -> []
      producers = Object [(node,Object ["node" .= String node,"implementation" .= keyOr "implementation" implementation,"revision" .= keyOr "revision" configuration]) | (node,implementation) <- applications]
      config = Object
        ["runId" .= String identity,"topologyDigest" .= keyOr "topologyDigest" payload
        ,"producers" .= producers,"edges" .= Object [(reRelationship edge,String (reSource edge)) | edge <- rtEdges topology]
        ,"journal" .= String (Path.join folder "observations.jsonl")]
      configPath = Path.join folder "receiver.json"
      environment = [("OTEL_EXPORTER_OTLP_ENDPOINT",endpoint),("OTEL_EXPORTER_OTLP_PROTOCOL","http/json")
        ,("IRONFRAME_OBSERVATION_RUN_ID",identity),("IRONFRAME_OBSERVATION_ADMIN",admin)
        ,("IRONFRAME_OBSERVATION_CONFIG",configPath),("IRONFRAME_OBSERVATION_DIR",folder)
        ,("IRONFRAME_CONFIGURATION_REVISION",text "revision" configuration)]
  jsonFile configPath config
  jsonFile (Path.join folder "configuration.json") configuration
  service <- startService [collector,"--config",configPath,"--listen",listen,"--admin-listen",adminListen]
    (resDir resolution) [] (Path.join folder "receiver.log") (Just admin) >>= either (failWith . ioMessage) pure
  result <- catchError
    (do ready service admin 300
        reply <- perform (Object ["effect" .= String "run","program" .= String program,"args" .= Array (map String args)
          ,"stream" .= Bool False,"ownedGroup" .= Bool True,"env" .= Object [(k,String v) | (k,v) <- environment]])
        value <- either (failWith . ioMessage) pure (ioResult reply)
        jsonFile (Path.join folder "runner.json") value
        pure (Right (case keyOr "code" value of Number (I code) -> code; _ -> 1)))
    (pure . Left)
  -- Collect on both outcomes. The independent runner record and receiver log
  -- remain even if the observation service cannot answer at all.
  retainHistories resolution folder
  sealed <- catchError (Right <$> request "POST" (admin <> "/v1/seal") (Just "{}")) (pure . Left)
  let bundle = either (\message -> Object ["format" .= String "ironframe-observation-failure","status" .= String "incomplete","reason" .= String message]) id sealed
      complete = text "status" bundle == "complete"
      runnerCode = either (const 1) id result
      exit = if runnerCode == 0 && not complete then 1 else runnerCode
  saved <- catchError (jsonFile (Path.join folder "bundle.json") bundle >> pure Nothing) (pure . Just)
  stopped <- stopService service
  forM_ saved (\message -> printErr ("observation export failed: " <> message <> "\n"))
  either (\problem -> printErr ("observation cleanup failed: " <> ioMessage problem <> "\n")) (const (pure ())) stopped
  forM_ (either Just (const Nothing) result) (\message -> printErr (message <> "\n"))
  printOut ("observations: " <> folder <> "; " <> text "status" bundle <> "\n")
  pure (if saved /= Nothing || either (const True) (const False) stopped then 1 else exit)
  where
    ready service admin attempts = do
      running <- serviceRunning service >>= either (failWith . ioMessage) pure
      unless running (failWith "observation receiver exited before readiness; see receiver.log")
      response <- httpRequest "GET" (admin <> "/healthz") [] Nothing 1000
      case response of
        Right reply | replyStatus reply == 200 -> pure ()
        _ | attempts > (0 :: Int) -> sleepMs 100 >> ready service admin (attempts-1)
        _ -> failWith "observation receiver did not become ready"
