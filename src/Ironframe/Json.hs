-- | JSON values as Ironframe reads and writes them. Objects keep their keys in
-- the order given, as serde_json does with preserve_order. Numbers are whole
-- numbers that fit 64 bits, or doubles. Text is read and written byte for
-- byte as serde_json 1.0.151 reads and writes it, with its error messages.
-- ref:DEC-haskell-wasm-core
module Ironframe.Json
  ( Value (..)
  , Number (..)
  , encode
  , encodePretty
  , encodeString
  , formatDouble
  , decode
  , decodeBytes
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
  , u64ToDouble
  ) where

import Data.Bits (shiftL, shiftR, (.&.))
import qualified Data.ByteString as B
import Data.Char (chr, ord)
import qualified Data.List as L
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word8)
import GHC.Float (castDoubleToWord64)
import Numeric (showHex)

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
object = Object . L.foldl' (\acc (k, v) -> insertPair k v acc) []

-- | A pair for 'object'.
(.=) :: Text -> Value -> (Text, Value)
k .= v = (k, v)

infixr 8 .=

-- | Sets a key, keeping its place when it is already there.
insertPair :: Text -> Value -> [(Text, Value)] -> [(Text, Value)]
insertPair k v pairs
  | any ((== k) . fst) pairs = [(k', if k' == k then v else v') | (k', v') <- pairs]
  | otherwise = pairs ++ [(k, v)]

-- | Sets a key of an object; anything else becomes an object of that key.
insert :: Text -> Value -> Value -> Value
insert k v (Object pairs) = Object (insertPair k v pairs)
insert k v _ = Object [(k, v)]

-- | Removes a key from an object.
delete :: Text -> Value -> Value
delete k (Object pairs) = Object (filter ((/= k) . fst) pairs)
delete _ v = v

-- | Whether an object has a key.
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

-- | The string under a key, if it is one.
textAt :: Text -> Value -> Maybe Text
textAt k v = case key k v of
  Just (String t) -> Just t
  _ -> Nothing

-- | The strings of an array under a key, skipping anything else.
textsAt :: Text -> Value -> [Text]
textsAt k v = case key k v of
  Just (Array items) -> [t | String t <- items]
  _ -> []

-- | Whether a value is an object.
isObject :: Value -> Bool
isObject (Object _) = True
isObject _ = False

-- | An object's pairs as a map; anything else is empty.
toMap :: Value -> Map.Map Text Value
toMap (Object pairs) = Map.fromList pairs
toMap _ = Map.empty

-- | An object of strings, in key order.
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
        ["[\n"] ++ joinLines [indent (depth + 1) : go (depth + 1) v | v <- items] ++ ["\n", indent depth, "]"]
      Object pairs ->
        ["{\n"]
          ++ joinLines [indent (depth + 1) : encodeString k : ": " : go (depth + 1) v | (k, v) <- pairs]
          ++ ["\n", indent depth, "}"]
      other -> [encode other]
    joinLines :: [[Text]] -> [Text]
    joinLines [] = []
    joinLines (x : xs) = x ++ concatMap (",\n" :) xs
    indent n = T.replicate n "  "

-- | A number as serde_json writes it.
encodeNumber :: Number -> Text
encodeNumber (I i) = T.pack (show i)
encodeNumber (D d)
  | isNaN d || isInfinite d = "null"
  | otherwise = formatDouble d

-- | A finite double as serde_json writes it, through zmij: the shortest
-- digits that read back as the same double, fixed notation when the decimal
-- exponent is from -5 to 15, otherwise @1.5e+20@ style.
formatDouble :: Double -> Text
formatDouble d
  | isNaN d = "NaN"
  | isInfinite d = if d > 0 then "inf" else "-inf"
  | d == 0 = if isNegativeZero d then "-0.0" else "0.0"
  | d < 0 = "-" <> formatDouble (negate d)
  | otherwise =
      let (ds, kk) = shortestDigits d
          len = length ds
          e = kk - 1
       in T.pack $
            if e >= -5 && e <= 15
              then
                if len - 1 <= e
                  then ds ++ replicate (e + 1 - len) '0' ++ ".0"
                  else
                    if e >= 0
                      then take (e + 1) ds ++ "." ++ drop (e + 1) ds
                      else "0." ++ replicate (negate e - 1) '0' ++ ds
              else
                let mantissa = case ds of
                      [c] -> [c]
                      (c : rest) -> c : '.' : rest
                      [] -> "0"
                 in mantissa ++ "e" ++ (if e >= 0 then "+" else "-") ++ show (abs e)

-- | The shortest decimal digits that read back as a positive finite double,
-- and the exponent placing the point before them: the digits are
-- @0.d1d2.. * 10^k@. Reading rounds half to even, so the bounds of the
-- interval that reads back count when the significand is even. Of the
-- shortest candidates the one nearest the double wins, a tie going to the
-- even digit, as Ryu, Schubfach and zmij choose.
shortestDigits :: Double -> (String, Int)
shortestDigits d = (show digits, length (show digits) + q)
  where
    bits = castDoubleToWord64 d
    fraction = toInteger (bits .&. 0xFFFFFFFFFFFFF)
    biased = toInteger (bits `shiftR` 52) .&. 0x7FF
    (m2, e2) = if biased == 0 then (fraction, -1074 :: Int) else (fraction + 2 ^ (52 :: Int), fromInteger biased - 1075)
    ulp = if e2 >= 0 then toRational (2 ^ e2 :: Integer) else 1 / toRational (2 ^ negate e2 :: Integer)
    v = toRational m2 * ulp
    lo = v - (if fraction == 0 && biased > 1 then ulp / 4 else ulp / 2)
    hi = v + ulp / 2
    inclusive = even m2
    pow :: Int -> Rational
    pow k = if k >= 0 then toRational (10 ^ k :: Integer) else 1 / toRational (10 ^ negate k :: Integer)
    start = ceiling (logBase 10 d) + 2 :: Int
    (q, dlo, dhi) = search start
    -- The largest power of ten with a whole multiple in the interval gives
    -- the fewest digits; there always is one by 10^-1074.
    search k =
      let (a, b) = range k
       in if a <= b && b > 0 then (k, a, b) else search (k - 1)
    range k =
      let a0 = ceiling (lo / pow k)
          a = if not inclusive && toRational a0 * pow k == lo then a0 + 1 else a0
          b0 = floor (hi / pow k)
          b = if not inclusive && toRational b0 * pow k == hi then b0 - 1 else b0
       in (a :: Integer, b :: Integer)
    t = v / pow q
    below = max dlo (min dhi (floor t))
    above = max dlo (min dhi (below + 1))
    digits
      | t - toRational below < toRational above - t = below
      | t - toRational below > toRational above - t = above
      | even below = below
      | otherwise = above

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

-- | A whole number from 0 to 2^64 - 1 as the nearest double, ties to even, as
-- Rust's @u64 as f64@ rounds it.
u64ToDouble :: Integer -> Double
u64ToDouble n
  | n < 2 ^ (53 :: Int) = fromInteger n
  | otherwise =
      let sh = bitLength n - 53
          q = n `shiftR` sh
          r = n .&. ((1 `shiftL` sh) - 1)
          half = 1 `shiftL` (sh - 1)
          q' = if r > half || (r == half && odd q) then q + 1 else q
       in encodeFloat q' sh
  where
    bitLength :: Integer -> Int
    bitLength x = length (takeWhile (> 0) (iterate (`shiftR` 1) x))

------------------------------------------------------------------------------
-- Reading, as serde_json's Deserializer over a str reads into a Value.

-- | Reads JSON text as serde_json's @from_str::<Value>@ does, with its error
-- messages and positions.
decode :: Text -> Either Text Value
decode = decodeBytes . TE.encodeUtf8

-- | 'decode' over UTF-8 bytes, which must be valid UTF-8.
decodeBytes :: B.ByteString -> Either Text Value
decodeBytes input = fst <$> unP whole input 0
  where
    whole = do
      v <- parseValue 128
      c <- whitespace
      case c of
        Nothing -> pure v
        Just _ -> peekError "trailing characters"

-- The parser: the input, the index of the next byte, and either an error or
-- a result with the new index.
newtype P a = P {unP :: B.ByteString -> Int -> Either Text (a, Int)}

instance Functor P where
  fmap f (P g) = P $ \s i -> case g s i of
    Left e -> Left e
    Right (a, j) -> Right (f a, j)

instance Applicative P where
  pure a = P $ \_ i -> Right (a, i)
  P f <*> P g = P $ \s i -> case f s i of
    Left e -> Left e
    Right (h, j) -> case g s j of
      Left e -> Left e
      Right (a, k) -> Right (h a, k)

instance Monad P where
  P g >>= f = P $ \s i -> case g s i of
    Left e -> Left e
    Right (a, j) -> unP (f a) s j

-- | The next byte, not consumed.
peek :: P (Maybe Word8)
peek = P $ \s i -> Right (if i < B.length s then Just (B.index s i) else Nothing, i)

-- | The next byte, or zero at the end.
peekOrNull :: P Word8
peekOrNull = maybe 0 id <$> peek

-- | Consumes the next byte.
eat :: P ()
eat = P $ \_ i -> Right ((), i + 1)

-- | Consumes and returns the next byte.
next :: P (Maybe Word8)
next = P $ \s i -> Right (if i < B.length s then (Just (B.index s i), i + 1) else (Nothing, i))

-- | The index of the next byte.
getIndex :: P Int
getIndex = P $ \_ i -> Right (i, i)

-- | Moves to an index.
setIndex :: Int -> P ()
setIndex j = P $ \_ _ -> Right ((), j)

-- | The length of the input.
inputLength :: P Int
inputLength = P $ \s i -> Right (B.length s, i)

-- | The bytes between two indexes.
slice :: Int -> Int -> P B.ByteString
slice a b = P $ \s i -> Right (B.take (b - a) (B.drop a s), i)

-- | An error at the index, as serde_json's @error@ places it.
failAt :: Text -> P a
failAt msg = P $ \s i -> Left (positioned msg s i)

-- | An error at the byte after the index, as serde_json's @peek_error@.
peekError :: Text -> P a
peekError msg = P $ \s i -> Left (positioned msg s (min (B.length s) (i + 1)))

-- | serde_json's message with the line and the byte column of an index.
positioned :: Text -> B.ByteString -> Int -> Text
positioned msg s i =
  let before = B.take i s
      startOfLine = maybe 0 (+ 1) (B.elemIndexEnd 10 before)
      line = 1 + B.count 10 (B.take startOfLine s)
      column = i - startOfLine
   in msg <> " at line " <> T.pack (show line) <> " column " <> T.pack (show column)

-- | Skips whitespace and returns the byte after it.
whitespace :: P (Maybe Word8)
whitespace =
  peek >>= \case
    Just c | c == 32 || c == 10 || c == 9 || c == 13 -> eat >> whitespace
    other -> pure other

-- | Whether a byte is an ASCII digit.
isDigitW :: Word8 -> Bool
isDigitW c = c >= 48 && c <= 57

-- | A value, with the nesting depth left, as @deserialize_any@.
parseValue :: Int -> P Value
parseValue depth =
  whitespace >>= \case
    Nothing -> peekError "EOF while parsing a value"
    Just c -> case c of
      110 -> eat >> ident "ull" >> pure Null
      116 -> eat >> ident "rue" >> pure (Bool True)
      102 -> eat >> ident "alse" >> pure (Bool False)
      45 -> eat >> (Number <$> parseInteger False)
      _ | isDigitW c -> Number <$> parseInteger True
      34 -> eat >> (String <$> parseStr)
      91 -> do
        let depth' = depth - 1
        if depth' == 0 then peekError "recursion limit exceeded" else pure ()
        eat
        items <- seqItems depth' True []
        endSeq
        pure (Array items)
      123 -> do
        let depth' = depth - 1
        if depth' == 0 then peekError "recursion limit exceeded" else pure ()
        eat
        pairs <- mapItems depth' True [] Set.empty
        endMap
        pure (Object pairs)
      _ -> peekError "expected value"

-- | The rest of a literal word.
ident :: String -> P ()
ident [] = pure ()
ident (w : ws) =
  next >>= \case
    Nothing -> failAt "EOF while parsing a value"
    Just c
      | fromIntegral c /= ord w -> failAt "expected ident"
      | otherwise -> ident ws

-- | An array's elements, as serde_json's SeqAccess reads them.
seqItems :: Int -> Bool -> [Value] -> P [Value]
seqItems depth first acc =
  whitespace >>= \case
    Nothing -> peekError "EOF while parsing a list"
    Just 93 -> pure (reverse acc)
    Just c
      | first -> item
      | c == 44 -> do
          eat
          whitespace >>= \case
            Just 93 -> peekError "trailing comma"
            Just _ -> item
            Nothing -> peekError "EOF while parsing a value"
      | otherwise -> peekError "expected `,` or `]`"
  where
    item = do
      v <- parseValue depth
      seqItems depth False (v : acc)

-- | The end of an array.
endSeq :: P ()
endSeq =
  whitespace >>= \case
    Just 93 -> eat
    Just 44 -> do
      eat
      whitespace >>= \case
        Just 93 -> peekError "trailing comma"
        _ -> peekError "trailing characters"
    Just _ -> peekError "trailing characters"
    Nothing -> peekError "EOF while parsing a list"

-- | An object's entries, as serde_json's MapAccess reads them; a repeated key
-- keeps its first place and its last value.
mapItems :: Int -> Bool -> [(Text, Value)] -> Set.Set Text -> P [(Text, Value)]
mapItems depth first acc seen =
  whitespace >>= \case
    Nothing -> peekError "EOF while parsing an object"
    Just 125 -> pure (reverse acc)
    Just c
      | first -> if c == 34 then entry else peekError "key must be a string"
      | c == 44 -> do
          eat
          whitespace >>= \case
            Just 34 -> entry
            Just 125 -> peekError "trailing comma"
            Just _ -> peekError "key must be a string"
            Nothing -> peekError "EOF while parsing a value"
      | otherwise -> peekError "expected `,` or `}`"
  where
    entry = do
      eat
      k <- parseStr
      whitespace >>= \case
        Just 58 -> eat
        Just _ -> peekError "expected `:`"
        Nothing -> peekError "EOF while parsing an object"
      v <- parseValue depth
      if Set.member k seen
        then mapItems depth False [(k', if k' == k then v else v') | (k', v') <- acc] seen
        else mapItems depth False ((k, v) : acc) (Set.insert k seen)

-- | The end of an object.
endMap :: P ()
endMap =
  whitespace >>= \case
    Just 125 -> eat
    Just 44 -> peekError "trailing comma"
    Just _ -> peekError "trailing characters"
    Nothing -> peekError "EOF while parsing an object"

-- | A string's contents after its opening quote, as @parse_str_bytes@.
parseStr :: P Text
parseStr = go []
  where
    go acc = do
      start <- getIndex
      skipPlain
      i <- getIndex
      n <- inputLength
      if i == n
        then failAt "EOF while parsing a string"
        else do
          raw <- slice start i
          let acc' = if B.null raw then acc else TE.decodeUtf8 raw : acc
          c <- peekOrNull
          case c of
            34 -> eat >> pure (T.concat (reverse acc'))
            92 -> do
              eat
              t <- parseEscape
              go (t : acc')
            _ -> eat >> failAt "control character (\\u0000-\\u001F) found while parsing a string"
    skipPlain =
      peek >>= \case
        Just c | c /= 34 && c /= 92 && c >= 0x20 -> eat >> skipPlain
        _ -> pure ()

-- | The next byte inside a string.
nextOrEof :: P Word8
nextOrEof = next >>= maybe (failAt "EOF while parsing a string") pure

-- | The next byte inside a string, not consumed.
peekOrEof :: P Word8
peekOrEof = peek >>= maybe (failAt "EOF while parsing a string") pure

-- | An escape after its backslash.
parseEscape :: P Text
parseEscape = do
  c <- nextOrEof
  case c of
    34 -> pure "\""
    92 -> pure "\\"
    47 -> pure "/"
    98 -> pure "\b"
    102 -> pure "\f"
    110 -> pure "\n"
    114 -> pure "\r"
    116 -> pure "\t"
    117 -> parseUnicodeEscape
    _ -> failAt "invalid escape"

-- | Four hex digits of a @\\u@ escape.
hexEscape :: P Int
hexEscape = do
  i <- getIndex
  n <- inputLength
  if n - i >= 4
    then do
      bytes <- slice i (i + 4)
      setIndex (i + 4)
      case mapM hexValue (B.unpack bytes) of
        Just [a, b, c, d] -> pure (((a * 16 + b) * 16 + c) * 16 + d)
        _ -> failAt "invalid escape"
    else setIndex n >> failAt "EOF while parsing a string"
  where
    hexValue w
      | w >= 48 && w <= 57 = Just (fromIntegral w - 48)
      | w >= 97 && w <= 102 = Just (fromIntegral w - 87)
      | w >= 65 && w <= 70 = Just (fromIntegral w - 55)
      | otherwise = Nothing

-- | A @\\u@ escape, pairing surrogates.
parseUnicodeEscape :: P Text
parseUnicodeEscape = do
  n <- hexEscape
  if n >= 0xDC00 && n <= 0xDFFF
    then failAt "lone leading surrogate in hex escape"
    else
      if n < 0xD800 || n > 0xDBFF
        then pure (T.singleton (chr n))
        else do
          b <- peekOrEof
          if b == 92 then eat else eat >> failAt "unexpected end of hex escape"
          u <- peekOrEof
          if u == 117 then eat else eat >> failAt "unexpected end of hex escape"
          n2 <- hexEscape
          if n2 < 0xDC00 || n2 > 0xDFFF
            then failAt "lone leading surrogate in hex escape"
            else pure (T.singleton (chr (((n - 0xD800) * 0x400) + (n2 - 0xDC00) + 0x10000)))

-- | The largest u64.
u64Max :: Integer
u64Max = 18446744073709551615

-- | serde_json's @overflow!(a * 10 + b, c)@.
overflows :: Integer -> Integer -> Integer -> Bool
overflows a b c = a >= c `div` 10 && (a > c `div` 10 || b > c `mod` 10)

-- | A number after its sign, as @parse_integer@.
parseInteger :: Bool -> P Number
parseInteger positive =
  next >>= \case
    Nothing -> failAt "EOF while parsing a value"
    Just 48 -> do
      c <- peekOrNull
      if isDigitW c then peekError "invalid number" else parseNumber positive 0
    Just c | c >= 49 && c <= 57 -> digits (fromIntegral c - 48)
    Just _ -> failAt "invalid number"
  where
    digits sig = do
      c <- peekOrNull
      if isDigitW c
        then do
          let dg = fromIntegral c - 48
          if overflows sig dg u64Max
            then D <$> parseLongInteger positive sig
            else eat >> digits (sig * 10 + dg)
        else parseNumber positive sig

-- | What follows a number's whole part, as @parse_number@.
parseNumber :: Bool -> Integer -> P Number
parseNumber positive sig =
  peekOrNull >>= \case
    46 -> D <$> parseDecimal positive sig 0
    c | c == 101 || c == 69 -> D <$> parseExponent positive sig 0
    _
      | positive -> pure (I sig)
      | sig == 0 -> pure (D (-0.0))
      | sig <= 9223372036854775808 -> pure (I (negate sig))
      | otherwise -> pure (D (negate (u64ToDouble sig)))

-- | A fraction, as @parse_decimal@.
parseDecimal :: Bool -> Integer -> Integer -> P Double
parseDecimal positive sig0 expBefore = do
  eat
  let loop sig after = do
        c <- peekOrNull
        if isDigitW c
          then do
            let dg = fromIntegral c - 48
            if overflows sig dg u64Max
              then Left <$> parseDecimalOverflow positive sig (expBefore + after)
              else eat >> loop (sig * 10 + dg) (after - 1)
          else pure (Right (sig, after))
  r <- loop sig0 (0 :: Integer)
  case r of
    Left d -> pure d
    Right (sig, after) -> do
      if after == 0
        then
          peek >>= \case
            Just _ -> peekError "invalid number"
            Nothing -> peekError "EOF while parsing a value"
        else pure ()
      let ex = expBefore + after
      c <- peekOrNull
      if c == 101 || c == 69 then parseExponent positive sig ex else fromParts positive sig ex

-- | A fraction whose further digits no longer fit, as
-- @parse_decimal_overflow@.
parseDecimalOverflow :: Bool -> Integer -> Integer -> P Double
parseDecimalOverflow positive sig ex = do
  skipDigits
  c <- peekOrNull
  if c == 101 || c == 69 then parseExponent positive sig ex else fromParts positive sig ex

-- | Skips digits.
skipDigits :: P ()
skipDigits = peekOrNull >>= \c -> if isDigitW c then eat >> skipDigits else pure ()

-- | An exponent, as @parse_exponent@; exponents are i32 in serde_json, kept
-- as Integer here and saturated where it saturates.
parseExponent :: Bool -> Integer -> Integer -> P Double
parseExponent positive sig startingExp = do
  eat
  positiveExp <-
    peekOrNull >>= \case
      43 -> eat >> pure True
      45 -> eat >> pure False
      _ -> pure True
  first <- next
  case first of
    Nothing -> failAt "EOF while parsing a value"
    Just c
      | not (isDigitW c) -> failAt "invalid number"
      | otherwise -> do
          let loop e = do
                d <- peekOrNull
                if isDigitW d
                  then do
                    eat
                    let dg = fromIntegral d - 48
                    if overflows e dg i32Max
                      then Left <$> exponentOverflow positive (sig == 0) positiveExp
                      else loop (e * 10 + dg)
                  else pure (Right e)
          r <- loop (fromIntegral c - 48)
          case r of
            Left d -> pure d
            Right e -> fromParts positive sig (saturate (if positiveExp then startingExp + e else startingExp - e))
  where
    saturate = max (negate i32Max - 1) . min i32Max

-- | The largest i32.
i32Max :: Integer
i32Max = 2147483647

-- | An exponent too large for i32, as @parse_exponent_overflow@.
exponentOverflow :: Bool -> Bool -> Bool -> P Double
exponentOverflow positive zeroSig positiveExp
  | not zeroSig && positiveExp = failAt "number out of range"
  | otherwise = skipDigits >> pure (if positive then 0.0 else -0.0)

-- | A whole part too long for u64, as @parse_long_integer@.
parseLongInteger :: Bool -> Integer -> P Double
parseLongInteger positive sig = go 0
  where
    go ex =
      peekOrNull >>= \case
        c | isDigitW c -> eat >> go (ex + 1)
        46 -> parseDecimal positive sig ex
        c | c == 101 || c == 69 -> parseExponent positive sig ex
        _ -> fromParts positive sig ex

-- | serde_json's @f64_from_parts@ without float_roundtrip: the significand as
-- a double, times or divided by a power of ten from its table.
fromParts :: Bool -> Integer -> Integer -> P Double
fromParts positive sig ex0 = loop (u64ToDouble sig) ex0
  where
    -- i32::MIN.wrapping_abs() is i32::MIN, which is past the table.
    loop f ex
      | ex /= negate i32Max - 1 && abs ex <= 308 =
          if ex >= 0
            then
              let f' = f * pow10 (fromInteger ex)
               in if isInfinite f' then failAt "number out of range" else done f'
            else done (f / pow10 (fromInteger (negate ex)))
      | f == 0 = done f
      | ex >= 0 = failAt "number out of range"
      | otherwise = loop (f / 1e308) (ex + 308)
    done f = pure (if positive then f else negate f)

-- | A power of ten from the table.
pow10 :: Int -> Double
pow10 k = pow10Table Map.! k

-- | Ten to the 0 through 308, each the nearest double, as serde_json's POW10.
pow10Table :: Map.Map Int Double
pow10Table = Map.fromList [(k, fromRational (10 ^ k)) | k <- [0 .. 308]]
