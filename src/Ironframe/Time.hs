-- | Date-times with an offset, read and written as RFC 3339 the way the Rust
-- time crate 0.3.55 does with its well-known Rfc3339 format. Error messages
-- are the crate's own. Two date-times are equal when they name one instant.
-- ref:DEC-haskell-wasm-core
module Ironframe.Time
  ( Timestamp (..)
  , parseRfc3339
  , formatRfc3339
  , fromUnix
  , unixNanos
  , compareInstant
  , maxInstant
  ) where

import qualified Data.ByteString as B
import Data.Ord (comparing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word8)

-- | A calendar date and wall-clock time with nanoseconds, at an offset from
-- UTC given in whole minutes (east positive).
data Timestamp = Timestamp
  { tsYear :: !Integer
  , tsMonth :: !Int
  , tsDay :: !Int
  , tsHour :: !Int
  , tsMinute :: !Int
  , tsSecond :: !Int
  , tsNanosecond :: !Int
  , tsOffsetMinutes :: !Int
  }
  deriving (Show)

instance Eq Timestamp where
  a == b = compareInstant a b == EQ

instance Ord Timestamp where
  compare = compareInstant

-- | Orders two date-times by the instant they name.
compareInstant :: Timestamp -> Timestamp -> Ordering
compareInstant = comparing unixNanos

-- | The later of two date-times, the second when they name one instant, as
-- Rust's @Ord::max@ gives.
maxInstant :: Timestamp -> Timestamp -> Timestamp
maxInstant a b = if compareInstant a b == GT then a else b

-- | Nanoseconds since the Unix epoch.
unixNanos :: Timestamp -> Integer
unixNanos t = localSeconds t * 1000000000 + toInteger (tsNanosecond t)

-- Seconds since the epoch of the instant, ignoring its nanoseconds.
localSeconds :: Timestamp -> Integer
localSeconds t =
  daysFromCivil (tsYear t) (tsMonth t) (tsDay t) * 86400
    + toInteger (tsHour t * 3600 + tsMinute t * 60 + tsSecond t)
    - toInteger (tsOffsetMinutes t * 60)

