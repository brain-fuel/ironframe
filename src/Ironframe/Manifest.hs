-- | The manifest, @ironframe.yaml@. A manifest is read in two passes, the JSON
-- Schema for its shape and then the rules across fields, and every problem of
-- a pass is reported at once with the path of the field at fault.
-- ref:DEC-manifest-shape
module Ironframe.Manifest
  ( module Ironframe.Manifest.Types
  , Problem (..)
  , ManifestError (..)
  , renderProblem
  , renderManifestError
  , supportedVersion
  , defaultManifest
  , placeholderNames
  , credentialSchemes
  , twinConfigVariable
  , unrated
  , parseManifest
  , loadManifest
  , readReports
  , environmentOf
  , manifestProblems
  , reportProblems
  , placeholders
  , isName
  , isSettingKey
  , runtimeIsCloud
  , runtimeModule
  , providerInputs
  , moduleInputs
  , requiredInputs
  , inputsOfModule
  , twinImageRef
  , twinProtocolOrDefault
  , twinConfigJson
  , conformanceLevel
  , conformanceDeclared
  , conformanceReport
  , conformanceImageLabel
  , parseReport
  , reportMatches
  , reportDescribe
  , adminHostPort
  , adminUrlOn
  , problemAt
  ) where

import Control.Monad (forM)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit, toLower)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Ironframe.Effect
import qualified Ironframe.Embedded as Embedded
import Ironframe.Json
import qualified Ironframe.Json.Schema as Schema
import Ironframe.Manifest.Serde (decodeManifest)
import Ironframe.Manifest.Types
import qualified Ironframe.Path as Path
import Ironframe.Rust (debugStr)
import Ironframe.Yaml (decodeYaml)

-- | The one manifest version this release reads.
supportedVersion :: Integer
supportedVersion = 1

-- | The file name Ironframe looks for when no manifest is named.
defaultManifest :: Text
defaultManifest = "ironframe.yaml"

-- | The placeholders a settings template may use.
placeholderNames :: [Text]
placeholderNames = ["endpoint", "host", "port", "credentials", "kind", "name"]

-- | The schemes a credentials reference may use.
credentialSchemes :: [Text]
credentialSchemes = ["env", "file", "aws-secretsmanager", "gcp-secretmanager", "azure-keyvault", "vault"]

-- | The environment variable a twin's @config@ reaches it through.
twinConfigVariable :: Text
twinConfigVariable = "TWIN_CONFIG"

-- | The level recorded for a twin whose level nothing declares.
unrated :: Text
unrated = "unrated"

-- | One thing wrong with a manifest: the dotted path of the field, empty for
-- the whole document, and what is wrong with it.
data Problem = Problem {problemPath :: Text, problemMessage :: Text}
  deriving (Show, Eq)

problemAt :: Text -> Text -> Problem
problemAt = Problem

renderProblem :: Problem -> Text
renderProblem (Problem at msg)
  | T.null at = msg
  | otherwise = at <> ": " <> msg

-- | Why a manifest could not be used: the file, and every problem in it.
data ManifestError = ManifestError {errorOrigin :: Maybe Text, errorProblems :: [Problem]}
  deriving (Show, Eq)

renderManifestError :: ManifestError -> Text
renderManifestError (ManifestError origin problems) =
  let name = fromMaybe "manifest" origin
   in case problems of
        [one] -> name <> ": " <> renderProblem one
        many ->
          name <> ": " <> tshow (length many) <> " problems"
            <> T.concat ["\n  - " <> renderProblem p | p <- many]

tshow :: Show a => a -> Text
tshow = T.pack . show

-- Runtime facts.

runtimeIsCloud :: Runtime -> Bool
runtimeIsCloud = (/= Podman)

