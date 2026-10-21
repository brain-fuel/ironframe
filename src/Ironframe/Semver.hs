-- | Semantic versions and version requirements, as the Rust semver crate
-- 1.0.28 reads, writes and matches them. Error messages are the crate's own.
-- Numbers are whole numbers up to the largest 64-bit unsigned value.
-- ref:DEC-haskell-wasm-core
module Ironframe.Semver
  ( Version (..)
  , VersionReq (..)
  , Comparator (..)
  , Op (..)
  , parseVersion
  , parseReq
  , matches
  , renderVersion
  , renderReq
  , comparePrerelease
  ) where

import Data.Char (GeneralCategory (..), generalCategory, isAsciiLower, isAsciiUpper, isPrint, ord)
import Data.Text (Text)
import qualified Data.Text as T
import Numeric (showHex)

-- | A version: major, minor and patch numbers, a pre-release identifier and
-- build metadata, each identifier empty when absent.
data Version = Version
  { major :: !Integer
  , minor :: !Integer
  , patch :: !Integer
  , pre :: !Text
  , build :: !Text
  }
  deriving (Show, Eq)

-- | A requirement: comparators that must all match; none means any version.
newtype VersionReq = VersionReq {comparators :: [Comparator]}
  deriving (Show, Eq)

-- | One comparator of a requirement.
data Comparator = Comparator
  { cmpOp :: !Op
  , cmpMajor :: !Integer
  , cmpMinor :: !(Maybe Integer)
  , cmpPatch :: !(Maybe Integer)
  , cmpPre :: !Text
  }
  deriving (Show, Eq)

-- | A comparator's operator.
data Op = Exact | Greater | GreaterEq | Less | LessEq | Tilde | Caret | Wildcard
  deriving (Show, Eq)

data Position = PMajor | PMinor | PPatch | PPre | PBuild
  deriving (Eq)

data Err
  = Empty
  | UnexpectedEnd Position
  | UnexpectedChar Position Char
  | UnexpectedCharAfter Position Char
  | ExpectedCommaFound Position Char
  | LeadingZero Position
  | Overflow Position
  | EmptySegment Position
  | WildcardNotTheOnlyComparator Char
  | UnexpectedAfterWildcard
  | ExcessiveComparators

-- | Reads a version as @Version::parse@ does.
parseVersion :: Text -> Either Text Version
parseVersion = either (Left . errText) Right . version

-- | Reads a requirement as @VersionReq::parse@ does.
parseReq :: Text -> Either Text VersionReq
parseReq = either (Left . errText) Right . versionReq

-- | Whether a version satisfies a requirement, as @VersionReq::matches@ does.
matches :: VersionReq -> Version -> Bool
matches (VersionReq cs) ver =
  all (`matchesImpl` ver) cs && (T.null (pre ver) || any (`preIsCompatible` ver) cs)

-- | A version as the crate displays it.
renderVersion :: Version -> Text
renderVersion v =
  T.concat
    [ tshow (major v), ".", tshow (minor v), ".", tshow (patch v)
    , if T.null (pre v) then "" else "-" <> pre v
    , if T.null (build v) then "" else "+" <> build v
    ]

-- | A requirement as the crate displays it.
renderReq :: VersionReq -> Text
renderReq (VersionReq []) = "*"
renderReq (VersionReq cs) = T.intercalate ", " (map renderComparator cs)

renderComparator :: Comparator -> Text
renderComparator c = opText (cmpOp c) <> tshow (cmpMajor c) <> rest
  where
    star = if cmpOp c == Wildcard then ".*" else ""
    rest = case cmpMinor c of
      Nothing -> star
      Just mi -> "." <> tshow mi <> case cmpPatch c of
        Nothing -> star
        Just pa -> "." <> tshow pa <> (if T.null (cmpPre c) then "" else "-" <> cmpPre c)
    opText = \case
      Exact -> "="
      Greater -> ">"
      GreaterEq -> ">="
      Less -> "<"
      LessEq -> "<="
      Tilde -> "~"
      Caret -> "^"
      Wildcard -> ""

tshow :: Integer -> Text
tshow = T.pack . show

-- Parsing

