-- | Resolving one environment of a decorated CALM architecture: every
-- application node with the LawSpec package it implements, every dependency
-- node with the contract its binding must satisfy and the binding it has in
-- the environment, and every connects relationship from an application to a
-- dependency. Whatever cannot be resolved, or resolves to a binding that does
-- not satisfy its contract, is refused with every problem named by element.
-- The topology is lowered onto the manifest model, so the machinery
-- @ironframe.yaml@ uses serves it unchanged. ref:DEC-calm-resolution
-- ref:DEC-calm-refusals ref:DEC-manifest-compat
module Ironframe.Calm.Resolve
  ( topologyFormat
  , ContractIdentity (..)
  , ArchitectureIdentity (..)
  , Deployment (..)
  , ResolvedApplication (..)
  , BoundKind (..)
  , boundWord
  , ResolvedDependencyNode (..)
  , Provider (..)
  , TwinIdentity (..)
  , ResolvedEdge (..)
  , ResolvedTopology (..)
  , Resolution (..)
  , encodeTopology
  , encodeContractIdentity
  , encodeDeployment
  , topologyDigest
  , applicationOf
  , dependencyOf
  , edgesOf
  , resolveCalm
  , isAbilityIdentity
  ) where

import Control.Monad (foldM)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe, isJust, isNothing)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Ironframe.Calm.Model
import Ironframe.Effect
import Ironframe.Json
import Ironframe.Json.Serde
import Ironframe.Manifest
import Ironframe.Manifest.Serde (decodeCloud, decodeConfigService, decodeReal, decodeRuntime, decodeSyncTarget, decodeTwin)
import qualified Ironframe.Path as Path
import Ironframe.Rust (debugStr)
import qualified Ironframe.Semver as Semver

topologyFormat :: Text
topologyFormat = "ironframe-resolved-topology"

data ContractIdentity = ContractIdentity {ciPackage :: Text, ciVersion :: Text, ciAbilities :: [Text]}
  deriving (Show, Eq)

data ArchitectureIdentity = ArchitectureIdentity
  { aiDocument :: Text
  , aiDigest :: Text
  , aiUniqueId :: Maybe Text
  , aiDecorators :: Text
  , aiDecoratorsDigest :: Text
  }
  deriving (Show, Eq)

data Deployment
  = External
  | Process [Text] (Maybe Text)
  | Image Text [Text] (Maybe Text) (Maybe Text)
  deriving (Show, Eq)

data ResolvedApplication = ResolvedApplication
  { raNode :: Text
  , raName :: Text
  , raContract :: ContractIdentity
  , raDeployment :: Deployment
  , raVersion :: Text
  , raCommit :: Maybe Text
  , raEdges :: [Text]
  }
  deriving (Show, Eq)

data BoundKind = BoundReal | BoundTwin
  deriving (Show, Eq)

boundWord :: BoundKind -> Text
boundWord BoundReal = "real"
boundWord BoundTwin = "twin"

data Provider = Provider {providerName :: Text, providerVersion :: Text}
  deriving (Show, Eq)

data TwinIdentity = TwinIdentity
  { tiImage :: Text
  , tiVersion :: Text
  , tiStandsInFor :: ContractIdentity
  , tiConformance :: Text
  , tiSeed :: Maybe Integer
  , tiFaults :: [Text]
  }
  deriving (Show, Eq)

data ResolvedDependencyNode = ResolvedDependencyNode
  { rnNode :: Text
  , rnName :: Text
  , rnContract :: ContractIdentity
  , rnBinding :: Text
  , rnKind :: BoundKind
  , rnProvider :: Maybe Provider
  , rnTwin :: Maybe TwinIdentity
  , rnConsumers :: Int
  }
  deriving (Show, Eq)

data ResolvedEdge = ResolvedEdge
  { reRelationship :: Text
  , reSource :: Text
  , reDestination :: Text
  , reProtocol :: Maybe Text
  , reConsumes :: [Text]
  , reSettings :: Map Text Text
  , reKind :: BoundKind
  }
  deriving (Show, Eq)

data ResolvedTopology = ResolvedTopology
  { rtArchitecture :: ArchitectureIdentity
  , rtEnvironment :: Text
  , rtProject :: Text
  , rtRuntime :: Runtime
  , rtApplications :: [ResolvedApplication]
  , rtDependencies :: [ResolvedDependencyNode]
  , rtEdges :: [ResolvedEdge]
  }
  deriving (Show, Eq)

