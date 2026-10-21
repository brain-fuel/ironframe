-- | A JSON Schema (draft 2020-12) validator for the schemas Ironframe embeds.
-- It reproduces jsonschema-rs 0.33.0: the same errors, in the order its
-- iter_errors gives them, with the same instance paths, schema paths and
-- messages. Keywords are applied in the order the schema writes them.
-- Keywords it does not implement are refused when the schema is compiled.
-- format is an annotation and is not asserted, as jsonschema-rs does for 2020-12.
-- ref:DEC-haskell-wasm-core
module Ironframe.Json.Schema
  ( Schema
  , SchemaError (..)
  , compile
  , validate
  , isValid
  ) where

import Control.Monad (foldM)
import Data.Char (chr, digitToInt, isHexDigit)
import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Set as Set
import Ironframe.Json (Number (..), Value (..), encode)
import qualified Ironframe.Regex as Regex

-- | A compiled schema: the root, the documents its references reach, and its patterns.
data Schema = Schema
  { schemaRoot :: Value
  , schemaBase :: Text
  , schemaDocuments :: Map.Map Text Value
  , schemaPatterns :: Map.Map Text Regex.Regex
  }

-- | One validation error, as jsonschema-rs reports it.
data SchemaError = SchemaError
  { errorInstancePath :: Text
  , errorSchemaPath :: Text
  , errorMessage :: Text
  }
  deriving (Show, Eq)

defaultBase :: Text
defaultBase = "json-schema:///"

-- | Compiles a root schema with extra resources registered by absolute URI.
compile :: [(Text, Value)] -> Value -> Either Text Schema
compile resources root = do
  let base = case root of
        Object kv | Just (String i) <- lookup "$id" kv -> stripFragment i
        _ -> defaultBase
      docs = Map.fromList ((base, root) : [(stripFragment u, v) | (u, v) <- resources])
  pats <- check docs base root
  let schema = Schema root base docs pats
  Right schema

-- | Every error of the instance, in jsonschema-rs's iter_errors order.
validate :: Schema -> Value -> [SchemaError]
validate s = node s (schemaBase s) [] (schemaRoot s) []

-- | Whether the instance is valid.
isValid :: Schema -> Value -> Bool
isValid s = null . validate s

-- Compile-time checks: references resolve, patterns compile, keywords are known.

-- | Keywords jsonschema-rs asserts that this validator does not.
unsupported :: Set.Set Text
unsupported =
  Set.fromList
    [ "contains", "minContains", "maxContains", "uniqueItems", "multipleOf", "prefixItems"
    , "additionalItems", "dependencies", "dependentRequired", "dependentSchemas"
    , "unevaluatedItems", "unevaluatedProperties", "$dynamicRef", "$dynamicAnchor", "$recursiveRef"
    ]

type Seen = (Set.Set Text, Map.Map Text Regex.Regex)