version :: Text -> Either Err Version
version text
  | T.null text = Left Empty
  | otherwise = do
      (ma, t1) <- numericIdentifier PMajor text
      t2 <- dot PMajor t1
      (mi, t3) <- numericIdentifier PMinor t2
      t4 <- dot PMinor t3
      (pa, t5) <- numericIdentifier PPatch t4
      if T.null t5
        then Right (Version ma mi pa "" "")
        else do
          (pr, t6, pos1) <- case T.stripPrefix "-" t5 of
            Just t -> do
              (p, r) <- identifier PPre t
              if T.null p then Left (EmptySegment PPre) else Right (p, r, PPre)
            Nothing -> Right ("", t5, PPatch)
          (bu, t7, pos2) <- case T.stripPrefix "+" t6 of
            Just t -> do
              (b, r) <- identifier PBuild t
              if T.null b then Left (EmptySegment PBuild) else Right (b, r, PBuild)
            Nothing -> Right ("", t6, pos1)
          case T.uncons t7 of
            Just (c, _) -> Left (UnexpectedCharAfter pos2 c)
            Nothing -> Right (Version ma mi pa pr bu)

versionReq :: Text -> Either Err VersionReq
versionReq input =
  let text = T.dropWhile (== ' ') input
   in case wildcard text of
        Just (ch, r) ->
          let rest = T.dropWhile (== ' ') r
           in if T.null rest
                then Right (VersionReq [])
                else
                  if "," `T.isPrefixOf` rest
                    then Left (WildcardNotTheOnlyComparator ch)
                    else Left UnexpectedAfterWildcard
        Nothing -> VersionReq <$> comparatorsFrom 0 text

comparatorsFrom :: Int -> Text -> Either Err [Comparator]
comparatorsFrom depth input = case comparator input of
  Left err -> Left $ case wildcard input of
    Just (ch, r)
      | let rest = T.dropWhile (== ' ') r
      , T.null rest || "," `T.isPrefixOf` rest ->
          WildcardNotTheOnlyComparator ch
    _ -> err
  Right (c, pos, text)
    | T.null text -> Right [c]
    | otherwise -> case T.uncons text of
        Just (',', r)
          | depth + 1 == maxComparators -> Left ExcessiveComparators
          | otherwise -> (c :) <$> comparatorsFrom (depth + 1) (T.dropWhile (== ' ') r)
        Just (ch, _) -> Left (ExpectedCommaFound pos ch)
        Nothing -> Right [c]
  where
    maxComparators = 32

comparator :: Text -> Either Err (Comparator, Position, Text)
comparator input = do
  let (op0, afterOp) = parseOp input
      defaultOp = T.length afterOp == T.length input
      t0 = T.dropWhile (== ' ') afterOp
  (ma, t1) <- numericIdentifier PMajor t0
  (mi, t2, op1, wild, pos1) <- case T.stripPrefix "." t1 of
    Just t -> case wildcard t of
      Just (_, r) -> Right (Nothing, r, if defaultOp then Wildcard else op0, True, PMinor)
      Nothing -> do
        (n, r) <- numericIdentifier PMinor t
        Right (Just n, r, op0, False, PMinor)
    Nothing -> Right (Nothing, t1, op0, False, PMajor)
  (pa, t3, op2, pos2) <- case T.stripPrefix "." t2 of
    Just t -> case wildcard t of
      Just (_, r) -> Right (Nothing, r, if defaultOp then Wildcard else op1, PPatch)
      Nothing
        | wild -> Left UnexpectedAfterWildcard
        | otherwise -> do
            (n, r) <- numericIdentifier PPatch t
            Right (Just n, r, op1, PPatch)
    Nothing -> Right (Nothing, t2, op1, pos1)
  let hasPatch = pa /= Nothing
  (pr, t4, pos3) <- case T.stripPrefix "-" t3 of
    Just t | hasPatch -> do
      (p, r) <- identifier PPre t
      if T.null p then Left (EmptySegment PPre) else Right (p, r, PPre)
    _ -> Right ("", t3, pos2)
  (t5, pos4) <- case T.stripPrefix "+" t4 of
    Just t | hasPatch -> do
      (b, r) <- identifier PBuild t
      if T.null b then Left (EmptySegment PBuild) else Right (r, PBuild)
    _ -> Right (t4, pos3)
  Right (Comparator op2 ma mi pa pr, pos4, T.dropWhile (== ' ') t5)

