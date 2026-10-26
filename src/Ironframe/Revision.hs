-- | Immutable configuration identities and evidence requirements for changing
-- dependency bindings. These are execution policy checks, not proof checking.
-- Producer reports and local evidence files are within the runner trust boundary.
module Ironframe.Revision
  ( canonical
  , identify
  , prepare
  , validateRevision
  , assess
  , adoption
  , binding
  , bindingSettings
  ) where

import Control.Monad (forM_, unless, when)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Ironframe.Attestation as A
import Ironframe.Calm.Resolve
import Ironframe.Calm.Run (settingsOf)
import qualified Ironframe.Component as C
import Ironframe.Digest (digestOf)
import Ironframe.Effect
import Ironframe.Json
import Ironframe.Ops (resolveIn)
import qualified Ironframe.Settings as S

-- | Object key order is presentation; arrays retain their semantic order.
canonical :: Value -> Value
canonical (Object entries) = Object (sortOn fst [(k, canonical v) | (k,v) <- entries])
canonical (Array values) = Array (map canonical values)
canonical value = value

identify :: Value -> Text
identify = digestOf . encode . canonical

ensure :: Bool -> Text -> Either Text ()
ensure condition message = unless condition (Left message)

array :: Value -> [Value]
array (Array values) = values
array _ = []

fields :: Value -> [(Text,Value)]
fields (Object values) = values
fields _ = []

at :: Text -> Value -> Text
at name = maybe "" id . textAt name

projectFields :: [Text] -> Value -> Value
projectFields names value = Object [(name,keyOr name value) | name <- names]

-- | Freeze resolved endpoints, references (never secret values), implementation
-- identities and the complete graph. A bare version is not an implementation id.
prepare :: Resolution -> Eff Value
prepare resolution = do
  let topology = resTopology resolution
  resolved <- resolveIn (resManifest resolution) (resDir resolution) (rtEnvironment topology) >>= either (failWith . S.renderResolveError) pure
  settings <- mapM (\app -> do s <- settingsOf resolution (raNode app); pure (raNode app, fromTextMap s)) (rtApplications topology)
  applications <- mapM (\app -> do
    implementation <- case Map.lookup (raNode app) (rtComponents topology) of
      Just component -> pure (C.componentFingerprint component)
      Nothing -> case raCommit app of
        Just commit | not (T.null commit), not ("-dirty" `T.isSuffixOf` commit) -> pure commit
        _ -> failWith (raNode app <> ": revisions require a component fingerprint or explicit clean implementation commit")
    let inventory = maybe [] (filter (T.isInfixOf "::law::") . C.componentDeclarations) (Map.lookup (raNode app) (rtComponents topology))
    pure (raNode app, Object ["implementation" .= String implementation, "version" .= String (raVersion app),"lawInventory" .= Array (map String inventory)])) (rtApplications topology)
  let payload = Object
        [ "environment" .= String (rtEnvironment topology)
        , "project" .= String (rtProject topology)
        , "topologyDigest" .= String (topologyDigest topology)
        , "topology" .= encodeTopology topology
        , "settings" .= Object settings
        , "applications" .= Object applications
        , "bindings" .= Object [(S.rdName dependency, Object ["endpoint" .= String (S.rdEndpoint dependency), "kind" .= String (S.kindWord (S.rdKind dependency))]) | dependency <- S.reDependencies resolved]
        ]
  pure (Object ["format" .= String "ironframe-configuration", "version" .= Number (I 1), "revision" .= String (identify payload), "payload" .= payload])

