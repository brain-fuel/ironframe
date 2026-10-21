-- | The commands as programs: @up@, @down@, @status@, @plan@, @sync@ and
-- @attest@, for podman and cloud environments. Each takes the manifest and its
-- directory and asks the host for every effect, so the order of steps, above
-- all that every image is checked before anything starts, is the same
-- wherever it runs. ref:DEC-podman-compose ref:DEC-opentofu
-- ref:REQ-missing-image-fails-clearly
module Ironframe.Ops
  ( UpOptions (..)
  , UpReport (..)
  , DependencyStatus (..)
  , encodeStatus
  , resolveIn
  , syncEnvironment
  , up
  , plan
  , down
  , status
  , attestNow
  , adminUrls
  , observeTwins
  , controlPlaneFor
  , writeAttestation
  , writeJson
  , ioFailure
  ) where

import Control.Monad (foldM, forM, when)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Ironframe.Attest
import Ironframe.Attestation
import Ironframe.Compose
import Ironframe.Effect
import Ironframe.Json
import Ironframe.Json.FromStr (Expect (..), fromStr)
import Ironframe.Manifest
import qualified Ironframe.Path as Path
import Ironframe.Podman
import Ironframe.Rust (debugStr)
import Ironframe.Settings
import Ironframe.Sync
import Ironframe.Tofu
import Ironframe.Twin
import Ironframe.Workdir

data UpOptions = UpOptions {upSync :: Bool, upWaitSeconds :: Integer}

data UpReport = UpReport
  { reportEnvironment :: ResolvedEnvironment
  , reportAttestation :: Attestation
  , reportAttestationPath :: Text
  , reportSynced :: [(Text, SyncOutcome)]
  , reportUnreached :: [Text]
  }

-- | A failure carrying an io error, worded as Rust's @{path}: {error}@.
ioFailure :: Text -> IoError -> Text
ioFailure path e = Path.display path <> ": " <> ioMessage e

orFail :: Eff (Either e a) -> (e -> Text) -> Eff a
orFail action render = action >>= either (failWith . render) pure

writeJson :: Text -> Value -> Eff ()
writeJson path value = writeAtomically path (encodePretty value <> "\n") `orFail` ioFailure path >> pure ()

-- | Resolves an environment, with the endpoints of an earlier cloud deployment.
resolveIn :: Manifest -> Text -> Text -> Eff (Either ResolveError ResolvedEnvironment)
resolveIn manifest manifestDir name = do
  let w = workDir manifestDir name
  deployed <- readEndpoints w
  case deployed of
    Left e -> failWith (Path.display (endpointsPath w) <> ": " <> e)
    Right d -> pure (resolve manifest name d)

resolveOrFail :: Manifest -> Text -> Map Text Text -> Eff ResolvedEnvironment
resolveOrFail manifest name deployed = either (failWith . renderResolveError) pure (resolve manifest name deployed)

environmentOrFail :: Manifest -> Text -> Eff Environment
environmentOrFail manifest name = either (failWith . renderManifestError) pure (environmentOf manifest name)

-- | Runs every sync target of the environment, in order, stopping at the
-- first failure.
syncEnvironment :: CloudClients -> Manifest -> Text -> ResolvedEnvironment -> Eff [(Text, SyncOutcome)]
syncEnvironment clouds manifest manifestDir environment = do
  declared <- environmentOrFail manifest (reEnvironment environment)
  let settings = environmentSettings environment
      name = reEnvironment environment
  forM (envSync declared) $ \target -> do
    let label = describeTarget target name
    outcome <- case target of
      SyncEnvFile t -> syncEnvFile t manifestDir (reProject environment) name settings
      SyncAws t -> syncAws t name settings
      SyncGcp t -> syncGcp t name settings
      SyncAzure t -> do
        client <- azureClient clouds t
        case client of
          Left reason -> pure (Left (SyncError label reason))
          Right () -> syncAzure t name settings
    either (failWith . renderSyncError) (\o -> pure (label, o)) outcome

writeSettings :: WorkDir -> ResolvedEnvironment -> Eff Text
writeSettings w environment = do
  let path = settingsPath w
  writeJson path (encodeDocument (insertEnvironment environment emptyDocument))
  pure path

writeAttestation :: Text -> Attestation -> Eff ()
writeAttestation path attestation = do
  text <- either failWith pure (toJson attestation)
  _ <- writeAtomically path text `orFail` ioFailure path
  pure ()