-- | The module under @modules/@ that runs a twin serving @protocol@ on the runtime.
runtimeModule :: Runtime -> Protocol -> Maybe Text
runtimeModule runtime protocol = case (runtime, protocol) of
  (Podman, _) -> Nothing
  (Aws, _) -> Just "aws-ecs-fargate"
  (Gcp, Http) -> Just "gcp-cloud-run"
  (Gcp, Tcp) -> Just "gcp-compute-engine"
  (Azure, _) -> Just "azure-container-apps"

providerInputs :: Runtime -> [Text]
providerInputs = \case
  Podman -> []
  Aws -> ["region"]
  Gcp -> ["project", "region"]
  Azure -> ["subscription_id"]

moduleInputs :: Runtime -> [Text]
moduleInputs runtime =
  foldl
    (\acc input -> if input `elem` acc then acc else acc ++ [input])
    []
    (concat [inputsOfModule m | Just m <- [runtimeModule runtime Tcp, runtimeModule runtime Http]])

requiredInputs :: Runtime -> [Text]
requiredInputs = \case
  Podman -> []
  Aws -> ["region", "vpc_id", "subnet_ids"]
  Gcp -> ["project", "region"]
  Azure -> ["location", "resource_group_name"]

-- | The inputs one module takes from @cloud@.
inputsOfModule :: Text -> [Text]
inputsOfModule = \case
  "aws-ecs-fargate" -> ["vpc_id", "subnet_ids", "cpu", "memory", "assign_public_ip", "allowed_cidr_blocks", "internal"]
  "gcp-cloud-run" -> ["project", "region", "cpu", "memory", "public"]
  "gcp-compute-engine" -> ["project", "region", "zone", "machine_type", "network", "subnetwork", "allowed_cidr_blocks", "public"]
  "azure-container-apps" -> ["location", "resource_group_name", "cpu", "memory", "infrastructure_subnet_id", "transport", "external"]
  _ -> []

-- Twins.

twinImageRef :: Twin -> Text
twinImageRef t = twinImage t <> ":" <> twinVersion t

twinProtocolOrDefault :: Twin -> Protocol
twinProtocolOrDefault = fromMaybe Http . twinProtocol

-- | The JSON handed to the twin in @TWIN_CONFIG@: @config@ with @seed@ and
-- @contract@ set.
twinConfigJson :: Twin -> Value
twinConfigJson t =
  let base = case twinConfig t of
        Just o@(Object _) -> o
        _ -> Object []
      withSeed = maybe base (\s -> insert "seed" (Number (I s)) base) (twinSeed t)
   in maybe withSeed (\c -> insert "contract" (String c) withSeed) (twinContract t)

-- | The conformance level to record: the report's, else the declared one,
-- else @unrated@.
conformanceLevel :: Twin -> Text
conformanceLevel t = case twinReport t of
  Just r -> reportLevel r
  Nothing -> fromMaybe unrated (conformanceDeclared (twinConformance t))

conformanceDeclared :: Conformance -> Maybe Text
conformanceDeclared = \case
  Level l -> Just l
  Sourced s -> sourceLevel s

conformanceReport :: Conformance -> Maybe Text
conformanceReport = \case
  Level _ -> Nothing
  Sourced s -> sourceReport s

conformanceImageLabel :: Conformance -> Maybe Text
conformanceImageLabel = \case
  Level _ -> Nothing
  Sourced s -> sourceImageLabel s

-- | Reads a conformance report from its JSON.
parseReport :: Text -> Either Text ConformanceReport
parseReport text = do
  value <- either (Left . ("not JSON: " <>)) Right (decode text)
  (level, number) <- case keyOr "level" value of
    String name -> Right (name, Nothing)
    o@(Object _) -> case keyOr "name" o of
      String name -> Right (name, asU64 (keyOr "number" o))
      _ -> Left "level has no name"
    _ -> Left "the report has no level"
  if T.null (T.strip level)
    then Left "the report's level is empty"
    else
      Right
        ConformanceReport
          { reportLevel = level
          , reportNumber = number
          , reportRelease = textOf (keyOr "release" value)
          , reportTwin = textOf (keyOr "twin" value)
          , reportContract = case textOf (keyOr "contract" value) of
              Just c -> Just c
              Nothing -> textOf (keyOr "package" (keyOr "contract" value))
          }
  where
    textOf (String t) = Just t
    textOf _ = Nothing
    asU64 (Number (I n)) | n >= 0 = Just n
    asU64 _ = Nothing

