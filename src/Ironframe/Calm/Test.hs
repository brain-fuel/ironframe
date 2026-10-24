-- | Integration runs bracket the processes and local fixture environment
-- they own. Each component's laws still run through the LawSpec CLI.
module Ironframe.Calm.Test (testComponents) where

import Control.Monad (forM, forM_, unless, when)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Ironframe.Attest (startRun, RunRecord (..), nowTimestamp)
import Ironframe.Attestation
import Ironframe.Time (maxInstant)
import Ironframe.Calm.Resolve
import Ironframe.Calm.Run
import qualified Ironframe.Component as Component
import Ironframe.Effect
import Ironframe.Json
import Ironframe.Manifest (runtimeIsCloud, Manifest (..), Environment (..))
import Ironframe.Ops
import qualified Ironframe.Path as Path
import Ironframe.Podman (locatePodman, podmanProgram, renderPodmanError)
import Ironframe.Settings
import Ironframe.Sync (realClouds)
import Ironframe.Workdir

data Service = Service
  { serviceNode :: Text
  , serviceCommand :: [Text]
  , serviceDirectory :: Text
  , serviceReady :: Text
  , serviceStatuses :: [Integer]
  , serviceTimeout :: Integer
  }

testComponents :: Resolution -> Maybe Text -> [Text] -> Eff Integer
testComponents resolution selected arguments = do
  record <- startRun
  let topology = resTopology resolution
      architecture = rtArchitecture topology
      running = (newAttestation (rtEnvironment topology) (Run (recordId record) (recordStartedAt record) (recordStartedAt record)))
        { attProducer = Just (Producer "ironframe" "0.2.0")
        , attArchitecture = Just (ArchitectureRef (aiDocument architecture) (aiDigest architecture) (aiUniqueId architecture)
            (Just (aiDecorators architecture)) (Just (aiDecoratorsDigest architecture)) (Just (topologyDigest topology))
            (Map.keys (rtComponents topology)))
        , attExecution = Just (Execution Running (["ironframe", "test", "--env", rtEnvironment topology] ++ maybe [] (\node -> ["--app", node]) selected ++ ["--"] ++ arguments) Nothing Nothing Nothing)
        }
  _ <- writeRun resolution running Nothing
  result <- catchError (Right <$> runComponents (recordId record) resolution selected arguments) (pure . Left)
  latest <- readFileE (runAttestationPath resolution (recordId record)) >>= either (failWith . ioMessage) pure
  updated <- either failWith pure (fromJson latest)
  recorded <- nowTimestamp
  let finished = maxInstant recorded (recordStartedAt record)
      code = either (const 1) id result
      completed = updated
        { attRun = (attRun updated) {runRecordedAt = finished}
        , attExecution = fmap (\execution -> execution {execStatus = CompletedRun, execExitCode = Just code, execFinishedAt = Just finished}) (attExecution updated)
        }
  _ <- writeRun resolution completed Nothing
  printOut ("integration: exit " <> T.pack (show code) <> "; attestation " <> runAttestationPath resolution (recordId record) <> "\n")
  either failWith pure result