-- | The UTC date-time some seconds and nanoseconds after the Unix epoch.
fromUnix :: Integer -> Integer -> Timestamp
fromUnix seconds nanos =
  let total = seconds * 1000000000 + nanos
      (secs, ns) = total `divMod` 1000000000
      (days, sod) = secs `divMod` 86400
      (y, m, d) = civilFromDays days
      sod' = fromInteger sod
   in Timestamp y m d (sod' `div` 3600) (sod' `mod` 3600 `div` 60) (sod' `mod` 60) (fromInteger ns) 0

-- | Writes a date-time as RFC 3339: subseconds without trailing zeros, and
-- @Z@ for a zero offset.
formatRfc3339 :: Timestamp -> Text
formatRfc3339 t =
  T.concat
    [ pad 4 (tsYear t), "-", pad2 (tsMonth t), "-", pad2 (tsDay t)
    , "T", pad2 (tsHour t), ":", pad2 (tsMinute t), ":", pad2 (tsSecond t)
    , subsecond
    , offset
    ]
  where
    pad2 = pad 2 . toInteger
    subsecond
      | tsNanosecond t == 0 = ""
      | otherwise = "." <> T.dropWhileEnd (== '0') (pad 9 (toInteger (tsNanosecond t)))
    off = tsOffsetMinutes t
    offset
      | off == 0 = "Z"
      | otherwise =
          (if off < 0 then "-" else "+") <> pad2 (abs off `div` 60) <> ":" <> pad2 (abs off `mod` 60)

pad :: Int -> Integer -> Text
pad n v = T.justifyRight n '0' (T.pack (show v))

-- Parsing

-- | Reads RFC 3339 text as @OffsetDateTime::parse(text, &Rfc3339)@ does.
parseRfc3339 :: Text -> Either Text Timestamp
parseRfc3339 = parseBytes . TE.encodeUtf8

parseBytes :: B.ByteString -> Either Text Timestamp
parseBytes i0 = do
  (year, i1) <- digits 4 i0 `orElse` component "year"
  i2 <- literal 45 i1
  (month, i3) <- (digits 2 i2 >>= nonZero) `orElse` component "month"
  i4 <- literal 45 i3
  (day, i5) <- digits 2 i4 `orElse` component "day"
  i6 <- (if B.null i5 then Nothing else Just (B.drop 1 i5)) `orElse` component "separator"
  (hour, i7) <- digits 2 i6 `orElse` component "hour"
  i8 <- literal 58 i7
  (minute, i9) <- digits 2 i8 `orElse` component "minute"
  i10 <- literal 58 i9
  (second0, i11) <- digits 2 i10 `orElse` component "second"
  (nano0, i12) <- case B.uncons i11 of
    Just (46, r) -> do
      (d, r') <- anyDigit r `orElse` component "subsecond"
      Right (subsecondDigits (d * 100000000) 10000000 r')
    _ -> Right (0, i11)
  (offset, i13) <- case B.uncons i12 of
    Just (c, r) | c == 90 || c == 122 -> Right (0, r)
    _ -> do
      (negative, r1) <- sign i12 `orElse` component "offset hour"
      (oh, r2) <- (digits 2 r1 >>= \p@(h, _) -> if h <= 23 then Just p else Nothing)
        `orElse` component "offset hour"
      r3 <- literal 58 r2
      (om, r4) <- digits 2 r3 `orElse` component "offset minute"
      if om > 59
        then Left (range "offset minute")
        else Right ((if negative then negate else id) (oh * 60 + om), r4)
  if not (B.null i13)
    then Left "unexpected trailing characters; the end of input was expected"
    else Right ()
  let leap = second0 == 60
      second = if leap then 59 else second0
      nano = if leap then 999999999 else nano0
  if month > 12 then Left (range "month") else Right ()
  if day < 1 || day > monthLength (toInteger year) month then Left (range "day") else Right ()
  if hour > 23 then Left (range "hour") else Right ()
  if minute > 59 then Left (range "minute") else Right ()
  if second > 59 then Left (range "second") else Right ()
  let t = Timestamp (toInteger year) month day hour minute second nano offset
  if leap && not (validLeapStandIn t) then Left (range "second") else Right t
  where
    orElse m e = maybe (Left e) Right m
    component name = "the '" <> name <> "' component could not be parsed"
    range name = name <> " was not in range"
    literal c input = case B.uncons input of
      Just (x, r) | x == c -> Right r
      _ -> Left "a character literal was not valid"
    nonZero p@(v, _) = if v == 0 then Nothing else Just p
    sign input = case B.uncons input of
      Just (45, r) -> Just (True, r)
      Just (43, r) -> Just (False, r)
      _ -> Nothing

-- The remaining subsecond digits, each worth a tenth of the one before, and
-- nothing once past nanoseconds.
subsecondDigits :: Int -> Int -> B.ByteString -> (Int, B.ByteString)
subsecondDigits value multiplier input = case anyDigit input of
  Just (d, r) -> subsecondDigits (value + d * multiplier) (multiplier `div` 10) r
  Nothing -> (value, input)

isDigitByte :: Word8 -> Bool
isDigitByte b = b >= 48 && b <= 57

anyDigit :: B.ByteString -> Maybe (Int, B.ByteString)
anyDigit input = case B.uncons input of
  Just (b, r) | isDigitByte b -> Just (fromIntegral b - 48, r)
  _ -> Nothing

digits :: Int -> B.ByteString -> Maybe (Int, B.ByteString)
digits n input
  | B.length h == n && B.all isDigitByte h = Just (B.foldl' (\acc b -> acc * 10 + fromIntegral b - 48) 0 h, r)
  | otherwise = Nothing
  where
    (h, r) = B.splitAt n input

-- A leap second stands in only for the last second of a month in UTC.
validLeapStandIn :: Timestamp -> Bool
validLeapStandIn t =
  let u = fromUnix (localSeconds t) 0
   in tsHour u == 23 && tsMinute u == 59 && tsSecond u == 59
        && tsDay u == monthLength (tsYear u) (tsMonth u)

-- Calendar arithmetic

isLeapYear :: Integer -> Bool
isLeapYear y = (y `mod` 4 == 0 && y `mod` 100 /= 0) || y `mod` 400 == 0

monthLength :: Integer -> Int -> Int
monthLength y m
  | m == 2 = if isLeapYear y then 29 else 28
  | m `elem` [4, 6, 9, 11] = 30
  | otherwise = 31

-- Days since 1970-01-01 of a proleptic Gregorian date (Hinnant's algorithm).
daysFromCivil :: Integer -> Int -> Int -> Integer
daysFromCivil y0 m d =
  let y = if m <= 2 then y0 - 1 else y0
      era = y `div` 400
      yoe = y - era * 400
      mp = toInteger ((m + 9) `mod` 12)
      doy = (153 * mp + 2) `div` 5 + toInteger d - 1
      doe = yoe * 365 + yoe `div` 4 - yoe `div` 100 + doy
   in era * 146097 + doe - 719468

-- The proleptic Gregorian date some days after 1970-01-01.
civilFromDays :: Integer -> (Integer, Int, Int)
civilFromDays z0 =
  let z = z0 + 719468
      era = z `div` 146097
      doe = z - era * 146097
      yoe = (doe - doe `div` 1460 + doe `div` 36524 - doe `div` 146096) `div` 365
      y = yoe + era * 400
      doy = doe - (365 * yoe + yoe `div` 4 - yoe `div` 100)
      mp = (5 * doy + 2) `div` 153
      d = doy - (153 * mp + 2) `div` 5 + 1
      m = if mp < 10 then mp + 3 else mp - 9
   in (if m <= 2 then y + 1 else y, fromInteger m, fromInteger d)
