module Ironframe.ComponentSpec (spec) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Ironframe.Component
import Ironframe.Calm.Model
import Ironframe.Calm.Export (applicationSettings, applicationSettingsWithCredentials, mermaid, mermaidProblems)
import Ironframe.Calm.Resolve
import Ironframe.Effect
import Ironframe.Json
import Test.Hspec

descriptor :: Text -> Value
descriptor name = Object
  [ "format" .= String "lawspec-component", "version" .= Number (I 1)
  , "manifest" .= String ("/repo/" <> name <> "/lawspec.edn"), "root" .= String ("/repo/" <> name)
  , "component" .= Object ["name" .= String name, "version" .= String "0.1.0"]
  , "fingerprint" .= String (T.replicate 64 "a")
  , "provides" .= Array [contract | name == "server"]
  , "requires" .= Object [("graph", insert "declarations" (Array [String "example.client::read"]) (insert "settings" (Array [String "BASE_URL"]) contract)) | name == "client"]
  , "targets" .= Array [Object ["language" .= String "javascript", "root" .= String "."]]
  , "declarations" .= Array (map String ["example.client::read", "example.graph::ability::Graph"])
  ]
  where
    contract = Object ["contract" .= String "example.graph", "version" .= String "1.0.0", "digest" .= String (T.replicate 64 "b"), "abilities" .= Array [String "example.graph::ability::Graph"]]

architecture :: Either Text Architecture
architecture = case parseArchitecture (encode document) of
  Left problem -> Left (renderCalmError problem)
  Right model -> Right model
  where
    document = Object
      [ "unique-id" .= String "components"
      , "nodes" .= Array [Object ["unique-id" .= String name, "node-type" .= String "service", "name" .= String name, "description" .= String name] | name <- ["client", "server"]]
      , "relationships" .= Array [Object ["unique-id" .= String "client-server", "description" .= String "reads", "protocol" .= String "HTTP", "relationship-type" .= Object ["connects" .= Object ["source" .= Object ["node" .= String "client"], "destination" .= Object ["node" .= String "server"]]]]]
      ]

decorations :: Either Text Decorators
decorations = case parseDecorators (encode (Array values)) of
  Left problem -> Left (renderCalmError problem)
  Right model -> Right model
  where
    decorate identifier kind target dat = Object
      [ "unique-id" .= String identifier, "type" .= String kind, "target" .= Array [String "components"], "applies-to" .= Array [String target], "data" .= dat]
    values =
      [ decorate (name <> "-component") "ironframe-contract" name (Object ["component" .= Object ["manifest" .= String (name <> "/lawspec.edn")]]) | name <- ["client", "server"]] ++
      [ decorate "connection" "ironframe-contract" "client-server" (Object ["connection" .= Object ["requirement" .= String "graph", "settings" .= Object ["BASE_URL" .= String "${endpoint}"]]])
      , decorate "environment" "ironframe-environment" "client" (Object ["environment" .= String "local", "project" .= String "components", "runtime" .= String "podman"])
      , decorate "client-binding" "ironframe-binding" "client" (Object ["environment" .= String "local", "component" .= Object ["external" .= Object []]])
      , decorate "server-binding" "ironframe-binding" "server" (Object ["environment" .= String "local", "component" .= Object ["endpoint" .= String "127.0.0.1:8100", "managed" .= Object ["process" .= Object ["command" .= Array [String "server"]]]]])
      ]

resolve :: (Text -> Value) -> Either Text Resolution
resolve describe = resolveWith describe id

resolveWith :: (Text -> Value) -> (Decorators -> Decorators) -> Either Text Resolution
resolveWith describe change = do
  model <- architecture
  decorators <- change <$> decorations
  let go results = case runEff (resolveCalm model decorators "local" "/repo") results of
        Done (Left problem) -> Left problem
        Done (Right (Left problem)) -> Left (renderCalmError problem)
        Done (Right (Right result)) -> Right result
        Need effect -> case textAt "effect" effect of
          Just "env" -> go (results ++ [Object ["ok" .= Null]])
          Just "run" ->
            let source = case key "args" effect of
                  Just (Array args) | String file <- last args -> file
                  _ -> ""
                name = if "client" `T.isInfixOf` source then "client" else "server"
                result = Object ["success" .= Bool True, "code" .= Number (I 0), "stdout" .= String (encode (describe name)), "stderr" .= String ""]
             in go (results ++ [Object ["ok" .= result]])
          _ -> Left ("unexpected effect " <> encode effect)
  go []

