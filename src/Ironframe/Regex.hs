-- | A small regular expression engine for the patterns JSON Schemas carry.
-- It reads the ECMA-262 subset jsonschema-rs hands to Rust's regex crate:
-- anchors, classes and ranges, escapes, groups, alternation and quantifiers.
-- A match is a search anywhere in the text, as the pattern keyword asks.
-- Look-around, backreferences, named groups and flags are refused.
-- ref:DEC-haskell-wasm-core
module Ironframe.Regex
  ( Regex
  , compile
  , match
  , source
  , rustPattern
  ) where

import Data.Char (chr, digitToInt, isAlphaNum, isAsciiLower, isAsciiUpper, isDigit, isHexDigit)
import Data.Text (Text)
import qualified Data.Text as T

-- | A compiled pattern with the text it came from.
data Regex = Regex
  { source :: Text
  , regexAlt :: [[Piece]]
  }

instance Show Regex where
  show r = "Regex " ++ show (source r)

data Piece = Piece Node Int (Maybe Int)

data Node
  = NChar Char
  | NAny
  | NClass Bool [Item]
  | NGroup [[Piece]]
  | NStart
  | NEnd
  | NBoundary Bool

data Item = IRange Char Char | IClass Bool [Item]

-- | Compiles a pattern, or says why it cannot be read.
compile :: Text -> Either Text Regex
compile t = case parseAlt (T.unpack t) of
  Left e -> Left e
  Right (alt, []) -> Right (Regex t alt)
  Right (_, c : _) -> Left ("unexpected " <> T.singleton c <> " in pattern " <> t)

-- | Whether the pattern matches anywhere in the text.
match :: Regex -> Text -> Bool
match r t = go Nothing (T.unpack t) True
  where
    go prev s start
      | runAlt (regexAlt r) (St prev s start) (const True) = True
      | otherwise = case s of
          [] -> False
          c : rest -> go (Just c) rest False

-- | The pattern as jsonschema-rs prints it: Perl classes written out as Rust's.
rustPattern :: Text -> Text
rustPattern = T.pack . go . T.unpack
  where
    go ('\\' : c : rest) = case c of
      'd' -> "[0-9]" ++ go rest
      'D' -> "[^0-9]" ++ go rest
      'w' -> "[A-Za-z0-9_]" ++ go rest
      'W' -> "[^A-Za-z0-9_]" ++ go rest
      's' -> "[" ++ spaces ++ "]" ++ go rest
      'S' -> "[^" ++ spaces ++ "]" ++ go rest
      _ -> '\\' : c : go rest
    go (c : rest) = c : go rest
    go [] = []
    spaces = " \t\n\r\x0b\x0c\x00a0\xfeff\x2003\x2029"

-- Matching, by backtracking with continuations.

data St = St (Maybe Char) String Bool

runAlt :: [[Piece]] -> St -> (St -> Bool) -> Bool
runAlt alts st k = any (\ps -> runSeq ps st k) alts

