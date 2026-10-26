-- | Running an application against a resolved environment and attesting the
-- run: Ironframe hands the application its settings through its environment,
-- records the wiring as the run begins, runs the command, and records the run
-- again once it has completed. The same two steps serve an application
-- deployed by other tooling. ref:DEC-calm-run ref:DEC-calm-planned-vs-completed
module Ironframe.Calm.Run
  ( attestationVariable
  , runVariable
  , defaultDecorators
  , loadAndResolve
  , applicationIn
  , settingsOf
  , executionSettings
  , begin
  , complete
  , runAttestationPath
  , writeRun
  , RunReport (..)
  , runCommand
  , runOwnedCommand
  , runLawSpecTestIn
  , runManaged
  , writeTopology
  ) where

import Control.Monad (foldM, forM, forM_, when)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Ironframe.Attest
import Ironframe.Attestation
import Ironframe.Calm.Export (applicationSettings, applicationSettingsWithCredentials)
import Ironframe.Calm.Model
import qualified Ironframe.Component as Component
import Ironframe.Calm.Resolve
import Ironframe.Effect
import Ironframe.Json.FromStr (Expect (..), fromStr)
import Ironframe.Manifest (Twin (..))
import Ironframe.Ops
import qualified Ironframe.Path as Path
import Ironframe.Podman
import Ironframe.Rust (debugStr)
import Ironframe.Settings
import Ironframe.Time
import Ironframe.Twin
import Ironframe.Workdir
import qualified Ironframe.Observation.Environment as Observation
import qualified Ironframe.Evidence.Histories as Histories

attestationVariable, runVariable :: Text
attestationVariable = "IRONFRAME_ATTESTATION"
runVariable = "IRONFRAME_RUN_ID"