-- | A resolution: the topology, the manifest it lowers to, the directory
-- relative paths in bindings are read against, and the architecture.
data Resolution = Resolution
  { resTopology :: ResolvedTopology
  , resManifest :: Manifest
  , resDir :: Text
  , resArchitecture :: Architecture
  }

-- Writing.

encodeContractIdentity :: ContractIdentity -> Value
encodeContractIdentity c =
  Object $
    ["package" .= String (ciPackage c), "version" .= String (ciVersion c)]
      ++ ["abilities" .= Array (map String (ciAbilities c)) | not (null (ciAbilities c))]

encodeDeployment :: Deployment -> Value
encodeDeployment = \case
  External -> Object ["deployment" .= String "external"]
  Process command dir ->
    Object (["deployment" .= String "process", "command" .= Array (map String command)] ++ maybe [] (\d -> ["dir" .= String d]) dir)
  Image image args context containerfile ->
    Object $
      ["deployment" .= String "image", "image" .= String image]
        ++ ["args" .= Array (map String args) | not (null args)]
        ++ maybe [] (\c -> ["build_context" .= String c]) context
        ++ maybe [] (\c -> ["containerfile" .= String c]) containerfile

encodeTopology :: ResolvedTopology -> Value
encodeTopology t =
  Object
    [ "format" .= String topologyFormat
    , "version" .= Number (I 1)
    , "architecture" .= encodeArchitectureIdentity (rtArchitecture t)
    , "environment" .= String (rtEnvironment t)
    , "project" .= String (rtProject t)
    , "runtime" .= String (runtimeWord (rtRuntime t))
    , "applications" .= Array (map application (rtApplications t))
    , "dependencies" .= Array (map dependency (rtDependencies t))
    , "edges" .= Array (map edge (rtEdges t))
    ]
  where
    application a =
      Object $
        [ "node" .= String (raNode a)
        , "name" .= String (raName a)
        , "contract" .= encodeContractIdentity (raContract a)
        , "deployment" .= encodeDeployment (raDeployment a)
        , "version" .= String (raVersion a)
        ]
          ++ maybe [] (\c -> ["commit" .= String c]) (raCommit a)
          ++ ["edges" .= Array (map String (raEdges a))]
    dependency d =
      Object $
        [ "node" .= String (rnNode d)
        , "name" .= String (rnName d)
        , "contract" .= encodeContractIdentity (rnContract d)
        , "binding" .= String (rnBinding d)
        , "kind" .= String (boundWord (rnKind d))
        ]
          ++ maybe [] (\p -> ["provider" .= Object ["name" .= String (providerName p), "version" .= String (providerVersion p)]]) (rnProvider d)
          ++ maybe [] (\ti -> ["twin" .= twin ti]) (rnTwin d)
          ++ ["consumers" .= Number (I (toInteger (rnConsumers d)))]
    twin ti =
      Object $
        [ "image" .= String (tiImage ti)
        , "version" .= String (tiVersion ti)
        , "stands_in_for" .= encodeContractIdentity (tiStandsInFor ti)
        , "conformance" .= String (tiConformance ti)
        ]
          ++ maybe [] (\s -> ["seed" .= Number (I s)]) (tiSeed ti)
          ++ ["faults" .= Array (map String (tiFaults ti)) | not (null (tiFaults ti))]
    edge e =
      Object $
        ["relationship" .= String (reRelationship e), "source" .= String (reSource e), "destination" .= String (reDestination e)]
          ++ maybe [] (\p -> ["protocol" .= String p]) (reProtocol e)
          ++ [ "consumes" .= Array (map String (reConsumes e))
             , "settings" .= fromTextMap (reSettings e)
             , "kind" .= String (boundWord (reKind e))
             ]

encodeArchitectureIdentity :: ArchitectureIdentity -> Value
encodeArchitectureIdentity a =
  Object $
    ["document" .= String (aiDocument a), "digest" .= String (aiDigest a)]
      ++ maybe [] (\u -> ["unique_id" .= String u]) (aiUniqueId a)
      ++ ["decorators" .= String (aiDecorators a), "decorators_digest" .= String (aiDecoratorsDigest a)]

