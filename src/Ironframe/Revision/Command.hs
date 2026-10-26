-- | Explicit prepare, check, activate, publish, adopt and revert operations.
-- Activation selects an immutable bundle; publishing settings and applications
-- adopting them are separately recorded effects. No operation migrates data.
module Ironframe.Revision.Command (command) where

import Control.Monad (forM, forM_, unless, when)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Ironframe.Calm.Resolve
import Ironframe.Effect
import Ironframe.Json
import Ironframe.Manifest
import qualified Ironframe.Path as Path
import Ironframe.Revision
import qualified Ironframe.Sync as Sync

at :: Text -> Value -> Text
at name = maybe "" id . textAt name

array :: Value -> [Value]
array (Array values) = values
array _ = []

load :: Text -> Eff (Text,Value)
load path = do
  text <- readFileE path >>= either (failWith . ioMessage) pure
  value <- either failWith pure (decode text)
  pure (text,value)

save :: Text -> Value -> Eff ()
save path value = do
  changed <- compareAndSwap path Nothing (encodePretty value <> "\n")
  unless changed $ do
    (_,existing) <- load path
    unless (canonical existing == canonical value) (failWith (path <> ": immutable content already exists and differs"))

need :: Text -> Value -> Eff Text
need name options = case textAt name options of
  Just value | not (T.null value) -> pure value
  _ -> failWith ("revision command requires --" <> name)

revisionPath :: Text -> Text -> Eff Text
revisionPath root identity = case T.stripPrefix "sha256:" identity of
  Just hex | T.length hex == 64, T.all (`elem` ("0123456789abcdef" :: String)) hex -> pure (Path.join root (hex <> ".json"))
  _ -> failWith "revision must be a full sha256: content identity"

-- | Resolve file references in a runner-authored evidence manifest before
-- assessing it. Paths are relative to the manifest, never the current shell.
evidenceAt :: Text -> Eff Value
evidenceAt path = do
  (_,manifest) <- load path
  let dir = maybe "." id (Path.parent path)
  runs <- forM (array (keyOr "runs" manifest)) $ \entry -> do
    values <- forM ["configuration","attestation","laws","observations","histories"] $ \name -> do
      file <- need name entry
      (_,value) <- load (Path.join dir file)
      pure (name,value)
    pure (Object (("role",keyOr "role" entry):values))
  pure (insert "runs" (Array runs) manifest)

command :: Resolution -> Text -> Value -> Eff Integer
command resolution action options =
  let lock = Path.join (resDir resolution) (".ironframe/" <> rtEnvironment (resTopology resolution) <> "/revisions/operation.lock")
   in if action == "status" then commandLocked resolution action options else withDirectoryLock lock (commandLocked resolution action options)

