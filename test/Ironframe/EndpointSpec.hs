module Ironframe.EndpointSpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Ironframe.Compose (composeFile)
import Ironframe.Manifest
import Ironframe.Settings
import Test.Hspec

manifest :: T.Text
manifest = T.unlines
  [ "version: 1", "project: published-ports", "dependencies:"
  , "  one:", "    settings:", "      ONE_URL: ${endpoint}"
  , "  two:", "    settings:", "      TWO_URL: ${endpoint}"
  , "environments:", "  local:", "    runtime: podman", "    dependencies:"
  , "      one:", "        real:", "          endpoint: http://localhost:18180", "          image: example/http", "          ports: [8080]"
  , "      two:", "        real:", "          endpoint: http://localhost:18181", "          image: example/http", "          ports: [8080]"
  ]

spec :: Spec
spec = describe "endpoint publication" $ do
  it "publishes the endpoint host ports while retaining container ports and injected settings" $
    case parseManifest manifest of
      Left problem -> expectationFailure (T.unpack (renderManifestError problem))
      Right decoded -> case resolve decoded "local" Map.empty of
        Left problem -> expectationFailure (T.unpack (renderResolveError problem))
        Right environment -> do
          let compose = composeFile environment Nothing
          compose `shouldSatisfy` T.isInfixOf "18180:8080"
          compose `shouldSatisfy` T.isInfixOf "18181:8080"
          Map.lookup "ONE_URL" (environmentSettings environment) `shouldBe` Just "http://localhost:18180"
  it "rejects two bindings that publish the same host port" $
    case parseManifest (T.replace "18181" "18180" manifest) of
      Left problem -> renderManifestError problem `shouldSatisfy` T.isInfixOf "already published"
      Right _ -> expectationFailure "accepted colliding host publications"
