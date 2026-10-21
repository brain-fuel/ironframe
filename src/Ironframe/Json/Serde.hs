-- | Typed decoding of JSON values with the messages serde gives when
-- serde_json's @from_value@ reads a value into a Rust type with derived
-- Deserialize. Objects are read entry by entry in their order, as serde
-- reads them, so the first error in entry order wins. Missing fields are
-- then reported in declaration order. A struct also reads from an array,
-- positionally, as derived visit_seq does. ref:DEC-haskell-wasm-core
module Ironframe.Json.Serde
  ( -- * Decoders
    Decoder
  , decodeWith
  , mapDecoder
  , unexpected
  , invalidType
  , invalidValue
  , invalidLength
  , oneOf
    -- * Primitives
  , string
  , pathBuf
  , bool
  , u8
  , u16
  , u32
  , u64
  , i8
  , i16
  , i32
  , i64
  , f64
  , value
  , unitValue
  , option
  , vec
  , textMap
    -- * Structs
  , Fields
  , struct
  , required
  , optional
  , optionalNoDefault
  , defaulted
    -- * Enums
  , unitVariants
  , externallyTagged
  , untagged
  ) where

import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as T
import Ironframe.Json
import Ironframe.Rust (debugStr)

-- | A reader of one Rust type from a JSON value.
newtype Decoder a = Decoder {runDecoder :: Value -> Either Text a}

instance Functor Decoder where
  fmap f (Decoder g) = Decoder (fmap f . g)

-- | @serde_json::from_value@: the value as the type, or serde's message.
decodeWith :: Decoder a -> Value -> Either Text a
decodeWith = runDecoder

-- | A decoder written by hand.
mapDecoder :: (Value -> Either Text a) -> Decoder a
mapDecoder = Decoder

-- | How serde_json names a value it did not expect: serde's Unexpected, with
-- null for unit and floats as serde_json writes them.
unexpected :: Value -> Text
unexpected = \case
  Null -> "null"
  Bool b -> "boolean `" <> (if b then "true" else "false") <> "`"
  Number (I n) -> "integer `" <> T.pack (show n) <> "`"
  Number (D d) -> "floating point `" <> formatDouble d <> "`"
  String s -> "string " <> debugStr s
  Array _ -> "sequence"
  Object _ -> "map"

-- | serde's @invalid_type@ message.
invalidType :: Value -> Text -> Text
invalidType v expected = "invalid type: " <> unexpected v <> ", expected " <> expected

-- | serde's @invalid_value@ message.
invalidValue :: Value -> Text -> Text
invalidValue v expected = "invalid value: " <> unexpected v <> ", expected " <> expected

-- | serde's @invalid_length@ message.
invalidLength :: Int -> Text -> Text
invalidLength n expected = "invalid length " <> T.pack (show n) <> ", expected " <> expected

-- | serde's list of names: @`a`@, @`a` or `b`@, or @one of `a`, `b`, `c`@.
oneOf :: [Text] -> Text
oneOf = \case
  [a] -> tick a
  [a, b] -> tick a <> " or " <> tick b
  names -> "one of " <> T.intercalate ", " (map tick names)

-- | A name in backticks.
tick :: Text -> Text
tick t = "`" <> t <> "`"

-- | @String@.
string :: Decoder Text
string = Decoder $ \case
  String s -> Right s
  v -> Left (invalidType v "a string")

-- | @PathBuf@, which reads a string and calls it a path string.
pathBuf :: Decoder Text
pathBuf = Decoder $ \case
  String s -> Right s
  v -> Left (invalidType v "path string")

-- | @bool@.
bool :: Decoder Bool
bool = Decoder $ \case
  Bool b -> Right b
  v -> Left (invalidType v "a boolean")

-- | An integer type by name and range. serde_json hands a non-negative whole
-- number to visit_u64 and a negative one to visit_i64, and each says invalid
-- value when out of range; a float is an invalid type.
integer :: Text -> Integer -> Integer -> Decoder Integer
integer name lo hi = Decoder $ \case
  v@(Number (I n))
    | n >= lo && n <= hi -> Right n
    | otherwise -> Left (invalidValue v name)
  v -> Left (invalidType v name)

