-- | The methods that expose the libraries the core is built on, so each is
-- checked against the behaviour of the Rust crate it stands in for: JSON and
-- YAML reading and writing, JSON Schema, semantic versions, RFC 3339 times,
-- Rust's Debug quoting and serde's typed reading. ref:DEC-haskell-wasm-core
module Ironframe.Library (libraryMethod, schemaNamed) where

import qualified Data.Text as T
import Data.Text (Text)
import GHC.Float (castWord64ToDouble)
import Ironframe.Effect (Eff)
import qualified Ironframe.Embedded as Embedded
import Ironframe.Json
import qualified Ironframe.Json.Schema as Schema
import Ironframe.Json.Serde (decodeWith)
import Ironframe.Manifest.Serde
import Ironframe.Rust (debugStr)
import qualified Ironframe.Semver as Semver
import Ironframe.Time
import Ironframe.Yaml (decodeYaml, encodeYaml)

text' :: Text -> Value -> Text
text' k v = case keyOr k v of
  String t -> t
  _ -> ""

okOr :: Either Text Value -> Value
okOr = either (\e -> Object ["error" .= String e]) (\v -> Object ["ok" .= v])

-- | The versions the corpus matches every requirement against.
corpusVersions :: [Text]
corpusVersions =
  [ "0.1.0", "1.2.3", "1.2.3-alpha.1", "1.2.3+build.5", "1.2.3-rc.1+b", "01.2.3", "1.2", "1", "v1.2.3", "1.2.3-", "1.2.3-01", "1.2.3-a..b"
  , "", " 1.2.3", "1.2.3 ", "18446744073709551615.0.0", "18446744073709551616.0.0", "1.2.3-alpha.01", "0.0.0", "1.2.3+", "1.2.3-x-y"
  , "0.1.5-beta.1", "0.2.0", "0.9.0", "1.0", "1.a.0"
  ]

parsed :: Text -> Value
parsed t = either (error . T.unpack) id (decode t)

-- | A schema the corpus names.
schemaNamed :: Text -> Maybe Schema.Schema
schemaNamed name = either (const Nothing) Just =<< case name of
  "manifest" -> Just (Schema.compile [] (parsed Embedded.manifestSchema))
  "attestation" -> Just (Schema.compile [] (parsed Embedded.attestationSchema))
  "ironframe-contract" -> Just (Schema.compile [] (parsed Embedded.contractDecoratorSchema))
  "ironframe-binding" -> Just (Schema.compile [] (parsed Embedded.bindingDecoratorSchema))
  "ironframe-environment" -> Just (Schema.compile [] (parsed Embedded.environmentDecoratorSchema))
  "calm-decorator" -> Just (Schema.compile [] (keyOr "decorator" (keyOr "defs" (parsed Embedded.calmDecorators))))
  "calm-core" ->
    Just
      ( Schema.compile
          [ ("https://calm.finos.org/release/1.2/meta/" <> n, parsed t)
          | (n, t) <-
              [ ("core.json", Embedded.calmCore)
              , ("control.json", Embedded.calmControl)
              , ("flow.json", Embedded.calmFlow)
              , ("interface.json", Embedded.calmInterface)
              , ("decorators.json", Embedded.calmDecorators)
              ]
          ]
          (parsed Embedded.calmCore)
      )
  _ -> Nothing

libraryMethod :: Text -> Value -> Maybe (Eff Value)
libraryMethod method p = pure <$> case method of
  "json.decode" -> Just $ case decode (text' "text" p) of
    Right v -> Object ["compact" .= String (encode v), "pretty" .= String (encodePretty v)]
    Left e -> Object ["error" .= String e]
  "json.formatDouble" -> Just (String (encode (Number (D (castWord64ToDouble (read (T.unpack (text' "bits" p))))))))
  "yaml.decode" -> Just (okOr (String . encode <$> decodeYaml (text' "text" p)))
  "yaml.encode" -> Just (String (encodeYaml (keyOr "value" p)))
  "schema.validate" -> Just $ case schemaNamed (text' "schema" p) of
    Nothing -> Object ["error" .= String "no such schema"]
    Just schema ->
      Array
        [ Object
            [ "path" .= String (Schema.errorInstancePath e)
            , "schemaPath" .= String (Schema.errorSchemaPath e)
            , "message" .= String (Schema.errorMessage e)
            ]
        | e <- Schema.validate schema (keyOr "instance" p)
        ]
  "semver.version" -> Just (okOr (String . Semver.renderVersion <$> Semver.parseVersion (text' "text" p)))
  "semver.requirement" -> Just $ case Semver.parseReq (text' "text" p) of
    Left e -> Object ["error" .= String e]
    Right req ->
      Object
        [ "ok" .= String (Semver.renderReq req)
        , "matches" .= Array [Array [String v, Bool (Semver.matches req version)] | v <- corpusVersions, Right version <- [Semver.parseVersion v]]
        ]
  "time.rfc3339" -> Just $ case parseRfc3339 (text' "text" p) of
    Left e -> Object ["error" .= String e]
    Right t -> Object ["ok" .= String (formatRfc3339 t), "unixNanos" .= String (T.pack (show (unixNanos t)))]
  "time.format" -> Just (String (formatRfc3339 (fromUnix (number "seconds") (number "nanos"))))
  "rust.debugStr" -> Just (String (debugStr (text' "text" p)))
  "serde.twin" -> Just (serde decodeTwin encodeTwin)
  "serde.real" -> Just (serde decodeReal encodeReal)
  "serde.fault" -> Just (serde decodeFault encodeFault)
  "serde.admin" -> Just (serde decodeAdmin encodeAdmin)
  _ -> Nothing
  where
    number k = case keyOr k p of
      Number (I n) -> n
      _ -> 0
    serde decoder encoder = case decodeWith decoder (keyOr "value" p) of
      Right v -> Object ["ok" .= String (encode (encoder v))]
      Left e -> Object ["error" .= String e]
