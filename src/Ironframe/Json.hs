-- | JSON values as Ironframe reads and writes them: objects keep their keys in
-- the order given, numbers are whole numbers or floating point, and text is
-- written byte for byte as serde_json writes it, compact or indented.
-- ref:DEC-haskell-wasm-core
module Ironframe.Json
  ( Value (..)
  , Number (..)
  , encode
  , encodePretty
  , encodeString
  , formatDouble
  , decode
  , object
  , (.=)
  , key
  , keyOr
  , textAt
  , textsAt
  , isObject
  , insert
  , delete
  , member
  , toMap
  , fromTextMap
  , typeName
  ) where

import Data.Char (chr, isDigit, isHexDigit, ord)
import Data.List (foldl')
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Numeric (floatToDigits, showHex)

-- | A JSON number: whole numbers that fit 64 bits, as serde_json keeps them,
-- and every other number as a double.
data Number = I !Integer | D !Double
  deriving (Show)

instance Eq Number where
  I a == I b = a == b
  D a == D b = a == b
  I a == D b = fromInteger a == b
  D a == I b = a == fromInteger b

-- | A JSON value; an object's pairs keep the order they were given or read in.
data Value
  = Null
  | Bool !Bool
  | Number !Number
  | String !Text
  | Array [Value]
  | Object [(Text, Value)]
  deriving (Show, Eq)

-- | An object from pairs, the last of a repeated key winning in its first place.
object :: [(Text, Value)] -> Value
object = Object . foldl' (\acc (k, v) -> insertPair k v acc) []

(.=) :: Text -> Value -> (Text, Value)
k .= v = (k, v)
infixr 8 .=

-- | Sets a key, keeping its place when it is already there.
insertPair :: Text -> Value -> [(Text, Value)] -> [(Text, Value)]
insertPair k v pairs
  | any ((== k) . fst) pairs = [(k', if k' == k then v else v') | (k', v') <- pairs]
  | otherwise = pairs ++ [(k, v)]

insert :: Text -> Value -> Value -> Value
insert k v (Object pairs) = Object (insertPair k v pairs)
insert k v _ = Object [(k, v)]

delete :: Text -> Value -> Value
delete k (Object pairs) = Object (filter ((/= k) . fst) pairs)
delete _ v = v

member :: Text -> Value -> Bool
member k (Object pairs) = any ((== k) . fst) pairs
member _ _ = False

-- | The value under a key, as serde_json's index reads it: absent is nothing.
key :: Text -> Value -> Maybe Value
key k (Object pairs) = lookup k pairs
key _ _ = Nothing

-- | The value under a key, or null, as serde_json's @value[key]@ reads it.
keyOr :: Text -> Value -> Value
keyOr k v = maybe Null id (key k v)

textAt :: Text -> Value -> Maybe Text
textAt k v = case key k v of
  Just (String t) -> Just t
  _ -> Nothing

-- | The strings of an array under a key, skipping anything else.
textsAt :: Text -> Value -> [Text]
textsAt k v = case key k v of
  Just (Array items) -> [t | String t <- items]
  _ -> []

isObject :: Value -> Bool
isObject (Object _) = True
isObject _ = False

toMap :: Value -> Map.Map Text Value
toMap (Object pairs) = Map.fromList pairs
toMap _ = Map.empty

fromTextMap :: Map.Map Text Text -> Value
fromTextMap m = Object [(k, String v) | (k, v) <- Map.toAscList m]

-- | The word serde uses for a value's type.
typeName :: Value -> Text
typeName = \case
  Null -> "null"
  Bool _ -> "boolean"
  Number _ -> "number"
  String _ -> "string"
  Array _ -> "array"
  Object _ -> "object"

-- | serde_json's @to_string@.
encode :: Value -> Text
encode = T.concat . go
  where
    go = \case
      Null -> ["null"]
      Bool b -> [if b then "true" else "false"]
      Number n -> [encodeNumber n]
      String s -> [encodeString s]
      Array items -> ["["] ++ commas (map go items) ++ ["]"]
      Object pairs -> ["{"] ++ commas [encodeString k : ":" : go v | (k, v) <- pairs] ++ ["}"]
    commas [] = []
    commas (x : xs) = x ++ concatMap ("," :) xs

-- | serde_json's @to_string_pretty@: two spaces of indent, @": "@ after a key.
encodePretty :: Value -> Text
encodePretty v0 = T.concat (go 0 v0)
  where
    go :: Int -> Value -> [Text]
    go depth = \case
      Array [] -> ["[]"]
      Object [] -> ["{}"]
      Array items ->
        ["[\n"] ++ joinLines depth [indent (depth + 1) : go (depth + 1) v | v <- items] ++ ["\n", indent depth, "]"]
      Object pairs ->
        ["{\n"]
          ++ joinLines depth [indent (depth + 1) : encodeString k : ": " : go (depth + 1) v | (k, v) <- pairs]
          ++ ["\n", indent depth, "}"]
      other -> [encode other]
    joinLines :: Int -> [[Text]] -> [Text]
    joinLines _ [] = []
    joinLines _ (x : xs) = x ++ concatMap (",\n" :) xs
    indent n = T.replicate n "  "

encodeNumber :: Number -> Text
encodeNumber (I i) = T.pack (show i)
encodeNumber (D d)
  | isNaN d || isInfinite d = "null"
  | otherwise = formatDouble d

-- | A double as ryu writes it, which is how serde_json writes floats.
formatDouble :: Double -> Text
formatDouble d
  | d == 0 = if isNegativeZero d then "-0.0" else "0.0"
  | d < 0 = "-" <> formatDouble (negate d)
  | otherwise =
      let (digits, kk) = floatToDigits 10 d
          ds = map (\x -> chr (x + ord '0')) digits
          len = length ds
          k = kk - len
       in T.pack $
            if k >= 0 && kk <= 16
              then ds ++ replicate k '0' ++ ".0"
              else
                if kk > 0 && kk <= 16
                  then take kk ds ++ "." ++ drop kk ds
                  else
                    if kk > -5 && kk <= 0
                      then "0." ++ replicate (negate kk) '0' ++ ds
                      else case ds of
                        [c] -> c : 'e' : show (kk - 1)
                        (c : rest) -> c : '.' : rest ++ "e" ++ show (kk - 1)
                        [] -> "0.0"

-- | A JSON string literal as serde_json writes it.
encodeString :: Text -> Text
encodeString s = "\"" <> T.concatMap escape s <> "\""
  where
    escape c = case c of
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      '\r' -> "\\r"
      '\t' -> "\\t"
      '\b' -> "\\b"
      '\f' -> "\\f"
      _
        | ord c < 0x20 -> T.pack ("\\u" ++ pad (showHex (ord c) ""))
        | otherwise -> T.singleton c
    pad h = replicate (4 - length h) '0' ++ h

-- | Reads JSON text as serde_json's @from_str@ does, with its error messages.
decode :: Text -> Either Text Value
decode input = case parseValue 0 (Pos 1 0) (T.unpack input) of
  Left e -> Left e
  Right (v, pos, rest) -> case skipWs pos rest of
    (_, []) -> Right v
    (p, _ : _) -> Left (at "trailing characters" (advance p))

-- Position bookkeeping as serde_json reports it: the line, and the column of
-- the last character read.
data Pos = Pos !Int !Int

advance :: Pos -> Pos
advance (Pos l c) = Pos l (c + 1)

step :: Pos -> Char -> Pos
step (Pos l _) '\n' = Pos (l + 1) 0
step (Pos l c) _ = Pos l (c + 1)

at :: Text -> Pos -> Text
at msg (Pos l c) = msg <> " at line " <> T.pack (show l) <> " column " <> T.pack (show c)

skipWs :: Pos -> String -> (Pos, String)
skipWs p (c : rest) | c `elem` (" \t\n\r" :: String) = skipWs (step p c) rest
skipWs p s = (p, s)

type P a = Either Text (a, Pos, String)

recursionLimit :: Int
recursionLimit = 128

parseValue :: Int -> Pos -> String -> P Value
parseValue depth p0 s0 =
  let (p, s) = skipWs p0 s0
   in case s of
        [] -> Left (at "EOF while parsing a value" p)
        ('n' : _) -> literal "null" Null p s
        ('t' : _) -> literal "true" (Bool True) p s
        ('f' : _) -> literal "false" (Bool False) p s
        ('"' : rest) -> do
          (t, p', r) <- parseString (advance p) rest
          pure (String t, p', r)
        ('[' : rest)
          | depth >= recursionLimit -> Left (at "recursion limit exceeded" (advance p))
          | otherwise -> parseArray (depth + 1) (advance p) rest
        ('{' : rest)
          | depth >= recursionLimit -> Left (at "recursion limit exceeded" (advance p))
          | otherwise -> parseObject (depth + 1) (advance p) rest
        (c : _)
          | c == '-' || isDigit c -> parseNumber p s
          | otherwise -> Left (at "expected value" (advance p))

literal :: String -> Value -> Pos -> String -> P Value
literal word v p s = go word p s
  where
    go [] q r = Right (v, q, r)
    go (w : ws) q (c : r)
      | w == c = go ws (advance q) r
      | otherwise = Left (at "expected ident" (advance q))
    go _ q [] = Left (at "EOF while parsing a value" q)

parseArray :: Int -> Pos -> String -> P Value
parseArray depth p0 s0 =
  let (p, s) = skipWs p0 s0
   in case s of
        (']' : rest) -> Right (Array [], advance p, rest)
        [] -> Left (at "EOF while parsing a list" p)
        _ -> loop [] p s
  where
    loop acc p s = do
      (v, p1, r1) <- parseValue depth p s
      let (p2, r2) = skipWs p1 r1
      case r2 of
        (',' : r3) ->
          let (p3, r4) = skipWs (advance p2) r3
           in case r4 of
                (']' : _) -> Left (at "trailing comma" (advance p3))
                [] -> Left (at "EOF while parsing a value" p3)
                _ -> loop (v : acc) p3 r4
        (']' : r3) -> Right (Array (reverse (v : acc)), advance p2, r3)
        [] -> Left (at "EOF while parsing a list" p2)
        _ -> Left (at "expected `,` or `]`" (advance p2))

parseObject :: Int -> Pos -> String -> P Value
parseObject depth p0 s0 =
  let (p, s) = skipWs p0 s0
   in case s of
        ('}' : rest) -> Right (Object [], advance p, rest)
        [] -> Left (at "EOF while parsing an object" p)
        _ -> loop [] p s
  where
    loop acc p s = case s of
      ('"' : r0) -> do
        (k, p1, r1) <- parseString (advance p) r0
        let (p2, r2) = skipWs p1 r1
        case r2 of
          (':' : r3) -> do
            (v, p4, r4) <- parseValue depth (advance p2) r3
            let acc' = insertPair k v acc
                (p5, r5) = skipWs p4 r4
            case r5 of
              (',' : r6) ->
                let (p6, r7) = skipWs (advance p5) r6
                 in case r7 of
                      ('}' : _) -> Left (at "trailing comma" (advance p6))
                      [] -> Left (at "EOF while parsing a value" p6)
                      _ -> loop acc' p6 r7
              ('}' : r6) -> Right (Object acc', advance p5, r6)
              [] -> Left (at "EOF while parsing an object" p5)
              _ -> Left (at "expected `,` or `}`" (advance p5))
          [] -> Left (at "EOF while parsing an object" p2)
          _ -> Left (at "expected `:`" (advance p2))
      [] -> Left (at "EOF while parsing an object" p)
      _ -> Left (at "key must be a string" (advance p))

parseString :: Pos -> String -> P Text
parseString = go []
  where
    go acc p s = case s of
      [] -> Left (at "EOF while parsing a string" p)
      ('"' : rest) -> Right (T.pack (reverse acc), advance p, rest)
      ('\\' : rest) -> escapeChar acc (advance p) rest
      (c : rest)
        | ord c < 0x20 -> Left (at "control character (\\u0000-\\u001F) found while parsing a string" (step p c))
        | otherwise -> go (c : acc) (step p c) rest
    escapeChar acc p s = case s of
      [] -> Left (at "EOF while parsing a string" p)
      (c : rest) ->
        let p' = advance p
         in case c of
              '"' -> go ('"' : acc) p' rest
              '\\' -> go ('\\' : acc) p' rest
              '/' -> go ('/' : acc) p' rest
              'b' -> go ('\b' : acc) p' rest
              'f' -> go ('\f' : acc) p' rest
              'n' -> go ('\n' : acc) p' rest
              'r' -> go ('\r' : acc) p' rest
              't' -> go ('\t' : acc) p' rest
              'u' -> unicode acc p' rest
              _ -> Left (at "invalid escape" p')
    hex4 p s = case splitAt 4 s of
      (h, rest)
        | length h == 4 && all isHexDigit h -> Right (read ("0x" ++ h) :: Int, iterate advance p !! 4, rest)
        | otherwise ->
            let good = takeWhile isHexDigit h
                q = iterate advance p !! (length good + if length good < length h then 1 else 0)
             in if length h < 4 && length good == length h
                  then Left (at "EOF while parsing a string" q)
                  else Left (at "invalid escape" q)
    unicode acc p s = do
      (n, p1, r1) <- hex4 p s
      if n >= 0xD800 && n < 0xDC00
        then case r1 of
          ('\\' : 'u' : r2) -> do
            (m, p2, r3) <- hex4 (advance (advance p1)) r2
            if m >= 0xDC00 && m < 0xE000
              then go (chr (0x10000 + (n - 0xD800) * 0x400 + (m - 0xDC00)) : acc) p2 r3
              else Left (at "lone leading surrogate in hex escape" p2)
          _ -> Left (at "unexpected end of hex escape" p1)
        else
          if n >= 0xDC00 && n < 0xE000
            then Left (at "lone leading surrogate in hex escape" p1)
            else go (chr n : acc) p1 r1

parseNumber :: Pos -> String -> P Value
parseNumber p s =
  let (neg, s1, p1) = case s of
        ('-' : r) -> (True, r, advance p)
        _ -> (False, s, p)
   in case s1 of
        ('0' : r) | (c : _) <- r, isDigit c -> Left (at "invalid number" (advance (advance p1)))
        (c : _) | isDigit c ->
          let (intPart, r2) = span isDigit s1
              p2 = iterate advance p1 !! length intPart
           in fraction neg intPart p2 r2
        [] -> Left (at "EOF while parsing a value" p1)
        _ -> Left (at "invalid number" (advance p1))
  where
    fraction neg intPart p2 r2 = case r2 of
      ('.' : r3) ->
        let (frac, r4) = span isDigit r3
         in if null frac
              then case r3 of
                [] -> Left (at "EOF while parsing a value" (advance p2))
                _ -> Left (at "invalid number" (advance (advance p2)))
              else exponentPart neg intPart frac (iterate advance (advance p2) !! length frac) r4
      _ -> exponentPart neg intPart "" p2 r2
    exponentPart neg intPart frac p3 r = case r of
      (e : r4)
        | e == 'e' || e == 'E' ->
            let (sign, r5, p4) = case r4 of
                  ('+' : x) -> ("", x, advance (advance p3))
                  ('-' : x) -> ("-", x, advance (advance p3))
                  _ -> ("", r4, advance p3)
                (ex, r6) = span isDigit r5
             in if null ex
                  then case r5 of
                    [] -> Left (at "EOF while parsing a value" p4)
                    _ -> Left (at "invalid number" (advance p4))
                  else finish neg intPart frac (sign ++ ex) (iterate advance p4 !! length ex) r6
      _ -> finish neg intPart frac "" p3 r
    finish neg intPart frac ex p' rest
      | null frac && null ex =
          let n = (if neg then negate else id) (read intPart :: Integer)
           in if (neg && n >= -(2 ^ (63 :: Int))) || (not neg && n < 2 ^ (64 :: Int))
                then Right (Number (I n), p', rest)
                else Right (Number (D (fromInteger n)), p', rest)
      | otherwise =
          let txt = intPart ++ (if null frac then "" else '.' : frac) ++ (if null ex then "" else 'e' : ex)
              d = read (fixup txt) :: Double
           in if isInfinite d
                then Left (at "number out of range" p')
                else Right (Number (D (if neg then negate d else d)), p', rest)
    fixup t = case break (== 'e') t of
      (m, 'e' : '-' : e) -> m ++ "e-" ++ e
      (m, 'e' : e) -> m ++ "e" ++ e
      (m, _) -> m