-- | The Rust integer types, by name.
u8, u16, u32, u64, i8, i16, i32, i64 :: Decoder Integer
u8 = integer "u8" 0 255
u16 = integer "u16" 0 65535
u32 = integer "u32" 0 4294967295
u64 = integer "u64" 0 18446744073709551615
i8 = integer "i8" (-128) 127
i16 = integer "i16" (-32768) 32767
i32 = integer "i32" (-2147483648) 2147483647
i64 = integer "i64" (-9223372036854775808) 9223372036854775807

-- | @f64@: any number.
f64 :: Decoder Double
f64 = Decoder $ \case
  Number (I n) -> Right (fromInteger n)
  Number (D d) -> Right d
  v -> Left (invalidType v "f64")

-- | @serde_json::Value@: anything.
value :: Decoder Value
value = Decoder Right

-- | @()@: null.
unitValue :: Decoder ()
unitValue = Decoder $ \case
  Null -> Right ()
  v -> Left (invalidType v "unit")

-- | @Option<T>@: null is None.
option :: Decoder a -> Decoder (Maybe a)
option d = Decoder $ \case
  Null -> Right Nothing
  v -> Just <$> runDecoder d v

-- | @Vec<T>@, element by element.
vec :: Decoder a -> Decoder [a]
vec d = Decoder $ \case
  Array items -> mapM (runDecoder d) items
  v -> Left (invalidType v "a sequence")

-- | @BTreeMap<String, T>@, entry by entry.
textMap :: Decoder a -> Decoder (Map Text a)
textMap d = Decoder $ \case
  Object pairs -> Map.fromList <$> mapM (\(k, v) -> (,) k <$> runDecoder d v) pairs
  v -> Left (invalidType v "a map")

------------------------------------------------------------------------------
-- Structs

-- One field: its name, a check of its value, how it is built from an
-- object's value or its absence, and how from an array's element.
data Field = Field
  { fieldName :: Text
  , fieldCheck :: Value -> Maybe Text
  }

-- | The fields of a struct, in declaration order, built applicatively.
data Fields a = Fields
  { fieldList :: [Field]
  , fromObject :: Map Text Value -> Either Text a
  , fromArray :: Text -> Int -> [Value] -> Either Text (a, Int, [Value])
  }

instance Functor Fields where
  fmap f (Fields l o a) = Fields l (fmap f . o) (\e i vs -> (\(x, j, r) -> (f x, j, r)) <$> a e i vs)