runComponents :: Text -> Resolution -> Maybe Text -> [Text] -> Eff Integer
runComponents integration resolution selected arguments = do
  when (any (\argument -> any (\name -> argument == name || (name <> "=") `T.isPrefixOf` argument) ["--config", "--project", "--attestation"]) arguments)
    (failWith "component config, project and attestation come from the resolved topology")
  let topology = resTopology resolution
      components = rtComponents topology
      targets = [(node, component) | (node,component) <- Map.toAscList components,
        maybe True (== node) selected, not (null (Component.componentTargets component)),
        maybe True ((/= BoundTwin) . rnKind) (dependencyOf topology node)]
  when (null targets) (failWith "no selected CALM component has native LawSpec targets")
  let reachable seen [] = seen
      reachable seen (node:rest)
        | node `elem` seen = reachable seen rest
        | maybe False ((== BoundTwin) . rnKind) (dependencyOf topology node) = reachable (node:seen) rest
        | otherwise = reachable (node:seen) ([reDestination edge | edge <- rtEdges topology, reSource edge == node] ++ rest)
      needed = reachable [] (map fst targets)
      selectedComponents = [(node, component) | (node,component) <- Map.toAscList components, node `elem` needed]
  services <- fmap mapMaybeIdentity $ forM selectedComponents $ \(node,component) -> serviceDefinition resolution node component
  tool <- fromMaybe "lawspec" <$> getEnv "IRONFRAME_LAWSPEC"
  run <- newUuid
  let folder = Path.join (workRoot (workDir (resDir resolution) (rtEnvironment topology))) ("tests/" <> run)
  createDirE folder >>= either (failWith . ioMessage) pure
  _ <- writeTopology resolution
  forM_ targets $ \(_,component) -> do
    native tool ["generate", "--config", Component.componentManifest component] [] (Just (Component.componentRoot component))
  let scopedManifest = (resManifest resolution)
        { manifestDependencies = Map.filterWithKey (\node _ -> node `elem` needed) (manifestDependencies (resManifest resolution))
        , manifestEnvironments = fmap (\environment -> environment {envDependencies = Map.filterWithKey (\node _ -> node `elem` needed) (envDependencies environment)}) (manifestEnvironments (resManifest resolution))
        }
  deployed <- resolveIn scopedManifest (resDir resolution) (rtEnvironment topology) >>= either (failWith . renderResolveError) pure
  let localImages = not (runtimeIsCloud (rtRuntime topology)) && any (maybe False (const True) . rdImage) (reDependencies deployed)
      buildComponents = forM_ selectedComponents $ \(node,component) -> do
        let binding = Map.findWithDefault Null node (resComponentBindings resolution)
        case key "command" (keyOr "build" binding) of
          Just (Array values) -> do
            let command = [text | String text <- values]
                directory = fromMaybe (Component.componentRoot component) (Path.join (resDir resolution) <$> textAt "dir" (keyOr "build" binding))
            settings <- executionSettings resolution node
            execute command (Map.toAscList settings) (Just directory)
          _ -> pure ()
      action = do
        buildComponents
        prepared <- refreshComponents resolution (map fst selectedComponents)
        _ <- writeTopology prepared
        rootText <- readFileE (runAttestationPath resolution integration) >>= either (failWith . ioMessage) pure
        rootRun <- either failWith pure (fromJson rootText)
        _ <- writeRun prepared (rootRun {attArchitecture = fmap (\architecture -> architecture {refTopologyDigest = Just (topologyDigest (resTopology prepared))}) (attArchitecture rootRun)}) Nothing
        withServices prepared folder services [] (\running -> do
          forM_ running $ \(service,handle) -> awaitReady prepared service handle
          codes <- forM targets $ \(node,component) -> do
            report <- runLawSpecTestIn integration prepared node
              ([tool, "test", "--fresh", "--config", Component.componentManifest component] ++ arguments)
              (Just (Component.componentRoot component)) Nothing
            printOut ("component " <> node <> ": exit " <> T.pack (show (runExitCode report)) <> "; attestation " <> runPathWritten report <> "\n")
            evidence <- runProcess tool (["evidence", "--json", "--config", Component.componentManifest component, "--attestation", runPathWritten report] ++ evidenceArguments arguments) False >>= either (failWith . ioMessage) pure
            unless (procSuccess evidence) (failWith (node <> ": completed evidence could not be read: " <> procStderr evidence))
            let evidencePath = Path.join folder (node <> "-evidence.json")
            writeFileE evidencePath (procStdout evidence) >>= either (failWith . ioMessage) pure
            checked <- either failWith pure (decode (procStdout evidence))
            let rows = case checked of Array values -> values; _ -> []
                nativeRows = [row | row <- rows, key "nativeEvidence" row /= Nothing]
                currentRows = [(row, [observation | Just (Array observations) <- [key "observations" (keyOr "nativeEvidence" row)], observation <- observations,
                  textAt "executionRun" (keyOr "attempt" observation) == Just (runId (attRun (runAttestation report)))]) | row <- nativeRows]
                observed = [observation | (_,observations) <- currentRows, observation <- observations,
                  textAt "freshness" observation == Just "matching-inputs"]
                stale = [observation | (_,observations) <- currentRows, observation <- observations,
                  textAt "freshness" observation /= Just "matching-inputs"]
                unlinked = [row | (row,observations) <- currentRows, not (null observations), Just (Array dependencies) <- [key "plannedAgainst" row], not (null dependencies)]
            unless (not (null observed) && null stale && null unlinked) (failWith (node <> ": completed native evidence is missing, stale or unlinked; see " <> evidencePath))
            pure (runExitCode report)
          pure (if all (== 0) codes then 0 else 1))
  if localImages
    then do
      podman <- locatePodman >>= either (failWith . renderPodmanError) pure
      forM_ ["io.podman.compose.project", "com.docker.compose.project"] $ \label -> do
        existing <- runProcess (podmanProgram podman) ["ps", "-aq", "--filter", "label=" <> label <> "=" <> stackName deployed] False >>= either (failWith . ioMessage) pure
        unless (procSuccess existing && T.null (T.strip (procStdout existing)))
          (failWith "the integration environment already has containers; use external bindings or take it down first")
      result <- catchError
        (do _ <- up realClouds scopedManifest (resDir resolution) (rtEnvironment topology) (UpOptions True 90) progress
            Right <$> action)
        (pure . Left)
      cleanup <- catchError (down scopedManifest (resDir resolution) (rtEnvironment topology) >> pure Nothing) (pure . Just)
      finish result cleanup
    else action
  where
    mapMaybeIdentity = mapMaybe id
    native program args environment directory = do
      result <- runOwnedInherited program args environment directory >>= either (failWith . ioMessage) pure
      unless (procSuccess result) (failWith (program <> " failed"))
    execute (program:args) = native program args
    execute [] = \_ _ -> failWith "empty component build command"