-- | Content must match its address. Unknown protocols and malformed snapshots
-- fail before any activation, publication or adoption effect.
validateRevision :: Value -> Either Text Value
validateRevision revision = do
  ensure (textAt "format" revision == Just "ironframe-configuration" && keyOr "version" revision == Number (I 1)) "expected ironframe-configuration version 1"
  let payload = keyOr "payload" revision
      topology = keyOr "topology" payload
      settings = fields (keyOr "settings" payload)
      applications = fields (keyOr "applications" payload)
  ensure (isObject payload && at "revision" revision == identify payload) "configuration content does not match revision"
  ensure (at "topologyDigest" payload == digestOf (encode topology)) "configuration topology digest does not match topology"
  ensure (not (T.null (at "environment" payload)) && not (T.null (at "project" payload))) "configuration needs environment and project"
  ensure (keyOr "environment" payload == keyOr "environment" topology && keyOr "project" payload == keyOr "project" topology) "configuration scope differs from topology"
  ensure (not (null applications) && sortOn id (map fst settings) == sortOn id (map fst applications)) "settings and application identities must cover the same nodes"
  ensure (sortOn id (map fst applications) == sortOn id [at "node" app | app <- array (keyOr "applications" topology)]) "configuration applications differ from topology"
  forM_ applications $ \(node,identity) -> do
    ensure (not (T.null node) && T.all (`elem` ("abcdefghijklmnopqrstuvwxyz0123456789-" :: String)) node && not (T.null (at "implementation" identity))) "application needs a resource-safe node name and implementation identity"
    let values = keyOr node (keyOr "settings" payload)
    ensure (isObject values && all (\(_,v) -> case v of String _ -> True; _ -> False) (fields values)) "settings must be an object of strings"
    ensure (all (not . T.isPrefixOf "IRONFRAME_CONFIGURATION_" . fst) (fields values)) "IRONFRAME_CONFIGURATION_ settings are reserved for revision identity"
  pure payload

-- | The testable interface remains the same across real/twin environments.
shape :: Value -> Value
shape payload = canonical (Object
  [ "project" .= keyOr "project" payload
  , "architecture" .= keyOr "digest" (keyOr "architecture" topology)
  , "applications" .= keyOr "applications" payload
  , "dependencies" .= Array (sortOn (at "node") [projectFields ["node","contract","provides"] d | d <- array (keyOr "dependencies" topology)])
  , "edges" .= Array (sortOn (at "relationship") [projectFields ["relationship","source","destination","protocol","consumes","requirement"] e | e <- array (keyOr "edges" topology)])
  , "settingNames" .= Object [(node, Array (map (String . fst) (sortOn fst (fields values)))) | (node,values) <- fields (keyOr "settings" payload)]
  , "observation" .= keyOr "observation" topology
  ])
  where topology = keyOr "topology" payload

-- | Check a complete set of native-law observations, not merely a successful
-- process exit or a log message. Unsupported/pending/stale results cannot pass.
checkedLaws :: [Text] -> Text -> Value -> Either Text ()
checkedLaws inventory run laws = do
  let rows = [row | row <- array laws, at "stage" row == "law"]
      native = [keyOr "nativeEvidence" row | row <- rows, key "nativeEvidence" row /= Nothing]
  ensure (not (null rows) && not (null native)) "promotion needs native LawSpec observations"
  unless (null inventory) $
    ensure (sortOn id (map (at "declaration") rows) == sortOn id inventory) "law report does not cover the checked component's complete law inventory"
  forM_ native $ \evidence -> do
    ensure (at "status" evidence == "passed") "native law evidence has not passed"
    let observations = array (keyOr "observations" evidence)
        current = [o | o <- observations, at "executionRun" (keyOr "attempt" o) == run]
    ensure (not (null current)) "law has no observation from this execution run"
    ensure (all ((== "matching-inputs") . at "freshness") current) "law observation is stale"
    ensure (all ((== "passed") . at "outcome") current) "a current native observation did not pass"
  forM_ rows $ \row -> do
    ensure (at "status" row `elem` ["property-tested","exhaustively-verified","proved"]) "law result is failed, unknown, pending or unsupported"
    ensure (null (array (keyOr "plannedAgainst" row))) "law dependencies are still planned rather than completed"
    when (key "nativeEvidence" row == Nothing) $
      ensure (at "status" row `elem` ["proved","exhaustively-verified"]) "law without native observations has no accepted verification result"