prepareTofu :: Manifest -> Text -> Text -> Eff Tofu
prepareTofu manifest manifestDir name = do
  let w = workDir manifestDir name
  root <- either (failWith . renderTofuError) pure (rootModule manifest name manifestDir)
  writeJson (Path.join (tofuPath w) "main.tf.json") root
  locateTofu (tofuPath w) `orFail` renderTofuError

tofuStep :: Eff (Either TofuError a) -> Eff a
tofuStep action = action `orFail` renderTofuError

podmanStep :: Eff (Either PodmanError a) -> Eff a
podmanStep action = action `orFail` renderPodmanError

-- | Brings an environment up. On podman every image is checked, and pulled
-- if absent, before anything starts; in a cloud the OpenTofu root is applied
-- and the endpoints it reports are kept. Then the twins are set up, the
-- endpoints probed, the settings synced and the attestation written.
up :: CloudClients -> Manifest -> Text -> Text -> UpOptions -> (Text -> Eff ()) -> Eff UpReport
up clouds manifest manifestDir name options progress' = do
  declared <- environmentOrFail manifest name
  let w = workDir manifestDir name
  run <- startRun
  (environment, startedImages, labelled) <-
    if runtimeIsCloud (envRuntime declared)
      then do
        tofu <- prepareTofu manifest manifestDir name
        progress' "applying the OpenTofu root"
        tofuStep (tofuInit tofu)
        tofuStep (tofuApply tofu)
        endpoints <- tofuStep (tofuEndpoints tofu)
        writeJson (endpointsPath w) (fromTextMap endpoints)
        environment <- resolveOrFail manifest name endpoints
        _ <- writeSettings w environment
        pure (environment, [], Map.empty)
      else do
        environment <- resolveOrFail manifest name Map.empty
        podman <- podmanStep locatePodman
        podmanStep (checkCompose podman)
        let images =
              [("dependency " <> debugStr (rdName d), image) | d <- reDependencies environment, Just image <- [rdImage d]]
                ++ [(configServiceName, qualifyImage (configServiceImage s)) | Just s <- [envConfigService declared]]
        progress' "checking images"
        podmanStep (ensureImages podman images)
        labelled <- labelledLevels podman environment
        settings <- writeSettings w environment
        _ <- writeAtomically (composePath w) (composeFile environment (fmap (\s -> (s, settings)) (envConfigService declared))) `orFail` ioFailure (composePath w)
        progress' "starting containers"
        podmanStep (composeUp podman (composePath w) (stackName environment))
        pure (environment, [rdName d | d <- reDependencies environment, isJust (rdImage d)], labelled)
  writeJson (runPath w) (encodeRunRecord run)
  records0 <-
    foldM
      ( \records d -> case (rdTwin d, rdAdminUrl d) of
          (Just twin, Just url) -> do
            let cp = controlPlane url
                failTwin e = failWith ("twin " <> debugStr (rdName d) <> ": " <> renderTwinError e)
            progress' ("waiting for the control plane of " <> rdName d <> " at " <> url)
            ok <- waitHealthy cp (upWaitSeconds options)
            when (not ok) $
              failTwin (Unreachable url ("no answer at /healthz within " <> T.pack (show (upWaitSeconds options)) <> "s"))
            when (isJust (twinSeed twin) || isJust (twinState twin) || not (null (twinFaults twin))) $
              progress' ("setting up " <> rdName d)
            record <- setUp cp twin manifestDir >>= either failTwin pure
            pure (Map.insert (rdName d) record {trConformance = Map.lookup (rdName d) labelled} records)
          _ -> pure records
      )
      Map.empty
      (reDependencies environment)
  let records = Map.foldrWithKey (\dep level rs -> Map.alter (\r -> Just (maybe emptyTwinRecord id r) {trConformance = Just level}) dep rs) records0 labelled
  writeJson (twinsPath w) (Object [(k, encodeTwinRecord r) | (k, r) <- Map.toAscList records])
  (unreached, reached) <-
    foldM
      ( \(unreached, reached) d -> do
          answered <-
            if rdName d `elem` startedImages
              then do
                progress' ("waiting for " <> rdName d <> " at " <> rdEndpoint d)
                waitReachable (rdEndpoint d) (upWaitSeconds options)
              else tcpReachable (rdEndpoint d) 3000
          pure (if answered then unreached else unreached ++ [rdName d], Map.insert (rdEndpoint d) answered reached)
      )
      ([], Map.empty)
      (reDependencies environment)
  synced <-
    if upSync options
      then progress' "syncing settings" >> syncEnvironment clouds manifest manifestDir environment
      else pure []
  observed <- observeTwins environment w records
  recorded <- nowTimestamp
  let attestation = attest environment run recorded (\e -> Map.findWithDefault False e reached) observed records
  writeAttestation (attestationPath w) attestation
  pure (UpReport environment attestation (attestationPath w) synced unreached)