runSeq :: [Piece] -> St -> (St -> Bool) -> Bool
runSeq [] st k = k st
runSeq (Piece n lo hi : ps) st k = rep 0 st
  where
    next = \st' -> runSeq ps st' k
    rep i s
      | i < lo = runNode n s (rep (i + 1))
      | maybe False (i >=) hi = next s
      | otherwise = runNode n s (\s' -> progressed s s' && rep (i + 1) s') || next s
    progressed (St _ a _) (St _ b _) = length a /= length b

runNode :: Node -> St -> (St -> Bool) -> Bool
runNode node st@(St prev s start) k = case node of
  NChar c -> one (== c)
  NAny -> one (/= '\n')
  NClass neg items -> one (\c -> inItems items c /= neg)
  NGroup alts -> runAlt alts st k
  NStart -> start && k st
  NEnd -> null s && k st
  NBoundary want -> (isWord prev /= isWord (headMaybe s)) == want && k st
  where
    one p = case s of
      c : rest | p c -> k (St (Just c) rest False)
      _ -> False
    headMaybe (c : _) = Just c
    headMaybe [] = Nothing
    isWord = maybe False (\c -> isAlphaNum c || c == '_')

inItems :: [Item] -> Char -> Bool
inItems items c = any hit items
  where
    hit (IRange a b) = a <= c && c <= b
    hit (IClass neg is) = inItems is c /= neg

-- Parsing.

type P a = Either Text (a, String)

parseAlt :: String -> P [[Piece]]
parseAlt s = do
  (sq, rest) <- parseSeq s
  case rest of
    '|' : rest' -> do
      (alts, rest'') <- parseAlt rest'
      Right (sq : alts, rest'')
    _ -> Right ([sq], rest)

parseSeq :: String -> P [Piece]
parseSeq s = case s of
  [] -> Right ([], s)
  c : _ | c `elem` ("|)" :: String) -> Right ([], s)
  _ -> do
    (n, rest) <- parseAtom s
    (p, rest') <- parseQuant n rest
    (ps, rest'') <- parseSeq rest'
    Right (p : ps, rest'')

parseQuant :: Node -> String -> P Piece
parseQuant n s = case s of
  '*' : r -> lazy (Piece n 0 Nothing) r
  '+' : r -> lazy (Piece n 1 Nothing) r
  '?' : r -> lazy (Piece n 0 (Just 1)) r
  '{' : r -> do
    (lo, r1) <- number r
    case r1 of
      '}' : r2 -> lazy (Piece n lo (Just lo)) r2
      ',' : '}' : r2 -> lazy (Piece n lo Nothing) r2
      ',' : r2 -> do
        (hi, r3) <- number r2
        case r3 of
          '}' : r4 | hi >= lo -> lazy (Piece n lo (Just hi)) r4
          _ -> Left "malformed repetition"
      _ -> Left "malformed repetition"
  _ -> Right (Piece n 1 (Just 1), s)
  where
    lazy p ('?' : r) = Right (p, r)
    lazy p r = case r of
      c : _ | c `elem` ("*+?{" :: String) -> Left "repeated quantifier"
      _ -> Right (p, r)
    number r = case span isDigit r of
      ([], _) -> Left "malformed repetition"
      (ds, r') -> Right (read ds, r')

parseAtom :: String -> P Node
parseAtom s = case s of
  '(' : '?' : ':' : r -> group r
  '(' : '?' : _ -> Left "unsupported group (look-around, named group or flags)"
  '(' : r -> group r
  '[' : r -> parseClass r
  '.' : r -> Right (NAny, r)
  '^' : r -> Right (NStart, r)
  '$' : r -> Right (NEnd, r)
  '\\' : 'b' : r -> Right (NBoundary True, r)
  '\\' : 'B' : r -> Right (NBoundary False, r)
  '\\' : r -> do
    (item, r') <- parseEscape r
    Right (itemNode item, r')
  c : _ | c `elem` ("*+?{" :: String) -> Left "quantifier without an operand"
  c : r -> Right (NChar c, r)
  [] -> Left "unexpected end of pattern"
  where
    group r = do
      (alts, r') <- parseAlt r
      case r' of
        ')' : r'' -> Right (NGroup alts, r'')
        _ -> Left "unclosed group"
    itemNode (IRange a b) | a == b = NChar a
    itemNode (IClass neg is) = NClass neg is
    itemNode i = NClass False [i]

-- | An escape after the backslash, as a single character or a class.
parseEscape :: String -> P Item
parseEscape s = case s of
  'd' : r -> Right (IClass False digits, r)
  'D' : r -> Right (IClass True digits, r)
  'w' : r -> Right (IClass False word, r)
  'W' : r -> Right (IClass True word, r)
  's' : r -> Right (IClass False spaces, r)
  'S' : r -> Right (IClass True spaces, r)
  'n' : r -> lit '\n' r
  't' : r -> lit '\t' r
  'r' : r -> lit '\r' r
  'f' : r -> lit '\f' r
  'v' : r -> lit '\v' r
  '0' : r -> lit '\0' r
  'x' : a : b : r | all isHexDigit [a, b] -> lit (hex [a, b]) r
  'u' : a : b : c : d : r | all isHexDigit [a, b, c, d] -> lit (hex [a, b, c, d]) r
  c : r | not (isAsciiLower c || isAsciiUpper c || isDigit c) -> lit c r
  c : _ -> Left ("unrecognised escape \\" <> T.singleton c)
  [] -> Left "trailing backslash"
  where
    lit c r = Right (IRange c c, r)
    hex = chr . foldl (\acc h -> acc * 16 + digitToInt h) 0
    digits = [IRange '0' '9']
    word = [IRange 'A' 'Z', IRange 'a' 'z', IRange '0' '9', IRange '_' '_']
    spaces = [IRange c c | c <- " \t\n\r\x0b\x0c\x00a0\xfeff\x2003\x2029"]

parseClass :: String -> P Node
parseClass s = case s of
  '^' : r -> body True r
  r -> body False r
  where
    body neg r = case r of
      ']' : r' -> items neg [IRange ']' ']'] r'
      _ -> items neg [] r
    items neg acc r = case r of
      ']' : r' -> Right (NClass neg (reverse acc), r')
      [] -> Left "unclosed character class"
      _ -> do
        (lo, r1) <- classChar r
        case (lo, r1) of
          (IRange a _, '-' : r2@(c : _)) | c /= ']' -> do
            (hi, r3) <- classChar r2
            case hi of
              IRange b _ | a <= b -> items neg (IRange a b : acc) r3
              _ -> Left "invalid class range"
          _ -> items neg (lo : acc) r1
    classChar r = case r of
      '\\' : 'b' : r' -> Right (IRange '\b' '\b', r')
      '\\' : r' -> parseEscape r'
      c : r' -> Right (IRange c c, r')
      [] -> Left "unclosed character class"