-- | The topology's digest, over its compact JSON: the planned wiring's identity.
topologyDigest :: ResolvedTopology -> Text
topologyDigest = digest . encode . encodeTopology

applicationOf :: ResolvedTopology -> Text -> Maybe ResolvedApplication
applicationOf t n = case filter ((== n) . raNode) (rtApplications t) of
  (a : _) -> Just a
  [] -> Nothing

dependencyOf :: ResolvedTopology -> Text -> Maybe ResolvedDependencyNode
dependencyOf t n = case filter ((== n) . rnNode) (rtDependencies t) of
  (d : _) -> Just d
  [] -> Nothing

edgesOf :: ResolvedTopology -> Text -> [ResolvedEdge]
edgesOf t n = filter ((== n) . reSource) (rtEdges t)

-- Reading the decorators' data.

data ContractData
  = ApplicationContract Text Text
  | DependencyContract Text Text [Text] (Maybe [Text])
  | ConnectionContract [Text] (Map Text Text)

contractData :: Decorator -> Either CalmProblem ContractData
contractData d =
  let dat = decData d
      parse k decoder = either (Left . calmProblem ("decorator " <> debugStr (decId d))) Right (decodeWith decoder (keyOr k dat))
   in if isJust (key "application" dat)
        then parse "application" (struct "ContractData::Application" False (ApplicationContract <$> required "package" string <*> required "version" string))
        else
          if isJust (key "dependency" dat)
            then
              parse
                "dependency"
                ( struct "ContractData::Dependency" False $
                    DependencyContract
                      <$> required "package" string
                      <*> required "version" string
                      <*> required "abilities" (vec string)
                      <*> optional "conformance" (struct "Accept" False (required "accept" (vec string)))
                )
            else parse "connection" (struct "ContractData::Connection" False (ConnectionContract <$> required "consumes" (vec string) <*> required "settings" (textMap string)))

data EnvironmentData = EnvironmentData
  { edProject :: Text
  , edRuntime :: Runtime
  , edCloud :: Maybe Cloud
  , edSync :: [SyncTarget]
  , edConfigService :: Maybe ConfigService
  }

environmentData :: Decoder EnvironmentData
environmentData =
  struct "EnvironmentData" False $
    EnvironmentData
      <$> required "project" string
      <*> required "runtime" decodeRuntime
      <*> optional "cloud" decodeCloud
      <*> defaulted "sync" [] (vec decodeSyncTarget)
      <*> optional "config_service" decodeConfigService

contractIdentity :: Decoder ContractIdentity
contractIdentity =
  struct "ContractIdentity" False $
    ContractIdentity <$> required "package" string <*> required "version" string <*> defaulted "abilities" [] (vec string)

providerDecoder :: Decoder Provider
providerDecoder = struct "Provider" False (Provider <$> required "name" string <*> required "version" string)

-- | Whether a text is an ability's resolved identity, @unit::ability::Name@.
isAbilityIdentity :: Text -> Bool
isAbilityIdentity identity = case T.breakOn "::ability::" identity of
  (unit, rest)
    | not (T.null rest) ->
        let name = T.drop (T.length "::ability::") rest
            unitOk =
              not (T.null unit)
                && all
                  (\part -> maybe False (isAsciiLower . fst) (T.uncons part) && T.all (\c -> isAsciiLower c || isDigit c || c == '_') part)
                  (T.splitOn "." unit)
            nameOk = maybe False (isAsciiUpper . fst) (T.uncons name) && T.all (\c -> isAsciiLower c || isAsciiUpper c || isDigit c || c == '_') name
         in unitOk && nameOk
  _ -> False

abilityUnit :: Text -> Text
abilityUnit identity = case T.breakOn "::ability::" identity of
  (unit, rest) | not (T.null rest) -> unit
  _ -> identity

unitInPackage :: Text -> Text -> Bool
unitInPackage unit package = unit == package || maybe False ("." `T.isPrefixOf`) (T.stripPrefix package unit)

data Edge = Edge {edgeRelationship :: Relationship, edgeSource :: Text, edgeDestination :: Text, edgeConsumes :: [Text], edgeSettings :: Map Text Text}