check :: Map.Map Text Value -> Text -> Value -> Either Text (Map.Map Text Regex.Regex)
check docs base0 root = snd <$> go (Set.empty, Map.empty) base0 root
  where
    go :: Seen -> Text -> Value -> Either Text Seen
    go seen base = \case
      Bool _ -> Right seen
      Object kv -> do
        let base' = case lookup "$id" kv of
              Just (String i) -> stripFragment (resolveUri base i)
              _ -> base
        foldM (checkKeyword base' kv) seen kv
      v -> Left ("a schema must be an object or a boolean, not " <> encode v)
    checkKeyword base kv seen (k, v)
      | k `Set.member` unsupported = Left ("unsupported keyword " <> k)
      | otherwise = case k of
          "$ref" -> case v of
            String r -> do
              let target = resolveUri base r
              if target `Set.member` fst seen
                then Right seen
                else do
                  (docUri, sub) <- resolveRef docs base r
                  go (Set.insert target (fst seen), snd seen) docUri sub
            _ -> Left "$ref must be a string"
          "properties" -> objectOf v >>= foldM (\s (_, sub) -> go s base sub) seen
          "patternProperties" -> do
            m <- objectOf v
            s' <- foldM (\s (p, _) -> regex s p) seen m
            foldM (\s (_, sub) -> go s base sub) s' m
          "pattern" -> case v of
            String p -> regex seen p
            _ -> Left "pattern must be a string"
          "additionalProperties" -> go seen base v
          "propertyNames" -> go seen base v
          "items" -> case v of
            Array xs -> foldM (\s sub -> go s base sub) seen xs
            _ -> go seen base v
          "not" -> go seen base v
          "if" -> do
            s1 <- go seen base v
            s2 <- maybe (Right s1) (go s1 base) (lookup "then" kv)
            maybe (Right s2) (go s2 base) (lookup "else" kv)
          _
            | k `elem` ["allOf", "anyOf", "oneOf"] -> case v of
                Array xs@(_ : _) -> foldM (\s sub -> go s base sub) seen xs
                _ -> Left (k <> " must be a non-empty array")
            | k `elem` ["minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties"] ->
                seen <$ count v
            | k `elem` ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"] -> case v of
                Number _ -> Right seen
                _ -> Left (k <> " must be a number")
            | k == "required" -> case v of
                Array xs | all isString xs -> Right seen
                _ -> Left "required must be an array of strings"
            | k == "enum" -> case v of
                Array _ -> Right seen
                _ -> Left "enum must be an array"
            | k == "type" -> seen <$ typesOf v
            | otherwise -> Right seen
    regex (refs, pats) p
      | Map.member p pats = Right (refs, pats)
      | otherwise = case Regex.compile p of
          Right r -> Right (refs, Map.insert p r pats)
          Left e -> Left ("invalid pattern " <> p <> ": " <> e)
    objectOf = \case
      Object m -> Right m
      _ -> Left "expected an object of schemas"
    isString = \case
      String _ -> True
      _ -> False

-- | A non-negative whole number, as jsonschema-rs reads a length limit.
count :: Value -> Either Text Integer
count = \case
  Number (I n) | n >= 0 -> Right n
  Number (D d) | d >= 0, fromInteger (truncate d) == d -> Right (truncate d)
  v -> Left ("expected a non-negative integer, not " <> encode v)

data JType = TArray | TBoolean | TInteger | TNull | TNumber | TObject | TString
  deriving (Eq, Ord, Enum, Bounded)

typeText :: JType -> Text
typeText = \case
  TArray -> "array"
  TBoolean -> "boolean"
  TInteger -> "integer"
  TNull -> "null"
  TNumber -> "number"
  TObject -> "object"
  TString -> "string"

typesOf :: Value -> Either Text [JType]
typesOf = \case
  String t -> (: []) <$> one t
  Array xs -> mapM (\case String t -> one t; _ -> Left "type must name types") xs
  _ -> Left "type must be a string or an array"
  where
    one t = maybe (Left ("unknown type " <> t)) Right (find ((== t) . typeText) [minBound .. maxBound])

hasType :: JType -> Value -> Bool
hasType t v = case (t, v) of
  (TArray, Array _) -> True
  (TBoolean, Bool _) -> True
  (TInteger, Number n) -> isInteger n
  (TNull, Null) -> True
  (TNumber, Number _) -> True
  (TObject, Object _) -> True
  (TString, String _) -> True
  _ -> False

isInteger :: Number -> Bool
isInteger = \case
  I _ -> True
  D d -> not (isNaN d || isInfinite d) && fromInteger (truncate d) == d

-- References.

stripFragment :: Text -> Text
stripFragment = T.takeWhile (/= '#')

-- | Resolves a reference against a base URI, keeping the fragment.
resolveUri :: Text -> Text -> Text
resolveUri base ref
  | T.null uriPart = stripFragment base <> frag
  | hasScheme uriPart = uriPart <> frag
  | "//" `T.isPrefixOf` uriPart = T.takeWhile (/= ':') base <> ":" <> uriPart <> frag
  | "/" `T.isPrefixOf` uriPart = authority <> normalise uriPart <> frag
  | otherwise = authority <> normalise (directory <> uriPart) <> frag
  where
    (uriPart, frag) = T.breakOn "#" ref
    b = stripFragment base
    hasScheme t = case T.breakOn ":" t of
      (s, rest) -> not (T.null rest) && not (T.null s) && T.all (\c -> c `notElem` ("/?" :: String)) s
    (schemeAuth, path) = case T.breakOn "://" b of
      (s, rest)
        | T.null rest -> (T.empty, b)
        | otherwise ->
            let afterScheme = T.drop 3 rest
                (auth, p) = T.breakOn "/" afterScheme
             in (s <> "://" <> auth, p)
    authority = schemeAuth
    directory = T.dropWhileEnd (/= '/') (if T.null path then "/" else path)
    normalise p = T.intercalate "/" (dots [] (T.splitOn "/" p))
    dots acc [] = reverse acc
    dots acc ["."] = reverse ("" : acc)
    dots acc [".."] = reverse ("" : drop 1 acc)
    dots acc ("." : rest) = dots acc rest
    dots acc (".." : rest) = dots (if length acc > 1 then drop 1 acc else acc) rest
    dots acc (x : rest) = dots (x : acc) rest

-- | The document a reference lands in and the subschema it names.
resolveRef :: Map.Map Text Value -> Text -> Text -> Either Text (Text, Value)
resolveRef docs base ref = do
  let target = resolveUri base ref
      (docUri, frag) = T.breakOn "#" target
  doc <- maybe (Left ("unresolvable reference " <> ref)) Right (Map.lookup docUri docs)
  let fragment = T.drop 1 frag
  sub <-
    if T.null fragment
      then Right doc
      else
        if "/" `T.isPrefixOf` fragment
          then maybe (Left ("unresolvable reference " <> ref)) Right (walk doc (map unescape (drop 1 (T.splitOn "/" (percentDecode fragment)))))
          else Left ("unsupported anchor reference " <> ref)
  Right (docUri, sub)
  where
    walk v [] = Just v
    walk (Object kv) (k : ks) = lookup k kv >>= (`walk` ks)
    walk (Array xs) (k : ks) = case reads (T.unpack k) of
      [(i, "")] | i >= 0, i < length xs -> walk (xs !! i) ks
      _ -> Nothing
    walk _ _ = Nothing
    unescape = T.replace "~0" "~" . T.replace "~1" "/"

percentDecode :: Text -> Text
percentDecode = T.pack . go . T.unpack
  where
    go ('%' : a : b : rest) | isHexDigit a, isHexDigit b = chr (digitToInt a * 16 + digitToInt b) : go rest
    go (c : rest) = c : go rest
    go [] = []

-- Validation.

-- | A JSON pointer from segments in order.
pointer :: [Text] -> Text
pointer = T.concat . map (\s -> "/" <> T.replace "/" "~1" (T.replace "~" "~0" s))

-- | The errors of one schema node; schema and instance paths are kept reversed.
node :: Schema -> Text -> [Text] -> Value -> [Text] -> Value -> [SchemaError]
node s base spath schema ipath inst = case schema of
  Bool True -> []
  Bool False -> [err spath ipath ("False schema does not allow " <> encode inst)]
  Object kv ->
    let base' = case lookup "$id" kv of
          Just (String i) -> stripFragment (resolveUri base i)
          _ -> base
     in concatMap (keyword s base' spath kv ipath inst) kv
  _ -> []

err :: [Text] -> [Text] -> Text -> SchemaError
err spath ipath = SchemaError (pointer (reverse ipath)) (pointer (reverse spath))

valid :: Schema -> Text -> [Text] -> Value -> Value -> Bool
valid s base spath schema inst = null (node s base spath schema [] inst)

keyword :: Schema -> Text -> [Text] -> [(Text, Value)] -> [Text] -> Value -> (Text, Value) -> [SchemaError]
keyword s base spath parent ipath inst (k, v) = case k of
  "$ref" -> case v of
    String r -> case resolveRef (schemaDocuments s) base r of
      Right (docUri, sub) -> node s docUri here sub ipath inst
      Left _ -> []
    _ -> []
  "type" -> case typesOf v of
    Right [t] | not (hasType t inst) -> [e (encode inst <> " is not of type \"" <> typeText t <> "\"")]
    Right ts@(_ : _ : _)
      | not (any (`hasType` inst) ts) ->
          [e (encode inst <> " is not of types " <> T.intercalate ", " [quote (typeText t) | t <- [minBound .. maxBound], t `elem` ts])]
    _ -> []
  "const" -> [e (encode v <> " was expected") | not (equal v inst)]
  "enum" -> case v of
    Array xs | not (any (equal inst) xs) -> [e (encode inst <> " is not one of " <> options xs)]
    _ -> []
  "required" -> case (v, inst) of
    (Array names, Object m) -> [e (encode n <> " is a required property") | n@(String name) <- names, isNothingIn name m]
    _ -> []
  "minLength" -> withString $ \t -> limit (\n -> toInteger (T.length t) < n) (\n -> " is shorter than " <> plural n "character" "characters")
  "maxLength" -> withString $ \t -> limit (\n -> toInteger (T.length t) > n) (\n -> " is longer than " <> plural n "character" "characters")
  "minItems" -> withArray $ \xs -> limit (\n -> toInteger (length xs) < n) (\n -> " has less than " <> plural n "item" "items")
  "maxItems" -> withArray $ \xs -> limit (\n -> toInteger (length xs) > n) (\n -> " has more than " <> plural n "item" "items")
  "minProperties" -> withObject $ \m -> limit (\n -> toInteger (length m) < n) (\n -> " has less than " <> plural n "property" "properties")
  "maxProperties" -> withObject $ \m -> limit (\n -> toInteger (length m) > n) (\n -> " has more than " <> plural n "property" "properties")
  "minimum" -> numeric (>=) " is less than the minimum of "
  "maximum" -> numeric (<=) " is greater than the maximum of "
  "exclusiveMinimum" -> numeric (>) " is less than or equal to the minimum of "
  "exclusiveMaximum" -> numeric (<) " is greater than or equal to the maximum of "
  "pattern" -> case (v, inst) of
    (String p, String t)
      | Just r <- Map.lookup p (schemaPatterns s)
      , not (Regex.match r t) ->
          [e (encode inst <> " does not match \"" <> Regex.rustPattern p <> "\"")]
    _ -> []
  "properties" -> case lookup "additionalProperties" parent of
    Just (Bool False) -> []
    Just (Object _) -> []
    _ -> case (v, inst) of
      (Object props, Object m) ->
        concat [node s base (name : here) sub (name : ipath) x | (name, sub) <- props, Just x <- [lookup name m]]
      _ -> []
  "patternProperties" -> case lookup "additionalProperties" parent of
    Just (Bool False) -> []
    Just (Object _) -> []
    _ -> case (v, inst) of
      (Object pats, Object m) ->
        concat [node s base (p : here) sub (key : ipath) x | (p, sub) <- pats, (key, x) <- m, matches p key]
      _ -> []
  "additionalProperties" -> additional
  "propertyNames" -> case (v, inst) of
    (Bool False, Object m@(_ : _)) -> [e ("False schema does not allow " <> encode (Object m))]
    (Object _, Object m) -> [er {errorInstancePath = pointer (reverse ipath)} | (key, _) <- m, er <- node s base here v ipath (String key)]
    _ -> []
  "items" -> case (v, inst) of
    (Array subs, Array xs) -> concat [node s base (T.pack (show i) : here) sub (T.pack (show i) : ipath) x | (i, sub, x) <- zip3 [0 :: Int ..] subs xs]
    (Bool True, _) -> []
    (_, Array xs) -> concat [node s base here v (T.pack (show i) : ipath) x | (i, x) <- zip [0 :: Int ..] xs]
    _ -> []
  "allOf" -> case v of
    Array subs -> concat [node s base (T.pack (show i) : here) sub ipath inst | (i, sub) <- zip [0 :: Int ..] subs]
    _ -> []
  "anyOf" -> case v of
    Array subs
      | not (or [valid s base (T.pack (show i) : here) sub inst | (i, sub) <- zip [0 :: Int ..] subs]) ->
          [e (encode inst <> " is not valid under any of the schemas listed in the 'anyOf' keyword")]
    _ -> []
  "oneOf" -> case v of
    Array subs -> case length (take 2 [() | (i, sub) <- zip [0 :: Int ..] subs, valid s base (T.pack (show i) : here) sub inst]) of
      0 -> [e (encode inst <> " is not valid under any of the schemas listed in the 'oneOf' keyword")]
      1 -> []
      _ -> [e (encode inst <> " is valid under more than one of the schemas listed in the 'oneOf' keyword")]
    _ -> []
  "not" -> [e (encode v <> " is not allowed for " <> encode inst) | valid s base here v inst]
  "if" ->
    let thenS = lookup "then" parent
        elseS = lookup "else" parent
     in if not (isJust thenS || isJust elseS)
          then []
          else
            if valid s base here v inst
              then maybe [] (\t -> node s base ("then" : spath) t ipath inst) thenS
              else maybe [] (\t -> node s base ("else" : spath) t ipath inst) elseS
  _ -> []
  where
    here = k : spath
    e = err here ipath
    quote t = "\"" <> t <> "\""
    isNothingIn name m = not (any ((== name) . fst) m)
    plural n one many = T.pack (show n) <> " " <> (if n == 1 then one else many)
    limit failing message = case count v of
      Right n | failing n -> [e (encode inst <> message n)]
      _ -> []
    withString f = case inst of String t -> f t; _ -> []
    withArray f = case inst of Array xs -> f xs; _ -> []
    withObject f = case inst of Object m -> f m; _ -> []
    numeric ok message = case (v, inst) of
      (Number lim, Number x) | not (rational x `ok` rational lim) -> [e (encode inst <> message <> encode v)]
      _ -> []
    matches p key = maybe False (`Regex.match` key) (Map.lookup p (schemaPatterns s))
    -- additionalProperties, which also applies properties and patternProperties beside it.
    additional = case inst of
      Object m ->
        let props = case lookup "properties" parent of Just (Object ps) -> Just ps; _ -> Nothing
            pats = case lookup "patternProperties" parent of Just (Object ps) -> Just ps; _ -> Nothing
            propErrors name x = case props >>= lookup name of
              Just sub -> Just (node s base (name : "properties" : spath) sub (name : ipath) x)
              Nothing -> Nothing
            patErrors key x = [node s base (p : "patternProperties" : spath) sub (key : ipath) x | (p, sub) <- concat pats, matches p key]
            rest key x = node s base here v (key : ipath) x
            unexpectedError keys =
              [ e
                  ( "Additional properties are not allowed ("
                      <> T.intercalate ", " ["'" <> key <> "'" | key <- keys]
                      <> (if length keys == 1 then " was unexpected)" else " were unexpected)")
                  )
              | not (null keys)
              ]
         in case v of
              Bool True -> []
              Bool False -> case (props, pats) of
                (Nothing, Nothing) -> case m of
                  (_, x) : _ -> [err here ipath ("False schema does not allow " <> encode x)]
                  [] -> []
                _ ->
                  let step (key, x) = case propErrors key x of
                        Just es -> (es ++ concat (patErrors key x), [])
                        Nothing -> case patErrors key x of
                          [] -> ([], [key])
                          es -> (concat es, [])
                      results = map step m
                   in concatMap fst results ++ unexpectedError (concatMap snd results)
              _ ->
                concat
                  [ case propErrors key x of
                    Just es -> es ++ concat (patErrors key x)
                    Nothing
                      | any (\(p, _) -> matches p key) (concat pats) -> concat (patErrors key x)
                      | otherwise -> rest key x
                  | (key, x) <- m
                  ]
      _ -> []

-- | The options of an enum as jsonschema-rs lists them.
options :: [Value] -> Text
options xs
  | length xs <= 3 = case map encode xs of
      [] -> ""
      [a] -> a
      y : ys -> joinOr y ys
  | otherwise = T.intercalate ", " (map encode (take 2 xs)) <> " or " <> T.pack (show (length xs - 2)) <> " other candidates"

-- | Joins options as "a, b or c".
joinOr :: Text -> [Text] -> Text
joinOr a = \case
  [] -> a
  [b] -> a <> " or " <> b
  b : rest -> a <> ", " <> joinOr b rest

rational :: Number -> Rational
rational = \case
  I n -> toRational n
  D d -> toRational d

-- | JSON Schema equality: numbers by value, objects key by key in order.
equal :: Value -> Value -> Bool
equal a b = case (a, b) of
  (Number x, Number y) -> rational x == rational y
  (Array xs, Array ys) -> length xs == length ys && and (zipWith equal xs ys)
  (Object xs, Object ys) -> length xs == length ys && and (zipWith (\(k1, v1) (k2, v2) -> k1 == k2 && equal v1 v2) xs ys)
  _ -> a == b