-- | Evidence uses the same target and machine selection as the test invocation.
evidenceArguments :: [Text] -> [Text]
evidenceArguments [] = []
evidenceArguments (flag:value:rest) | flag `elem` ["--target", "--machine-bits"] = flag:value:evidenceArguments rest
evidenceArguments (flag:rest)
  | any (`T.isPrefixOf` flag) ["--target=", "--machine-bits="] || flag `elem` ["--offline", "--locked", "--no-cache"] = flag:evidenceArguments rest
  | otherwise = evidenceArguments rest

-- | Native preparation may create adapters; freeze checked identities afterward.
refreshComponents :: Resolution -> [Text] -> Eff Resolution
refreshComponents resolution nodes = do
  let topology = resTopology resolution
  refreshed <- forM (Map.toAscList (rtComponents topology)) $ \(node,component) ->
    if node `notElem` nodes then pure (node,component) else do
      current <- Component.loadComponent (Component.componentManifest component) >>= either failWith pure
      unless (current {Component.componentFingerprint = Component.componentFingerprint component} == component)
        (failWith (node <> ": preparation changed component contracts, targets or declaration identities; resolve again"))
      pure (node,current)
  pure (resolution {resTopology = topology {rtComponents = Map.fromList refreshed}})

serviceDefinition :: Resolution -> Text -> Component.Component -> Eff (Maybe Service)
serviceDefinition resolution node component = do
  let binding = Map.findWithDefault Null node (resComponentBindings resolution)
      process = keyOr "process" (keyOr "managed" binding)
  when (key "image" (keyOr "managed" binding) /= Nothing)
    (failWith (node <> ": test brackets managed processes and dependency fixtures; deploy this image with ironframe app or your deployment tools and select an external binding for the native test"))
  case key "command" process of
    Just (Array values) -> do
      url <- maybe (failWith (node <> ": a managed process needs ready.url")) pure (textAt "url" (keyOr "ready" binding))
      let command = [text | String text <- values]
          statuses = case key "accept" (keyOr "ready" binding) of Just (Array codes) -> [code | Number (I code) <- codes]; _ -> [200]
          timeout = case key "timeoutSeconds" (keyOr "ready" binding) of Just (Number (I seconds)) -> seconds; _ -> 90
          directory = fromMaybe (Component.componentRoot component) (Path.join (resDir resolution) <$> textAt "dir" process)
      pure (Just (Service node command directory url statuses timeout))
    _ -> pure Nothing

withServices :: Resolution -> Text -> [Service] -> [(Service,Text)] -> ([(Service,Text)] -> Eff Integer) -> Eff Integer
withServices _ _ [] running action = action (reverse running)
withServices resolution folder (service:remaining) running action = do
  settings <- executionSettings resolution (serviceNode service)
  url <- readyUrl resolution service
  let logPath = Path.join folder (serviceNode service <> ".log")
  handle <- startService (serviceCommand service) (serviceDirectory service) (Map.toAscList settings) logPath (Just url) >>= either (failWith . ioMessage) pure
  printOut ("service " <> serviceNode service <> ": " <> logPath <> "\n")
  result <- catchError (Right <$> withServices resolution folder remaining ((service,handle):running) action) (pure . Left)
  cleanup <- stopService handle
  finish result (either (Just . ioMessage) (const Nothing) cleanup)

readyUrl :: Resolution -> Service -> Eff Text
readyUrl resolution service = do
  environment <- resolveIn (resManifest resolution) (resDir resolution) (rtEnvironment (resTopology resolution)) >>= either (failWith . renderResolveError) pure
  case filter ((== serviceNode service) . rdName) (reDependencies environment) of
    dependency:_ -> either (failWith . renderResolveError) pure (renderSetting (serviceNode service) "ready.url" (serviceReady service) dependency)
    [] -> pure (serviceReady service)

awaitReady :: Resolution -> Service -> Text -> Eff ()
awaitReady resolution service handle = do
  url <- readyUrl resolution service
  started <- monotonicMs
  let deadline = started + serviceTimeout service * 1000
      loop = do
        running <- serviceRunning handle >>= either (failWith . ioMessage) pure
        unless running (failWith (serviceNode service <> " exited before readiness; see its service log"))
        answer <- httpRequest "GET" url [] Nothing 1000
        case answer of
          Right response | toInteger (replyStatus response) `elem` serviceStatuses service -> pure ()
          _ -> do
            current <- monotonicMs
            if current >= deadline then failWith (serviceNode service <> " did not become ready") else sleepMs 100 >> loop
  loop

finish :: Either Text Integer -> Maybe Text -> Eff Integer
finish result cleanup = case (result,cleanup) of
  (Right code, Nothing) -> pure code
  (Left problem, Nothing) -> failWith problem
  (Right _, Just problem) -> failWith ("integration cleanup failed: " <> problem)
  (Left problem, Just cleanupProblem) -> failWith (problem <> "; integration cleanup failed: " <> cleanupProblem)