-- | Resolves an environment of an architecture and its decorators, or
-- refuses with every problem found. Relative paths in bindings, such as
-- conformance reports, are read against @dir@.
resolveCalm :: Architecture -> Decorators -> Text -> Text -> Eff (Either CalmError Resolution)
resolveCalm architecture decorators environment dir = do
  let found0 = targetProblems architecture decorators
      -- The environment.
      environments = ofType decorators environmentType
      declared = Set.fromList [e | d <- environments, Just e <- [textAt "environment" (decData d)]]
      mine = [d | d <- environments, textAt "environment" (decData d) == Just environment]
      (environmentProblems, environmentData') = case mine of
        [] ->
          ( [ calmProblem
                ("environment " <> debugStr environment)
                ( "no ironframe-environment decorator declares it; the decorators declare "
                    <> (if Set.null declared then "none" else T.intercalate ", " (map debugStr (Set.toAscList declared)))
                )
            ]
          , Nothing
          )
        [one] -> case decodeWith environmentData (decData one) of
          Right dat ->
            ( [ calmProblem ("decorator " <> debugStr (decId one)) ("an environment applies to nodes, and " <> debugStr e <> " is not one")
              | e <- decAppliesTo one
              , isNothing (nodeOf architecture e)
              ]
            , Just dat
            )
          Left err -> ([calmProblem ("decorator " <> debugStr (decId one)) err], Nothing)
        many ->
          ( [ calmProblem
                ("environment " <> debugStr environment)
                ( "is declared by " <> T.pack (show (length many)) <> " decorators ("
                    <> T.intercalate ", " (map (debugStr . decId) many)
                    <> "); it is ambiguous"
                )
            ]
          , Nothing
          )
      nameProblems =
        [ calmProblem ("environment " <> debugStr environment) "an environment name is lowercase letters, digits and -"
        | not (isName environment)
        ]
      -- Contracts, one per element.
      (contractProblems, contracts) =
        foldl
          ( \(ps, cs) d -> case contractData d of
              Left p -> (ps ++ [p], cs)
              Right dat ->
                foldl
                  ( \(ps', cs') e -> case Map.lookup e cs' of
                      Just (other, _) ->
                        ( ps' ++ [calmProblem ("element " <> debugStr e) ("has two contracts, decorators " <> debugStr other <> " and " <> debugStr (decId d) <> "; it is ambiguous")]
                        , cs'
                        )
                      Nothing -> (ps', Map.insert e (decId d, dat) cs')
                  )
                  (ps, cs)
                  (decAppliesTo d)
          )
          ([], Map.empty :: Map Text (Text, ContractData))
          (ofType decorators contractType)
      -- Classify nodes.
      (classProblems, applications, dependencies) =
        foldl classify ([], Map.empty, Map.empty) (Map.toAscList contracts)
      classify (ps, apps, deps) (element, (decorator, dat)) =
        let at = "decorator " <> debugStr decorator
            isNode = isJust (nodeOf architecture element)
         in case dat of
              ApplicationContract package version
                | not isNode -> (ps ++ [calmProblem at ("an application contract applies to a node, and " <> debugStr element <> " is not one")], apps, deps)
                | Left _ <- Semver.parseVersion version -> (ps ++ [calmProblem at ("version " <> debugStr version <> " is not an exact semantic version")], apps, deps)
                | otherwise -> (ps, Map.insert element (package, version) apps, deps)
              DependencyContract package version abilities accept
                | not isNode -> (ps ++ [calmProblem at ("a dependency contract applies to a node, and " <> debugStr element <> " is not one")], apps, deps)
                | Left _ <- Semver.parseReq version -> (ps ++ [calmProblem at ("version " <> debugStr version <> " is not a semantic version requirement")], apps, deps)
                | otherwise ->
                    let abilityProblems =
                          concat
                            [ if not (isAbilityIdentity a)
                                then [calmProblem at (debugStr a <> " is not an ability identity, unit::ability::Name")]
                                else [calmProblem at (a <> " is not an ability of package " <> package) | not (unitInPackage (abilityUnit a) package)]
                            | a <- abilities
                            ]
                        nameProblem =
                          [ calmProblem ("node " <> debugStr element) "a dependency node's unique-id names it in settings and resources: lowercase letters, digits and -"
                          | not (isName element)
                          ]
                     in (ps ++ abilityProblems ++ nameProblem, apps, Map.insert element (package, version, abilities, accept) deps)
              ConnectionContract _ _
                | isNothing (relationshipOf architecture element) ->
                    (ps ++ [calmProblem at ("a connection contract applies to a relationship, and " <> debugStr element <> " is not one")], apps, deps)
                | otherwise -> (ps, apps, deps)
      -- Edges from applications to dependencies.
      (edgeProblems, edges, _, _) = foldl edgeStep ([], [], Map.empty, Map.empty) (archRelationships architecture)
      edgeStep (ps, es, consumed, appSettings) relationship =
        let at = "relationship " <> debugStr (relId relationship)
            connection = case Map.lookup (relId relationship) contracts of
              Just (decorator, ConnectionContract consumes settings) -> Just (decorator, consumes, settings)
              _ -> Nothing
         in case relKind relationship of
              Connects source destination ->
                let sourceIsApp = Map.member source applications
                    destinationIsDependency = Map.member destination dependencies
                 in case (sourceIsApp, destinationIsDependency, connection) of
                      (True, True, Just (_, consumes, settings)) ->
                        let (package, _) = applications Map.! source
                            (abilityPs, consumed') =
                              foldl
                                ( \(aps, c) ability ->
                                    let identityPs
                                          | not (isAbilityIdentity ability) =
                                              [calmProblem at ("consumes " <> debugStr ability <> ", which is not an ability identity, unit::ability::Name")]
                                          | not (unitInPackage (abilityUnit ability) package) =
                                              [calmProblem at ("consumes " <> ability <> ", which is not an ability of " <> debugStr source <> "'s package " <> package)]
                                          | otherwise = []
                                        (twicePs, c') = case Map.lookup (source, ability) c of
                                          Just other ->
                                            ( [ calmProblem
                                                  at
                                                  ( "consumes " <> ability <> ", which relationship " <> debugStr other <> " of " <> debugStr source
                                                      <> " carries too; which endpoint it reaches is ambiguous"
                                                  )
                                              ]
                                            , Map.insert (source, ability) (relId relationship) c
                                            )
                                          Nothing -> ([], Map.insert (source, ability) (relId relationship) c)
                                     in (aps ++ identityPs ++ twicePs, c')
                                )
                                ([], consumed)
                                consumes
                            (settingPs, appSettings') =
                              foldl
                                ( \(sps, s) k -> case Map.lookup (source, k) s of
                                    Just other ->
                                      ( sps ++ [calmProblem at ("hands " <> debugStr source <> " setting " <> k <> ", which relationship " <> debugStr other <> " hands it too")]
                                      , Map.insert (source, k) (relId relationship) s
                                      )
                                    Nothing -> (sps, Map.insert (source, k) (relId relationship) s)
                                )
                                ([], appSettings)
                                (Map.keys settings)
                         in (ps ++ abilityPs ++ settingPs, es ++ [Edge relationship source destination consumes settings], consumed', appSettings')
                      (True, True, Nothing) ->
                        ( ps
                            ++ [ calmProblem
                                  at
                                  ( "connects application " <> debugStr source <> " to dependency " <> debugStr destination
                                      <> " but has no ironframe-contract connection decorator saying which abilities it carries and which settings the application reads; it is unresolved"
                                  )
                               ]
                        , es
                        , consumed
                        , appSettings
                        )
                      (_, _, Just _) ->
                        ( ps
                            ++ [ calmProblem
                                  at
                                  ( "carries a connection contract, but "
                                      <> ( if not sourceIsApp
                                            then "its source " <> debugStr source <> " has no application contract"
                                            else "its destination " <> debugStr destination <> " has no dependency contract"
                                         )
                                  )
                               ]
                        , es
                        , consumed
                        , appSettings
                        )
                      _ -> (ps, es, consumed, appSettings)
              _ ->
                ( ps ++ [calmProblem at "carries a connection contract, but only a connects relationship reaches a dependency" | isJust connection]
                , es
                , consumed
                , appSettings
                )
      -- Bindings in this environment, one per node.
      (bindingProblems, bindings) = foldl bindingStep ([], Map.empty) (ofType decorators bindingType)
      bindingStep (ps, bs) d =
        let at = "decorator " <> debugStr (decId d)
            bound = fromMaybe "" (textAt "environment" (decData d))
         in if not (bound `Set.member` declared)
              then (ps ++ [calmProblem at ("binds environment " <> debugStr bound <> ", which no ironframe-environment decorator declares")], bs)
              else
                if bound /= environment
                  then (ps, bs)
                  else
                    foldl
                      ( \(ps', bs') e ->
                          let isApplication = Map.member e applications
                              isDependency = Map.member e dependencies
                              saysApplication = isJust (key "application" (decData d))
                           in if not isApplication && not isDependency
                                then (ps' ++ [calmProblem at ("binds " <> debugStr e <> ", which has no application or dependency contract")], bs')
                                else
                                  if isApplication && not saysApplication
                                    then (ps' ++ [calmProblem at ("binds application " <> debugStr e <> " as a dependency, real or twin")], bs')
                                    else
                                      if isDependency && saysApplication
                                        then (ps' ++ [calmProblem at ("binds dependency " <> debugStr e <> " as an application")], bs')
                                        else case Map.lookup e bs' of
                                          Just other ->
                                            ( ps'
                                                ++ [ calmProblem
                                                      ("node " <> debugStr e)
                                                      ( "has two bindings in environment " <> debugStr environment <> ", decorators "
                                                          <> debugStr (decId other)
                                                          <> " and "
                                                          <> debugStr (decId d)
                                                          <> "; it is ambiguous"
                                                      )
                                                   ]
                                            , Map.insert e d bs'
                                            )
                                          Nothing -> (ps', Map.insert e d bs')
                      )
                      (ps, bs)
                      (decAppliesTo d)
      before = found0 ++ environmentProblems ++ nameProblems ++ contractProblems ++ classProblems ++ edgeProblems ++ bindingProblems
  -- Resolve each dependency's binding against its contract.
  (dependencyProblems, resolvedDependencies, manifestBindings) <-
    foldM
      ( \(ps, rds, mbs) (node, (package, requirement, abilities, accept)) -> do
          let at = "node " <> debugStr node
              consumers = length (filter ((== node) . edgeDestination) edges)
              consumerPs = [calmProblem at "has a dependency contract, but no application's connects relationship reaches it" | consumers == 0]
              nodeName = maybe "" nodeName' (nodeOf architecture node)
              nodeName' = Ironframe.Calm.Model.nodeName
          case Map.lookup node bindings of
            Nothing -> pure (ps ++ consumerPs ++ [calmProblem at ("has no binding in environment " <> debugStr environment <> "; it is unresolved")], rds, mbs)
            Just decorator -> do
              let contract = ContractIdentity package requirement abilities
                  bindingAt = "decorator " <> debugStr (decId decorator)
                  ps1 = ps ++ consumerPs
              case key "real" (decData decorator) of
                Just real -> do
                  let provider = key "provider" real >>= either (const Nothing) Just . decodeWith providerDecoder
                  pure $ case decodeWith decodeReal (delete "provider" real) of
                    Right r ->
                      ( ps1
                      , rds ++ [ResolvedDependencyNode node nodeName contract (decId decorator) BoundReal provider Nothing consumers]
                      , Map.insert node (BindReal r) mbs
                      )
                    Left err -> (ps1 ++ [calmProblem bindingAt ("real: " <> err)], rds, mbs)
                Nothing -> do
                  let fields = keyOr "twin" (decData decorator)
                  case key "stands-in-for" fields >>= either (const Nothing) Just . decodeWith contractIdentity of
                    Nothing -> pure (ps1 ++ [calmProblem bindingAt "a twin says which contract it stands in for under stands-in-for"], rds, mbs)
                    Just standsInFor -> case decodeWith decodeTwin (delete "stands-in-for" fields) of
                      Left err -> pure (ps1 ++ [calmProblem bindingAt ("twin: " <> err)], rds, mbs)
                      Right twin -> do
                        (compatibility, twin') <- compatibilityProblems bindingAt node contract accept twin standsInFor dir
                        if not (null compatibility)
                          then pure (ps1 ++ compatibility, rds, mbs)
                          else do
                            let identity =
                                  TwinIdentity
                                    (twinImage twin')
                                    (twinVersion twin')
                                    standsInFor
                                    (conformanceLevel twin')
                                    (twinSeed twin')
                                    (map faultName (twinFaults twin'))
                            pure
                              ( ps1
                              , rds ++ [ResolvedDependencyNode node nodeName contract (decId decorator) BoundTwin Nothing (Just identity) consumers]
                              , Map.insert node (BindTwin twin') mbs
                              )
      )
      (before, [], Map.empty)
      (Map.toAscList dependencies)
  let resolvedApplications =
        [ applicationFor node package version
        | (node, (package, version)) <- Map.toAscList applications
        ]
      applicationFor node package version =
        let base =
              ResolvedApplication
                node
                (maybe "" Ironframe.Calm.Model.nodeName (nodeOf architecture node))
                (ContractIdentity package version [])
                External
                version
                Nothing
                [relId (edgeRelationship e) | e <- edges, edgeSource e == node]
         in case Map.lookup node bindings of
              Nothing -> base
              Just decorator ->
                let dat = keyOr "application" (decData decorator)
                    deployment = case key "managed" dat of
                      Just managed
                        | Just process <- key "process" managed ->
                            Process (either (const []) id (decodeWith (vec string) (keyOr "command" process))) (textAt "dir" process)
                        | Just image <- key "image" managed ->
                            Image
                              (fromMaybe "" (textAt "image" image))
                              (either (const []) id (decodeWith (vec string) (keyOr "args" image)))
                              (textAt "context" (keyOr "build" image))
                              (textAt "containerfile" (keyOr "build" image))
                      _ -> External
                    implementation = keyOr "implementation" dat
                 in base
                      { raDeployment = deployment
                      , raVersion = fromMaybe version (textAt "version" implementation)
                      , raCommit = textAt "commit" implementation
                      }
      resolvedEdges =
        [ ResolvedEdge
            (relId (edgeRelationship e))
            (edgeSource e)
            (edgeDestination e)
            (relProtocol (edgeRelationship e))
            (edgeConsumes e)
            (edgeSettings e)
            (maybe BoundReal rnKind (lookupNode (edgeDestination e) resolvedDependencies))
        | e <- edges
        ]
      lookupNode n ds = case filter ((== n) . rnNode) ds of
        (d : _) -> Just d
        [] -> Nothing
      (declarationProblems, declarations) =
        foldl
          ( \(ps, decls) edge ->
              let destination = reDestination edge
                  decl0 = Map.findWithDefault (DependencyDecl (Ironframe.Calm.Model.nodeDescription <$> nodeOf architecture destination) Map.empty) destination decls
                  (ps', settings') =
                    foldl
                      ( \(sps, s) (k, template) -> case Map.lookup k s of
                          Just other
                            | other /= template ->
                                ( sps
                                    ++ [ calmProblem
                                          ("relationship " <> debugStr (reRelationship edge))
                                          ( "reads setting " <> k <> " of " <> debugStr destination <> " as " <> debugStr template
                                              <> ", but another relationship reads it as "
                                              <> debugStr other
                                          )
                                       ]
                                , Map.insert k template s
                                )
                          _ -> (sps, Map.insert k template s)
                      )
                      ([], declSettings decl0)
                      (Map.toAscList (reSettings edge))
               in (ps ++ ps', Map.insert destination decl0 {declSettings = settings'} decls)
          )
          ([], Map.empty)
          resolvedEdges
      found = dependencyProblems ++ declarationProblems
      refuse = Left . CalmError Nothing
  pure $ case environmentData' of
    Nothing -> refuse found
    Just _ | not (null found) -> refuse found
    Just dat ->
      let manifest =
            Manifest
              { manifestVersion = 1
              , manifestProject = edProject dat
              , manifestDependencies = declarations
              , manifestEnvironments =
                  Map.singleton
                    environment
                    (Environment (edRuntime dat) (edCloud dat) manifestBindings (edSync dat) (edConfigService dat))
              }
          lowered = [translate resolvedDependencies (problemPath p) (problemMessage p) | p <- manifestProblems manifest]
       in if not (null lowered)
            then refuse lowered
            else
              let topology =
                    ResolvedTopology
                      { rtArchitecture =
                          ArchitectureIdentity
                            (fromMaybe "architecture.json" (architectureFileName architecture))
                            (archDigest architecture)
                            (archUniqueId architecture)
                            (fromMaybe "decorators.json" (decsPath decorators >>= Path.fileName))
                            (decsDigest decorators)
                      , rtEnvironment = environment
                      , rtProject = edProject dat
                      , rtRuntime = edRuntime dat
                      , rtApplications = resolvedApplications
                      , rtDependencies = resolvedDependencies
                      , rtEdges = resolvedEdges
                      }
               in Right (Resolution topology manifest dir architecture)
  where
    translate resolved at message =
      let prefix = "environments." <> environment <> ".dependencies."
       in case T.stripPrefix prefix at of
            Just rest ->
              let node = head (T.splitOn "." rest)
                  field = T.dropWhile (== '.') (T.drop (T.length node) rest)
                  decorator = case filter ((== node) . rnNode) resolved of
                    (d : _) -> rnBinding d
                    [] -> ""
               in calmProblem
                    ( "binding of node " <> debugStr node <> " in environment " <> debugStr environment <> " (decorator " <> debugStr decorator <> ")"
                        <> (if T.null field then "" else " at " <> field)
                    )
                    message
            Nothing -> case T.stripPrefix "dependencies." at of
              Just rest -> calmProblem ("settings of node " <> debugStr (head (T.splitOn "." rest))) message
              Nothing -> calmProblem ("environment " <> debugStr environment <> (if T.null at then "" else " at " <> at)) message

-- | How a twin fails to satisfy the contract of the node it is bound to.
-- Reads the twin's conformance report against @dir@.
compatibilityProblems :: Text -> Text -> ContractIdentity -> Maybe [Text] -> Twin -> ContractIdentity -> Text -> Eff ([CalmProblem], Twin)
compatibilityProblems at node contract accept twin standsInFor dir = do
  let packagePs =
        [ calmProblem at ("the twin stands in for package " <> ciPackage standsInFor <> ", but node " <> debugStr node <> " requires " <> ciPackage contract <> "; it is incompatible")
        | ciPackage standsInFor /= ciPackage contract
        ]
      versionPs = case (Semver.parseVersion (ciVersion standsInFor), Semver.parseReq (ciVersion contract)) of
        (Right version, Right requirement)
          | not (Semver.matches requirement version) ->
              [ calmProblem
                  at
                  ( "the twin stands in for " <> ciPackage standsInFor <> " " <> ciVersion standsInFor <> ", outside node " <> debugStr node
                      <> "'s requirement "
                      <> ciVersion contract
                      <> "; it is incompatible"
                  )
              ]
        (Left _, _) -> [calmProblem at ("stands-in-for version " <> debugStr (ciVersion standsInFor) <> " is not an exact semantic version")]
        _ -> []
      abilityPs =
        [ calmProblem at ("node " <> debugStr node <> " requires ability " <> a <> ", which the twin does not stand in for; it is incompatible")
        | a <- ciAbilities contract
        , a `notElem` ciAbilities standsInFor
        ]
  (reportPs, report) <- case conformanceReport (twinConformance twin) of
    Nothing -> pure ([], Nothing)
    Just relative -> do
      text <- readFileE (Path.join dir relative)
      case either (\e -> Left ("cannot read it: " <> ioMessage e)) Right text >>= parseReport of
        Right r ->
          pure
            ( [calmProblem at (problemMessage p) | p <- reportProblems at twin r]
                ++ [ calmProblem
                      at
                      ("the twin's conformance report checked package " <> package <> ", but the twin says it stands in for " <> ciPackage standsInFor)
                   | Just package <- [reportContract r]
                   , package /= ciPackage standsInFor
                   ]
            , Just r
            )
        Left reason -> pure ([calmProblem at ("conformance report " <> Path.display relative <> ": " <> reason)], Nothing)
  let acceptPs = case accept of
        Nothing -> []
        Just accepted ->
          let ok = case (report, conformanceDeclared (twinConformance twin)) of
                (Just r, _) -> any (reportMatches r) accepted
                (Nothing, Just declared) -> any (\l -> asciiLower l == asciiLower declared) accepted
                (Nothing, Nothing) -> False
              has = case report of
                Just r -> Just (reportDescribe r)
                Nothing -> ("level " <>) <$> conformanceDeclared (twinConformance twin)
           in [ calmProblem
                  at
                  ( "node " <> debugStr node <> " accepts conformance " <> T.intercalate " or " accepted <> ", and the twin has "
                      <> fromMaybe "no level known before it runs" has
                      <> "; it is incompatible"
                  )
              | not ok
              ]
  pure (packagePs ++ versionPs ++ abilityPs ++ reportPs ++ acceptPs, twin {twinReport = report})
  where
    asciiLower = T.map (\c -> if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c)
