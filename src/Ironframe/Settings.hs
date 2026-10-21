-- | An environment resolved: each dependency's endpoint, the image to run for
-- it if any, and the settings the application reads, rendered from the
-- manifest's templates. Compose, OpenTofu, the configuration service, every
-- sync target and the attestation work from this one resolution.
-- ref:DEC-manifest-shape
module Ironframe.Settings
  ( BindingKind (..)
  , kindWord
  , ResolvedDependency (..)
  , ResolvedEnvironment (..)
  , environmentSettings
  , stackName
  , ResolveError (..)
  , renderResolveError
  , resolve
  , splitEndpoint
  , qualifyImage
  , SettingsDocument (..)
  , emptyDocument
  , insertEnvironment
  , encodeDocument
  , decodeDocument
  , renderDotenv
  , parseDotenv
  ) where

import Data.Char (isAlphaNum, isAscii, isDigit)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Ironframe.Attestation (StandIn (..), emptyStandIn)
import Ironframe.Json
import Ironframe.Json.Serde
import Ironframe.Manifest
import Ironframe.Rust (debugStr)

data BindingKind = KindRealBinding | KindTwinBinding
  deriving (Show, Eq)

kindWord :: BindingKind -> Text
kindWord KindRealBinding = "real"
kindWord KindTwinBinding = "twin"

data ResolvedDependency = ResolvedDependency
  { rdName :: Text
  , rdKind :: BindingKind
  , rdEndpoint :: Text
  , rdImage :: Maybe Text
  , rdPorts :: [Integer]
  , rdContainerEnv :: Map Text Text
  , rdStandIn :: Maybe StandIn
  , rdCredentials :: Maybe Text
  , rdSettings :: Map Text Text
  , rdAdminUrl :: Maybe Text
  , rdAdminPort :: Maybe (Integer, Integer)
  , rdTwin :: Maybe Twin
  }
  deriving (Show, Eq)

data ResolvedEnvironment = ResolvedEnvironment
  { reProject :: Text
  , reEnvironment :: Text
  , reRuntime :: Runtime
  , reDependencies :: [ResolvedDependency]
  }
  deriving (Show, Eq)

-- | Every setting of every dependency, which is what the application reads.
environmentSettings :: ResolvedEnvironment -> Map Text Text
environmentSettings = Map.unions . reverse . map rdSettings . reDependencies

-- | The name every container, compose project and cloud resource starts with.
stackName :: ResolvedEnvironment -> Text
stackName e = "ironframe-" <> reProject e <> "-" <> reEnvironment e

data ResolveError
  = ResolveManifest ManifestError
  | NotDeployed Text Text
  | MissingPart Text Text Text Text
  deriving (Show, Eq)

renderResolveError :: ResolveError -> Text
renderResolveError = \case
  ResolveManifest e -> renderManifestError e
  NotDeployed environment dependency ->
    "the endpoint of " <> debugStr dependency <> " in environment " <> debugStr environment
      <> " is known once the twin is deployed; run `ironframe up "
      <> environment
      <> "` first, or pin it with twin.endpoint"
  MissingPart dependency k placeholder endpoint ->
    "setting " <> k <> " of " <> debugStr dependency <> " uses ${" <> placeholder <> "}, but endpoint " <> debugStr endpoint <> " has none"

