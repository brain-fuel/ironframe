-- | Checked component descriptions come from LawSpec's public interface.
-- Ironframe owns connections and execution, and never interprets EDN itself.
module Ironframe.Component
  ( Component (..)
  , Contract (..)
  , Requirement (..)
  , loadComponent
  , decodeComponent
  , componentView
  , contractView
  ) where

import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as T
import Ironframe.Effect
import Ironframe.Json
import Ironframe.Json.Serde hiding (value)
import qualified Ironframe.Json.Serde as Serde

data Contract = Contract
  { contractPackage :: Text
  , contractVersion :: Text
  , contractDigest :: Text
  , contractAbilities :: [Text]
  }
  deriving (Show, Eq)

data Requirement = Requirement
  { requirementContract :: Contract
  , requirementDeclarations :: [Text]
  , requirementSettings :: [Text]
  }
  deriving (Show, Eq)

data Component = Component
  { componentManifest :: Text
  , componentRoot :: Text
  , componentName :: Text
  , componentVersion :: Text
  , componentFingerprint :: Text
  , componentProvides :: [Contract]
  , componentRequires :: Map Text Requirement
  , componentTargets :: [Value]
  , componentDeclarations :: [Text]
  }
  deriving (Show, Eq)

decodeComponent :: Value -> Either Text Component
decodeComponent document = do
  if textAt "format" document /= Just "lawspec-component" || key "version" document /= Just (Number (I 1))
    then Left "expected lawspec-component descriptor version 1"
    else pure ()
  let identity = case key "component" document of
        Just value | value /= Null -> value
        _ -> keyOr "package" document
  name <- field "name" identity
  version <- field "version" identity
  manifest <- field "manifest" document
  root <- field "root" document
  fingerprint <- field "fingerprint" document
  if T.length fingerprint /= 64 then Left "component fingerprint must be a SHA-256 digest" else pure ()
  provides <- decodeWith (vec contract) (keyOr "provides" document)
  requires <- decodeWith (textMap requirement) (keyOr "requires" document)
  targets <- decodeWith (vec Serde.value) (keyOr "targets" document)
  declarations <- decodeWith (vec string) (keyOr "declarations" document)
  pure (Component manifest root name version fingerprint provides requires targets declarations)
  where
    field name value = maybe (Left ("component descriptor is missing " <> name)) Right (textAt name value)
    contract = struct "ComponentContract" False $
      Contract <$> required "contract" string <*> required "version" string <*> required "digest" string <*> defaulted "abilities" [] (vec string)
    requirement = mapDecoder $ \value -> do
      provided <- decodeWith contract value
      declarations <- decodeWith (vec string) (maybe (Array []) id (key "declarations" value))
      settings <- decodeWith (vec string) (maybe (Array []) id (key "settings" value))
      pure (Requirement provided declarations settings)

loadComponent :: Text -> Eff (Either Text Component)
loadComponent manifest = do
  tool <- maybe "lawspec" id <$> getEnv "IRONFRAME_LAWSPEC"
  answer <- runProcess tool ["describe", "--json", "--config", manifest] False
  pure $ case answer of
    Left failure -> Left (manifest <> ": " <> ioMessage failure)
    Right output | not (procSuccess output) -> Left (manifest <> ": LawSpec refused the component: " <> procStdout output <> procStderr output)
    Right output -> decode (procStdout output) >>= decodeComponent

contractView :: Contract -> Value
contractView contract = Object
  [ "package" .= String (contractPackage contract)
  , "version" .= String (contractVersion contract)
  , "digest" .= String (contractDigest contract)
  , "abilities" .= Array (map String (contractAbilities contract))
  ]

componentView :: Component -> Value
componentView component = Object
  [ "manifest" .= String (componentManifest component)
  , "root" .= String (componentRoot component)
  , "name" .= String (componentName component)
  , "version" .= String (componentVersion component)
  , "fingerprint" .= String (componentFingerprint component)
  , "provides" .= Array (map contractView (componentProvides component))
  , "requires" .= Object
      [ (name, Object
          [ "contract" .= contractView (requirementContract requirement)
          , "declarations" .= Array (map String (requirementDeclarations requirement))
          , "settings" .= Array (map String (requirementSettings requirement))
          ])
      | (name, requirement) <- Map.toAscList (componentRequires component)
      ]
  , "targets" .= Array (componentTargets component)
  ]