-- | Whether a declared level names the report's level: its name ignoring
-- case, its number, or @<number>-<name>@.
reportMatches :: ConformanceReport -> Text -> Bool
reportMatches r declared0 =
  let declared = asciiLower (T.strip declared0)
      name = asciiLower (reportLevel r)
   in declared == name
        || maybe False (\n -> declared == tshow n || declared == tshow n <> "-" <> name) (reportNumber r)

asciiLower :: Text -> Text
asciiLower = T.map (\c -> if isAsciiUpper c then toLower c else c)

reportDescribe :: ConformanceReport -> Text
reportDescribe r = case reportNumber r of
  Just n -> "level " <> tshow n <> " (" <> reportLevel r <> ")"
  Nothing -> "level " <> reportLevel r

adminHostPort :: Admin -> Integer
adminHostPort a = fromMaybe (adminContainerPort a) (adminPort a)

-- | The control plane's URL in an environment on the runtime, if it has one.
adminUrlOn :: Admin -> Runtime -> Maybe Text
adminUrlOn a runtime = case (adminUrl a, runtime) of
  (Just url, _) -> Just (T.dropWhileEnd (== '/') url)
  (Nothing, Podman) -> Just ("http://127.0.0.1:" <> tshow (adminHostPort a))
  (Nothing, _) -> Nothing

-- Reading.

-- | Reads and checks a manifest from YAML text: its shape against the JSON
-- Schema, then the rules across fields.
parseManifest :: Text -> Either ManifestError Manifest
parseManifest text = do
  let failed ps = Left (ManifestError Nothing ps)
  value <- either (\e -> failed [Problem "" ("not valid YAML: " <> e)]) Right (decodeYaml text)
  let shape = schemaProblems value
  if not (null shape) then failed shape else Right ()
  manifest <- either (\e -> failed [Problem "" e]) Right (decodeManifest value)
  case manifestProblems manifest of
    [] -> Right manifest
    rules -> failed rules

manifestSchema :: Schema.Schema
manifestSchema = case decode Embedded.manifestSchema >>= Schema.compile [] of
  Right s -> s
  Left e -> error ("the embedded manifest schema does not compile: " <> T.unpack e)

schemaProblems :: Value -> [Problem]
schemaProblems value = dedupe [Problem (dotted (Schema.errorInstancePath e)) (Schema.errorMessage e) | e <- Schema.validate manifestSchema value]
  where
    dotted pointer =
      T.intercalate "." [T.replace "~0" "~" (T.replace "~1" "/" s) | s <- T.splitOn "/" (T.dropWhile (== '/') pointer), not (T.null s)]

dedupe :: [Problem] -> [Problem]
dedupe = go Set.empty
  where
    go _ [] = []
    go seen (p : ps)
      | renderProblem p `Set.member` seen = go seen ps
      | otherwise = p : go (Set.insert (renderProblem p) seen) ps