-- | Reads the conformance level from the image label of each twin that names
-- one, and checks it against the declared level and the report.
labelledLevels :: Podman -> ResolvedEnvironment -> Eff (Map Text Text)
labelledLevels podman environment =
  foldM
    ( \levels d -> case (rdTwin d, rdImage d) of
        (Just twin, Just image) | Just label <- conformanceImageLabel (twinConformance twin) -> do
          labels <- podmanStep (imageLabels podman image)
          let failLevel msg = failWith ("twin " <> debugStr (rdName d) <> ": " <> msg)
          level <- case Map.lookup label labels of
            Just l | not (T.null (T.strip l)) -> pure l
            _ -> failLevel ("image " <> image <> " has no label " <> debugStr label <> " to read the conformance level from")
          case conformanceDeclared (twinConformance twin) of
            Just declared
              | asciiLower declared /= asciiLower level
                  && not (maybe False (\r -> reportMatches r declared && reportMatches r level) (twinReport twin)) ->
                  failLevel ("the twin declares conformance " <> debugStr declared <> ", but image label " <> label <> " says " <> debugStr level)
            _ -> pure ()
          case twinReport twin of
            Just r
              | not (reportMatches r level) ->
                  failLevel ("image label " <> label <> " says " <> debugStr level <> ", but the report gives " <> reportDescribe r)
            _ -> pure ()
          pure (Map.insert (rdName d) (maybe level reportLevel (twinReport twin)) levels)
        _ -> pure levels
    )
    Map.empty
    (reDependencies environment)
  where
    asciiLower = T.map (\c -> if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c)

-- | Writes the OpenTofu root of a cloud environment and runs @init@ and
-- @plan@ on it.
plan :: Manifest -> Text -> Text -> Eff Text
plan manifest manifestDir name = do
  declared <- environmentOrFail manifest name
  when (not (runtimeIsCloud (envRuntime declared))) $ failWith (renderTofuError (NotCloud name))
  tofu <- prepareTofu manifest manifestDir name
  tofuStep (tofuInit tofu)
  tofuStep (tofuPlan tofu)
  pure (tofuRoot tofu)

-- | Takes an environment down: the compose project on podman, the OpenTofu
-- root in a cloud.
down :: Manifest -> Text -> Text -> Eff ()
down manifest manifestDir name = do
  declared <- environmentOrFail manifest name
  let w = workDir manifestDir name
  if runtimeIsCloud (envRuntime declared)
    then do
      tofu <- prepareTofu manifest manifestDir name
      tofuStep (tofuInit tofu)
      tofuStep (tofuDestroy tofu)
      removed <- removeFileE (endpointsPath w)
      case removed of
        Left e | not (ioNotFound e) -> failWith (ioFailure (endpointsPath w) e)
        _ -> pure ()
    else do
      environment <- resolveOrFail manifest name Map.empty
      podman <- podmanStep locatePodman
      podmanStep (checkCompose podman)
      _ <- writeAtomically (composePath w) (composeFile environment (fmap (\s -> (s, settingsPath w)) (envConfigService declared))) `orFail` ioFailure (composePath w)
      podmanStep (composeDown podman (composePath w) (stackName environment))

-- | One dependency's state, as @status@ reports it.
data DependencyStatus = DependencyStatus
  { statusName :: Text
  , statusKind :: Text
  , statusEndpoint :: Maybe Text
  , statusState :: Text
  , statusReachable :: Bool
  }

encodeStatus :: DependencyStatus -> Value
encodeStatus s =
  Object
    [ "name" .= String (statusName s)
    , "kind" .= String (statusKind s)
    , "endpoint" .= maybe Null String (statusEndpoint s)
    , "state" .= String (statusState s)
    , "reachable" .= Bool (statusReachable s)
    ]