-- | Validate a sealed observation bundle's identity, exact journal bytes, flush
-- accounting and checkpoints. A caller cannot turn an incomplete bundle into a
-- complete one by changing only its status field.
checkedObservations :: Text -> Text -> Text -> Text -> Value -> Either Text ()
checkedObservations node implementation revision execution bundle = do
  ensure (at "format" bundle == "lawtwin-observation" && keyOr "version" bundle == Number (I 1)) "expected lawtwin-observation version 1"
  let journal = array (keyOr "journal" bundle)
      bytes = T.concat [encode row <> "\n" | row <- journal]
      producers = [(producerId,p) | (producerId,p) <- fields (keyOr "producers" bundle), at "node" p == node]
      start = case journal of row:_ -> row; [] -> Null
      config = keyOr "config" start
  ensure (not (null journal) && at "journalDigest" bundle == digestOf bytes) "observation journal digest is invalid"
  ensure (at "status" bundle == "complete" && keyOr "lost" bundle == Number (I 0) && null (array (keyOr "reasons" bundle))) "observation collection is incomplete"
  ensure (at "kind" start == "start" && keyOr "producers" config == keyOr "producers" bundle && keyOr "runId" config == keyOr "runId" bundle && keyOr "topologyDigest" config == keyOr "topologyDigest" bundle) "observation header differs from exported identities"
  ensure (at "kind" (last journal) == "seal" && at "status" (last journal) == "complete") "journal has no completed seal"
  ensure (all ((/= "declared-loss") . at "kind") journal) "journal records observation loss"
  ensure (not (null producers)) "application has no observation producer"
  forM_ producers $ \(producerId,p) -> do
    ensure (at "implementation" p == implementation && at "revision" p == revision) "observation producer implementation or revision differs"
    let checkpoint = keyOr producerId (keyOr "checkpoints" bundle)
        counts = keyOr producerId (keyOr "counts" bundle)
        recorded = [keyOr "checkpoint" row | row <- journal, at "kind" row == "checkpoint", at "producer" (keyOr "checkpoint" row) == producerId]
        exports = [(at "signal" row, resource) | row <- journal, at "kind" row == "export",
          resource <- array (keyOr (if at "signal" row == "logs" then "resourceLogs" else "resourceSpans") (keyOr "request" row)),
          attribute "lawtwin.producer.id" (keyOr "attributes" (keyOr "resource" resource)) == producerId]
        number signal = sum [length (array (keyOr (if signal == "logs" then "logRecords" else "spans") scope)) |
          (kind,resource) <- exports, kind == signal,
          scope <- array (keyOr (if signal == "logs" then "scopeLogs" else "scopeSpans") resource)]
        actual = Object ["logs" .= Number (I (toInteger (number "logs"))),"spans" .= Number (I (toInteger (number "traces")))]
    ensure (keyOr "flushed" checkpoint == Bool True && keyOr "dropped" checkpoint == Number (I 0)) "producer did not flush without drops"
    ensure (counts == keyOr "counts" checkpoint && isObject counts) "producer counts do not match retained observations"
    ensure (recorded == [checkpoint] && canonical counts == canonical actual) "exported counts or checkpoints differ from journal"
    ensure (any (\(_,resource) -> attribute "ironframe.execution.id" (keyOr "attributes" (keyOr "resource" resource)) == execution) exports) "journal has no observations from this execution"
    forM_ exports $ \(_,resource) -> do
      let attributes = keyOr "attributes" (keyOr "resource" resource)
      forM_ [("ironframe.run.id", at "runId" bundle),("ironframe.topology.digest",at "topologyDigest" bundle),("ironframe.node.id",node),("service.version",implementation),("ironframe.configuration.revision",revision)] $ \(name,wanted) ->
        ensure (attribute name attributes == wanted) "journal resource identity differs from checked execution"
  where
    attribute name attributes = case [at "stringValue" (keyOr "value" a) | a <- array attributes, at "key" a == name] of
      [value] -> value
      _ -> ""