-- | Resolves an environment of a checked manifest. @deployed@ holds the
-- endpoints a cloud deployment reported.
resolve :: Manifest -> Text -> Map Text Text -> Either ResolveError ResolvedEnvironment
resolve manifest name deployed = do
  environment <- either (Left . ResolveManifest) Right (environmentOf manifest name)
  let runtime = envRuntime environment
  dependencies <- mapM (one environment runtime) (Map.toAscList (envDependencies environment))
  pure (ResolvedEnvironment (manifestProject manifest) name runtime dependencies)
  where
    one environment runtime (dependency, binding) = do
      let declaration = manifestDependencies manifest Map.! dependency
      resolved <- case binding of
        BindReal real ->
          Right
            ResolvedDependency
              { rdName = dependency
              , rdKind = KindRealBinding
              , rdEndpoint = realEndpoint real
              , rdImage = qualifyImage <$> realImage real
              , rdPorts = realPorts real
              , rdContainerEnv = realEnv real
              , rdStandIn = Nothing
              , rdCredentials = realCredentials real
              , rdSettings = Map.empty
              , rdAdminUrl = Nothing
              , rdAdminPort = Nothing
              , rdTwin = Nothing
              }
        BindTwin twin -> do
          endpoint <- case (twinEndpoint twin, Map.lookup dependency deployed) of
            (Just pinned, _) -> Right pinned
            (Nothing, Just reported) -> Right reported
            (Nothing, Nothing)
              | envRuntime environment == Podman -> Right ("localhost:" <> maybe "" tshow (firstPort (twinPorts twin)))
              | otherwise -> Left (NotDeployed name dependency)
          let withConfig = Map.insert twinConfigVariable (encode (twinConfigJson twin)) (twinEnv twin)
              containerEnv = case twinAdvertiseVariable twin of
                Just variable
                  | runtime == Podman ->
                      let (host, port) = splitEndpoint endpoint
                       in Map.insert variable (maybe host (\p -> host <> ":" <> tshow p) port) withConfig
                _ -> withConfig
              adminPort' = case twinAdmin twin of
                Just admin | runtime == Podman && isNothing (adminUrl admin) -> Just (adminHostPort admin, adminContainerPort admin)
                _ -> Nothing
          Right
            ResolvedDependency
              { rdName = dependency
              , rdKind = KindTwinBinding
              , rdEndpoint = endpoint
              , rdImage = Just (qualifyImage (twinImageRef twin))
              , rdPorts = twinPorts twin
              , rdContainerEnv = containerEnv
              , rdStandIn =
                  Just
                    emptyStandIn
                      { standProduct = twinImage twin
                      , standVersion = twinVersion twin
                      , standConformance = conformanceLevel twin
                      , standSeed = twinSeed twin
                      }
              , rdCredentials = twinCredentials twin
              , rdSettings = Map.empty
              , rdAdminUrl = twinAdmin twin >>= \a -> adminUrlOn a runtime
              , rdAdminPort = adminPort'
              , rdTwin = Just twin
              }
      settings <- mapM (\(k, template) -> (,) k <$> renderSetting dependency k template resolved) (Map.toAscList (declSettings declaration))
      pure resolved {rdSettings = Map.fromList settings}

renderSetting :: Text -> Text -> Text -> ResolvedDependency -> Either ResolveError Text
renderSetting dependency k template d = either (\p -> Left (MissingPart dependency k p (rdEndpoint d))) Right (render template)
  where
    (host, port) = splitEndpoint (rdEndpoint d)
    render rest = case T.breakOn "${" rest of
      (before, "") -> Right before
      (before, found) ->
        let after = T.drop 2 found
            (placeholder, close) = T.breakOn "}" after
         in do
              rendered <- case placeholder of
                "endpoint" -> Right (rdEndpoint d)
                "host" -> Right host
                "port" -> maybe (Left placeholder) (Right . tshow) port
                "credentials" -> maybe (Left placeholder) Right (rdCredentials d)
                "kind" -> Right (kindWord (rdKind d))
                "name" -> Right (rdName d)
                other -> Left other
              (\r -> before <> rendered <> r) <$> render (T.drop 1 close)

tshow :: Show a => a -> Text
tshow = T.pack . show

firstPort :: [Integer] -> Maybe Integer
firstPort = \case
  (p : _) -> Just p
  [] -> Nothing

-- | The host and port of an endpoint, @host:port@ or a URL; a URL without a
-- port takes its scheme's.
splitEndpoint :: Text -> (Text, Maybe Integer)
splitEndpoint endpoint =
  let (scheme, rest) = case T.breakOn "://" endpoint of
        (s, r) | not (T.null r) -> (Just s, T.drop 3 r)
        _ -> (Nothing, endpoint)
      authority0 = T.takeWhile (`notElem` ("/?#" :: String)) rest
      authority = last (T.splitOn "@" authority0)
      fallback = case scheme of
        Just "https" -> Just 443
        Just "http" -> Just 80
        _ -> Nothing
   in case T.breakOnEnd ":" authority of
        ("", _) -> (authority, fallback)
        (before, port)
          | Just p <- parseU16 port -> (T.dropEnd 1 before, Just p)
          | otherwise -> (authority, fallback)
  where
    parseU16 t
      | not (T.null t) && T.all isDigit t && T.length t <= 5 =
          let n = read (T.unpack t) :: Integer in if n <= 65535 then Just n else Nothing
      | T.length t > 1 && T.head t == '+' && T.all isDigit (T.tail t) && T.length t <= 6 =
          let n = read (T.unpack (T.tail t)) :: Integer in if n <= 65535 then Just n else Nothing
      | otherwise = Nothing