-- | The state of every dependency of an environment.
status :: Manifest -> Text -> Text -> Eff [DependencyStatus]
status manifest manifestDir name = do
  declared <- environmentOrFail manifest name
  let probe e = tcpReachable e 2000
      cloud = runtimeIsCloud (envRuntime declared)
  resolved <- resolveIn manifest manifestDir name
  case resolved of
    Right environment -> do
      found <-
        if cloud
          then pure []
          else do
            podman <- podmanStep locatePodman
            podmanStep (containers podman (reProject environment) name)
      forM (reDependencies environment) $ \d -> do
        let state = case filter ((== rdName d) . csDependency) found of
              (c : _) -> csState c
              []
                | isJust (rdImage d) && not cloud -> "absent"
                | cloud && rdKind d == KindTwinBinding -> "deployed"
                | otherwise -> "hosted"
        DependencyStatus (rdName d) (kindWord (rdKind d)) (Just (rdEndpoint d)) state <$> probe (rdEndpoint d)
    Left (NotDeployed _ _) ->
      forM (Map.toAscList (envDependencies declared)) $ \(dependency, binding) -> case binding of
        BindReal real -> DependencyStatus dependency "real" (Just (realEndpoint real)) "hosted" <$> probe (realEndpoint real)
        BindTwin _ -> pure (DependencyStatus dependency "twin" Nothing "not deployed" False)
    Left e -> failWith (renderResolveError e)

-- | Writes the attestation of an environment now: the run @up@ started, or a
-- new one, with each endpoint probed and each twin's seed and history read.
attestNow :: Manifest -> Text -> Text -> Maybe Text -> Eff (Attestation, Text)
attestNow manifest manifestDir name output = do
  environment <- resolveIn manifest manifestDir name >>= either (failWith . renderResolveError) pure
  let w = workDir manifestDir name
  runText <- readFileE (runPath w)
  run <- case runText of
    Right text -> either (failWith . ((Path.display (runPath w) <> ": ") <>)) pure (fromStr (ExpectStruct "RunRecord") decodeRunRecord text)
    Left _ -> startRun
  records <- readTwins w >>= either (failWith . ((Path.display (twinsPath w) <> ": ") <>)) pure
  observed <- observeTwins environment w records
  reached <- forM (reDependencies environment) $ \d -> (,) (rdEndpoint d) <$> tcpReachable (rdEndpoint d) 2000
  recorded <- nowTimestamp
  let attestation = attest environment run recorded (\e -> maybe False id (lookup e reached)) observed records
      path = maybe (attestationPath w) id output
  writeAttestation path attestation
  pure (attestation, path)

-- | The control-plane URL of each twin: the one @up@ recorded, else the one
-- the manifest gives.
adminUrls :: ResolvedEnvironment -> Map Text TwinRecord -> [(Text, Text)]
adminUrls environment records =
  [ (rdName d, url)
  | d <- reDependencies environment
  , isJust (rdTwin d)
  , Just url <- [maybe Nothing trAdmin (Map.lookup (rdName d) records) `orElse` rdAdminUrl d]
  ]
  where
    orElse (Just a) _ = Just a
    orElse Nothing b = b

-- | Reads each twin's seed and history and keeps the history in the working
-- directory; a twin whose control plane does not answer is skipped.
observeTwins :: ResolvedEnvironment -> WorkDir -> Map Text TwinRecord -> Eff (Map Text Observation)
observeTwins environment w records =
  foldM
    ( \observed (dependency, url) -> do
        r <- observe (controlPlane url)
        case r of
          Left _ -> pure observed
          Right observation -> do
            case obsHistory observation of
              Just h -> do
                let path = historyPath w dependency
                _ <- writeAtomically path h `orFail` ioFailure path
                pure ()
              Nothing -> pure ()
            pure (Map.insert dependency observation observed)
    )
    Map.empty
    (adminUrls environment records)

-- | The control plane of the twin standing in for a dependency.
controlPlaneFor :: Manifest -> Text -> Text -> Text -> Eff ControlPlane
controlPlaneFor manifest manifestDir name dependency = do
  environment <- resolveIn manifest manifestDir name >>= either (failWith . renderResolveError) pure
  resolved <- case filter ((== dependency) . rdName) (reDependencies environment) of
    (d : _) -> pure d
    [] ->
      failWith
        ( "environment " <> debugStr name <> " has no dependency " <> debugStr dependency <> "; it has "
            <> T.intercalate ", " (map (debugStr . rdName) (reDependencies environment))
        )
  when (isNothing (rdTwin resolved)) $
    failWith ("dependency " <> debugStr dependency <> " is the real thing in environment " <> debugStr name <> ", not a twin")
  let w = workDir manifestDir name
  records <- readTwins w >>= either (failWith . ((Path.display (twinsPath w) <> ": ") <>)) pure
  case lookup dependency (adminUrls environment records) of
    Just url -> pure (controlPlane url)
    Nothing ->
      failWith
        ( "the twin for " <> debugStr dependency <> " in environment " <> debugStr name
            <> " has no control plane; give it `admin` in the manifest"
        )