parseOp :: Text -> (Op, Text)
parseOp t = case T.unpack (T.take 2 t) of
  '=' : _ -> (Exact, T.drop 1 t)
  ">=" -> (GreaterEq, T.drop 2 t)
  '>' : _ -> (Greater, T.drop 1 t)
  "<=" -> (LessEq, T.drop 2 t)
  '<' : _ -> (Less, T.drop 1 t)
  '~' : _ -> (Tilde, T.drop 1 t)
  '^' : _ -> (Caret, T.drop 1 t)
  _ -> (Caret, t)

wildcard :: Text -> Maybe (Char, Text)
wildcard t = case T.uncons t of
  Just (c, r) | c `elem` ['*', 'x', 'X'] -> Just (c, r)
  _ -> Nothing

dot :: Position -> Text -> Either Err Text
dot pos t = case T.uncons t of
  Just ('.', r) -> Right r
  Just (c, _) -> Left (UnexpectedCharAfter pos c)
  Nothing -> Left (UnexpectedEnd pos)

isDigitA :: Char -> Bool
isDigitA c = c >= '0' && c <= '9'

maxU64 :: Integer
maxU64 = 2 ^ (64 :: Int) - 1

numericIdentifier :: Position -> Text -> Either Err (Integer, Text)
numericIdentifier pos = go (0 :: Int) 0
  where
    go len value s = case T.uncons s of
      Just (c, r)
        | isDigitA c ->
            if value == 0 && len > 0
              then Left (LeadingZero pos)
              else
                let v = value * 10 + toInteger (ord c - ord '0')
                 in if v > maxU64 then Left (Overflow pos) else go (len + 1) v r
      Just (c, _) | len == 0 -> Left (UnexpectedChar pos c)
      Nothing | len == 0 -> Left (UnexpectedEnd pos)
      _ -> Right (value, s)

identifier :: Position -> Text -> Either Err (Text, Text)
identifier pos input = go 0 input
  where
    isIdent c = isAsciiUpper c || isAsciiLower c || c == '-' || isDigitA c
    go acc s =
      let (seg, after) = T.span isIdent s
          segLen = T.length seg
          boundary = fst <$> T.uncons after
       in if segLen == 0
            then
              if acc == 0 && boundary /= Just '.'
                then Right ("", input)
                else Left (EmptySegment pos)
            else
              if pos == PPre && segLen > 1 && T.all isDigitA seg && T.head seg == '0'
                then Left (LeadingZero pos)
                else
                  if boundary == Just '.'
                    then go (acc + segLen + 1) (T.drop 1 after)
                    else Right (T.splitAt (acc + segLen) input)

-- Matching

matchesImpl :: Comparator -> Version -> Bool
matchesImpl c v = case cmpOp c of
  Exact -> matchesExact c v
  Wildcard -> matchesExact c v
  Greater -> matchesGreater c v
  GreaterEq -> matchesExact c v || matchesGreater c v
  Less -> matchesLess c v
  LessEq -> matchesExact c v || matchesLess c v
  Tilde -> matchesTilde c v
  Caret -> matchesCaret c v

matchesExact :: Comparator -> Version -> Bool
matchesExact c v =
  major v == cmpMajor c
    && maybe True (== minor v) (cmpMinor c)
    && maybe True (== patch v) (cmpPatch c)
    && pre v == cmpPre c

matchesGreater :: Comparator -> Version -> Bool
matchesGreater = ordered GT

matchesLess :: Comparator -> Version -> Bool
matchesLess = ordered LT

-- The shared shape of greater and less: the first differing part decides.
ordered :: Ordering -> Comparator -> Version -> Bool
ordered want c v
  | major v /= cmpMajor c = compare (major v) (cmpMajor c) == want
  | otherwise = case cmpMinor c of
      Nothing -> False
      Just mi
        | minor v /= mi -> compare (minor v) mi == want
        | otherwise -> case cmpPatch c of
            Nothing -> False
            Just pa
              | patch v /= pa -> compare (patch v) pa == want
              | otherwise -> comparePrerelease (pre v) (cmpPre c) == want