-- | An image reference with its registry spelled out; a short name is a
-- Docker Hub name.
qualifyImage :: Text -> Text
qualifyImage image =
  let first = T.takeWhile (/= '/') image
      hasSlash = "/" `T.isInfixOf` image
      hasRegistry = hasSlash && ("." `T.isInfixOf` first || ":" `T.isInfixOf` first || first == "localhost")
   in if hasRegistry
        then image
        else
          if hasSlash
            then "docker.io/" <> image
            else "docker.io/library/" <> image

-- | The settings of every environment of a project, which the configuration
-- service serves.
data SettingsDocument = SettingsDocument {docProject :: Text, docEnvironments :: Map Text (Map Text Text)}
  deriving (Show, Eq)

emptyDocument :: SettingsDocument
emptyDocument = SettingsDocument "" Map.empty

insertEnvironment :: ResolvedEnvironment -> SettingsDocument -> SettingsDocument
insertEnvironment e d = SettingsDocument (reProject e) (Map.insert (reEnvironment e) (environmentSettings e) (docEnvironments d))

encodeDocument :: SettingsDocument -> Value
encodeDocument d =
  Object
    [ "project" .= String (docProject d)
    , "environments" .= Object [(k, fromTextMap v) | (k, v) <- Map.toAscList (docEnvironments d)]
    ]

decodeDocument :: Value -> Either Text SettingsDocument
decodeDocument =
  decodeWith $
    struct "SettingsDocument" False $
      SettingsDocument <$> required "project" string <*> required "environments" (textMap (textMap string))

-- | Settings as a dotenv file: a header comment, then @KEY=value@ lines in
-- name order, quoting a value only when it holds something a reader would
-- take apart.
renderDotenv :: Text -> Map Text Text -> Text
renderDotenv header settings =
  T.concat (["# " <> line <> "\n" | line <- rustLines header] ++ [k <> "=" <> quoted v <> "\n" | (k, v) <- Map.toAscList settings])
  where
    quoted v
      | T.all (\c -> (isAscii c && isAlphaNum c) || c `elem` ("_./:,@+-" :: String)) v = v
      | otherwise = "\"" <> T.concatMap escape v <> "\""
    escape = \case
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      '$' -> "\\$"
      c -> T.singleton c

-- | Rust's @str::lines@: split on newlines, a final empty line dropped, and
-- a carriage return before each newline removed.
rustLines :: Text -> [Text]
rustLines t
  | T.null t = []
  | otherwise =
      let parts = T.splitOn "\n" t
          parts' = if T.null (last parts) then init parts else parts
       in map (\l -> maybe l id (T.stripSuffix "\r" l)) parts'

-- | Reads a dotenv file as 'renderDotenv' writes it.
parseDotenv :: Text -> Map Text Text
parseDotenv text = foldl step Map.empty (rustLines text)
  where
    step acc raw =
      let line = T.strip raw
       in if T.null line || "#" `T.isPrefixOf` line
            then acc
            else case T.breakOn "=" line of
              (_, "") -> acc
              (k, rest) ->
                let v = T.drop 1 rest
                    unquoted =
                      if T.length v >= 2 && "\"" `T.isPrefixOf` v && "\"" `T.isSuffixOf` v
                        then unescape (T.unpack (T.drop 1 (T.dropEnd 1 v)))
                        else v
                 in Map.insert (T.strip k) unquoted acc
    unescape = T.pack . go
      where
        go ('\\' : 'n' : rest) = '\n' : go rest
        go ('\\' : c : rest) = c : go rest
        go "\\" = "\\"
        go (c : rest) = c : go rest
        go [] = []
