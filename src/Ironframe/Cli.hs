-- | The @ironframe@ command: reading the command line, running a verb, and
-- printing what it did, all through the host. The host only starts it with
-- the arguments and the working directory. ref:DEC-wiring-in-ironframe
module Ironframe.Cli (cli) where

import Control.Monad (forM, forM_, unless, when)
import Data.Char (isDigit)
import Data.List (nub, sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Ironframe.Attestation as A
import Ironframe.Calm.Export
import Ironframe.Calm.Model
import Ironframe.Calm.Resolve
import Ironframe.Calm.Run
import Ironframe.Compose (composeFile)
import Ironframe.Effect
import qualified Ironframe.Embedded as Embedded
import Ironframe.Json
import Ironframe.Manifest
import Ironframe.Ops
import qualified Ironframe.Path as Path
import Ironframe.Rust (debugStr)
import Ironframe.Settings
import Ironframe.Sync (realClouds, renderOutcome)
import Ironframe.Tofu (renderTofuError, rootModule)
import Ironframe.Twin
import Ironframe.Workdir

-- | The verbs and their options, as the command line gives them.
data Command
  = Validate Bool
  | Resolve (Maybe Text) Text (Maybe Text)
  | Export ExportKind Text (Maybe Text) (Maybe Text) (Maybe Text)
  | Run Text Text (Maybe Text) (Maybe Text) [Text]
  | App Text Text (Maybe Text) [Text]
  | Schema SchemaKind
  | Settings Text SettingsFormat (Maybe Text)
  | Compose Text
  | Up Text Bool Integer
  | Down Text
  | Status Text Bool
  | Plan Text
  | Sync Text
  | Attest Text (Maybe Text) (Maybe Text) (Maybe Text) Integer
  | TwinCmd Text Text TwinAction

data ExportKind = ExportTopology | ExportDiagram | ExportSettings | ExportTofu | ExportCompose
  deriving (Eq)

data SchemaKind = SchemaManifest | SchemaAttestation | SchemaContract | SchemaBinding | SchemaEnvironment

data SettingsFormat = FormatEnv | FormatJson

data TwinAction
  = Inspect Bool
  | Force Text
  | FaultCmd Text [Text]
  | Faults
  | History (Maybe Integer) (Maybe Integer) Bool
  | Advance Text
  | Seed (Maybe Integer)
  | Reset
  | Laws
  | Replay (Maybe Text)

data Globals = Globals {gManifest :: Text, gArchitecture :: Maybe Text, gDecorators :: Maybe Text}

-- | The command run with its arguments in a working directory; its exit code.
cli :: [Text] -> Text -> Eff Integer
cli argv _cwd = case parseArgs argv of
  Left (ParseHelp text) -> printOut text >> pure 0
  Left (ParseError message) -> do
    printErr ("error: " <> message <> "\n\nUsage: ironframe [OPTIONS] <COMMAND>\n\nFor more information, try '--help'.\n")
    pure 2
  Right (globals, command) ->
    catchError (run globals command) $ \message -> do
      printErr ("ironframe: " <> message <> "\n")
      pure 2

-- Parsing the command line.

data ParseFailure = ParseHelp Text | ParseError Text

-- | Options as clap reads them: long options with a value as the next word or
-- after @=@, short options with the value next or attached, flags, and
-- positionals; @--@ ends the options.
data Parsed = Parsed {options :: Map.Map Text [Text], flags :: [Text], positionals :: [Text], rest :: [Text]}

parseArgs :: [Text] -> Either ParseFailure (Globals, Command)
parseArgs argv = do
  parsed <- scan argv (Parsed Map.empty [] [] [])
  let one k = case Map.lookup k (options parsed) of
        Just vs -> Just (last vs)
        Nothing -> Nothing
      globals = Globals (fromMaybe defaultManifest (one "manifest")) (one "architecture") (one "decorators")
  when ("help" `elem` flags parsed) $ Left (ParseHelp helpText)
  when ("version" `elem` flags parsed) $ Left (ParseHelp "ironframe 0.1.0\n")
  case positionals parsed of
    [] -> Left (ParseHelp helpText)
    (verb : args) -> (,) globals <$> command verb args parsed one
  where
    command verb args parsed one =
      let flag k = k `elem` flags parsed
          need k = maybe (Left (ParseError ("the following required arguments were not provided:\n  --" <> k <> " <" <> T.toUpper k <> ">"))) Right (one k)
          positional n name = case drop n args of
            (v : _) -> Right v
            [] -> Left (ParseError ("the following required arguments were not provided:\n  <" <> name <> ">"))
          optionalPositional n = case drop n args of
            (v : _) -> Just v
            [] -> Nothing
          extra n = case drop n args of
            [] -> Right ()
            (v : _) -> Left (ParseError ("unexpected argument '" <> v <> "' found"))
          number k = case one k of
            Nothing -> Right Nothing
            Just v | T.all isDigit v && not (T.null v) -> Right (Just (read (T.unpack v)))
            Just v -> Left (ParseError ("invalid value '" <> v <> "' for '--" <> k <> " <" <> T.toUpper k <> ">': invalid digit found in string"))
          env = one "env"
          envRequired = maybe (Left (ParseError "the following required arguments were not provided:\n  --env <ENVIRONMENT>")) Right env
       in case verb of
            "validate" -> extra 0 >> Right (Validate (flag "calm-cli"))
            "resolve" -> extra 1 >> (\e -> Resolve (optionalPositional 0) e (one "output")) <$> envRequired
            "export" -> do
              what <- positional 0 "WHAT" >>= exportKind
              e <- envRequired
              extra 1
              Right (Export what e (one "format") (one "app") (one "output"))
            "run" -> do
              e <- envRequired
              app <- need "app"
              when (null (rest parsed)) $ Left (ParseError "the following required arguments were not provided:\n  <COMMAND>...")
              extra 0
              Right (Run e app (one "dir") (one "attestation") (rest parsed))
            "app" -> do
              node <- positional 0 "NODE"
              e <- envRequired
              extra 1
              Right (App node e (one "attestation") (rest parsed))
            "schema" -> do
              which <- maybe (Right SchemaManifest) schemaKind (optionalPositional 0)
              extra 1
              Right (Schema which)
            "settings" -> do
              e <- positional 0 "ENVIRONMENT"
              extra 1
              format <- maybe (Right FormatEnv) settingsFormat (one "format")
              Right (Settings e format (one "app"))
            "compose" -> Compose <$> positional 0 "ENVIRONMENT" <* extra 1
            "up" -> do
              e <- positional 0 "ENVIRONMENT"
              extra 1
              wait <- number "wait"
              Right (Up e (flag "no-sync") (fromMaybe 90 wait))
            "down" -> Down <$> positional 0 "ENVIRONMENT" <* extra 1
            "status" -> (\e -> Status e (flag "json")) <$> positional 0 "ENVIRONMENT" <* extra 1
            "plan" -> Plan <$> positional 0 "ENVIRONMENT" <* extra 1
            "sync" -> Sync <$> positional 0 "ENVIRONMENT" <* extra 1
            "attest" -> do
              e <- positional 0 "ENVIRONMENT"
              extra 1
              code <- case one "exit-code" of
                Nothing -> Right 0
                Just v -> case T.uncons v of
                  Just ('-', digits) | T.all isDigit digits && not (T.null digits) -> Right (negate (read (T.unpack digits)))
                  _ | T.all isDigit v && not (T.null v) -> Right (read (T.unpack v))
                  _ -> Left (ParseError ("invalid value '" <> v <> "' for '--exit-code <EXIT_CODE>': invalid digit found in string"))
              Right (Attest e (one "output") (one "app") (one "complete") code)
            "twin" -> do
              dependency <- positional 0 "DEPENDENCY"
              action <- twinAction (drop 1 args) parsed one
              Right (TwinCmd dependency (fromMaybe "local" env) action)
            other -> Left (ParseError ("unrecognized subcommand '" <> other <> "'"))
    exportKind = \case
      "topology" -> Right ExportTopology
      "diagram" -> Right ExportDiagram
      "settings" -> Right ExportSettings
      "tofu" -> Right ExportTofu
      "compose" -> Right ExportCompose
      v -> Left (ParseError ("invalid value '" <> v <> "' for '<WHAT>'\n  [possible values: topology, diagram, settings, tofu, compose]"))
    schemaKind = \case
      "manifest" -> Right SchemaManifest
      "attestation" -> Right SchemaAttestation
      "contract" -> Right SchemaContract
      "binding" -> Right SchemaBinding
      "environment" -> Right SchemaEnvironment
      v -> Left (ParseError ("invalid value '" <> v <> "' for '[WHICH]'\n  [possible values: manifest, attestation, contract, binding, environment]"))
    settingsFormat = \case
      "env" -> Right FormatEnv
      "json" -> Right FormatJson
      v -> Left (ParseError ("invalid value '" <> v <> "' for '--format <FORMAT>'\n  [possible values: env, json]"))
    twinAction args parsed one =
      let numberOf k = case one k of
            Nothing -> Right Nothing
            Just v | T.all isDigit v && not (T.null v) -> Right (Just (read (T.unpack v)))
            Just v -> Left (ParseError ("invalid value '" <> v <> "' for '--" <> k <> " <" <> T.toUpper k <> ">': invalid digit found in string"))
       in case args of
            [] -> Left (ParseError "'ironframe twin' requires a subcommand but one was not provided\n  [subcommands: inspect, force, fault, faults, history, advance, seed, reset, laws, replay, help]")
            ("inspect" : _) -> Right (Inspect ("records" `elem` flags parsed))
            ["force", state] -> Right (Force state)
            ("force" : _) -> Left (ParseError "the following required arguments were not provided:\n  <STATE>")
            ("fault" : name : params) -> Right (FaultCmd name params)
            ("fault" : _) -> Left (ParseError "the following required arguments were not provided:\n  <NAME>")
            ("faults" : _) -> Right Faults
            ("history" : _) -> History <$> numberOf "since" <*> numberOf "limit" <*> pure ("array" `elem` flags parsed)
            ["advance", d] -> Right (Advance d)
            ("advance" : _) -> Left (ParseError "the following required arguments were not provided:\n  <DURATION>")
            ["seed"] -> Right (Seed Nothing)
            ["seed", s] | T.all isDigit s && not (T.null s) -> Right (Seed (Just (read (T.unpack s))))
            ("seed" : s : _) -> Left (ParseError ("invalid value '" <> s <> "' for '[SEED]': invalid digit found in string"))
            ("reset" : _) -> Right Reset
            ("laws" : _) -> Right Laws
            ["replay"] -> Right (Replay Nothing)
            ["replay", f] -> Right (Replay (Just f))
            (other : _) -> Left (ParseError ("unrecognized subcommand '" <> other <> "'"))

-- | The options that take a value, by long name, and their short names.
valueOptions :: [(Text, Maybe Char)]
valueOptions =
  [ ("manifest", Just 'f')
  , ("architecture", Just 'a')
  , ("decorators", Nothing)
  , ("env", Just 'e')
  , ("output", Just 'o')
  , ("format", Nothing)
  , ("app", Nothing)
  , ("dir", Nothing)
  , ("attestation", Nothing)
  , ("wait", Nothing)
  , ("complete", Nothing)
  , ("exit-code", Nothing)
  , ("since", Nothing)
  , ("limit", Nothing)
  ]

flagOptions :: [(Text, Maybe Char)]
flagOptions =
  [("calm-cli", Nothing), ("no-sync", Nothing), ("json", Nothing), ("records", Nothing), ("array", Nothing), ("help", Just 'h'), ("version", Just 'V')]

scan :: [Text] -> Parsed -> Either ParseFailure Parsed
scan [] p = Right p {positionals = reverse (positionals p)}
scan ("--" : more) p = Right p {positionals = reverse (positionals p), rest = more}
scan (word : more) p
  | Just long <- T.stripPrefix "--" word =
      let (name, attached) = case T.breakOn "=" long of
            (n, "") -> (n, Nothing)
            (n, v) -> (n, Just (T.drop 1 v))
       in if isJust (lookup name valueOptions)
            then case attached of
              Just v -> scan more (addOption name v p)
              Nothing -> case more of
                (v : more') -> scan more' (addOption name v p)
                [] -> Left (ParseError ("a value is required for '--" <> name <> " <" <> T.toUpper name <> ">' but none was supplied"))
            else
              if isJust (lookup name flagOptions)
                then scan more p {flags = name : flags p}
                else Left (ParseError ("unexpected argument '--" <> name <> "' found"))
  | Just short <- T.stripPrefix "-" word
  , Just (c, attached) <- T.uncons short
  , not (T.null short) && not (isDigit c) =
      case [n | (n, Just s) <- valueOptions, s == c] of
        (name : _)
          | not (T.null attached) -> scan more (addOption name (fromMaybe attached (T.stripPrefix "=" attached)) p)
          | otherwise -> case more of
              (v : more') -> scan more' (addOption name v p)
              [] -> Left (ParseError ("a value is required for '-" <> T.singleton c <> "' but none was supplied"))
        [] -> case [n | (n, Just s) <- flagOptions, s == c] of
          (name : _) -> scan more p {flags = name : flags p}
          [] -> Left (ParseError ("unexpected argument '-" <> T.singleton c <> "' found"))
  | otherwise = scan more p {positionals = word : positionals p}
  where
    addOption name v q = q {options = Map.insertWith (flip (++)) name [v] (options q)}

helpText :: Text
helpText =
  T.unlines
    [ "Wire applications to their dependencies, real or twin, per environment"
    , ""
    , "Usage: ironframe [OPTIONS] <COMMAND>"
    , ""
    , "Commands:"
    , "  validate  Check the manifest, or the architecture, its decorators and every environment they declare"
    , "  resolve   Resolve an environment of a CALM architecture and print the resolved topology, or refuse it"
    , "  export    Export what an environment's resolved topology generates, without deploying anything"
    , "  run       Run a command as an application of a CALM environment and attest the run"
    , "  app       Run a managed application of a CALM environment as its binding says, and attest the run"
    , "  schema    Print a JSON Schema: the manifest's, the attestation's or a decorator's"
    , "  settings  Print the settings an environment hands its application"
    , "  compose   Print the compose file of a podman environment"
    , "  up        Bring an environment up: start or deploy its containers, sync its settings, attest the run"
    , "  down      Take an environment down"
    , "  status    Show each dependency's state and whether its endpoint answers"
    , "  plan      Run `tofu plan` for a cloud environment"
    , "  sync      Write the environment's settings to its sync targets"
    , "  attest    Write the environment attestation now; with --app or --complete, a run's"
    , "  twin      Drive the twin standing in for a dependency through its control plane"
    , ""
    , "Options:"
    , "  -f, --manifest <MANIFEST>          The manifest to read [default: ironframe.yaml]"
    , "  -a, --architecture <ARCHITECTURE>  A CALM 1.2 architecture to read instead of the manifest"
    , "      --decorators <DECORATORS>      The architecture's decorators"
    , "  -h, --help                         Print help"
    , "  -V, --version                      Print version"
    ]

-- Running a verb.

environmentOfCommand :: Command -> Maybe Text
environmentOfCommand = \case
  Schema _ -> Nothing
  Validate _ -> Nothing
  Resolve _ e _ -> Just e
  Export _ e _ _ _ -> Just e
  Run e _ _ _ _ -> Just e
  App _ e _ _ -> Just e
  Settings e _ _ -> Just e
  Compose e -> Just e
  Up e _ _ -> Just e
  Down e -> Just e
  Status e _ -> Just e
  Plan e -> Just e
  Sync e -> Just e
  Attest e _ _ _ _ -> Just e
  TwinCmd _ e _ -> Just e

needsArchitecture :: Command -> Bool
needsArchitecture = \case
  Resolve {} -> True
  Export {} -> True
  Run {} -> True
  App {} -> True
  Settings _ _ (Just _) -> True
  Attest _ _ (Just _) _ _ -> True
  Attest _ _ _ (Just _) _ -> True
  _ -> False

-- | The manifest's directory, made absolute when it can be.
manifestDirOf :: Text -> Eff Text
manifestDirOf path = do
  let parent = case Path.parent path of
        Just p | not (T.null p) -> p
        _ -> "."
  either (const parent) id <$> canonicalize parent

run :: Globals -> Command -> Eff Integer
run globals0 command = case command of
  Schema which -> do
    printOut $ case which of
      SchemaManifest -> Embedded.manifestSchema
      SchemaAttestation -> Embedded.attestationSchema
      SchemaContract -> Embedded.contractDecoratorSchema
      SchemaBinding -> Embedded.bindingDecoratorSchema
      SchemaEnvironment -> Embedded.environmentDecoratorSchema
    pure 0
  _ -> do
    let globals = case command of
          Resolve (Just path) _ _ | isNothing (gArchitecture globals0) -> globals0 {gArchitecture = Just path}
          _ -> globals0
    case (command, gArchitecture globals) of
      (Validate calmCli, Just path) -> validateArchitecture path (gDecorators globals) calmCli
      _ -> do
        (manifest, dir, resolution) <- case gArchitecture globals of
          Just path -> case environmentOfCommand command of
            Nothing -> failWith "this verb reads a manifest; give it --manifest, not --architecture"
            Just environment -> do
              resolution <- loadAndResolve path (gDecorators globals) environment >>= either (failWith . renderCalmError) pure
              pure (resManifest resolution, resDir resolution, Just resolution)
          Nothing -> do
            when (isJust (environmentOfCommand command) && needsArchitecture command) $
              failWith "this verb resolves a CALM architecture; give it --architecture"
            manifest <- loadManifest (gManifest globals) >>= either (failWith . renderManifestError) pure
            dir <- manifestDirOf (gManifest globals)
            pure (manifest, dir, Nothing)
        let calm = maybe (failWith "this verb resolves a CALM architecture; give it --architecture") pure resolution
        verb globals manifest dir calm resolution command

verb :: Globals -> Manifest -> Text -> Eff Resolution -> Maybe Resolution -> Command -> Eff Integer
verb globals manifest dir calm resolution = \case
  Schema _ -> pure 0
  Resolve _ _ output -> do
    r <- calm
    let text = encodePretty (encodeTopology (resTopology r)) <> "\n"
    forM_ output $ \o -> writeFileE o text >>= either (failWith . ioMessage) pure
    printOut text
    pure 0
  Export what environment format app output -> do
    r <- calm
    text <- export r manifest dir environment what format app output
    case (output, what) of
      (Just _, ExportTofu) -> pure ()
      (Just path, _) -> writeFileE path text >>= either (failWith . ioMessage) pure
      (Nothing, _) -> printOut text
    pure 0
  Run _ app runDir attestation command -> do
    r <- calm
    report <- runCommand r app command runDir attestation
    printErr ("ironframe: run " <> A.runId (A.attRun (runAttestation report)) <> " of " <> app <> " exited " <> tshow (runExitCode report) <> "; attestation " <> runPathWritten report <> "\n")
    pure (exitCodeOf (runExitCode report))
  App node _ attestation args -> do
    r <- calm
    report <- runManaged r node args attestation
    printErr ("ironframe: run " <> A.runId (A.attRun (runAttestation report)) <> " of " <> node <> " exited " <> tshow (runExitCode report) <> "; attestation " <> runPathWritten report <> "\n")
    pure (exitCodeOf (runExitCode report))
  Attest _ output (Just app) _ _ -> do
    r <- calm
    running <- begin r app [] Nothing
    path <- writeRun r running output
    printOut ("run " <> A.runId (A.attRun running) <> " of " <> app <> " begun; attestation: " <> path <> "\n")
    pure 0
  Attest _ output Nothing (Just file) code -> do
    r <- calm
    text <- readFileE file >>= either (failWith . ioMessage) pure
    running <- either failWith pure (A.fromJson text)
    completed <- complete r running code
    path <- writeRun r completed (Just (fromMaybe file output))
    printOut ("run " <> A.runId (A.attRun completed) <> " completed with exit code " <> tshow code <> "; attestation: " <> path <> "\n")
    pure 0
  Validate _ -> do
    printOut (Path.display (gManifest globals) <> ": valid; project " <> manifestProject manifest <> ", environments " <> T.intercalate ", " (Map.keys (manifestEnvironments manifest)) <> "\n")
    pure 0
  Settings environment format (Just app) -> do
    r <- calm
    settings <- settingsOf r app
    printOut $ case format of
      FormatEnv -> renderDotenv ("Settings of " <> app <> " in environment " <> environment) settings
      FormatJson -> encodePretty (fromTextMap settings) <> "\n"
    pure 0
  Settings environment format Nothing -> do
    resolved <- resolveIn manifest dir environment >>= either (failWith . renderResolveError) pure
    printOut $ case format of
      FormatEnv -> renderDotenv ("Settings of environment " <> environment <> " of " <> manifestProject manifest) (environmentSettings resolved)
      FormatJson -> encodePretty (fromTextMap (environmentSettings resolved)) <> "\n"
    pure 0
  Compose environment -> do
    declared <- either (failWith . renderManifestError) pure (environmentOf manifest environment)
    when (runtimeIsCloud (envRuntime declared)) $
      failWith ("environment " <> debugStr environment <> " runs on " <> runtimeWord (envRuntime declared) <> "; only a podman environment has a compose file")
    resolved <- resolveIn manifest dir environment >>= either (failWith . renderResolveError) pure
    printOut (composeFile resolved (fmap (\s -> (s, settingsPath (workDir dir environment))) (envConfigService declared)))
    pure 0
  Up environment noSync wait -> do
    report <- up realClouds manifest dir environment (UpOptions (not noSync) wait) (\step -> printErr ("ironframe: " <> step <> "\n"))
    forM_ resolution $ \r -> do
      path <- writeTopology r
      printOut ("topology: " <> path <> "\n")
    forM_ (reDependencies (reportEnvironment report)) $ \d ->
      printOut (padRight 20 (rdName d) <> " " <> padRight 5 (kindWord (rdKind d)) <> " " <> rdEndpoint d <> "\n")
    forM_ (reportSynced report) $ \(target, done) -> printOut ("synced " <> target <> ": " <> renderOutcome done <> "\n")
    printOut ("attestation: " <> reportAttestationPath report <> "\n")
    if null (reportUnreached report)
      then pure 0
      else do
        printErr ("ironframe: no answer from " <> T.intercalate ", " (reportUnreached report) <> "; the attestation records them as not reached\n")
        pure 1
  Down environment -> do
    down manifest dir environment
    printOut ("environment " <> environment <> " is down\n")
    pure 0
  Status environment json -> do
    states <- status manifest dir environment
    if json
      then printOut (encodePretty (Array (map encodeStatus states)) <> "\n")
      else do
        printOut (padRight 20 "DEPENDENCY" <> " " <> padRight 5 "KIND" <> " " <> padRight 14 "STATE" <> " " <> padRight 10 "REACHABLE" <> " ENDPOINT\n")
        forM_ states $ \s ->
          printOut
            ( padRight 20 (statusName s) <> " " <> padRight 5 (statusKind s) <> " " <> padRight 14 (statusState s) <> " "
                <> padRight 10 (if statusReachable s then "yes" else "no")
                <> " "
                <> fromMaybe "-" (statusEndpoint s)
                <> "\n"
            )
    pure 0
  Plan environment -> do
    root <- plan manifest dir environment
    printOut ("planned " <> root <> "\n")
    pure 0
  Sync environment -> do
    resolved <- resolveIn manifest dir environment >>= either (failWith . renderResolveError) pure
    done <- syncEnvironment realClouds manifest dir resolved
    when (null done) $ printOut ("environment " <> environment <> " has no sync targets\n")
    forM_ done $ \(target, result) -> printOut ("synced " <> target <> ": " <> renderOutcome result <> "\n")
    pure 0
  Attest environment output _ _ _ -> do
    (attestation, path) <- attestNow manifest dir environment output
    forM_ (A.attDependencies attestation) $ \d -> do
      let standIn = case A.depStandIn d of
            Nothing -> ""
            Just s ->
              A.standProduct s <> ":" <> A.standVersion s <> " conformance " <> A.standConformance s
                <> maybe "" (\seed -> " seed " <> tshow seed) (A.standSeed s)
                <> maybe "" (" history " <>) (A.standHistoryDigest s)
      printOut
        ( padRight 20 (A.depName d) <> " " <> padRight 8 (if A.depKind d == A.KindReal then "real" else "stand-in") <> " "
            <> padRight 8 (if A.depReached d then "reached" else "unreached")
            <> " "
            <> padRight 24 (A.depEndpoint d)
            <> " "
            <> standIn
            <> "\n"
        )
    printOut ("attestation: " <> path <> "\n")
    pure 0
  TwinCmd dependency environment action -> do
    cp <- controlPlaneFor manifest dir environment dependency
    result <- twin cp action
    case result of
      Right () -> pure 0
      Left (message, code) -> do
        printErr ("ironframe twin " <> dependency <> ": " <> message <> "\n")
        pure (toInteger code)

tshow :: Show a => a -> Text
tshow = T.pack . show

-- | Rust's @{:<n}@: padded with spaces to n characters, never cut.
padRight :: Int -> Text -> Text
padRight n t = t <> T.replicate (n - T.length t) " "

-- | An exit code as the process's own: 0 to 255, anything else 1.
exitCodeOf :: Integer -> Integer
exitCodeOf c = if c >= 0 && c <= 255 then c else 1

-- | Runs one control-plane command and prints the twin's answer.
twin :: ControlPlane -> TwinAction -> Eff (Either (Text, Int) ())
twin cp action = case action of
  Inspect records -> printed (inspect cp records)
  Force state -> do
    text <-
      if state == "-"
        then either (\e -> Left (ioMessage e, 1)) Right <$> readStdin
        else either (\e -> Left (state <> ": " <> ioMessage e, 1)) Right <$> readFileE state
    case text of
      Left e -> pure (Left e)
      Right t -> printed (force cp t)
  FaultCmd "clear" params -> printed (clearFaults cp (case params of (p : _) -> Just p; [] -> Nothing))
  FaultCmd name params -> case parseFault name params of
    Left e -> pure (Left (failure e))
    Right fault -> printed (raise cp fault)
  Faults -> printed (faults cp)
  History since limit array -> do
    r <- history cp since limit array
    case r of
      Left e -> pure (Left (failure e))
      Right body -> do
        if array then printOut (pretty body <> "\n") else printOut body
        pure (Right ())
  Advance d -> printed (advance cp d)
  Seed (Just s) -> printed (setSeed cp s)
  Seed Nothing -> printed ((>>= replyOk) <$> cpRequest cp "GET" "/v1/seed" Nothing)
  Reset -> printed (reset cp)
  Replay file -> do
    body <- case file of
      Nothing -> pure (Right Nothing)
      Just "-" -> either (\e -> Left (ioMessage e, 1)) (Right . Just) <$> readStdin
      Just path -> either (\e -> Left (path <> ": " <> ioMessage e, 1)) (Right . Just) <$> readFileE path
    case body of
      Left e -> pure (Left e)
      Right b -> do
        r <- replay cp b
        case r of
          Left e -> pure (Left (failure e))
          Right answer -> do
            printOut (pretty answer <> "\n")
            let v = either (const Null) id (decode answer)
                diverged = case keyOr "divergences" v of
                  Array d -> not (null d)
                  _ -> True
                broken = or [case keyOr k (keyOr "violations" v) of Array xs -> not (null xs); _ -> True | k <- ["state", "history"]]
            pure (if diverged || broken then Left ("the replay diverged or broke a law", 1) else Right ())
  Laws -> do
    r <- (>>= replyOk) <$> cpRequest cp "GET" "/v1/laws" Nothing
    case r of
      Left e -> pure (Left (failure e))
      Right answer -> do
        printOut (pretty answer <> "\n")
        let v = either (const Null) id (decode answer)
        pure (if keyOr "holds" v == Bool True then Right () else Left ("a law does not hold", 1))
  where
    failure e = (renderTwinError e, twinExitCode e)
    printed request = do
      r <- request
      case r of
        Left e -> pure (Left (failure e))
        Right body -> printOut (pretty body <> "\n") >> pure (Right ())

-- | Checks an architecture and its decorators, resolves every environment
-- they declare, and, when asked, checks the architecture with the CALM CLI.
validateArchitecture :: Text -> Maybe Text -> Bool -> Eff Integer
validateArchitecture path decorators calmCli = do
  architecture <- loadArchitecture path >>= either (failWith . renderCalmError) pure
  let decoratorsPath = fromMaybe (defaultDecorators path) decorators
  decorations <- loadDecorators decoratorsPath >>= either (failWith . renderCalmError) pure
  let environments = nub (sort [e | d <- ofType decorations environmentType, Just e <- [textAt "environment" (decData d)]])
  noEnvironments <-
    if null environments
      then printErr ("ironframe: " <> decoratorsPath <> " declares no environment\n") >> pure True
      else pure False
  failures <- forM environments $ \environment -> do
    r <- loadAndResolve path (Just decoratorsPath) environment
    case r of
      Right resolution -> do
        let kinds = [rnNode d <> " " <> boundWord (rnKind d) | d <- rtDependencies (resTopology resolution)]
        printOut ("environment " <> environment <> ": resolved; " <> T.intercalate ", " kinds <> "\n")
        pure False
      Left e -> do
        printErr ("ironframe: environment " <> environment <> ": " <> renderCalmError e <> "\n")
        pure True
  printOut
    ( path <> ": CALM " <> calmRelease <> " architecture, " <> tshow (length (archNodes architecture)) <> " nodes, "
        <> tshow (length (archRelationships architecture))
        <> " relationships, "
        <> tshow (length (decsItems decorations))
        <> " decorators\n"
    )
  calmFailed <-
    if calmCli
      then do
        calmPath <- locate "IRONFRAME_CALM" ["calm"] [] >>= maybe (failWith "the CALM CLI is not installed; npm install -g @finos/calm-cli, or set IRONFRAME_CALM") pure
        result <- runInherited calmPath ["validate", "--architecture", path, "--format", "pretty"] [] Nothing
        out <- either (failWith . ioMessage) pure result
        printOut ("calm validate: " <> (if procSuccess out then "passed" else "failed") <> "\n")
        pure (not (procSuccess out))
      else pure False
  pure (if noEnvironments || or failures || calmFailed then 1 else 0)

-- | One export of a resolved environment, as text; the OpenTofu root is
-- written to its directory.
export :: Resolution -> Manifest -> Text -> Text -> ExportKind -> Maybe Text -> Maybe Text -> Maybe Text -> Eff Text
export resolution manifest dir environment what format app output = do
  let topology = resTopology resolution
  case what of
    ExportTopology -> pure (encodePretty (encodeTopology topology) <> "\n")
    ExportDiagram -> case fromMaybe "mermaid" format of
      "mermaid" -> pure (mermaid topology)
      "dot" -> pure (dot topology)
      f
        | f `elem` ["calm", "calm-template"] -> do
            let text = encodePretty (annotatedArchitecture (archDocument (resArchitecture resolution)) topology) <> "\n"
            if f == "calm" then pure text else calmTemplate text
      other -> failWith ("no diagram format " <> debugStr other <> "; use mermaid, dot, calm or calm-template")
    ExportSettings -> do
      let w = workDir dir environment
      deployed <- readEndpoints w >>= either (failWith . ((Path.display (endpointsPath w) <> ": ") <>)) pure
      all' <- either (failWith . renderResolveError) pure (applicationSettings resolution deployed)
      let one a = maybe (failWith ("no application node " <> debugStr a)) pure (Map.lookup a all')
      case (app, fromMaybe (if isJust app then "env" else "json") format) of
        (Just a, "env") -> renderDotenv ("Settings of " <> a <> " in environment " <> environment <> " of " <> rtProject topology) <$> one a
        (Just a, "json") -> (\s -> encodePretty (fromTextMap s) <> "\n") <$> one a
        (Nothing, "json") -> pure (encodePretty (Object [(k, fromTextMap v) | (k, v) <- Map.toAscList all']) <> "\n")
        (Nothing, _) -> failWith "dotenv settings are one application's; give --app"
        (_, other) -> failWith ("no settings format " <> debugStr other <> "; use env or json")
    ExportTofu -> do
      root <- either (failWith . renderTofuError) pure (rootModule manifest environment dir)
      let text = encodePretty root <> "\n"
      forM_ output $ \o -> do
        createDirE o >>= either (failWith . ioMessage) pure
        writeFileE (Path.join o "main.tf.json") text >>= either (failWith . ioMessage) pure
        printErr ("ironframe: wrote " <> Path.join o "main.tf.json" <> "\n")
      pure text
    ExportCompose -> do
      resolved <- resolveIn manifest dir environment >>= either (failWith . renderResolveError) pure
      declared <- either (failWith . renderManifestError) pure (environmentOf manifest environment)
      pure (composeFile resolved (fmap (\s -> (s, settingsPath (workDir dir environment))) (envConfigService declared)))

-- | Renders an annotated architecture with the CALM CLI's block-architecture
-- widget, through @calm docify@ with a one-line template.
calmTemplate :: Text -> Eff Text
calmTemplate annotated = do
  calmPath <- locate "IRONFRAME_CALM" ["calm"] [] >>= maybe (failWith "the CALM CLI is not installed; npm install -g @finos/calm-cli, or set IRONFRAME_CALM") pure
  tmp <- tempDir
  pid <- processId
  let scratch = Path.join tmp ("ironframe-calm-" <> tshow pid)
      architecture = Path.join scratch "architecture.json"
      template = Path.join scratch "diagram.md"
      output = Path.join scratch "out.md"
      orFail a = a >>= either (failWith . ioMessage) pure
  orFail (createDirE scratch)
  orFail (writeFileE architecture annotated)
  orFail (writeFileE template calmDiagramTemplate)
  result <- runProcess calmPath ["docify", "--architecture", architecture, "--template", template, "--output", output] False
  out <- either (failWith . ioMessage) pure result
  unless (procSuccess out) $ failWith ("calm docify failed: " <> T.strip (procStderr out))
  text <- orFail (readFileE output)
  _ <- removeTree scratch
  pure text