commandLocked :: Resolution -> Text -> Value -> Eff Integer
commandLocked resolution action options = do
  let topology = resTopology resolution
      environment = rtEnvironment topology
      root = Path.join (resDir resolution) (".ironframe/" <> environment <> "/revisions")
      current = Path.join root "current.json"
      output value = do
        forM_ (textAt "output" options) $ \path -> do
          _ <- writeAtomically path (encodePretty value <> "\n") >>= either (failWith . ioMessage) pure
          pure ()
        printOut (encodePretty value <> "\n")
        pure 0
      candidate = do
        file <- need "revision" options
        (_,value) <- load file
        _ <- either failWith pure (validateRevision value)
        fresh <- prepare resolution
        unless (keyOr "revision" fresh == keyOr "revision" value) (failWith "candidate no longer matches resolved topology, settings or implementation")
        pure value
      getState = do
        readFileE current >>= \case
          Left e | ioNotFound e -> pure (Nothing, Object ["desired" .= Null,"previous" .= Null,"history" .= Array []])
          Left e -> failWith (ioMessage e)
          Right text -> do value <- either failWith pure (decode text); pure (Just text,value)
      expected state = do
        wanted <- need "expected" options
        let selected = case keyOr "desired" state of String value -> value; _ -> "none"
        unless (wanted == selected) (failWith "active selection changed; --expected does not match")
      commit previous value = do
        changed <- compareAndSwap current previous (encodePretty value <> "\n")
        unless changed (failWith "configuration state changed concurrently; reread status before retrying")
        output value
  case action of
    "prepare" -> do
      value <- prepare resolution
      path <- revisionPath root (at "revision" value)
      save path value
      output value
    "check" -> do
      value <- candidate
      file <- need "evidence" options
      evidence <- evidenceAt file
      receipt <- either failWith pure (assess value evidence)
      output receipt
    "status" -> getState >>= output . snd
    "activate" -> do
      value <- candidate
      evidence <- need "evidence" options >>= evidenceAt
      receipt <- either failWith pure (assess value evidence)
      (previous,state) <- getState
      expected state
      when (at "phase" state == "awaiting-adoption") (failWith "previous activation is still awaiting application adoption; finish it or revert")
      when (keyOr "desired" state == keyOr "revision" value) (failWith "candidate revision is already selected")
      path <- revisionPath root (at "revision" value)
      save path value
      let evidencePath = Path.join root (T.drop 7 (identify evidence) <> ".evidence.json")
      save evidencePath evidence
      receiptPath <- revisionPath (Path.join root "receipts") (identify receipt)
      save receiptPath receipt
      transition <- newUuid
      let event = Object ["operation" .= String "activate", "transition" .= String transition, "from" .= keyOr "desired" state, "to" .= keyOr "revision" value, "evidenceDigest" .= String (identify evidence),"receipt" .= String (identify receipt)]
      commit previous (Object
        ["format" .= String "ironframe-activation", "version" .= Number (I 1)
        ,"desired" .= keyOr "revision" value,"previous" .= keyOr "desired" state
        ,"transition" .= String transition,"phase" .= String "awaiting-adoption"
        ,"receipt" .= String (identify receipt)
        ,"adopted" .= Object [],"published" .= Object []
        ,"history" .= Array (array (keyOr "history" state) ++ [event])])
    "adopt" -> do
      (previous,state) <- getState
      expected state
      path <- revisionPath root (at "desired" state)
      (_,value) <- load path
      (_,acknowledgement) <- need "ack" options >>= load
      unless (keyOr "transition" acknowledgement == keyOr "transition" state) (failWith "adoption belongs to another activation transition")
      updated <- either failWith pure (adoption value state acknowledgement)
      commit previous updated
    "revert" -> do
      (previous,state) <- getState
      expected state
      let wanted = at "previous" state
      when (T.null wanted) (failWith "there is no previous eligible revision to revert to")
      path <- revisionPath root wanted
      (_,value) <- load path
      _ <- either failWith pure (validateRevision value)
      let prior = [event | event <- reverse (array (keyOr "history" state)), at "to" event == wanted]
      receiptId <- case prior of event:_ -> pure (at "receipt" event); [] -> failWith "previous revision has no activation history"
      receiptPath <- revisionPath (Path.join root "receipts") receiptId
      (_,receipt) <- load receiptPath
      unless (identify receipt == receiptId) (failWith "previous promotion receipt does not match its content address")
      unless (at "status" receipt == "eligible" && at "revision" receipt == wanted) (failWith "previous revision has no promotion receipt")
      transition <- newUuid
      let event = Object ["operation" .= String "revert","transition" .= String transition,"from" .= keyOr "desired" state,"to" .= String wanted,"receipt" .= String receiptId]
      commit previous (insert "desired" (String wanted) (insert "previous" (keyOr "desired" state)
        (insert "transition" (String transition) (insert "receipt" (String receiptId) (insert "phase" (String "awaiting-adoption")
        (insert "adopted" (Object []) (insert "published" (Object [])
        (insert "history" (Array (array (keyOr "history" state) ++ [event])) state))))))))
    "publish" -> do
      (previous,state) <- getState
      expected state
      node <- need "app" options
      path <- revisionPath root (at "desired" state)
      (_,value) <- load path
      envelope <- either failWith pure (binding value state node)
      env <- either (failWith . renderManifestError) pure (environmentOf (resManifest resolution) environment)
      let supplied = Map.singleton "IRONFRAME_CONFIGURATION_BUNDLE" (encode envelope)
      when (null (envSync env)) (failWith "environment has no configured sync targets")
      outcomes <- forM (envSync env) $ \target -> do
        result <- case target of
          SyncEnvFile t -> Sync.syncEnvFile (t {envFilePath = envFilePath t <> "." <> node}) (resDir resolution) (rtProject topology) environment supplied
          SyncAws t -> Sync.syncAws (t {awsProfile = awsProfile t <> "-" <> node}) environment supplied
          SyncGcp t -> Sync.syncGcp (t {gcpParameter = gcpParameter t <> "-" <> node}) environment supplied
          SyncAzure t -> Sync.syncAzure (t {azurePrefix = azurePrefix t <> node <> ":"}) environment supplied
        either (failWith . Sync.renderSyncError) (pure . String . Sync.renderOutcome) result
      let publication = Object ["revision" .= keyOr "revision" value,"transition" .= keyOr "transition" state,"outcomes" .= Array outcomes]
      commit previous (insert "published" (insert node publication (keyOr "published" state)) state)
    _ -> failWith "revision action must be prepare, check, activate, status, publish, adopt or revert"