spec :: Spec
spec = describe "LawSpec component resolution" $ do
  it "checks telemetry diagram correspondence independently of business edges" $
    case resolve descriptor of
      Left problem -> expectationFailure (T.unpack problem)
      Right resolved -> do
        let topology = (resTopology resolved) {rtObservation = Just (Object ["node" .= String "run-observer"])}
            diagram = mermaid topology
            missing = T.unlines (filter (not . T.isInfixOf "-.->|OTLP|") (T.lines diagram))
        mermaidProblems topology diagram `shouldBe` []
        mermaidProblems topology missing `shouldSatisfy` (not . null)
  it "refuses observation wired to a business dependency without dedicated telemetry edges" $ do
    let change ds = ds {decsItems = [if decKind d == environmentType then d {decData = insert "observation" (Object ["node" .= String "server","relationships" .= Array [String "client-server"]]) (decData d)} else d | d <- decsItems ds]}
    case resolveWith descriptor change of
      Left problem -> problem `shouldSatisfy` T.isInfixOf "observation"
      Right _ -> expectationFailure "accepted a dependency node as the run observation receiver"
  it "checks the descriptor protocol before interpreting a component" $ do
    decodeComponent (insert "version" (Number (I 2)) (descriptor "client")) `shouldBe` Left "expected lawspec-component descriptor version 1"
  it "keeps one component identity while a managed service also provides a dependency" $ do
    let result = resolve descriptor
    case result of
      Left problem -> expectationFailure (T.unpack problem)
      Right resolution -> do
        let topology = resTopology resolution
        Map.keys (rtComponents topology) `shouldBe` ["client", "server"]
        map raNode (rtApplications topology) `shouldBe` ["client", "server"]
        map rnNode (rtDependencies topology) `shouldBe` ["server"]
        map reConsumes (rtEdges topology) `shouldBe` [["example.graph::ability::Graph", "example.client::read"]]
        raDeployment (last (rtApplications topology)) `shouldBe` Process ["server"] Nothing
  it "refuses a different published contract digest before execution" $ do
    let changed name = if name == "server" then insert "provides" (Array [Object ["contract" .= String "example.graph", "version" .= String "1.0.0", "digest" .= String (T.replicate 64 "c"), "abilities" .= Array [String "example.graph::ability::Graph"]]]) (descriptor name) else descriptor name
    case resolve changed of
      Left problem -> problem `shouldSatisfy` T.isInfixOf "does not provide the resolved contract"
      Right _ -> expectationFailure "accepted a contract with different content"

  it "refuses a declared setting with no connection binding" $ do
    let changed name = if name == "client" then
          insert "requires" (Object [("graph", insert "settings" (Array [String "BASE_URL", String "INVITE"]) (keyOr "graph" (keyOr "requires" (descriptor name))))]) (descriptor name)
          else descriptor name
    case resolve changed of
      Left problem -> problem `shouldSatisfy` T.isInfixOf "required setting INVITE"
      Right _ -> expectationFailure "accepted a missing required setting"
  it "renders typed credential substitutions without interpreting ordinary file URIs" $ do
    let changed name = if name == "client" then
          insert "requires" (Object [("graph", insert "settings" (Array [String "BASE_URL", String "AUTH"]) (keyOr "graph" (keyOr "requires" (descriptor name))))]) (descriptor name)
          else descriptor name
        change decorations' = decorations' {decsItems = map decorate (decsItems decorations')}
        decorate decorator
          | decId decorator == "connection" = decorator {decData = Object ["connection" .= Object ["requirement" .= String "graph", "settings" .= Object ["BASE_URL" .= String "${endpoint}", "AUTH" .= String "Bearer ${credentials}"]]]}
          | decId decorator == "server-binding" = decorator {decData = insert "component" (insert "credentials" (String "env:EXAMPLE_TOKEN") (keyOr "component" (decData decorator))) (decData decorator)}
          | decId decorator == "client-binding" = decorator {decData = insert "component" (insert "env" (Object ["DATABASE" .= String "file:cache.db"]) (keyOr "component" (decData decorator))) (decData decorator)}
          | otherwise = decorator
    case resolveWith changed change of
      Left problem -> expectationFailure (T.unpack problem)
      Right resolution -> do
        fmap (Map.lookup "AUTH" . (Map.! "client")) (applicationSettings resolution Map.empty) `shouldBe` Right (Just "Bearer env:EXAMPLE_TOKEN")
        let launched = applicationSettingsWithCredentials resolution Map.empty (Map.singleton "server" "controlled-token")
        fmap (Map.lookup "AUTH" . (Map.! "client")) launched `shouldBe` Right (Just "Bearer controlled-token")
        fmap (Map.lookup "DATABASE" . (Map.! "client")) launched `shouldBe` Right (Just "file:cache.db")