-- | Evidence entries embed the original revision, completed attestation, native
-- law evidence and sealed observation bundle. Provider runs must use the exact
-- candidate bindings. Fixture runs may differ only in bindings and settings.
assess :: Value -> Value -> Either Text Value
assess candidate evidence = do
  target <- validateRevision candidate
  ensure (at "format" evidence == "ironframe-promotion-evidence" && keyOr "version" evidence == Number (I 1)) "expected ironframe-promotion-evidence version 1"
  let runs = array (keyOr "runs" evidence)
  checked <- mapM (checkRun target) runs
  forM_ (fields (keyOr "applications" target)) $ \(node,_) -> do
    ensure (any (\(role,n,_) -> role == "fixture" && n == node) checked) (node <> ": no completed fixture test")
    let realEdges = [edge | edge <- array (keyOr "edges" (keyOr "topology" target)), at "source" edge == node, at "kind" edge == "real"]
    unless (null realEdges) $
      ensure (any (\(role,n,_) -> role == "provider" && n == node) checked) (node <> ": no completed test against candidate real providers")
  pure (Object
    [ "format" .= String "ironframe-promotion-receipt", "version" .= Number (I 1)
    , "revision" .= keyOr "revision" candidate, "evidenceDigest" .= String (identify evidence)
    , "runs" .= Array [Object ["role" .= String role,"node" .= String node,"run" .= String run] | (role,node,run) <- checked]
    , "status" .= String "eligible"
    , "trust" .= String "local runner reports and SDK flush checkpoints; not independent proof or provider conformance"
    ])
  where
    checkRun target entry = do
      source <- validateRevision (keyOr "configuration" entry)
      ensure (shape source == shape target) "evidence implementation, architecture or contract interface differs from candidate"
      let role = at "role" entry
      ensure (role `elem` ["fixture","provider"]) "evidence role must be fixture or provider"
      att <- A.fromJson (encode (keyOr "attestation" entry))
      application <- maybe (Left "evidence attestation has no application") Right (A.attApplication att)
      let node = A.appNode application
          identity = keyOr node (keyOr "applications" source)
          implementation = at "implementation" identity
          observation = keyOr "observations" entry
      ensure (not (T.null implementation)) "evidence application is outside configuration"
      ensure (A.attEnvironment att == at "environment" source) "attestation environment differs from configuration"
      ensure (maybe False ((== Just (at "topologyDigest" source)) . A.refTopologyDigest) (A.attArchitecture att)) "attestation topology differs from configuration"
      ensure (case A.attExecution att of Just e -> A.execStatus e == A.CompletedRun && A.execExitCode e == Just 0; _ -> False) "execution is not completed successfully"
      ensure ((case A.appComponent application of Just c -> at "fingerprint" c; Nothing -> maybe "" id (A.implCommit (A.appImplementation application))) == implementation) "attestation implementation differs from configuration"
      let edges = [e | e <- array (keyOr "edges" (keyOr "topology" source)), at "source" e == node]
          histories = keyOr "histories" entry
      ensure (at "format" histories == "ironframe-run-histories" && keyOr "version" histories == Number (I 1) && at "run" histories == A.runId (A.attRun att)) "fixture history snapshot belongs to another run or format"
      forM_ edges $ \edge -> do
        let records = [d | d <- A.attDependencies att, A.depEdge d == Just (at "relationship" edge), A.depNode d == Just (at "destination" edge)]
        ensure (not (null records) && sortOn id (map A.depName records) == sortOn id [name | String name <- array (keyOr "consumes" edge)]) "edge has missing, duplicate or unexpected execution obligations"
        forM_ records $ \d -> do
          ensure (A.depEndpoint d == at "endpoint" (keyOr (at "destination" edge) (keyOr "bindings" source))) "execution endpoint differs from configuration"
          ensure (maybe False A.completedReached (A.depCompleted d)) "dependency was not reached in completed execution"
          ensure ((A.depKind d == A.KindStandIn) == (at "kind" edge == "twin")) "execution dependency binding differs from configuration"
          when (A.depKind d == A.KindStandIn) $
            do
              ensure (maybe False (maybe False A.isHistoryDigest . A.completedHistoryDigest) (A.depCompleted d)) "fixture has no completed history digest"
              let retained = keyOr (at "destination" edge) (keyOr "dependencies" histories)
              ensure (at "status" retained == "retained" && digestOf (at "raw" retained) == at "digest" retained && Just (at "digest" retained) == (A.depCompleted d >>= A.completedHistoryDigest)) "fixture history is missing or does not match completed execution"
      when (role == "fixture") $
        ensure (all ((== "twin") . at "kind") edges) "fixture evidence must isolate every outgoing dependency"
      when (role == "provider") $
        ensure (keyOr "revision" (keyOr "configuration" entry) == keyOr "revision" candidate) "provider evidence must test exact candidate configuration"
      checkedLaws [law | String law <- array (keyOr "lawInventory" identity)] (A.runId (A.attRun att)) (keyOr "laws" entry)
      ensure (not (T.null (at "runId" observation)) && at "topologyDigest" observation == at "topologyDigest" source) "observation has no run identity or its topology differs"
      checkedObservations node implementation (at "revision" (keyOr "configuration" entry)) (A.runId (A.attRun att)) observation
      pure (role,node,A.runId (A.attRun att))

