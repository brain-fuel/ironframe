-- | What Ironframe generates from one resolved topology: the settings each
-- application reads, a Mermaid or Graphviz diagram marking each dependency
-- real or twin, a copy of the CALM architecture annotated with each binding,
-- and the comparison of each export against the topology.
-- ref:DEC-calm-exports
module Ironframe.Calm.Export
  ( applicationSettings
  , bindingLabel
  , mermaid
  , dot
  , annotatedArchitecture
  , calmDiagramTemplate
  , mermaidProblems
  , tofuProblems
  , settingsProblems
  ) where

import Control.Monad (forM)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Ironframe.Calm.Resolve
import qualified Ironframe.Component as Component
import Ironframe.Json
import Ironframe.Settings

-- | The settings each application reads, by application node.
applicationSettings :: Resolution -> Map Text Text -> Either ResolveError (Map Text (Map Text Text))
applicationSettings resolution deployed = do
  let topology = resTopology resolution
  environment <- resolve (resManifest resolution) (rtEnvironment topology) deployed
  fmap Map.fromList $ forM (rtApplications topology) $ \application -> do
    let wiring = Map.fromList
            [ (k, v)
            | edge <- edgesOf topology (raNode application)
            , dependency <- take 1 (filter ((== reDestination edge) . rdName) (reDependencies environment))
            , k <- Map.keys (reSettings edge)
            , Just v <- [Map.lookup k (rdSettings dependency)]
            ]
        ownTemplates = [(name, text) | Object fields <- [keyOr "env" (Map.findWithDefault Null (raNode application) (resComponentBindings resolution))], (name,String text) <- fields]
    ownSettings <- fmap Map.fromList $ forM ownTemplates $ \(name,template) -> do
      let located = case Map.lookup (raNode application) (rtComponents topology) of
            Just component -> T.replace "${componentRoot}" (Component.componentRoot component) template
            Nothing -> template
      rendered <- case filter ((== raNode application) . rdName) (reDependencies environment) of
        dependency : _ -> renderSetting (raNode application) name located dependency
        [] -> Right located
      pure (name,rendered)
    let
        conflicts = Map.keys (Map.intersection ownSettings wiring)
    case conflicts of
      name : _ -> Left (SettingConflict (raNode application) name)
      [] -> Right (raNode application, Map.union wiring ownSettings)

-- | What a dependency is bound to, in a few words.
bindingLabel :: ResolvedDependencyNode -> Text
bindingLabel d = case (rnTwin d, rnProvider d) of
  (Just t, _) -> "twin " <> tiImage t <> ":" <> tiVersion t <> " (" <> tiConformance t <> ")"
  (Nothing, Just p) -> "real " <> providerName p <> " " <> providerVersion p
  (Nothing, Nothing) -> "real"

shortAbility :: Text -> Text
shortAbility = last . T.splitOn "::"

mermaidId :: Text -> Text
mermaidId = T.replace "-" "_"

-- | The topology as a Mermaid flowchart.
mermaid :: ResolvedTopology -> Text
mermaid t =
  T.concat $
    [ "%% " <> rtProject t <> " environment " <> rtEnvironment t <> " of " <> aiDocument (rtArchitecture t) <> " (" <> aiDigest (rtArchitecture t) <> ")\nflowchart LR\n"
    ]
      ++ [ "  " <> mermaidId (raNode a) <> "([\"" <> raName a <> "<br/>" <> ciPackage (raContract a) <> " " <> raVersion a <> "\"])\n"
         | a <- rtApplications t, all ((/= raNode a) . rnNode) (rtDependencies t)
         ]
      ++ [ "  " <> mermaidId (rnNode d) <> "[(\"" <> rnName d <> "<br/>" <> bindingLabel d <> "\")]:::" <> boundWord (rnKind d) <> "\n"
         | d <- rtDependencies t
         ]
      ++ [ "  " <> mermaidId (reSource e) <> " -->|\"" <> T.intercalate ", " (map shortAbility (reConsumes e))
            <> maybe "" (" over " <>) (reProtocol e)
            <> "\"| "
            <> mermaidId (reDestination e)
            <> "\n"
         | e <- rtEdges t
         ]
      ++ [ "  classDef real fill:#e8f5e9,stroke:#2e7d32\n"
         , "  classDef twin fill:#e3f2fd,stroke:#1565c0,stroke-dasharray: 4 2\n"
         ]

-- | The topology as a Graphviz digraph.
dot :: ResolvedTopology -> Text
dot t =
  T.concat $
    [ "// " <> rtProject t <> " environment " <> rtEnvironment t <> " of " <> aiDocument (rtArchitecture t) <> " (" <> aiDigest (rtArchitecture t) <> ")\n"
    , "digraph \"" <> rtProject t <> "-" <> rtEnvironment t <> "\" {\n  rankdir=LR;\n"
    ]
      ++ [ "  \"" <> raNode a <> "\" [shape=box, style=rounded, label=\"" <> raName a <> "\\n" <> ciPackage (raContract a) <> " " <> raVersion a <> "\"];\n"
         | a <- rtApplications t, all ((/= raNode a) . rnNode) (rtDependencies t)
         ]
      ++ [ "  \"" <> rnNode d <> "\" [shape=cylinder, " <> style (rnKind d) <> ", class=\"" <> boundWord (rnKind d) <> "\", label=\"" <> rnName d <> "\\n" <> bindingLabel d <> "\"];\n"
         | d <- rtDependencies t
         ]
      ++ [ "  \"" <> reSource e <> "\" -> \"" <> reDestination e <> "\" [label=\"" <> T.intercalate ", " (map shortAbility (reConsumes e)) <> "\"];\n"
         | e <- rtEdges t
         ]
      ++ ["}\n"]
  where
    style BoundReal = "style=filled, fillcolor=\"#e8f5e9\""
    style BoundTwin = "style=\"filled,dashed\", fillcolor=\"#e3f2fd\""