-- | Reads and checks the manifest at a path, and the conformance reports its
-- twins name, relative to its directory.
loadManifest :: Text -> Eff (Either ManifestError Manifest)
loadManifest path = do
  read' <- readFileE path
  case read' of
    Left e -> pure (Left (ManifestError (Just path) [Problem "" ("cannot read the manifest: " <> ioMessage e)]))
    Right text -> case parseManifest text of
      Left e -> pure (Left e {errorOrigin = Just path})
      Right manifest -> do
        let dir = case Path.parent path of
              Just p | not (T.null p) -> p
              _ -> "."
        (problems, manifest') <- readReports dir manifest
        pure $ if null problems then Right manifest' else Left (ManifestError (Just path) problems)

-- | Reads the conformance report of every twin that names one, and checks it
-- against the twin.
readReports :: Text -> Manifest -> Eff ([Problem], Manifest)
readReports dir manifest = do
  envs <- forM (Map.toAscList (manifestEnvironments manifest)) $ \(name, environment) -> do
    deps <- forM (Map.toAscList (envDependencies environment)) $ \(dependency, binding) -> case binding of
      BindTwin twin | Just relative <- conformanceReport (twinConformance twin) -> do
        let at = "environments." <> name <> ".dependencies." <> dependency <> ".twin.conformance.report"
        text <- readFileE (Path.join dir relative)
        let report = case text of
              Right t -> parseReport t
              Left e -> Left ("cannot read it: " <> ioMessage e)
        pure $ case report of
          Left reason -> ([Problem at (Path.display relative <> ": " <> reason)], (dependency, binding))
          Right r -> (reportProblems at twin r, (dependency, BindTwin twin {twinReport = Just r}))
      _ -> pure ([], (dependency, binding))
    pure (concatMap fst deps, (name, environment {envDependencies = Map.fromList (map snd deps)}))
  pure (concatMap fst envs, manifest {manifestEnvironments = Map.fromList (map snd envs)})

-- | The environment named, or an error naming the ones there are.
environmentOf :: Manifest -> Text -> Either ManifestError Environment
environmentOf manifest name = case Map.lookup name (manifestEnvironments manifest) of
  Just e -> Right e
  Nothing ->
    Left
      ( ManifestError
          Nothing
          [ Problem
              ""
              ( "no environment named " <> debugStr name <> "; the manifest has "
                  <> T.intercalate ", " (map debugStr (Map.keys (manifestEnvironments manifest)))
              )
          ]
      )

-- Rules across fields.

nameRule :: Text
nameRule = "a name is lowercase letters, digits, - and _, starting with a letter, at most 40 characters"

-- | Every rule across fields the manifest breaks.
manifestProblems :: Manifest -> [Problem]
manifestProblems m =
  versionProblems ++ projectProblems ++ dependencyProblems ++ environmentsEmpty
    ++ concat [environmentProblems m name e | (name, e) <- Map.toAscList (manifestEnvironments m)]
  where
    versionProblems =
      [ Problem "version" ("version " <> tshow (manifestVersion m) <> " is not supported; use " <> tshow supportedVersion)
      | manifestVersion m /= supportedVersion
      ]
    projectProblems = [Problem "project" nameRule | not (isName (manifestProject m))]
    dependencyProblems = goDeps Map.empty (Map.toAscList (manifestDependencies m))
    goDeps _ [] = []
    goDeps owners ((dependency, declaration) : rest) =
      let at = "dependencies." <> dependency
          (found, owners') = settingsProblems at dependency owners (Map.toAscList (declSettings declaration))
       in [Problem at nameRule | not (isName dependency)]
            ++ [Problem (at <> ".settings") "declare at least one setting the application reads" | Map.null (declSettings declaration)]
            ++ found
            ++ goDeps owners' rest
    settingsProblems _ _ owners [] = ([], owners)
    settingsProblems at dependency owners ((k, template) : rest) =
      let here = at <> ".settings." <> k
          keyProblem =
            [ Problem here "a setting name is an environment variable name: letters, digits and _, not starting with a digit"
            | not (isSettingKey k)
            ]
          (ownerProblem, owners') = case Map.lookup k owners of
            Just other -> ([Problem here ("setting " <> k <> " is also declared by dependency " <> debugStr other)], Map.insert k dependency owners)
            Nothing -> ([], Map.insert k dependency owners)
          templateProblems = case placeholders template of
            Right names ->
              [ Problem here ("unknown placeholder ${" <> n <> "}; use one of " <> placeholderList)
              | n <- names
              , n `notElem` placeholderNames
              ]
            Left msg -> [Problem here msg]
          (more, owners'') = settingsProblems at dependency owners' rest
       in (keyProblem ++ ownerProblem ++ templateProblems ++ more, owners'')
    environmentsEmpty = [Problem "environments" "declare at least one environment" | Map.null (manifestEnvironments m)]

placeholderList :: Text
placeholderList = T.intercalate ", " ["${" <> p <> "}" | p <- placeholderNames]

environmentProblems :: Manifest -> Text -> Environment -> [Problem]
environmentProblems m name environment =
  [Problem at nameRule | not (isName name)]
    ++ [ Problem (at <> ".dependencies") ("dependency " <> debugStr missing <> " is declared but not bound; bind it to `real` or `twin`")
       | missing <- Map.keys (manifestDependencies m)
       , not (Map.member missing (envDependencies environment))
       ]
    ++ cloudProblems
    ++ [ Problem (at <> ".config_service") "the configuration service runs on podman; a cloud environment's settings reach its applications through `sync`"
       | isJust (envConfigService environment) && runtimeIsCloud runtime
       ]
    ++ servicePortProblems
    ++ bindingProblems initialPublished (Map.toAscList (envDependencies environment))
    ++ syncProblems
  where
    at = "environments." <> name
    runtime = envRuntime environment
    cloudProblems = case (envCloud environment, runtimeIsCloud runtime) of
      (Just _, False) -> [Problem (at <> ".cloud") "only a cloud runtime takes `cloud` inputs"]
      (Nothing, True) ->
        [Problem (at <> ".cloud") ("runtime " <> runtimeWord runtime <> " needs `cloud` with " <> T.intercalate ", " (requiredInputs runtime))]
      (Just cloud, True) ->
        [ Problem (at <> ".cloud." <> input) ("runtime " <> runtimeWord runtime <> " needs " <> input)
        | input <- requiredInputs runtime
        , not (Map.member input (cloudInputs cloud))
        ]
          ++ [ Problem
                (at <> ".cloud." <> input)
                ( "runtime " <> runtimeWord runtime <> " takes no input " <> debugStr input <> "; it takes modules, "
                    <> T.intercalate ", " allInputs
                )
             | input <- Map.keys (cloudInputs cloud)
             , input `notElem` providerInputs runtime && input `notElem` moduleInputs runtime
             ]
      (Nothing, False) -> []
    allInputs = foldl (\acc i -> if i `elem` acc then acc else acc ++ [i]) (providerInputs runtime) (moduleInputs runtime)
    initialPublished = case envConfigService environment of
      Just service -> Map.singleton (configServicePort service) "the configuration service"
      Nothing -> Map.empty
    servicePortProblems = case envConfigService environment of
      Just service | configServicePort service == 0 -> [Problem (at <> ".config_service.port") "a port is between 1 and 65535"]
      _ -> []
    bindingProblems _ [] = []
    bindingProblems published ((dependency, binding) : rest) =
      let here = at <> ".dependencies." <> dependency
       in case Map.lookup dependency (manifestDependencies m) of
            Nothing ->
              Problem here ("dependency " <> debugStr dependency <> " is not declared under the top-level `dependencies`")
                : bindingProblems published rest
            Just declaration ->
              let usesCredentials = any (T.isInfixOf "${credentials}") (Map.elems (declSettings declaration))
                  (own, ports, runsImage) = case binding of
                    BindReal real -> (realProblems (here <> ".real") real usesCredentials, realPorts real, isJust (realImage real))
                    BindTwin twin ->
                      let twinAt = here <> ".twin"
                          extra = case twinAdmin twin of
                            Just admin | runtime == Podman && isNothing (adminUrl admin) -> [adminHostPort admin]
                            _ -> []
                       in (twinBindingProblems twinAt twin usesCredentials, twinPorts twin ++ extra, True)
                  (portProblems, published') = publish here dependency runsImage published ports
               in own ++ portProblems ++ bindingProblems published' rest
    publish _ _ _ published [] = ([], published)
    publish here dependency runsImage published (port : ports)
      | port == 0 =
          let (more, p') = publish here dependency runsImage published ports
           in (Problem (here <> ".ports") "a port is between 1 and 65535" : more, p')
      | runtime == Podman && runsImage =
          let label = "dependency " <> debugStr dependency
              (clash, p1) = case Map.lookup port published of
                Just other -> ([Problem (here <> ".ports") ("port " <> tshow port <> " is already published by " <> other <> " in this environment")], Map.insert port label published)
                Nothing -> ([], Map.insert port label published)
              (more, p2) = publish here dependency runsImage p1 ports
           in (clash ++ more, p2)
      | otherwise = publish here dependency runsImage published ports
    realProblems here real usesCredentials =
      [Problem (here <> ".endpoint") "the endpoint must not be empty" | T.null (T.strip (realEndpoint real))]
        ++ credentialsProblems here (realCredentials real) usesCredentials
        ++ case realImage real of
          Just image ->
            [ Problem (here <> ".image") "a real dependency runs from an image only on podman; in a cloud it is hosted and named by its endpoint"
            | runtimeIsCloud runtime
            ]
              ++ [Problem (here <> ".image") "the image must not be empty" | T.null (T.strip image)]
              ++ [Problem (here <> ".ports") "an image run locally needs the ports to publish" | null (realPorts real)]
          Nothing -> [Problem here "`ports` and `env` apply only with `image`" | not (null (realPorts real)) || not (Map.null (realEnv real))]
    twinBindingProblems here twin usesCredentials =
      ( if T.null (T.strip (twinImage twin))
          then [Problem (here <> ".image") "the image must not be empty"]
          else
            [ Problem (here <> ".image") "name the image without a tag or digest; the twin's `version` is its tag"
            | hasTag (twinImage twin)
            ]
      )
        ++ [Problem (here <> ".version") "the version must not be empty" | T.null (T.strip (twinVersion twin))]
        ++ twinProblems here twin runtime
        ++ credentialsProblems here (twinCredentials twin) usesCredentials
    syncProblems = concat (zipWith syncTargetProblems [0 :: Int ..] (envSync environment))
    syncTargetProblems index target =
      let here = at <> ".sync[" <> tshow index <> "]"
          required = case target of
            SyncEnvFile t -> [("env_file.path", envFilePath t)]
            SyncAws t -> [("aws_appconfig.region", awsRegion t), ("aws_appconfig.application", awsApplication t), ("aws_appconfig.profile", awsProfile t)]
            SyncGcp t -> [("gcp_parameter_manager.project", gcpProject t), ("gcp_parameter_manager.location", gcpLocation t), ("gcp_parameter_manager.parameter", gcpParameter t)]
            SyncAzure t -> [("azure_app_configuration.endpoint", azureEndpoint t), ("azure_app_configuration.connection_string_env", azureConnectionStringEnv t)]
       in [Problem (here <> "." <> field) "must not be empty" | (field, v) <- required, T.null (T.strip v)]
            ++ case target of
              SyncAzure t
                | not ("https://" `T.isPrefixOf` azureEndpoint t) ->
                    [Problem (here <> ".azure_app_configuration.endpoint") "the endpoint is an https:// URL"]
              _ -> []

-- | How a twin disagrees with its conformance report.
reportProblems :: Text -> Twin -> ConformanceReport -> [Problem]
reportProblems at twin report =
  [ Problem at ("the twin declares conformance " <> debugStr declared <> ", but its report gives " <> reportDescribe report)
  | Just declared <- [conformanceDeclared (twinConformance twin)]
  , not (reportMatches report declared)
  ]
    ++ [ Problem at ("the report is for release " <> release <> ", but the twin is version " <> twinVersion twin)
       | Just release <- [reportRelease report]
       , release /= twinVersion twin
       ]
    ++ [ Problem at ("the report is for the " <> name <> " twin, but the image is " <> twinImage twin)
       | Just name <- [reportTwin report]
       , let image = last (T.splitOn "/" (twinImage twin))
       , image /= name
       ]
    ++ [ Problem at ("the report checked contract " <> package <> ", but the twin serves " <> contract)
       | Just contract <- [twinContract twin]
       , Just package <- [reportContract report]
       , package /= contract
       , not (("." <> contract) `T.isSuffixOf` package)
       ]

twinProblems :: Text -> Twin -> Runtime -> [Problem]
twinProblems at twin runtime =
  conformanceProblems
    ++ [Problem (at <> ".ports") "a twin serves at least one port" | null (twinPorts twin)]
    ++ [ Problem (at <> ".ports") "Cloud Run serves one port per service; a twin serving more is `protocol: tcp`, run on Compute Engine"
       | runtime == Gcp && twinProtocolOrDefault twin == Http && length (twinPorts twin) > 1
       ]
    ++ configProblems
    ++ [Problem (at <> ".env." <> twinConfigVariable) "TWIN_CONFIG is written from `config`; set the configuration there" | Map.member twinConfigVariable (twinEnv twin)]
    ++ [Problem (at <> ".contract") "the contract must not be empty" | maybe False (T.null . T.strip) (twinContract twin)]
    ++ adminProblems
    ++ [needsAdmin "state" | isJust (twinState twin), isNothing adminUrl']
    ++ stateShape
    ++ [needsAdmin "faults" | not (null (twinFaults twin)), isNothing adminUrl']
    ++ concat (zipWith faultProblems [0 :: Int ..] (twinFaults twin))
    ++ advertiseProblems
  where
    conformanceProblems = case twinConformance twin of
      Level l | T.null (T.strip l) -> [Problem (at <> ".conformance") "declare the release's conformance level"]
      Level _ -> []
      Sourced s ->
        [ Problem (at <> ".conformance") "give the level, the report to read it from, or the image label that holds it"
        | isNothing (sourceLevel s) && isNothing (sourceReport s) && isNothing (sourceImageLabel s)
        ]
          ++ [Problem (at <> ".conformance.level") "the level must not be empty" | maybe False (T.null . T.strip) (sourceLevel s)]
          ++ [Problem (at <> ".conformance.image_label") "the label must not be empty" | maybe False (T.null . T.strip) (sourceImageLabel s)]
    configProblems = case twinConfig twin of
      Nothing -> []
      Just config ->
        [Problem (at <> ".config") "the twin's config is a mapping" | not (isObject config)]
          ++ [ Problem
                (at <> ".config." <> k)
                ("config." <> k <> " is " <> encode inConfig <> " but the twin's " <> k <> " is " <> encode given <> "; give it once")
             | (k, Just given) <- [("seed", Number . I <$> twinSeed twin), ("contract", String <$> twinContract twin)]
             , Just inConfig <- [key k config]
             , given /= inConfig
             ]
    adminUrl' = twinAdmin twin >>= \a -> adminUrlOn a runtime
    adminProblems = case twinAdmin twin of
      Nothing -> []
      Just admin ->
        [Problem (at <> ".admin") "a port is between 1 and 65535" | adminContainerPort admin == 0 || adminPort admin == Just 0]
          ++ [ Problem (at <> ".admin.url") "a cloud twin's control plane is not published; give the URL it is reached at"
             | runtimeIsCloud runtime && isNothing (adminUrl admin)
             ]
          ++ [ Problem (at <> ".admin.url") "the control plane's URL is http:// or https://"
             | Just url <- [adminUrl admin]
             , not ("http://" `T.isPrefixOf` url || "https://" `T.isPrefixOf` url)
             ]
          ++ [ Problem (at <> ".ports") ("port " <> tshow (adminContainerPort admin) <> " is the control plane's; it is published through `admin`")
             | runtime == Podman && isNothing (adminUrl admin) && adminContainerPort admin `elem` twinPorts twin
             ]
    needsAdmin what = Problem (at <> "." <> what) "applied through the twin's control plane, so the twin needs `admin`"
    stateShape = case twinState twin of
      Just state
        | not (isObject state || isPath state) ->
            [Problem (at <> ".state") "a state is a mapping, or the path of a JSON file"]
      _ -> []
    isPath (String p) = not (T.null (T.strip p))
    isPath _ = False
    faultProblems index fault =
      [Problem (at <> ".faults[" <> tshow index <> "].name") "the fault's name must not be empty" | T.null (T.strip (faultName fault))]
        ++ [ Problem (at <> ".faults[" <> tshow index <> "].params." <> n) "a fault's parameter is a string or a whole number"
           | (n, v) <- Map.toAscList (faultParams fault)
           , not (isStringOrInteger v)
           ]
    isStringOrInteger = \case
      String _ -> True
      Number (I _) -> True
      _ -> False
    advertiseProblems = case twinAdvertiseVariable twin of
      Nothing -> []
      Just variable ->
        [Problem (at <> ".advertise_variable") "an environment variable name" | not (isSettingKey variable)]
          ++ [Problem (at <> ".env." <> variable) "this variable is set from the endpoint through `advertise_variable`" | Map.member variable (twinEnv twin)]
          ++ [ Problem
                (at <> ".advertise_variable")
                ( "the address a twin advertises is set on podman and on GCP Compute Engine (`protocol: tcp`); on "
                    <> runtimeWord runtime
                    <> " pin it in `config` or `env`"
                )
             | not (runtime == Podman || (runtime == Gcp && twinProtocolOrDefault twin == Tcp))
             ]

credentialsProblems :: Text -> Maybe Text -> Bool -> [Problem]
credentialsProblems at credentials used = case credentials of
  Just reference ->
    let ok = case T.breakOn ":" reference of
          (scheme, rest) -> T.length rest > 1 && scheme `elem` credentialSchemes
     in [ Problem
            (at <> ".credentials")
            ( "a credentials reference is <scheme>:<location> with scheme one of "
                <> T.intercalate ", " credentialSchemes
                <> "; Ironframe never holds the secret itself"
            )
        | not ok
        ]
  Nothing
    | used -> [Problem (at <> ".credentials") "the dependency's settings use ${credentials}, so this binding must name a credentials reference"]
    | otherwise -> []

-- | Whether a name may be a project, environment or dependency name.
isName :: Text -> Bool
isName name = case T.uncons name of
  Just (c, rest) ->
    isAsciiLower c && T.length name <= 40 && T.all (\x -> isAsciiLower x || isDigit x || x == '-' || x == '_') rest
  Nothing -> False

isSettingKey :: Text -> Bool
isSettingKey k = case T.uncons k of
  Just (c, rest) -> (isAsciiAlpha c || c == '_') && T.all (\x -> isAsciiAlpha x || isDigit x || x == '_') rest
  Nothing -> False
  where
    isAsciiAlpha x = isAsciiLower x || isAsciiUpper x

hasTag :: Text -> Bool
hasTag image = "@" `T.isInfixOf` image || ":" `T.isInfixOf` last (T.splitOn "/" image)

-- | The placeholder names a template uses, in order, or why it is malformed.
placeholders :: Text -> Either Text [Text]
placeholders template = go template
  where
    go rest = case T.breakOn "${" rest of
      (_, "") -> Right []
      (_, found) ->
        let after = T.drop 2 found
         in case T.breakOn "}" after of
              (_, "") -> Left ("unclosed placeholder in " <> debugStr template)
              (name, close) -> (name :) <$> go (T.drop 1 close)