-- | Acknowledgement after draining old work and loading the exact per-app
-- settings. This verifies a declaration; it does not introspect client sockets.
adoption :: Value -> Value -> Value -> Either Text Value
adoption configuration state acknowledgement = do
  payload <- validateRevision configuration
  let revision = at "revision" configuration
      node = at "node" acknowledgement
      implementation = at "implementation" (keyOr node (keyOr "applications" payload))
      settings = keyOr node (keyOr "settings" payload)
  ensure (at "format" state == "ironframe-activation" && keyOr "version" state == Number (I 1)) "expected ironframe-activation version 1"
  ensure (keyOr "transition" acknowledgement == keyOr "transition" state && not (T.null (at "transition" state))) "adoption belongs to another activation transition"
  ensure (at "desired" state == revision && at "revision" acknowledgement == revision) "adoption is not for the current desired revision"
  ensure (not (T.null implementation) && at "implementation" acknowledgement == implementation) "adoption implementation differs from candidate"
  ensure (at "settingsDigest" acknowledgement == identify settings) "application did not acknowledge exact settings"
  ensure (keyOr "drainedFrom" acknowledgement == keyOr "previous" state && keyOr "drained" acknowledgement == Bool True) "previous work must drain before adopting this revision"
  case key node (keyOr "adopted" state) of
    Just existing -> ensure (canonical existing == canonical acknowledgement) "application adoption is already recorded and immutable"
    Nothing -> pure ()
  let adopted = insert node acknowledgement (keyOr "adopted" state)
      complete = all (\(name,_) -> key name adopted /= Nothing) (fields (keyOr "applications" payload))
  pure (insert "phase" (String (if complete then "active" else "awaiting-adoption")) (insert "adopted" adopted state))

-- | Publish one complete value, including on Azure: readers never assemble a
-- revision from independently mutable endpoint keys. The application unwraps
-- this document through its normal configuration mechanism before connecting.
binding :: Value -> Value -> Text -> Either Text Value
binding configuration state node = do
  payload <- validateRevision configuration
  ensure (keyOr "desired" state == keyOr "revision" configuration) "binding is not for the selected revision"
  let settings = keyOr node (keyOr "settings" payload)
  ensure (isObject settings && not (T.null (at "transition" state))) "binding needs a configured application and activation transition"
  pure (Object
    ["format" .= String "ironframe-application-binding","version" .= Number (I 1)
    ,"revision" .= keyOr "revision" configuration,"transition" .= keyOr "transition" state
    ,"previous" .= keyOr "previous" state,"node" .= String node
    ,"implementation" .= keyOr "implementation" (keyOr node (keyOr "applications" payload))
    ,"settings" .= settings,"settingsDigest" .= String (identify settings)
    ,"activation" .= String "drain-and-restart"])

bindingSettings :: Value -> Either Text Value
bindingSettings value = do
  ensure (at "format" value == "ironframe-application-binding" && keyOr "version" value == Number (I 1)) "expected ironframe-application-binding version 1"
  ensure (at "activation" value == "drain-and-restart") "unsupported binding activation method"
  ensure (A.isHistoryDigest (at "revision" value) && not (T.null (at "transition" value)) && not (T.null (at "implementation" value))) "binding has no revision, transition or implementation identity"
  let settings = keyOr "settings" value
  ensure (isObject settings && at "settingsDigest" value == identify settings) "binding settings digest does not match"
  ensure (all (\(_,v) -> case v of String _ -> True; _ -> False) (fields settings)) "binding settings must be strings"
  pure (insert "IRONFRAME_CONFIGURATION_REVISION" (keyOr "revision" value) (insert "IRONFRAME_CONFIGURATION_TRANSITION" (keyOr "transition" value) settings))