-- | The decorators file beside an architecture @<name>.json@:
-- @<name>.decorators.json@, a trailing @.calm@ of the stem dropped first.
defaultDecorators :: Text -> Text
defaultDecorators architecture =
  let stem = fromMaybe "" (Path.fileStem architecture)
      stem' = fromMaybe stem (T.stripSuffix ".calm" stem)
   in Path.withFileName architecture (stem' <> ".decorators.json")

-- | Reads an architecture and its decorators and resolves an environment.
loadAndResolve :: Text -> Maybe Text -> Text -> Eff (Either CalmError Resolution)
loadAndResolve architecturePath decorators environment = do
  model <- loadArchitecture architecturePath
  case model of
    Left e -> pure (Left e)
    Right architecture -> do
      let decoratorsPath = fromMaybe (defaultDecorators architecturePath) decorators
      loaded <- loadDecorators decoratorsPath
      case loaded of
        Left e -> pure (Left e)
        Right decorations -> do
          let dir0 = case Path.parent decoratorsPath of
                Just p | not (T.null p) -> p
                _ -> "."
          canonical <- canonicalize dir0
          let dir = either (const dir0) id canonical
          r <- resolveCalm architecture decorations environment dir
          pure (either (\e -> Left e {calmOrigin = Just decoratorsPath}) Right r)

-- | The application node, or an error naming those there are.
applicationIn :: Resolution -> Text -> Eff ResolvedApplication
applicationIn resolution node = case applicationOf (resTopology resolution) node of
  Just a -> pure a
  Nothing ->
    failWith
      ( "the architecture has no application node " <> debugStr node <> "; it has "
          <> T.intercalate ", " (map (debugStr . raNode) (rtApplications (resTopology resolution)))
      )

-- | The settings an application reads in the resolved environment.
settingsOf :: Resolution -> Text -> Eff (Map Text Text)
settingsOf resolution node = do
  _ <- applicationIn resolution node
  let w = workDir (resDir resolution) (rtEnvironment (resTopology resolution))
  deployed <- readEndpoints w >>= either (failWith . ((Path.display (endpointsPath w) <> ": ") <>)) pure
  all' <- either (failWith . renderResolveError) pure (applicationSettings resolution deployed)
  pure (Map.findWithDefault Map.empty node all')

-- | Resolve local credential references only while launching owned commands.
-- Exported settings and attestations keep references, never credential values.
executionSettings :: Resolution -> Text -> Eff (Map Text Text)
executionSettings resolution node = do
  _ <- applicationIn resolution node
  let topology = resTopology resolution
      environmentName = rtEnvironment topology
      w = workDir (resDir resolution) environmentName
      required = node : map reDestination (edgesOf topology node)
  environment <- resolveIn (resManifest resolution) (resDir resolution) environmentName >>= either (failWith . renderResolveError) pure
  credentials <- fmap Map.fromList $ forM [(rdName dependency, reference) | dependency <- reDependencies environment,
      rdName dependency `elem` required, Just reference <- [rdCredentials dependency]] $ \(name,reference) -> do
    value <- resolveReference reference
    pure (name,value)
  deployed <- readEndpoints w >>= either (failWith . ((Path.display (endpointsPath w) <> ": ") <>)) pure
  allSettings <- either (failWith . renderResolveError) pure (applicationSettingsWithCredentials resolution deployed credentials)
  pure (Map.findWithDefault Map.empty node allSettings)
  where
    resolveReference value
      | Just name <- T.stripPrefix "env:" value =
          getEnv name >>= maybe (failWith ("required credential environment variable is missing: " <> name)) pure
      | Just file <- T.stripPrefix "file:" value =
          readFileE (Path.join (resDir resolution) file) >>= either (failWith . ioMessage) (pure . T.stripEnd)
      | otherwise = pure value

-- | The commit of the git checkout holding a directory, with @-dirty@ when
-- it has changes there.
commitOf :: Text -> Eff (Maybe Text)
commitOf dir = do
  head' <- runProcess "git" ["-C", dir, "rev-parse", "HEAD"] False
  case head' of
    Right out | procSuccess out -> do
      let commit = T.strip (procStdout out)
      dirty <- runProcess "git" ["-C", dir, "status", "--porcelain", "--", "."] False
      pure $ Just $ case dirty of
        Right o | procSuccess o && not (T.null (procStdout o)) -> commit <> "-dirty"
        _ -> commit
    _ -> pure Nothing

contractRef :: ContractIdentity -> ContractRef
contractRef c = ContractRef (ciPackage c) (ciVersion c) (ciAbilities c) Nothing

edgeContract :: ResolvedTopology -> ResolvedEdge -> ResolvedDependencyNode -> ContractRef
edgeContract topology edge dependency = case do
  component <- Map.lookup (reSource edge) (rtComponents topology)
  name <- reRequirement edge
  Component.requirementContract <$> Map.lookup name (Component.componentRequires component) of
    Just contract -> ContractRef (Component.contractPackage contract) (Component.contractVersion contract) (Component.contractAbilities contract) (Just (Component.contractDigest contract))
    Nothing -> contractRef (rnContract dependency)

-- | The attestation of an application as its run begins.
begin :: Resolution -> Text -> [Text] -> Maybe Text -> Eff Attestation
begin resolution node command appDir = do
  app <- applicationIn resolution node
  let topology = resTopology resolution
      name = rtEnvironment topology
  environment <- resolveIn (resManifest resolution) (resDir resolution) name >>= either (failWith . renderResolveError) pure
  let w = workDir (resDir resolution) name
  records <- readTwins w >>= either (failWith . ((Path.display (twinsPath w) <> ": ") <>)) pure
  observed <- observeTwins environment w records
  runText <- readFileE (runPath w)
  let environmentRun = either (const Nothing) (either (const Nothing) Just . fromStr (ExpectStruct "RunRecord") decodeRunRecord) runText
  run <- startRun
  podman <- either (const Nothing) Just <$> locatePodman
  (elements, dependencies) <-
    foldM
      ( \(elements, dependencies) edge -> case (dependencyOf topology (reDestination edge), filter ((== reDestination edge) . rdName) (reDependencies environment)) of
          (Just dependency, wired : _) -> do
            let elements' = elements ++ [reRelationship edge] ++ [rnNode dependency | rnNode dependency `notElem` (elements ++ [reRelationship edge])]
            reached <- tcpReachable (rdEndpoint wired) 2000
            imageDigest' <- case (rdImage wired, podman) of
              (Just image, Just p) -> imageDigest p image
              _ -> pure Nothing
            let implementation = case (rnTwin dependency, rnProvider dependency) of
                  (Just twin, _) -> Implementation "fixture" (tiImage twin) (tiVersion twin) Nothing imageDigest'
                  (Nothing, provider) ->
                    Implementation
                      "real-provider"
                      (maybe (fromMaybe (rdEndpoint wired) (rdImage wired)) providerName provider)
                      (maybe "unknown" providerVersion provider)
                      Nothing
                      imageDigest'
                standIn = fmap (adjust wired dependency records observed) (rdStandIn wired)
                records' =
                  [ emptyRecord
                      { depName = ability
                      , depEndpoint = rdEndpoint wired
                      , depReached = reached
                      , depKind = if rnKind dependency == BoundTwin then KindStandIn else KindReal
                      , depStandIn = standIn
                      , depNode = Just (rnNode dependency)
                      , depEdge = Just (reRelationship edge)
                      , depContract = Just (edgeContract topology edge dependency)
                      , depImplementation = Just implementation
                      }
                  | ability <- reConsumes edge
                  ]
            pure (elements', dependencies ++ records')
          _ -> pure (elements, dependencies)
      )
      ([raNode app], [])
      (edgesOf topology node)
  let dir = fromMaybe (resDir resolution) appDir
  commit <- maybe (commitOf dir) (pure . Just) (raCommit app)
  appDigest <- case (raDeployment app, podman) of
    (Image image _ _ _, Just p) -> imageDigest p image
    _ -> pure Nothing
  let attestation =
        (newAttestation name (Run (recordId run) (recordStartedAt run) (recordStartedAt run)))
          { attProducer = Just (Producer "ironframe" "0.3.0")
          , attDependencies = dependencies
          , attArchitecture =
              Just
                ArchitectureRef
                  { refDocument = aiDocument (rtArchitecture topology)
                  , refDigest = aiDigest (rtArchitecture topology)
                  , refUniqueId = aiUniqueId (rtArchitecture topology)
                  , refDecorators = Just (aiDecorators (rtArchitecture topology))
                  , refDecoratorsDigest = Just (aiDecoratorsDigest (rtArchitecture topology))
                  , refTopologyDigest = Just (topologyDigest topology)
                  , refElements = elements
                  }
          , attApplication =
              Just
                ApplicationRef
                  { appNode = raNode app
                  , appContract = if Map.member node (rtComponents topology) then Nothing else Just (contractRef (raContract app))
                  , appComponent = Component.componentView <$> Map.lookup node (rtComponents topology)
                  , appImplementation = Implementation "application" (ciPackage (raContract app)) (raVersion app) commit appDigest
                  }
          , attExecution = Just (Execution Running command Nothing Nothing (recordId <$> environmentRun))
          }
  either failWith (const (pure attestation)) (validate attestation)
  where
    adjust wired dependency records observed s =
      let record = Map.lookup (rdName wired) records
          observation = Map.lookup (rdName wired) observed
       in s
            { standConformance = fromMaybe (standConformance s) (record >>= trConformance)
            , standSeed = firstJust [observation >>= obsSeed, record >>= trSeed, standSeed s]
            , standHistoryDigest = observation >>= obsHistoryDigest
            , standHistoryEntries = observation >>= obsHistoryEntries
            , standStandsInFor = contractRef . tiStandsInFor <$> rnTwin dependency
            }
    firstJust xs = case [x | Just x <- xs] of
      (x : _) -> Just x
      [] -> Nothing

-- | The attestation of a run that has completed with an exit code.
complete :: Resolution -> Attestation -> Integer -> Eff Attestation
complete resolution running exitCode = do
  let name = rtEnvironment (resTopology resolution)
  when (attEnvironment running /= name) $
    failWith ("the attestation is of environment " <> debugStr (attEnvironment running) <> ", not " <> debugStr name)
  when (fmap execStatus (attExecution running) /= Just Running) $ failWith "only a running attestation can be completed"
  environment <- resolveIn (resManifest resolution) (resDir resolution) name >>= either (failWith . renderResolveError) pure
  let w = workDir (resDir resolution) name
  records <- readTwins w >>= either (failWith . ((Path.display (twinsPath w) <> ": ") <>)) pure
  observed <- observeTwins environment w records
  now' <- nowTimestamp
  let finished = maxInstant now' (runStartedAt (attRun running))
  dependencies <- forM (attDependencies running) $ \record -> do
    let node = fromMaybe (depName record) (depNode record)
        observation = Map.lookup node observed
    reached <- tcpReachable (depEndpoint record) 2000
    pure record {depCompleted = Just (Completed reached (observation >>= obsHistoryDigest) (observation >>= obsHistoryEntries))}
  let done =
        running
          { attRun = (attRun running) {runRecordedAt = finished}
          , attDependencies = dependencies
          , attExecution = fmap (\e -> e {execStatus = CompletedRun, execExitCode = Just exitCode, execFinishedAt = Just finished}) (attExecution running)
          }
  either failWith (const (pure done)) (validate done)

-- | Where a run's attestation is kept in the environment's working directory.
runAttestationPath :: Resolution -> Text -> Text
runAttestationPath resolution run =
  Path.join (Path.join (workRoot (workDir (resDir resolution) (rtEnvironment (resTopology resolution)))) "runs") (run <> ".json")

-- | Writes an attestation to the run's path and to @also@, if given.
writeRun :: Resolution -> Attestation -> Maybe Text -> Eff Text
writeRun resolution attestation also = do
  let path = runAttestationPath resolution (runId (attRun attestation))
  writeAttestation path attestation
  maybe (pure ()) (`writeAttestation` attestation) also
  pure (fromMaybe path also)

data RunReport = RunReport {runExitCode :: Integer, runAttestation :: Attestation, runPathWritten :: Text}

-- | Runs a command as an application: its settings and the running
-- attestation's path in its environment, the attestation written before it
-- starts and completed after it exits.
runCommand :: Resolution -> Text -> [Text] -> Maybe Text -> Maybe Text -> Eff RunReport
runCommand = runCommandWith False Nothing

runOwnedCommand :: Resolution -> Text -> [Text] -> Maybe Text -> Maybe Text -> Eff RunReport
runOwnedCommand = runCommandWith True Nothing

runLawSpecTestIn :: Text -> Resolution -> Text -> [Text] -> Maybe Text -> Maybe Text -> Eff RunReport
runLawSpecTestIn parent = runCommandWith True (Just parent)

runCommandWith :: Bool -> Maybe Text -> Resolution -> Text -> [Text] -> Maybe Text -> Maybe Text -> Eff RunReport
runCommandWith owned parent resolution node command dir output = do
  (program, args) <- case command of
    (p : as) -> pure (p, as)
    [] -> failWith "give the command to run after --"
  settings <- if owned then executionSettings resolution node else settingsOf resolution node
  begun <- begin resolution node command dir
  let invocation = case parent of
        Nothing -> command
        Just _ -> command ++ ["--attestation", runAttestationPath resolution (runId (attRun begun))]
      running = case parent of
        Nothing -> begun
        Just identity -> begun {attExecution = fmap (\execution -> execution {execEnvironmentRun = Just identity, execCommand = invocation}) (attExecution begun)}
  path <- writeRun resolution running output
  observation <- Observation.forExecution node (runId (attRun running))
  result <-
    (if owned then runOwnedInherited else runInherited)
      program
      (if parent == Nothing then args else drop 1 invocation)
      (Map.toAscList settings ++ observation ++ [(attestationVariable, path), (runVariable, runId (attRun running))])
      dir
  out <- either (failWith . ((program <> ": ") <>) . ioMessage) pure result
  let exitCode = fromMaybe 1 (procCode out)
  completed <- complete resolution running exitCode
  path' <- writeRun resolution completed output
  observing <- getEnv "IRONFRAME_OBSERVATION_CONFIG"
  forM_ observing (\_ -> Histories.retain (resDir resolution) completed (path' <> ".histories.json"))
  pure (RunReport exitCode completed path')

-- | Runs a managed application as its binding says: its process in its
-- directory, or its image with podman on the host's network, built first
-- when podman does not have it.
runManaged :: Resolution -> Text -> [Text] -> Maybe Text -> Eff RunReport
runManaged resolution node extra output = do
  app <- applicationIn resolution node
  case raDeployment app of
    External ->
      failWith
        ( "application " <> debugStr node <> " is deployed by its own tooling in environment " <> debugStr (rtEnvironment (resTopology resolution))
            <> "; run it there with `ironframe settings`, or use `ironframe run`"
        )
    Process command dir -> runCommand resolution node (command ++ extra) (Path.join (resDir resolution) <$> dir) output
    Image image args context containerfile -> do
      podman <- locatePodman >>= either (failWith . renderPodmanError) pure
      let qualified = qualifyImage image
      present <- hasImage podman qualified
      when (not present) $ case context of
        Nothing -> failWith ("podman has no image " <> qualified <> " and the binding names no build context")
        Just c -> do
          let contextPath = Path.join (resDir resolution) c
          buildImage podman contextPath (Path.join contextPath <$> containerfile) qualified >>= either (failWith . renderPodmanError) pure
      settings <- settingsOf resolution node
      let words' =
            [podmanProgram podman, "run", "--rm", "--network", "host"]
              ++ concat [["-e", k <> "=" <> v] | (k, v) <- Map.toAscList settings]
              ++ [qualified]
              ++ args
              ++ extra
      runCommand resolution node words' Nothing output

-- | Writes the resolved topology into the working directory.
writeTopology :: Resolution -> Eff Text
writeTopology resolution = do
  let w = workDir (resDir resolution) (rtEnvironment (resTopology resolution))
      path = Path.join (workRoot w) "topology.json"
  writeJson path (encodeTopology (resTopology resolution))
  pure path

-- Keep the Twin import for its record fields used in patterns elsewhere.
_twinImage :: Twin -> Text
_twinImage = twinImage