instance Applicative Fields where
  pure x = Fields [] (const (Right x)) (\_ i vs -> Right (x, i, vs))
  Fields l1 o1 a1 <*> Fields l2 o2 a2 =
    Fields
      (l1 ++ l2)
      (\m -> o1 m <*> o2 m)
      ( \e i vs -> do
          (f, j, rest) <- a1 e i vs
          (x, k, rest') <- a2 e j rest
          pure (f x, k, rest')
      )

-- | A field with what to do when it is absent from an object, and from an
-- array too short for it.
field :: Text -> Decoder a -> Either Text a -> Maybe a -> Fields a
field name d absent seqDefault =
  Fields
    [Field name (\v -> either Just (const Nothing) (runDecoder d v))]
    (\m -> maybe absent (runDecoder d) (Map.lookup name m))
    ( \expecting i -> \case
        (v : rest) -> (\x -> (x, i + 1, rest)) <$> runDecoder d v
        [] -> case seqDefault of
          Just x -> Right (x, i + 1, [])
          Nothing -> Left (invalidLength i expecting)
    )

-- | A field with no default: absent is @missing field `name`@.
required :: Text -> Decoder a -> Fields a
required name d = field name d (Left ("missing field `" <> name <> "`")) Nothing

-- | An @Option<T>@ field with @#[serde(default)]@, as every optional field of
-- the manifest is: absent or null is Nothing.
optional :: Text -> Decoder a -> Fields (Maybe a)
optional name d = field name (option d) (Right Nothing) (Just Nothing)

-- | An @Option<T>@ field without @#[serde(default)]@: absent from an object
-- is Nothing, but an array too short for it is an invalid length.
optionalNoDefault :: Text -> Decoder a -> Fields (Maybe a)
optionalNoDefault name d = field name (option d) (Right Nothing) Nothing

-- | A field with @#[serde(default)]@ or @#[serde(default = "...")]@.
defaulted :: Text -> a -> Decoder a -> Fields a
defaulted name def d = field name d (Right def) (Just def)

-- | A struct with derived Deserialize, by its name, whether it denies
-- unknown fields, and its fields.
struct :: Text -> Bool -> Fields a -> Decoder a
struct name deny fields = Decoder $ \case
  Object pairs -> do
    let checks = Map.fromList [(fieldName f, fieldCheck f) | f <- fieldList fields]
        names = map fieldName (fieldList fields)
        go [] = Right ()
        go ((k, v) : rest) = case Map.lookup k checks of
          Just c -> maybe (go rest) Left (c v)
          Nothing
            | deny -> Left (unknownField k names)
            | otherwise -> go rest
    go pairs
    fromObject fields (Map.fromList pairs)
  Array items -> do
    let count = length (fieldList fields)
        expecting =
          "struct " <> name <> " with " <> T.pack (show count) <> (if count == 1 then " element" else " elements")
    (x, _, rest) <- fromArray fields expecting 0 items
    if null rest then Right x else Left (invalidLength (length items) "fewer elements in array")
  v -> Left (invalidType v ("struct " <> name))

-- | serde's @unknown_field@ message.
unknownField :: Text -> [Text] -> Text
unknownField k = \case
  [] -> "unknown field `" <> k <> "`, there are no fields"
  names -> "unknown field `" <> k <> "`, expected " <> oneOf names

-- | serde's @unknown_variant@ message.
unknownVariant :: Text -> [Text] -> Text
unknownVariant k = \case
  [] -> "unknown variant `" <> k <> "`, there are no variants"
  names -> "unknown variant `" <> k <> "`, expected " <> oneOf names

------------------------------------------------------------------------------
-- Enums

-- | serde_json's deserialize_enum: a string names a variant with no value; an
-- object of one key names a variant and holds its value.
enumAccess :: [Text] -> Value -> Either Text (Text, Maybe Value)
enumAccess names = \case
  String s -> check s Nothing
  Object [(k, v)] -> check k (Just v)
  v@(Object _) -> Left (invalidValue v "map with a single key")
  v -> Left (invalidType v "string or map")
  where
    check k v
      | k `elem` names = Right (k, v)
      | otherwise = Left (unknownVariant k names)

-- | An enum of unit variants, by name and Rust's name for each variant as
-- renamed: @"podman"@, or @{"podman": null}@.
unitVariants :: Text -> [(Text, a)] -> Decoder a
unitVariants _ variants = Decoder $ \v -> do
  (k, inner) <- enumAccess (map fst variants) v
  maybe (Right ()) (runDecoder unitValue) inner
  maybe (Left (unknownVariant k (map fst variants))) Right (lookup k variants)

-- | An externally tagged enum of newtype variants: @{"real": {...}}@.
externallyTagged :: Text -> [(Text, Decoder a)] -> Decoder a
externallyTagged _ variants = Decoder $ \v -> do
  (k, inner) <- enumAccess (map fst variants) v
  d <- maybe (Left (unknownVariant k (map fst variants))) Right (lookup k variants)
  case inner of
    Nothing -> Left "invalid type: unit variant, expected newtype variant"
    Just x -> runDecoder d x

-- | An untagged enum: the first variant that reads the value.
untagged :: Text -> [Decoder a] -> Decoder a
untagged name ds = Decoder $ \v ->
  case [a | Right a <- map (`runDecoder` v) ds] of
    (a : _) -> Right a
    [] -> Left ("data did not match any variant of untagged enum " <> name)