-- | A copy of the CALM architecture with each resolved node's binding in its
-- name and under its @metadata@, still a CALM 1.2 architecture.
annotatedArchitecture :: Value -> ResolvedTopology -> Value
annotatedArchitecture document t = case keyOr "nodes" document of
  Array nodes | member "nodes" document -> insert "nodes" (Array (map annotate nodes)) document
  _ -> document
  where
    annotate node =
      let i = case keyOr "unique-id" node of
            String s -> s
            _ -> ""
       in case (dependencyOf t i, applicationOf t i) of
            (Just d, _) ->
              apply
                node
                (" [" <> bindingLabel d <> "]")
                ( Object
                    [ "environment" .= String (rtEnvironment t)
                    , "kind" .= String (boundWord (rnKind d))
                    , "binding" .= String (bindingLabel d)
                    , "contract" .= encodeContractIdentity (rnContract d)
                    ]
                )
            (Nothing, Just a) ->
              apply
                node
                (" [" <> ciPackage (raContract a) <> " " <> raVersion a <> "]")
                ( Object
                    [ "environment" .= String (rtEnvironment t)
                    , "contract" .= encodeContractIdentity (raContract a)
                    , "deployment" .= encodeDeployment (raDeployment a)
                    ]
                )
            _ -> node
    apply node suffix binding =
      let named = case keyOr "name" node of
            String n -> insert "name" (String (n <> suffix)) node
            _ -> node
          entry = Object ["ironframe-binding" .= binding]
       in case key "metadata" named of
            Just (Array items) -> insert "metadata" (Array (items ++ [entry])) named
            Just m@(Object _) -> insert "metadata" (insert "ironframe-binding" binding m) named
            _ -> insert "metadata" (Array [entry]) named

-- | The template @calm docify@ renders the annotated architecture with.
calmDiagramTemplate :: Text
calmDiagramTemplate = "{{block-architecture this}}\n"

-- | Where a Mermaid diagram disagrees with the topology.
mermaidProblems :: ResolvedTopology -> Text -> [Text]
mermaidProblems t diagram =
  concatMap dependencyProblem (rtDependencies t)
    ++ ["the diagram has no edge " <> a <> " --> " <> b | (a, b) <- Set.toAscList (Set.difference expected drawn)]
    ++ ["the diagram has an edge " <> a <> " --> " <> b <> " the topology does not" | (a, b) <- Set.toAscList (Set.difference drawn expected)]
  where
    diagramLines = rustLines diagram
    dependencyProblem d =
      let start = mermaidId (rnNode d) <> "[("
       in case filter (T.isPrefixOf start . T.stripStart) diagramLines of
            [] -> ["the diagram does not draw dependency " <> rnNode d]
            (line : _)
              | not ((":::" <> boundWord (rnKind d)) `T.isSuffixOf` line) || not (bindingLabel d `T.isInfixOf` line) ->
                  ["the diagram draws " <> rnNode d <> " other than as " <> bindingLabel d]
              | otherwise -> []
    drawn =
      Set.fromList
        [ (from, to)
        | l <- diagramLines
        , let trimmed = T.strip l
        , (from, rest) <- splitOnce " -->|" trimmed
        , (_, to) <- rsplitOnce "| " rest
        ]
    expected = Set.fromList [(mermaidId (reSource e), mermaidId (reDestination e)) | e <- rtEdges t]
    splitOnce sep s = case T.breakOn sep s of
      (_, "") -> []
      (a, b) -> [(a, T.drop (T.length sep) b)]
    rsplitOnce sep s = case T.breakOnEnd sep s of
      ("", _) -> []
      (a, b) -> [(T.dropEnd (T.length sep) a, b)]

rustLines :: Text -> [Text]
rustLines t
  | T.null t = []
  | otherwise =
      let parts = T.splitOn "\n" t
       in map (\l -> maybe l id (T.stripSuffix "\r" l)) (if T.null (last parts) then init parts else parts)

-- | Where an OpenTofu root disagrees with the topology: every twin, and only
-- the twins, has a module instance.
tofuProblems :: ResolvedTopology -> Value -> [Text]
tofuProblems t root =
  ["the root deploys no module " <> m <> " for a twin of the topology" | m <- Set.toAscList (Set.difference twins modules)]
    ++ ["the root deploys module " <> m <> ", which is no twin of the topology" | m <- Set.toAscList (Set.difference modules twins)]
  where
    modules = case keyOr "module" root of
      Object pairs -> Set.fromList (map fst pairs)
      _ -> Set.empty
    twins = Set.fromList ["twin_" <> T.replace "-" "_" (rnNode d) | d <- rtDependencies t, rnKind d == BoundTwin]

-- | Where the settings handed to an application disagree with the topology.
settingsProblems :: ResolvedTopology -> Text -> Map Text Text -> [Text]
settingsProblems t application settings =
  [application <> " is not handed " <> k | k <- Set.toAscList (Set.difference expected given)]
    ++ [application <> " is handed " <> k <> ", which none of its edges reads" | k <- Set.toAscList (Set.difference given expected)]
  where
    expected = Set.fromList (concatMap (Map.keys . reSettings) (edgesOf t application) ++ Map.findWithDefault [] application (rtComponentSettings t))
    given = Map.keysSet settings