matchesTilde :: Comparator -> Version -> Bool
matchesTilde c v
  | major v /= cmpMajor c = False
  | Just mi <- cmpMinor c, minor v /= mi = False
  | Just pa <- cmpPatch c, patch v /= pa = patch v > pa
  | otherwise = comparePrerelease (pre v) (cmpPre c) /= LT

matchesCaret :: Comparator -> Version -> Bool
matchesCaret c v
  | major v /= cmpMajor c = False
  | otherwise = case cmpMinor c of
      Nothing -> True
      Just mi -> case cmpPatch c of
        Nothing
          | cmpMajor c > 0 -> minor v >= mi
          | otherwise -> minor v == mi
        Just pa
          | cmpMajor c > 0 ->
              if minor v /= mi
                then minor v > mi
                else if patch v /= pa then patch v > pa else preOk
          | mi > 0 ->
              if minor v /= mi
                then False
                else if patch v /= pa then patch v > pa else preOk
          | minor v /= mi || patch v /= pa -> False
          | otherwise -> preOk
  where
    preOk = comparePrerelease (pre v) (cmpPre c) /= LT

preIsCompatible :: Comparator -> Version -> Bool
preIsCompatible c v =
  cmpMajor c == major v
    && cmpMinor c == Just (minor v)
    && cmpPatch c == Just (patch v)
    && not (T.null (cmpPre c))

-- | Orders pre-release identifiers as the crate does: no identifier is
-- greatest, numeric parts compare as numbers and below other parts.
comparePrerelease :: Text -> Text -> Ordering
comparePrerelease a b
  | T.null a && T.null b = EQ
  | T.null a = GT
  | T.null b = LT
  | otherwise = go (T.splitOn "." a) (T.splitOn "." b)
  where
    go [] [] = EQ
    go [] _ = LT
    go _ [] = GT
    go (x : xs) (y : ys) =
      let numeric = T.all isDigitA
       in case (numeric x, numeric y) of
            (True, True) -> case compare (T.length x) (T.length y) <> compare x y of
              EQ -> go xs ys
              o -> o
            (True, False) -> LT
            (False, True) -> GT
            (False, False) -> case compare x y of
              EQ -> go xs ys
              o -> o

-- Errors

errText :: Err -> Text
errText = \case
  Empty -> "empty string, expected a semver version"
  UnexpectedEnd p -> "unexpected end of input while parsing " <> posText p
  UnexpectedChar p c -> "unexpected character " <> quotedChar c <> " while parsing " <> posText p
  UnexpectedCharAfter p c -> "unexpected character " <> quotedChar c <> " after " <> posText p
  ExpectedCommaFound p c -> "expected comma after " <> posText p <> ", found " <> quotedChar c
  LeadingZero p -> "invalid leading zero in " <> posText p
  Overflow p -> "value of " <> posText p <> " exceeds u64::MAX"
  EmptySegment p -> "empty identifier segment in " <> posText p
  WildcardNotTheOnlyComparator c ->
    "wildcard req (" <> T.singleton c <> ") must be the only comparator in the version req"
  UnexpectedAfterWildcard -> "unexpected character after wildcard in version req"
  ExcessiveComparators -> "excessive number of version comparators"

posText :: Position -> Text
posText = \case
  PMajor -> "major version number"
  PMinor -> "minor version number"
  PPatch -> "patch version number"
  PPre -> "pre-release identifier"
  PBuild -> "build metadata"

-- A character quoted as Rust's Debug for char writes it.
quotedChar :: Char -> Text
quotedChar c = "'" <> body <> "'"
  where
    body = case c of
      '\0' -> "\\0"
      '\t' -> "\\t"
      '\r' -> "\\r"
      '\n' -> "\\n"
      '\'' -> "\\'"
      '\\' -> "\\\\"
      _
        | extending || not (isPrint c) -> T.pack ("\\u{" ++ showHex (ord c) "}")
        | otherwise -> T.singleton c
    extending = generalCategory c `elem` [NonSpacingMark, EnclosingMark]
