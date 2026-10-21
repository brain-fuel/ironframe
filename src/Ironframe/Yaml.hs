{-# LANGUAGE MultiWayIf #-}

-- | YAML text read and written as serde_yaml 0.9 does it.
-- Reading follows libyaml's reader, scanner and parser step by step.
-- So documents, errors and their positions come out as Rust reports them.
-- Scalars then resolve into JSON values by serde_yaml's own rules.
-- Writing follows libyaml's emitter with serde_yaml's choice of quoting.
-- ref:DEC-haskell-wasm-core
module Ironframe.Yaml
  ( decodeYaml
  , encodeYaml
  ) where

import Control.Monad (ap, forM_, unless, when)
import Data.Bits (shiftR, (.&.))
import Data.Char (GeneralCategory (..), chr, digitToInt, generalCategory, isAsciiLower, isAsciiUpper, isDigit, isHexDigit, ord)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Ratio ((%))
import Data.Sequence (Seq, ViewL (..), (|>))
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import qualified Data.ByteString as BS
import Ironframe.Json (Number (..), Value (..))
import GHC.Float (castDoubleToWord64)
import Numeric (showHex)

------------------------------------------------------------------------------
-- Positions and libyaml errors

-- | A libyaml mark: byte index, line and column, all counted from zero.
data Mark = Mark {mIndex :: !Int, mLine :: !Int, mCol :: !Int}

-- | The start of the input.
zeroMark :: Mark
zeroMark = Mark 0 0 0

-- | A libyaml error: the problem, where it was found, and what was being read.
data YErr = YErr Text Mark Int (Maybe (Text, Mark))

-- | Whether a mark is past the start; libyaml prints only such marks.
nonZero :: Mark -> Bool
nonZero m = mLine m /= 0 || mCol m /= 0

-- | A mark as serde_yaml prints it, counting from one.
showMark :: Mark -> Text
showMark m = "line " <> tshow (mLine m + 1) <> " column " <> tshow (mCol m + 1)

-- | Shows a value as text.
tshow :: Show a => a -> Text
tshow = T.pack . show

-- | libyaml's error as serde_yaml displays it.
showYErr :: YErr -> Text
showYErr (YErr problem m off ctx) = problem <> at <> context
  where
    at
      | nonZero m = " at " <> showMark m
      | off /= 0 = " at position " <> tshow off
      | otherwise = ""
    context = case ctx of
      Nothing -> ""
      Just (c, cm) ->
        ", " <> c
          <> if nonZero cm && (mLine cm /= mLine m || mCol cm /= mCol m)
            then " at " <> showMark cm
            else ""

------------------------------------------------------------------------------
-- Tokens, events and the reading state

-- | How a scalar was written.
data Style = Plain | SingleQ | DoubleQ | Literal | Folded
  deriving (Eq)

-- | libyaml's token types with their data.
data Tok
  = TStreamStart
  | TStreamEnd
  | TVersion !Int !Int
  | TTagDir String String
  | TDocStart
  | TDocEnd
  | TBlockSeqStart
  | TBlockMapStart
  | TBlockEnd
  | TFlowSeqStart
  | TFlowSeqEnd
  | TFlowMapStart
  | TFlowMapEnd
  | TBlockEntry
  | TFlowEntry
  | TKey
  | TValue
  | TAlias Text
  | TAnchor Text
  | TTag String String
  | TScalar Text Style

-- | A token and where it starts and ends.
data Token = Token {tokType :: Tok, tokStart :: Mark, tokEnd :: Mark}

-- | A place where a key without ? may have started.
data SimpleKey = SimpleKey
  { skPossible :: !Bool
  , skRequired :: !Bool
  , skTokenNumber :: !Int
  , skMark :: Mark
  }

-- | libyaml's parser states.
data PState
  = PStreamStart
  | PImplicitDocStart
  | PDocStart
  | PDocContent
  | PDocEnd
  | PBlockNode
  | PBlockNodeOrIndentless
  | PFlowNode
  | PBlockSeqFirst
  | PBlockSeqEntry
  | PIndentlessEntry
  | PBlockMapFirst
  | PBlockMapKey
  | PBlockMapValue
  | PFlowSeqFirst
  | PFlowSeqEntry
  | PFlowSeqMapKey
  | PFlowSeqMapValue
  | PFlowSeqMapEnd
  | PFlowMapFirst
  | PFlowMapKey
  | PFlowMapValue
  | PFlowMapEmptyValue
  | PEnd

-- | libyaml's events with their data.
data Ev
  = EStreamStart
  | EStreamEnd
  | EDocStart
  | EDocEnd
  | EAlias Text
  | EScalar (Maybe Text) (Maybe Text) Text Style
  | ESeqStart (Maybe Text) (Maybe Text)
  | ESeqEnd
  | EMapStart (Maybe Text) (Maybe Text)
  | EMapEnd

-- | The reader, scanner and parser state together.
data S = S
  { sInput :: String
  , sMark :: !Mark
  , sConsumed :: !Int
  , sDecoded :: !Int
  , sChunks :: [(Int, Maybe Int)]
  , sNul :: !Bool
  , sTokens :: Seq Token
  , sTokensParsed :: !Int
  , sTokenAvailable :: !Bool
  , sStreamStarted :: !Bool
  , sIndent :: !Int
  , sIndents :: [Int]
  , sKeyAllowed :: !Bool
  , sKeys :: [SimpleKey]
  , sFlow :: !Int
  , sState :: PState
  , sStates :: [PState]
  , sMarks :: [Mark]
  , sTagDirs :: [(String, String)]
  }

-- | State and failure, keeping the state reached when a failure happens.
newtype M a = M {runM :: S -> (Either YErr a, S)}

instance Functor M where
  fmap f (M g) = M $ \s -> case g s of (r, s') -> (fmap f r, s')

instance Applicative M where
  pure a = M (\s -> (Right a, s))
  (<*>) = ap

instance Monad M where
  M g >>= k = M $ \s -> case g s of
    (Left e, s') -> (Left e, s')
    (Right a, s') -> runM (k a) s'

-- | Reads from the reading state.
gets :: (S -> a) -> M a
gets f = M (\s -> (Right (f s), s))

-- | Changes the reading state.
modify' :: (S -> S) -> M ()
modify' f = M (\s -> let s' = f s in s' `seq` (Right (), s'))

-- | Fails with a libyaml error.
throwE :: YErr -> M a
throwE e = M (\s -> (Left e, s))

------------------------------------------------------------------------------
-- The reader: characters, chunks of input, and marks

-- | The bytes a character takes in UTF-8.
utf8Len :: Char -> Int
utf8Len c
  | n < 0x80 = 1
  | n < 0x800 = 2
  | n < 0x10000 = 3
  | otherwise = 4
  where
    n = ord c

-- | The characters libyaml's reader accepts.
readerAllows :: Char -> Bool
readerAllows c =
  n == 0x9 || n == 0xA || n == 0xD || (n >= 0x20 && n <= 0x7E) || n == 0x85
    || (n >= 0xA0 && n <= 0xD7FF)
    || (n >= 0xE000 && n <= 0xFFFD)
    || (n >= 0x10000 && n <= 0x10FFFF)
  where
    n = ord c

-- | The input as libyaml's reader decodes it, 16384 raw bytes at a time: the
-- character count at each chunk's end, and a rejected character's offset.
-- serde_yaml fixes the encoding as UTF-8, so a byte order mark stays in the
-- input; the scanner skips it as a character at the start of a line.
mkChunks :: String -> [(Int, Maybe Int)]
mkChunks = go 0 0 0
  where
    go rawStart off n cs
      | null cs = []
      | otherwise = chunk (rawStart + 16384) off n cs
    chunk limit o k xs = case xs of
      (c : rest)
        | o + utf8Len c <= limit ->
            if readerAllows c then chunk limit (o + utf8Len c) (k + 1) rest else [(k, Just o)]
      _ -> (k, Nothing) : go o o k xs

-- | libyaml's CACHE: makes sure enough characters are decoded.
cache :: Int -> M ()
cache n = do
  s <- gets id
  let unread = sDecoded s - sConsumed s + (if sNul s then 1 else 0)
  when (unread < n) $ case sChunks s of
    [] -> unless (sNul s) $ modify' (\st -> st {sNul = True})
    ((end, bad) : rest) -> case bad of
      Just off -> throwE (YErr "control characters are not allowed" zeroMark off Nothing)
      Nothing -> modify' (\st -> st {sDecoded = end, sChunks = rest}) >> cache n

-- | The character some places ahead; NUL past the end, as libyaml pads it.
peekAt :: Int -> M Char
peekAt k = gets (\s -> case drop k (sInput s) of (c : _) -> c; [] -> '\0')

-- | The next character.
peek :: M Char
peek = peekAt 0

-- | libyaml's SKIP: steps over one character.
skip :: M ()
skip = modify' $ \s -> case sInput s of
  (c : cs) ->
    let Mark i l col = sMark s
     in s {sInput = cs, sMark = Mark (i + utf8Len c) l (col + 1), sConsumed = sConsumed s + 1}
  [] -> s

-- | Steps over a line break of the given characters and bytes.
newline :: Int -> Int -> M ()
newline nChars nBytes = modify' $ \s ->
  let Mark i l _ = sMark s
   in s {sInput = drop nChars (sInput s), sMark = Mark (i + nBytes) (l + 1) 0, sConsumed = sConsumed s + nChars}

-- | libyaml's SKIP_LINE: steps over one line break.
skipLine :: M ()
skipLine = do
  c0 <- peek
  c1 <- peekAt 1
  if c0 == '\r' && c1 == '\n'
    then newline 2 2
    else when (isBreak c0) (newline 1 (utf8Len c0))

-- | libyaml's READ_LINE: a line break read as it is kept in a scalar.
readLine :: M String
readLine = do
  c0 <- peek
  c1 <- peekAt 1
  case c0 of
    '\r' | c1 == '\n' -> newline 2 2 >> pure "\n"
    '\r' -> newline 1 1 >> pure "\n"
    '\n' -> newline 1 1 >> pure "\n"
    '\x85' -> newline 1 2 >> pure "\n"
    '\x2028' -> newline 1 3 >> pure [c0]
    '\x2029' -> newline 1 3 >> pure [c0]
    _ -> pure ""

-- | A line break as libyaml counts them.
isBreak :: Char -> Bool
isBreak c = c == '\r' || c == '\n' || c == '\x85' || c == '\x2028' || c == '\x2029'

-- | A line break or the end of input.
isBreakZ :: Char -> Bool
isBreakZ c = isBreak c || c == '\0'

-- | A space or a tab.
isBlank :: Char -> Bool
isBlank c = c == ' ' || c == '\t'

-- | A blank, a line break or the end of input.
isBlankZ :: Char -> Bool
isBlankZ c = isBlank c || isBreakZ c

-- | libyaml's IS_ALPHA: ASCII letters, digits, underscore and dash.
isAlphaY :: Char -> Bool
isAlphaY c = isDigit c || isAsciiUpper c || isAsciiLower c || c == '_' || c == '-'

-- | A scanner error at the current mark.
scannerError :: Maybe Text -> Mark -> Text -> M a
scannerError ctx ctxMark problem = do
  m <- gets sMark
  throwE (YErr problem m 0 (fmap (\c -> (c, ctxMark)) ctx))

------------------------------------------------------------------------------
-- The scanner

-- | Adds a token at the end of the queue.
enqueue :: Token -> M ()
enqueue t = modify' (\s -> s {sTokens = sTokens s |> t})

-- | Fetches tokens until the next one can no longer become a key.
fetchMoreTokens :: M ()
fetchMoreTokens = do
  q <- gets sTokens
  need <-
    if Seq.null q
      then pure True
      else do
        staleSimpleKeys
        s <- gets id
        pure (any (\k -> skPossible k && skTokenNumber k == sTokensParsed s) (sKeys s))
  if need
    then fetchNextToken >> fetchMoreTokens
    else modify' (\s -> s {sTokenAvailable = True})

-- | libyaml's yaml_parser_fetch_next_token.
fetchNextToken :: M ()
fetchNextToken = do
  cache 1
  started <- gets sStreamStarted
  if not started
    then fetchStreamStart
    else do
      scanToNextToken
      staleSimpleKeys
      col <- gets (mCol . sMark)
      unrollIndent col
      cache 4
      c <- peek
      c1 <- peekAt 1
      c2 <- peekAt 2
      c3 <- peekAt 3
      flow <- gets sFlow
      let docIndicator ch = col == 0 && c == ch && c1 == ch && c2 == ch && isBlankZ c3
          plainStart =
            not (isBlankZ c || c `elem` ("-?:,[]{}#&*!|>'\"%@`" :: String))
              || (c == '-' && not (isBlank c1))
              || (flow == 0 && (c == '?' || c == ':') && not (isBlankZ c1))
      if
        | c == '\0' -> fetchStreamEnd
        | col == 0 && c == '%' -> fetchDirective
        | docIndicator '-' -> fetchDocumentIndicator TDocStart
        | docIndicator '.' -> fetchDocumentIndicator TDocEnd
        | c == '[' -> fetchFlowCollectionStart TFlowSeqStart
        | c == '{' -> fetchFlowCollectionStart TFlowMapStart
        | c == ']' -> fetchFlowCollectionEnd TFlowSeqEnd
        | c == '}' -> fetchFlowCollectionEnd TFlowMapEnd
        | c == ',' -> fetchFlowEntry
        | c == '-' && isBlankZ c1 -> fetchBlockEntry
        | c == '?' && (flow /= 0 || isBlankZ c1) -> fetchKey
        | c == ':' && (flow /= 0 || isBlankZ c1) -> fetchValue
        | c == '*' -> fetchAnchor False
        | c == '&' -> fetchAnchor True
        | c == '!' -> fetchTag
        | c == '|' && flow == 0 -> fetchBlockScalar True
        | c == '>' && flow == 0 -> fetchBlockScalar False
        | c == '\'' -> fetchFlowScalar True
        | c == '"' -> fetchFlowScalar False
        | plainStart -> fetchPlainScalar
        | otherwise -> do
            m <- gets sMark
            scannerError (Just "while scanning for the next token") m "found character that cannot start any token"

-- | Drops possible simple keys that can no longer be keys.
staleSimpleKeys :: M ()
staleSimpleKeys = do
  s <- gets id
  let m = sMark s
      go [] = Right []
      go (k : ks)
        | skPossible k && (mLine (skMark k) < mLine m || mIndex (skMark k) + 1024 < mIndex m) =
            if skRequired k then Left k else (k {skPossible = False} :) <$> go ks
        | otherwise = (k :) <$> go ks
  case go (reverse (sKeys s)) of
    Left k -> throwE (YErr "could not find expected ':'" m 0 (Just ("while scanning a simple key", skMark k)))
    Right ks -> modify' (\st -> st {sKeys = reverse ks})

-- | The simple key of the current flow level.
topKey :: M SimpleKey
topKey = gets (\s -> case sKeys s of (k : _) -> k; [] -> emptyKey)

-- | Replaces the simple key of the current flow level.
setTopKey :: SimpleKey -> M ()
setTopKey k = modify' (\s -> s {sKeys = k : drop 1 (sKeys s)})

-- | A simple key slot that holds no key.
emptyKey :: SimpleKey
emptyKey = SimpleKey False False 0 zeroMark

-- | Remembers that the next token may start a simple key.
saveSimpleKey :: M ()
saveSimpleKey = do
  s <- gets id
  let required = sFlow s == 0 && sIndent s == mCol (sMark s)
  when (sKeyAllowed s) $ do
    removeSimpleKey
    setTopKey (SimpleKey True required (sTokensParsed s + Seq.length (sTokens s)) (sMark s))

-- | Forgets the current possible simple key.
removeSimpleKey :: M ()
removeSimpleKey = do
  k <- topKey
  when (skPossible k && skRequired k) $ do
    m <- gets sMark
    throwE (YErr "could not find expected ':'" m 0 (Just ("while scanning a simple key", skMark k)))
  setTopKey k {skPossible = False}

-- | Enters a flow collection.
increaseFlowLevel :: M ()
increaseFlowLevel = modify' (\s -> s {sKeys = emptyKey : sKeys s, sFlow = sFlow s + 1})

-- | Leaves a flow collection.
decreaseFlowLevel :: M ()
decreaseFlowLevel = modify' $ \s ->
  if sFlow s /= 0 then s {sFlow = sFlow s - 1, sKeys = drop 1 (sKeys s)} else s

-- | Opens a block collection when the column goes deeper.
rollIndent :: Int -> Int -> Tok -> Mark -> M ()
rollIndent col number typ mark = do
  s <- gets id
  when (sFlow s == 0 && sIndent s < col) $ do
    modify' (\st -> st {sIndents = sIndent st : sIndents st, sIndent = col})
    let t = Token typ mark mark
    if number == -1
      then enqueue t
      else modify' (\st -> st {sTokens = Seq.insertAt (number - sTokensParsed st) t (sTokens st)})

-- | Closes block collections deeper than the column.
unrollIndent :: Int -> M ()
unrollIndent col = do
  s <- gets id
  when (sFlow s == 0 && sIndent s > col) $ do
    enqueue (Token TBlockEnd (sMark s) (sMark s))
    modify' (\st -> case sIndents st of (i : is) -> st {sIndent = i, sIndents = is}; [] -> st)
    unrollIndent col

-- | Sets whether a simple key may start here.
setKeyAllowed :: Bool -> M ()
setKeyAllowed b = modify' (\s -> s {sKeyAllowed = b})

-- | The STREAM-START token.
fetchStreamStart :: M ()
fetchStreamStart = do
  modify' (\s -> s {sIndent = -1, sKeys = [emptyKey], sKeyAllowed = True, sStreamStarted = True})
  m <- gets sMark
  enqueue (Token TStreamStart m m)

-- | The STREAM-END token, closing all blocks.
fetchStreamEnd :: M ()
fetchStreamEnd = do
  modify' (\s -> let Mark i l c = sMark s in if c /= 0 then s {sMark = Mark i (l + 1) 0} else s)
  unrollIndent (-1)
  removeSimpleKey
  setKeyAllowed False
  m <- gets sMark
  enqueue (Token TStreamEnd m m)

-- | A %YAML or %TAG directive token.
fetchDirective :: M ()
fetchDirective = do
  unrollIndent (-1)
  removeSimpleKey
  setKeyAllowed False
  scanDirective >>= enqueue

-- | A --- or ... token.
fetchDocumentIndicator :: Tok -> M ()
fetchDocumentIndicator typ = do
  unrollIndent (-1)
  removeSimpleKey
  setKeyAllowed False
  simpleToken typ 3

-- | A token of a few indicator characters.
simpleToken :: Tok -> Int -> M ()
simpleToken typ n = do
  start <- gets sMark
  mapM_ (const skip) [1 .. n]
  end <- gets sMark
  enqueue (Token typ start end)

-- | A [ or { token.
fetchFlowCollectionStart :: Tok -> M ()
fetchFlowCollectionStart typ = do
  saveSimpleKey
  increaseFlowLevel
  setKeyAllowed True
  simpleToken typ 1

-- | A ] or } token.
fetchFlowCollectionEnd :: Tok -> M ()
fetchFlowCollectionEnd typ = do
  removeSimpleKey
  decreaseFlowLevel
  setKeyAllowed False
  simpleToken typ 1

-- | A , token.
fetchFlowEntry :: M ()
fetchFlowEntry = do
  removeSimpleKey
  setKeyAllowed True
  simpleToken TFlowEntry 1

-- | A - token, opening a block sequence when needed.
fetchBlockEntry :: M ()
fetchBlockEntry = do
  s <- gets id
  when (sFlow s == 0) $ do
    unless (sKeyAllowed s) $
      scannerError Nothing (sMark s) "block sequence entries are not allowed in this context"
    rollIndent (mCol (sMark s)) (-1) TBlockSeqStart (sMark s)
  removeSimpleKey
  setKeyAllowed True
  simpleToken TBlockEntry 1

-- | A ? token, opening a block mapping when needed.
fetchKey :: M ()
fetchKey = do
  s <- gets id
  when (sFlow s == 0) $ do
    unless (sKeyAllowed s) $
      scannerError Nothing (sMark s) "mapping keys are not allowed in this context"
    rollIndent (mCol (sMark s)) (-1) TBlockMapStart (sMark s)
  removeSimpleKey
  flow <- gets sFlow
  setKeyAllowed (flow == 0)
  simpleToken TKey 1

-- | A : token, turning a remembered simple key into a KEY token.
fetchValue :: M ()
fetchValue = do
  k <- topKey
  if skPossible k
    then do
      modify' (\st -> st {sTokens = Seq.insertAt (skTokenNumber k - sTokensParsed st) (Token TKey (skMark k) (skMark k)) (sTokens st)})
      rollIndent (mCol (skMark k)) (skTokenNumber k) TBlockMapStart (skMark k)
      setTopKey k {skPossible = False}
      setKeyAllowed False
    else do
      s <- gets id
      when (sFlow s == 0) $ do
        unless (sKeyAllowed s) $
          scannerError Nothing (sMark s) "mapping values are not allowed in this context"
        rollIndent (mCol (sMark s)) (-1) TBlockMapStart (sMark s)
      setKeyAllowed (sFlow s == 0)
  simpleToken TValue 1

-- | An anchor or alias token.
fetchAnchor :: Bool -> M ()
fetchAnchor isAnchor = do
  saveSimpleKey
  setKeyAllowed False
  scanAnchor isAnchor >>= enqueue

-- | A tag token.
fetchTag :: M ()
fetchTag = do
  saveSimpleKey
  setKeyAllowed False
  scanTag >>= enqueue

-- | A literal or folded block scalar token.
fetchBlockScalar :: Bool -> M ()
fetchBlockScalar literal = do
  removeSimpleKey
  setKeyAllowed True
  scanBlockScalar literal >>= enqueue

-- | A single or double quoted scalar token.
fetchFlowScalar :: Bool -> M ()
fetchFlowScalar single = do
  saveSimpleKey
  setKeyAllowed False
  scanFlowScalar single >>= enqueue

-- | A plain scalar token.
fetchPlainScalar :: M ()
fetchPlainScalar = do
  saveSimpleKey
  setKeyAllowed False
  scanPlainScalar >>= enqueue

-- | Skips blanks, comments and line breaks before a token.
scanToNextToken :: M ()
scanToNextToken = do
  cache 1
  col <- gets (mCol . sMark)
  c <- peek
  when (col == 0 && c == '\xFEFF') skip
  cache 1
  let blanks = do
        ch <- peek
        s <- gets id
        when (ch == ' ' || ((sFlow s /= 0 || not (sKeyAllowed s)) && ch == '\t')) $
          skip >> cache 1 >> blanks
  blanks
  ch <- peek
  when (ch == '#') skipComment
  ch' <- peek
  when (isBreak ch') $ do
    cache 2
    skipLine
    flow <- gets sFlow
    when (flow == 0) (setKeyAllowed True)
    scanToNextToken

-- | Skips a comment up to the line break.
skipComment :: M ()
skipComment = do
  c <- peek
  unless (isBreakZ c) (skip >> cache 1 >> skipComment)

-- | Skips spaces and tabs.
skipBlanks :: M ()
skipBlanks = do
  c <- peek
  when (isBlank c) (skip >> cache 1 >> skipBlanks)

-- | Reads a directive line.
scanDirective :: M Token
scanDirective = do
  start <- gets sMark
  skip
  name <- scanDirectiveName start
  tok <- case name of
    "YAML" -> do
      (major, minor) <- scanVersionDirectiveValue start
      end <- gets sMark
      pure (Token (TVersion major minor) start end)
    "TAG" -> do
      (handle, prefix) <- scanTagDirectiveValue start
      end <- gets sMark
      pure (Token (TTagDir handle prefix) start end)
    _ -> scannerError (Just "while scanning a directive") start "found unknown directive name"
  cache 1
  skipBlanks
  c <- peek
  when (c == '#') skipComment
  c' <- peek
  unless (isBreakZ c') $
    scannerError (Just "while scanning a directive") start "did not find expected comment or line break"
  when (isBreak c') (cache 2 >> skipLine)
  pure tok

-- | Reads a directive's name.
scanDirectiveName :: Mark -> M String
scanDirectiveName start = do
  cache 1
  name <- readWhile isAlphaY
  c <- peek
  if null name
    then scannerError (Just "while scanning a directive") start "could not find expected directive name"
    else
      if not (isBlankZ c)
        then scannerError (Just "while scanning a directive") start "found unexpected non-alphabetical character"
        else pure name

-- | Reads characters while they match, caching one ahead as libyaml does.
readWhile :: (Char -> Bool) -> M String
readWhile p = go []
  where
    go acc = do
      c <- peek
      if p c
        then skip >> cache 1 >> go (c : acc)
        else pure (reverse acc)

-- | Reads the version of a %YAML directive.
scanVersionDirectiveValue :: Mark -> M (Int, Int)
scanVersionDirectiveValue start = do
  cache 1
  skipBlanks
  major <- scanVersionDirectiveNumber start
  c <- peek
  unless (c == '.') $
    scannerError (Just "while scanning a %YAML directive") start "did not find expected digit or '.' character"
  skip
  minor <- scanVersionDirectiveNumber start
  pure (major, minor)

-- | Reads one number of a %YAML version.
scanVersionDirectiveNumber :: Mark -> M Int
scanVersionDirectiveNumber start = cache 1 >> go 0 (0 :: Int)
  where
    go value len = do
      c <- peek
      if isDigit c
        then do
          when (len + 1 > 9) $
            scannerError (Just "while scanning a %YAML directive") start "found extremely long version number"
          skip
          cache 1
          go (value * 10 + digitToInt c) (len + 1)
        else
          if len == 0
            then scannerError (Just "while scanning a %YAML directive") start "did not find expected version number"
            else pure value

-- | Reads the handle and prefix of a %TAG directive.
scanTagDirectiveValue :: Mark -> M (String, String)
scanTagDirectiveValue start = do
  cache 1
  skipBlanks
  handle <- scanTagHandle True start
  cache 1
  c <- peek
  unless (isBlank c) $
    scannerError (Just "while scanning a %TAG directive") start "did not find expected whitespace"
  skipBlanks
  prefix <- scanTagUri True True Nothing start
  cache 1
  c' <- peek
  unless (isBlankZ c') $
    scannerError (Just "while scanning a %TAG directive") start "did not find expected whitespace or line break"
  pure (handle, prefix)

-- | Reads an anchor or alias name.
scanAnchor :: Bool -> M Token
scanAnchor isAnchor = do
  start <- gets sMark
  skip
  cache 1
  name <- readWhile isAlphaY
  end <- gets sMark
  c <- peek
  when (null name || not (isBlankZ c || c `elem` ("?:,]}%@`" :: String))) $
    scannerError
      (Just (if isAnchor then "while scanning an anchor" else "while scanning an alias"))
      start
      "did not find expected alphabetic or numeric character"
  let v = T.pack name
  pure (Token (if isAnchor then TAnchor v else TAlias v) start end)

-- | Reads a tag's handle and suffix.
scanTag :: M Token
scanTag = do
  start <- gets sMark
  cache 2
  c1 <- peekAt 1
  (handle, suffix) <-
    if c1 == '<'
      then do
        skip
        skip
        suffix <- scanTagUri True False Nothing start
        c <- peek
        unless (c == '>') $
          scannerError (Just "while scanning a tag") start "did not find the expected '>'"
        skip
        pure ("", suffix)
      else do
        handle <- scanTagHandle False start
        if length handle > 1 && take 1 handle == "!" && take 1 (reverse handle) == "!"
          then do
            suffix <- scanTagUri False False Nothing start
            pure (handle, suffix)
          else do
            suffix <- scanTagUri False False (Just handle) start
            pure (if null suffix then ("", "!") else ("!", suffix))
  cache 1
  c <- peek
  flow <- gets sFlow
  when (not (isBlankZ c) && (flow == 0 || c /= ',')) $
    scannerError (Just "while scanning a tag") start "did not find expected whitespace or line break"
  end <- gets sMark
  pure (Token (TTag handle suffix) start end)

-- | Reads a tag handle such as ! or !!.
scanTagHandle :: Bool -> Mark -> M String
scanTagHandle directive start = do
  cache 1
  c <- peek
  unless (c == '!') $
    scannerError
      (Just (if directive then "while scanning a tag directive" else "while scanning a tag"))
      start
      "did not find expected '!'"
  skip
  cache 1
  name <- readWhile isAlphaY
  c' <- peek
  if c' == '!'
    then skip >> pure ('!' : name ++ "!")
    else
      if directive && not (null name)
        then scannerError (Just "while parsing a tag directive") start "did not find expected '!'"
        else pure ('!' : name)

-- | A tag URI, kept as a string of bytes; escaped octets are decoded.
scanTagUri :: Bool -> Bool -> Maybe String -> Mark -> M String
scanTagUri uriChar directive headM start = do
  let headS = fromMaybe "" headM
  cache 1
  go (length headS) (reverse (drop 1 headS))
  where
    ctx = if directive then "while parsing a %TAG directive" else "while parsing a tag"
    ok c =
      isAlphaY c || c `elem` (";/?:@&=+$.%!~*'()" :: String)
        || (uriChar && c `elem` (",[]" :: String))
    go len acc = do
      c <- peek
      if ok c
        then do
          acc' <-
            if c == '%'
              then (++ acc) . reverse <$> scanUriEscapes directive start
              else skip >> pure (c : acc)
          cache 1
          go (len + 1 :: Int) acc'
        else
          if len == 0
            then scannerError (Just ctx) start "did not find expected tag URI"
            else pure (reverse acc)

-- | Reads %-escaped octets of one UTF-8 character.
scanUriEscapes :: Bool -> Mark -> M String
scanUriEscapes directive start = go (0 :: Int) []
  where
    ctx = if directive then "while parsing a %TAG directive" else "while parsing a tag"
    go width acc = do
      cache 3
      c0 <- peek
      c1 <- peekAt 1
      c2 <- peekAt 2
      unless (c0 == '%' && isHexDigit c1 && isHexDigit c2) $
        scannerError (Just ctx) start "did not find URI escaped octet"
      let octet = digitToInt c1 * 16 + digitToInt c2
      width' <-
        if width == 0
          then do
            let w = utf8Width octet
            when (w == 0) $ scannerError (Just ctx) start "found an incorrect leading UTF-8 octet"
            pure w
          else do
            when (octet `div` 64 /= 2) $ scannerError (Just ctx) start "found an incorrect trailing UTF-8 octet"
            pure width
      skip >> skip >> skip
      let acc' = chr octet : acc
      if width' - 1 == 0 then pure (reverse acc') else go (width' - 1) acc'

-- | The length of a UTF-8 sequence from its first octet; 0 when invalid.
utf8Width :: Int -> Int
utf8Width o
  | o < 0x80 = 1
  | o >= 0xC0 && o < 0xE0 = 2
  | o >= 0xE0 && o < 0xF0 = 3
  | o >= 0xF0 && o < 0xF8 = 4
  | otherwise = 0

-- | Reads a literal or folded block scalar.
scanBlockScalar :: Bool -> M Token
scanBlockScalar literal = do
  start <- gets sMark
  skip
  cache 1
  let ctx = Just "while scanning a block scalar"
      zeroIndicator = scannerError ctx start "found an indentation indicator equal to 0"
  c <- peek
  (chomping, increment) <-
    if c == '+' || c == '-'
      then do
        let ch = if c == '+' then 1 else -1 :: Int
        skip
        cache 1
        d <- peek
        if isDigit d
          then do
            when (d == '0') zeroIndicator
            skip
            pure (ch, digitToInt d)
          else pure (ch, 0)
      else
        if isDigit c
          then do
            when (c == '0') zeroIndicator
            skip
            cache 1
            d <- peek
            if d == '+' || d == '-'
              then skip >> pure (if d == '+' then 1 else -1, digitToInt c)
              else pure (0, digitToInt c)
          else pure (0, 0)
  cache 1
  skipBlanks
  c' <- peek
  when (c' == '#') skipComment
  c'' <- peek
  unless (isBreakZ c'') $ scannerError ctx start "did not find expected comment or line break"
  when (isBreak c'') (cache 2 >> skipLine)
  end0 <- gets sMark
  parentIndent <- gets sIndent
  let indent0
        | increment /= 0 = if parentIndent >= 0 then parentIndent + increment else increment
        | otherwise = 0
  (indent, trailing0, end1) <- scanBlockScalarBreaks indent0 [] start end0
  cache 1
  let loop str leadingBreak trailing leadingBlank end = do
        col <- gets (mCol . sMark)
        ch <- peek
        if col == indent && ch /= '\0'
          then do
            let trailingBlank = isBlank ch
                (str1, leading1)
                  | not literal && take 1 leadingBreak == "\n" && not leadingBlank && not trailingBlank =
                      (if null trailing then ' ' : str else str, [])
                  | otherwise = (reverse leadingBreak ++ str, [])
                str2 = reverse trailing ++ str1
                leadingBlank' = isBlank ch
            content <- readContent []
            cache 2
            lb <- readLine
            (_, trailing', end') <- scanBlockScalarBreaks indent [] start end
            loop (reverse content ++ str2) (leading1 ++ lb) trailing' leadingBlank' end'
          else pure (str, leadingBreak, trailing, end)
      readContent acc = do
        ch <- peek
        if isBreakZ ch then pure (reverse acc) else skip >> cache 1 >> readContent (ch : acc)
  (str, leadingBreak, trailing, end) <- loop [] [] trailing0 False end1
  let str' = (if chomping /= -1 then reverse leadingBreak else []) ++ str
      str'' = (if chomping == 1 then reverse trailing else []) ++ str'
  pure (Token (TScalar (T.pack (reverse str'')) (if literal then Literal else Folded)) start end)

-- | Line breaks and indentation before block scalar content.
scanBlockScalarBreaks :: Int -> String -> Mark -> Mark -> M (Int, String, Mark)
scanBlockScalarBreaks indent0 breaks0 start _ = do
  end0 <- gets sMark
  go 0 breaks0 end0
  where
    go maxIndent breaks end = do
      cache 1
      let spaces = do
            col <- gets (mCol . sMark)
            c <- peek
            when ((indent0 == 0 || col < indent0) && c == ' ') (skip >> cache 1 >> spaces)
      spaces
      col <- gets (mCol . sMark)
      let maxIndent' = max maxIndent col
      c <- peek
      when ((indent0 == 0 || col < indent0) && c == '\t') $
        scannerError
          (Just "while scanning a block scalar")
          start
          "found a tab character where an indentation space is expected"
      if not (isBreak c)
        then do
          parentIndent <- gets sIndent
          let indent
                | indent0 == 0 = maximum [maxIndent', parentIndent + 1, 1]
                | otherwise = indent0
          pure (indent, breaks, end)
        else do
          cache 2
          lb <- readLine
          end' <- gets sMark
          go maxIndent' (breaks ++ lb) end'

-- | Reads a single or double quoted scalar.
scanFlowScalar :: Bool -> M Token
scanFlowScalar single = do
  start <- gets sMark
  skip
  let ctxQ = Just "while scanning a quoted scalar"
      ctxP = Just "while parsing a quoted scalar"
      quote = if single then '\'' else '"'
      outer str = do
        cache 4
        col <- gets (mCol . sMark)
        c0 <- peek
        c1 <- peekAt 1
        c2 <- peekAt 2
        c3 <- peekAt 3
        when (col == 0 && ((c0 == '-' && c1 == '-' && c2 == '-') || (c0 == '.' && c1 == '.' && c2 == '.')) && isBlankZ c3) $
          scannerError ctxQ start "found unexpected document indicator"
        when (c0 == '\0') $ scannerError ctxQ start "found unexpected end of stream"
        cache 2
        (str1, leadingBlanks) <- inner str
        cache 1
        c <- peek
        if c == quote
          then pure str1
          else do
            cache 1
            (str2, _) <- blanks str1 leadingBlanks [] [] []
            outer str2
      inner str = do
        c <- peek
        c1 <- peekAt 1
        if isBlankZ c
          then pure (str, False)
          else
            if single && c == '\'' && c1 == '\''
              then skip >> skip >> cache 2 >> inner ('\'' : str)
              else
                if c == quote
                  then pure (str, False)
                  else
                    if not single && c == '\\' && isBreak c1
                      then cache 3 >> skip >> skipLine >> pure (str, True)
                      else
                        if not single && c == '\\'
                          then do
                            str' <- escape str c1
                            cache 2
                            inner str'
                          else do
                            skip
                            cache 2
                            inner (c : str)
      escape str e = do
        let simple ch = skip >> skip >> pure (ch : str)
        case e of
          '0' -> simple '\0'
          'a' -> simple '\x07'
          'b' -> simple '\x08'
          't' -> simple '\t'
          '\t' -> simple '\t'
          'n' -> simple '\n'
          'v' -> simple '\x0B'
          'f' -> simple '\x0C'
          'r' -> simple '\r'
          'e' -> simple '\x1B'
          ' ' -> simple ' '
          '"' -> simple '"'
          '/' -> simple '/'
          '\\' -> simple '\\'
          'N' -> simple '\x85'
          '_' -> simple '\xA0'
          'L' -> simple '\x2028'
          'P' -> simple '\x2029'
          'x' -> code 2
          'u' -> code 4
          'U' -> code 8
          _ -> scannerError ctxP start "found unknown escape character"
        where
          code n = do
            skip
            skip
            cache n
            ds <- mapM peekAt [0 .. n - 1]
            unless (all isHexDigit ds) $
              scannerError ctxP start "did not find expected hexadecimal number"
            let value = foldl (\a d -> a * 16 + digitToInt d) 0 ds
            when ((value >= 0xD800 && value <= 0xDFFF) || value > 0x10FFFF) $
              scannerError ctxP start "found invalid Unicode character escape code"
            mapM_ (const skip) [1 .. n]
            pure (chr value : str)
      blanks str leadingBlanks whitespaces leadingBreak trailing = do
        c <- peek
        if isBlank c || isBreak c
          then
            if isBlank c
              then
                if not leadingBlanks
                  then skip >> cache 1 >> blanks str leadingBlanks (c : whitespaces) leadingBreak trailing
                  else skip >> cache 1 >> blanks str leadingBlanks whitespaces leadingBreak trailing
              else do
                cache 2
                if not leadingBlanks
                  then do
                    lb <- readLine
                    cache 1
                    blanks str True [] lb trailing
                  else do
                    lb <- readLine
                    cache 1
                    blanks str leadingBlanks whitespaces leadingBreak (trailing ++ lb)
          else pure (fold str leadingBlanks whitespaces leadingBreak trailing, ())
  str <- outer []
  skip
  end <- gets sMark
  pure (Token (TScalar (T.pack (reverse str)) (if single then SingleQ else DoubleQ)) start end)

-- | How libyaml joins the lines of a flow or plain scalar.
fold :: String -> Bool -> String -> String -> String -> String
fold str leadingBlanks whitespaces leadingBreak trailing
  | leadingBlanks =
      if take 1 leadingBreak == "\n"
        then if null trailing then ' ' : str else reverse trailing ++ str
        else reverse trailing ++ reverse leadingBreak ++ str
  | otherwise = whitespaces ++ str

-- | Reads a plain scalar.
scanPlainScalar :: M Token
scanPlainScalar = do
  start <- gets sMark
  parentIndent <- gets sIndent
  let indent = parentIndent + 1
      ctx = Just "while scanning a plain scalar"
      outer str end leadingBlanks whitespaces leadingBreak trailing = do
        cache 4
        col <- gets (mCol . sMark)
        c0 <- peek
        c1 <- peekAt 1
        c2 <- peekAt 2
        c3 <- peekAt 3
        if (col == 0 && ((c0 == '-' && c1 == '-' && c2 == '-') || (c0 == '.' && c1 == '.' && c2 == '.')) && isBlankZ c3) || c0 == '#'
          then pure (str, end, leadingBlanks)
          else do
            (str1, end1, lb1, ws1, lbr1, tr1) <- inner str end leadingBlanks whitespaces leadingBreak trailing
            c <- peek
            if not (isBlank c || isBreak c)
              then pure (str1, end1, lb1)
              else do
                cache 1
                (lb2, ws2, lbr2, tr2) <- blanks lb1 ws1 lbr1 tr1
                flow <- gets sFlow
                col' <- gets (mCol . sMark)
                if flow == 0 && col' < indent
                  then pure (str1, end1, lb2)
                  else outer str1 end1 lb2 ws2 lbr2 tr2
      inner str end leadingBlanks whitespaces leadingBreak trailing = do
        c <- peek
        c1 <- peekAt 1
        flow <- gets sFlow
        if isBlankZ c
          then pure (str, end, leadingBlanks, whitespaces, leadingBreak, trailing)
          else do
            when (flow /= 0 && c == ':' && c1 `elem` (",?[]{}" :: String)) $
              scannerError ctx start "found unexpected ':'"
            if (c == ':' && isBlankZ c1) || (flow /= 0 && c `elem` (",[]{}" :: String))
              then pure (str, end, leadingBlanks, whitespaces, leadingBreak, trailing)
              else do
                let str'
                      | leadingBlanks || not (null whitespaces) = fold str leadingBlanks whitespaces leadingBreak trailing
                      | otherwise = str
                skip
                end' <- gets sMark
                cache 2
                inner (c : str') end' False [] [] []
      blanks leadingBlanks whitespaces leadingBreak trailing = do
        c <- peek
        if isBlank c || isBreak c
          then
            if isBlank c
              then do
                col <- gets (mCol . sMark)
                when (leadingBlanks && col < indent && c == '\t') $
                  scannerError ctx start "found a tab character that violates indentation"
                skip
                cache 1
                if not leadingBlanks
                  then blanks leadingBlanks (c : whitespaces) leadingBreak trailing
                  else blanks leadingBlanks whitespaces leadingBreak trailing
              else do
                cache 2
                lb <- readLine
                cache 1
                if not leadingBlanks
                  then blanks True [] lb trailing
                  else blanks leadingBlanks whitespaces leadingBreak (trailing ++ lb)
          else pure (leadingBlanks, whitespaces, leadingBreak, trailing)
  (str, end, leadingBlanks) <- outer [] start False [] [] []
  when leadingBlanks (setKeyAllowed True)
  pure (Token (TScalar (T.pack (reverse str)) Plain) start end)

------------------------------------------------------------------------------
-- The parser

-- | The next token, fetching more when needed.
peekToken :: M Token
peekToken = do
  avail <- gets sTokenAvailable
  unless avail fetchMoreTokens
  gets (\s -> case Seq.viewl (sTokens s) of t :< _ -> t; EmptyL -> Token TStreamEnd zeroMark zeroMark)

-- | Consumes the next token.
skipToken :: M ()
skipToken = modify' $ \s -> case Seq.viewl (sTokens s) of
  _ :< rest -> s {sTokenAvailable = False, sTokensParsed = sTokensParsed s + 1, sTokens = rest}
  EmptyL -> s

-- | Sets the parser state.
setState :: PState -> M ()
setState st = modify' (\s -> s {sState = st})

-- | Saves a parser state to return to.
pushState :: PState -> M ()
pushState st = modify' (\s -> s {sStates = st : sStates s})

-- | Returns to the last saved parser state.
popState :: M ()
popState = modify' (\s -> case sStates s of (x : xs) -> s {sState = x, sStates = xs}; [] -> s)

-- | Saves the start of a collection for error messages.
pushMark :: Mark -> M ()
pushMark m = modify' (\s -> s {sMarks = m : sMarks s})

-- | The start of the innermost collection.
popMark :: M Mark
popMark = do
  ms <- gets sMarks
  case ms of
    (m : rest) -> modify' (\s -> s {sMarks = rest}) >> pure m
    [] -> pure zeroMark

-- | A parser error without context.
parserError :: Text -> Mark -> M a
parserError problem m = throwE (YErr problem m 0 Nothing)

-- | A parser error with what was being parsed.
parserErrorCtx :: Text -> Mark -> Text -> Mark -> M a
parserErrorCtx ctx cm problem m = throwE (YErr problem m 0 (Just (ctx, cm)))

-- | An empty plain scalar event at a mark.
emptyScalar :: Mark -> M (Ev, Mark)
emptyScalar m = pure (EScalar Nothing Nothing "" Plain, m)

-- | libyaml's yaml_parser_parse: the next event and its start mark.
parseEvent :: M (Ev, Mark)
parseEvent = do
  st <- gets sState
  case st of
    PStreamStart -> parseStreamStart
    PImplicitDocStart -> parseDocumentStart True
    PDocStart -> parseDocumentStart False
    PDocContent -> parseDocumentContent
    PDocEnd -> parseDocumentEnd
    PBlockNode -> parseNode True False
    PBlockNodeOrIndentless -> parseNode True True
    PFlowNode -> parseNode False False
    PBlockSeqFirst -> parseBlockSequenceEntry True
    PBlockSeqEntry -> parseBlockSequenceEntry False
    PIndentlessEntry -> parseIndentlessSequenceEntry
    PBlockMapFirst -> parseBlockMappingKey True
    PBlockMapKey -> parseBlockMappingKey False
    PBlockMapValue -> parseBlockMappingValue
    PFlowSeqFirst -> parseFlowSequenceEntry True
    PFlowSeqEntry -> parseFlowSequenceEntry False
    PFlowSeqMapKey -> parseFlowSequenceEntryMappingKey
    PFlowSeqMapValue -> parseFlowSequenceEntryMappingValue
    PFlowSeqMapEnd -> parseFlowSequenceEntryMappingEnd
    PFlowMapFirst -> parseFlowMappingKey True
    PFlowMapKey -> parseFlowMappingKey False
    PFlowMapValue -> parseFlowMappingValue False
    PFlowMapEmptyValue -> parseFlowMappingValue True
    PEnd -> pure (EStreamEnd, zeroMark)

-- | Tests a token's type.
isTok :: (Tok -> Bool) -> Token -> Bool
isTok p = p . tokType

-- | Token type tests.
isStreamEnd, isDocStart, isDocEnd, isDirective, isBlockEntry, isBlockEnd, isKey, isValue, isFlowEntry, isFlowSeqEnd, isFlowMapEnd :: Tok -> Bool
isStreamEnd = \case TStreamEnd -> True; _ -> False
isDocStart = \case TDocStart -> True; _ -> False
isDocEnd = \case TDocEnd -> True; _ -> False
isDirective = \case TVersion _ _ -> True; TTagDir _ _ -> True; _ -> False
isBlockEntry = \case TBlockEntry -> True; _ -> False
isBlockEnd = \case TBlockEnd -> True; _ -> False
isKey = \case TKey -> True; _ -> False
isValue = \case TValue -> True; _ -> False
isFlowEntry = \case TFlowEntry -> True; _ -> False
isFlowSeqEnd = \case TFlowSeqEnd -> True; _ -> False
isFlowMapEnd = \case TFlowMapEnd -> True; _ -> False

-- | The STREAM-START event.
parseStreamStart :: M (Ev, Mark)
parseStreamStart = do
  t <- peekToken
  case tokType t of
    TStreamStart -> setState PImplicitDocStart >> skipToken >> pure (EStreamStart, tokStart t)
    _ -> parserError "did not find expected <stream-start>" (tokStart t)

-- | A DOCUMENT-START event, or STREAM-END.
parseDocumentStart :: Bool -> M (Ev, Mark)
parseDocumentStart implicit = do
  let skipEnds = do
        t <- peekToken
        if isTok isDocEnd t then skipToken >> skipEnds else pure t
  t <- if implicit then peekToken else skipEnds
  if implicit && not (isTok isDirective t || isTok isDocStart t || isTok isStreamEnd t)
    then do
      processDirectives
      pushState PDocEnd
      setState PBlockNode
      pure (EDocStart, tokStart t)
    else
      if not (isTok isStreamEnd t)
        then do
          let start = tokStart t
          processDirectives
          t' <- peekToken
          unless (isTok isDocStart t') $ parserError "did not find expected <document start>" (tokStart t')
          pushState PDocEnd
          setState PDocContent
          skipToken
          pure (EDocStart, start)
        else do
          setState PEnd
          skipToken
          pure (EStreamEnd, tokStart t)

-- | Reads directives and adds the default tag handles.
processDirectives :: M ()
processDirectives = go False
  where
    go seenVersion = do
      t <- peekToken
      case tokType t of
        TVersion major minor -> do
          when seenVersion $ parserError "found duplicate %YAML directive" (tokStart t)
          when (major /= 1 || (minor /= 1 && minor /= 2)) $
            parserError "found incompatible YAML document" (tokStart t)
          skipToken
          go True
        TTagDir handle prefix -> do
          appendTagDirective (handle, prefix) False (tokStart t)
          skipToken
          go seenVersion
        _ -> do
          appendTagDirective ("!", "!") True (tokStart t)
          appendTagDirective ("!!", "tag:yaml.org,2002:") True (tokStart t)

-- | Adds a tag handle for this document.
appendTagDirective :: (String, String) -> Bool -> Mark -> M ()
appendTagDirective (handle, prefix) allowDuplicates m = do
  dirs <- gets sTagDirs
  if any ((== handle) . fst) dirs
    then unless allowDuplicates $ parserError "found duplicate %TAG directive" m
    else modify' (\s -> s {sTagDirs = sTagDirs s ++ [(handle, prefix)]})

-- | The root node, or an empty one.
parseDocumentContent :: M (Ev, Mark)
parseDocumentContent = do
  t <- peekToken
  if isTok isDirective t || isTok isDocStart t || isTok isDocEnd t || isTok isStreamEnd t
    then popState >> emptyScalar (tokStart t)
    else parseNode True False

-- | A DOCUMENT-END event.
parseDocumentEnd :: M (Ev, Mark)
parseDocumentEnd = do
  t <- peekToken
  when (isTok isDocEnd t) skipToken
  modify' (\s -> s {sTagDirs = []})
  setState PDocStart
  pure (EDocEnd, tokStart t)

-- | A tag as libyaml hands it over: bytes read as UTF-8, cut at a NUL.
tagText :: String -> Text
tagText = T.takeWhile (/= '\0') . TE.decodeUtf8With TE.lenientDecode . BS.pack . map (fromIntegral . ord)

-- | A node with its anchor and tag.
parseNode :: Bool -> Bool -> M (Ev, Mark)
parseNode block indentless = do
  t <- peekToken
  case tokType t of
    TAlias a -> popState >> skipToken >> pure (EAlias a, tokStart t)
    _ -> do
      (anchor, tagParts, start, tagMark, tok) <- case tokType t of
        TAnchor a -> do
          skipToken
          t2 <- peekToken
          case tokType t2 of
            TTag h sfx -> do
              skipToken
              t3 <- peekToken
              pure (Just a, Just (h, sfx), tokStart t, tokStart t2, t3)
            _ -> pure (Just a, Nothing, tokStart t, zeroMark, t2)
        TTag h sfx -> do
          skipToken
          t2 <- peekToken
          case tokType t2 of
            TAnchor a -> do
              skipToken
              t3 <- peekToken
              pure (Just a, Just (h, sfx), tokStart t, tokStart t, t3)
            _ -> pure (Nothing, Just (h, sfx), tokStart t, tokStart t, t2)
        _ -> pure (Nothing, Nothing, tokStart t, zeroMark, t)
      tag <- case tagParts of
        Nothing -> pure Nothing
        Just ("", sfx) -> pure (Just (tagText sfx))
        Just (h, sfx) -> do
          dirs <- gets sTagDirs
          case lookup h dirs of
            Just prefix -> pure (Just (tagText (prefix ++ sfx)))
            Nothing -> parserErrorCtx "while parsing a node" start "found undefined tag handle" tagMark
      case tokType tok of
        TBlockEntry | indentless -> do
          setState PIndentlessEntry
          pure (ESeqStart anchor tag, start)
        TScalar v sty -> do
          popState
          skipToken
          pure (EScalar anchor tag v sty, start)
        TFlowSeqStart -> setState PFlowSeqFirst >> pure (ESeqStart anchor tag, start)
        TFlowMapStart -> setState PFlowMapFirst >> pure (EMapStart anchor tag, start)
        TBlockSeqStart | block -> setState PBlockSeqFirst >> pure (ESeqStart anchor tag, start)
        TBlockMapStart | block -> setState PBlockMapFirst >> pure (EMapStart anchor tag, start)
        _
          | isJust anchor || isJust tag -> do
              popState
              pure (EScalar anchor tag "" Plain, start)
          | otherwise ->
              parserErrorCtx
                (if block then "while parsing a block node" else "while parsing a flow node")
                start
                "did not find expected node content"
                (tokStart tok)

-- | An entry of a block sequence, or its end.
parseBlockSequenceEntry :: Bool -> M (Ev, Mark)
parseBlockSequenceEntry first = do
  when first $ do
    t0 <- peekToken
    pushMark (tokStart t0)
    skipToken
  t <- peekToken
  case tokType t of
    TBlockEntry -> do
      let m = tokEnd t
      skipToken
      t2 <- peekToken
      if not (isTok isBlockEntry t2 || isTok isBlockEnd t2)
        then pushState PBlockSeqEntry >> parseNode True False
        else setState PBlockSeqEntry >> emptyScalar m
    TBlockEnd -> do
      popState
      _ <- popMark
      skipToken
      pure (ESeqEnd, tokStart t)
    _ -> do
      m <- popMark
      parserErrorCtx "while parsing a block collection" m "did not find expected '-' indicator" (tokStart t)

-- | An entry of a sequence at its mapping's indentation.
parseIndentlessSequenceEntry :: M (Ev, Mark)
parseIndentlessSequenceEntry = do
  t <- peekToken
  case tokType t of
    TBlockEntry -> do
      let m = tokEnd t
      skipToken
      t2 <- peekToken
      if not (isTok isBlockEntry t2 || isTok isKey t2 || isTok isValue t2 || isTok isBlockEnd t2)
        then pushState PIndentlessEntry >> parseNode True False
        else setState PIndentlessEntry >> emptyScalar m
    _ -> popState >> pure (ESeqEnd, tokStart t)

-- | A key of a block mapping, or its end.
parseBlockMappingKey :: Bool -> M (Ev, Mark)
parseBlockMappingKey first = do
  when first $ do
    t0 <- peekToken
    pushMark (tokStart t0)
    skipToken
  t <- peekToken
  case tokType t of
    TKey -> do
      let m = tokEnd t
      skipToken
      t2 <- peekToken
      if not (isTok isKey t2 || isTok isValue t2 || isTok isBlockEnd t2)
        then pushState PBlockMapValue >> parseNode True True
        else setState PBlockMapValue >> emptyScalar m
    TBlockEnd -> do
      popState
      _ <- popMark
      skipToken
      pure (EMapEnd, tokStart t)
    _ -> do
      m <- popMark
      parserErrorCtx "while parsing a block mapping" m "did not find expected key" (tokStart t)

-- | A value of a block mapping.
parseBlockMappingValue :: M (Ev, Mark)
parseBlockMappingValue = do
  t <- peekToken
  case tokType t of
    TValue -> do
      let m = tokEnd t
      skipToken
      t2 <- peekToken
      if not (isTok isKey t2 || isTok isValue t2 || isTok isBlockEnd t2)
        then pushState PBlockMapKey >> parseNode True True
        else setState PBlockMapKey >> emptyScalar m
    _ -> setState PBlockMapKey >> emptyScalar (tokStart t)

-- | An entry of a flow sequence, or its end.
parseFlowSequenceEntry :: Bool -> M (Ev, Mark)
parseFlowSequenceEntry first = do
  when first $ do
    t0 <- peekToken
    pushMark (tokStart t0)
    skipToken
  t <- peekToken
  let end tk = do
        popState
        _ <- popMark
        skipToken
        pure (ESeqEnd, tokStart tk)
  if isTok isFlowSeqEnd t
    then end t
    else do
      t' <-
        if first
          then pure t
          else
            if isTok isFlowEntry t
              then skipToken >> peekToken
              else do
                m <- popMark
                parserErrorCtx "while parsing a flow sequence" m "did not find expected ',' or ']'" (tokStart t)
      case tokType t' of
        TKey -> do
          setState PFlowSeqMapKey
          skipToken
          pure (EMapStart Nothing Nothing, tokStart t')
        TFlowSeqEnd -> end t'
        _ -> pushState PFlowSeqEntry >> parseNode False False

-- | The key of a single pair inside a flow sequence.
parseFlowSequenceEntryMappingKey :: M (Ev, Mark)
parseFlowSequenceEntryMappingKey = do
  t <- peekToken
  if not (isTok isValue t || isTok isFlowEntry t || isTok isFlowSeqEnd t)
    then pushState PFlowSeqMapValue >> parseNode False False
    else do
      let m = tokEnd t
      skipToken
      setState PFlowSeqMapValue
      emptyScalar m

-- | The value of a single pair inside a flow sequence.
parseFlowSequenceEntryMappingValue :: M (Ev, Mark)
parseFlowSequenceEntryMappingValue = do
  t <- peekToken
  t' <-
    if isTok isValue t
      then skipToken >> peekToken
      else pure t
  if isTok isValue t && not (isTok isFlowEntry t' || isTok isFlowSeqEnd t')
    then pushState PFlowSeqMapEnd >> parseNode False False
    else setState PFlowSeqMapEnd >> emptyScalar (tokStart t')

-- | The end of a single pair inside a flow sequence.
parseFlowSequenceEntryMappingEnd :: M (Ev, Mark)
parseFlowSequenceEntryMappingEnd = do
  t <- peekToken
  setState PFlowSeqEntry
  pure (EMapEnd, tokStart t)

-- | A key of a flow mapping, or its end.
parseFlowMappingKey :: Bool -> M (Ev, Mark)
parseFlowMappingKey first = do
  when first $ do
    t0 <- peekToken
    pushMark (tokStart t0)
    skipToken
  t <- peekToken
  let end tk = do
        popState
        _ <- popMark
        skipToken
        pure (EMapEnd, tokStart tk)
  if isTok isFlowMapEnd t
    then end t
    else do
      t' <-
        if first
          then pure t
          else
            if isTok isFlowEntry t
              then skipToken >> peekToken
              else do
                m <- popMark
                parserErrorCtx "while parsing a flow mapping" m "did not find expected ',' or '}'" (tokStart t)
      case tokType t' of
        TKey -> do
          skipToken
          t2 <- peekToken
          if not (isTok isValue t2 || isTok isFlowEntry t2 || isTok isFlowMapEnd t2)
            then pushState PFlowMapValue >> parseNode False False
            else setState PFlowMapValue >> emptyScalar (tokStart t2)
        TFlowMapEnd -> end t'
        _ -> pushState PFlowMapEmptyValue >> parseNode False False

-- | A value of a flow mapping.
parseFlowMappingValue :: Bool -> M (Ev, Mark)
parseFlowMappingValue empty = do
  t <- peekToken
  if empty
    then setState PFlowMapKey >> emptyScalar (tokStart t)
    else do
      t' <-
        if isTok isValue t
          then skipToken >> peekToken
          else pure t
      if isTok isValue t && not (isTok isFlowEntry t' || isTok isFlowMapEnd t')
        then pushState PFlowMapKey >> parseNode False False
        else setState PFlowMapKey >> emptyScalar (tokStart t')

------------------------------------------------------------------------------
-- serde_yaml's loader: one document's events with its anchors resolved

-- | An event as serde_yaml's loader keeps it.
data DEv
  = DAlias Int
  | DScalar (Maybe Text) Text Style
  | DSeqStart (Maybe Text)
  | DSeqEnd
  | DMapStart (Maybe Text)
  | DMapEnd
  | DVoid

-- | One document's events, aliases and any error that ended it.
data Doc = Doc
  { docEvents :: Seq (DEv, Mark)
  , docError :: Maybe SErr
  , docAliases :: Map.Map Int Int
  }

-- | Where serde_yaml's loader stands in the stream.
data Loader = LoaderLive S Int | LoaderFailed YErr | LoaderDone

-- | The reading state at the start of the input.
initialState :: Text -> S
initialState input =
  S
    { sInput = chars
    , sMark = zeroMark
    , sConsumed = 0
    , sDecoded = 0
    , sChunks = mkChunks chars
    , sNul = False
    , sTokens = Seq.empty
    , sTokensParsed = 0
    , sTokenAvailable = False
    , sStreamStarted = False
    , sIndent = 0
    , sIndents = []
    , sKeyAllowed = False
    , sKeys = []
    , sFlow = 0
    , sState = PStreamStart
    , sStates = []
    , sMarks = []
    , sTagDirs = []
    }
  where
    chars = T.unpack input

-- | serde_yaml's Loader::next_document.
nextDocument :: Loader -> Maybe (Doc, Loader)
nextDocument = \case
  LoaderDone -> Nothing
  LoaderFailed e -> Just (Doc Seq.empty (Just (LibErr e)) Map.empty, LoaderFailed e)
  LoaderLive s0 count -> go s0 count Map.empty Seq.empty Map.empty
  where
    go s count anchors evs aliases = case runM parseEvent s of
      (Left e, _) -> Just (Doc evs (Just (LibErr e)) aliases, LoaderFailed e)
      (Right (ev, mark), s') ->
        let continue = go s' count anchors evs aliases
            push d = go s' count anchors (evs |> (d, mark)) aliases
            anchored anchor d = case anchor of
              Nothing -> push d
              Just name ->
                let ident = Map.size anchors
                 in go s' count (Map.insert name ident anchors) (evs |> (d, mark)) (Map.insert ident (Seq.length evs) aliases)
         in case ev of
              EStreamStart -> continue
              EStreamEnd
                | count == 0 ->
                    Just (Doc (if Seq.null evs then Seq.singleton (DVoid, mark) else evs) Nothing aliases, LoaderDone)
                | otherwise -> Nothing
              EDocStart -> continue
              EDocEnd -> Just (Doc evs Nothing aliases, LoaderLive s' (count + 1))
              EAlias name -> case Map.lookup name anchors of
                Just ident -> push (DAlias ident)
                Nothing -> Just (Doc evs (Just (UnknownAnchor mark)) aliases, LoaderLive s' (count + 1))
              EScalar anchor tag v sty -> anchored anchor (DScalar tag v sty)
              ESeqStart anchor tag -> anchored anchor (DSeqStart tag)
              ESeqEnd -> push DSeqEnd
              EMapStart anchor tag -> anchored anchor (DMapStart tag)
              EMapEnd -> push DMapEnd

------------------------------------------------------------------------------
-- serde_yaml's errors

-- | serde_yaml's errors.
data SErr
  = LibErr YErr
  | Msg Text (Maybe (Mark, Text))
  | EndOfStream
  | MoreThanOneDocument
  | RecursionLimit Mark
  | RepetitionLimit
  | UnknownAnchor Mark

-- | " at line L column C" for a mark past the start.
markSuffix :: Mark -> Text
markSuffix m = if nonZero m then " at " <> showMark m else ""

-- | serde_yaml's error Display.
showSErr :: SErr -> Text
showSErr = \case
  LibErr e -> showYErr e
  Msg m Nothing -> m
  Msg m (Just (mark, path)) -> (if path /= "." then path <> ": " else "") <> m <> markSuffix mark
  EndOfStream -> "EOF while parsing a value"
  MoreThanOneDocument -> "deserializing from YAML containing more than one document is not supported"
  RecursionLimit m -> "recursion limit exceeded" <> markSuffix m
  RepetitionLimit -> "repetition limit exceeded"
  UnknownAnchor m -> "unknown anchor" <> markSuffix m

------------------------------------------------------------------------------
-- serde_yaml's deserializer into a serde_json value

-- | serde_yaml's path to the value being read.
data Path = Root | PSeq Path Int | PMap Path Text | PAlias Path | PUnknown Path

-- | serde_yaml's path to the value an error is about.
showPath :: Path -> Text
showPath = \case
  Root -> "."
  PSeq p i -> showPath p <> "[" <> tshow i <> "]"
  PMap p k -> parent p <> k
  PAlias p -> showPath p
  PUnknown p -> parent p <> "?"
  where
    parent Root = ""
    parent p = showPath p <> "."

-- | Failure and a count of alias jumps.
newtype De a = De {runDe :: Int -> Either SErr (a, Int)}

instance Functor De where
  fmap f (De g) = De (fmap (\(a, n) -> (f a, n)) . g)

instance Applicative De where
  pure a = De (\n -> Right (a, n))
  (<*>) = ap

instance Monad De where
  De g >>= k = De $ \n -> case g n of
    Left e -> Left e
    Right (a, n') -> runDe (k a) n'

-- | Fails with a serde_yaml error.
failD :: SErr -> De a
failD e = De (const (Left e))

-- | Lifts a result into the deserializer.
liftD :: Either SErr a -> De a
liftD = either failD pure

-- | serde_yaml's fix_mark: a plain message learns where it happened.
fixMark :: Mark -> Path -> De a -> De a
fixMark mark path (De g) = De $ \n -> case g n of
  Left (Msg m Nothing) -> Left (Msg m (Just (mark, showPath path)))
  other -> other

-- | The event at a position, or the parse error that ended the document.
eventAt :: Doc -> Int -> Either SErr (DEv, Mark)
eventAt doc pos = case Seq.lookup pos (docEvents doc) of
  Just x -> Right x
  Nothing -> Left (fromMaybe EndOfStream (docError doc))

-- | Follows an alias, counting jumps against the repetition limit.
jump :: Doc -> Int -> De Int
jump doc ident = De $ \n ->
  if n + 1 > Seq.length (docEvents doc) * 100
    then Left RepetitionLimit
    else Right (fromMaybe 0 (Map.lookup ident (docAliases doc)), n + 1)

-- | A tag that serde_yaml reads as an enum variant.
enumTag :: Maybe Text -> Bool
enumTag = maybe False (T.isPrefixOf "!")

-- | What serde_json says when given an enum.
enumError :: De a
enumError = failD (Msg "invalid type: enum, expected any valid JSON value" Nothing)

-- | serde_yaml's deserialize_any for a serde_json value.
deAny :: Doc -> Path -> Int -> Int -> De (Value, Int)
deAny doc path depth pos = do
  (ev, mark) <- liftD (eventAt doc pos)
  let next = pos + 1
  fixMark mark path $ case ev of
    DAlias ident -> do
      target <- jump doc ident
      (v, _) <- deAny doc (PAlias path) depth target
      pure (v, next)
    DScalar tag v sty
      | enumTag tag -> enumError
      | otherwise -> (\x -> (x, next)) <$> liftD (visitScalar tag v sty)
    DSeqStart tag
      | enumTag tag -> enumError
      | otherwise -> visitSequence doc path depth mark next
    DMapStart tag
      | enumTag tag -> enumError
      | otherwise -> visitMapping doc path depth mark next
    DVoid -> pure (Null, next)
    DSeqEnd -> failD (Msg "unexpected end of sequence" Nothing)
    DMapEnd -> failD (Msg "unexpected end of mapping" Nothing)

-- | An event that ends a collection.
isEnd :: DEv -> Bool
isEnd = \case DSeqEnd -> True; DMapEnd -> True; DVoid -> True; _ -> False

-- | A sequence into a JSON array.
visitSequence :: Doc -> Path -> Int -> Mark -> Int -> De (Value, Int)
visitSequence doc path depth mark pos0 = do
  when (depth == 0) $ failD (RecursionLimit mark)
  let go i pos acc = do
        (ev, _) <- liftD (eventAt doc pos)
        if isEnd ev
          then pure (reverse acc, pos)
          else do
            (v, pos') <- deAny doc (PSeq path i) (depth - 1) pos
            go (i + 1) pos' (v : acc)
  (items, pos) <- go (0 :: Int) pos0 []
  _ <- liftD (eventAt doc pos)
  pure (Array items, pos + 1)

-- | A mapping into a JSON object; a repeated key keeps its first place.
visitMapping :: Doc -> Path -> Int -> Mark -> Int -> De (Value, Int)
visitMapping doc path depth mark pos0 = do
  when (depth == 0) $ failD (RecursionLimit mark)
  let go expected i pos acc = do
        (ev, _) <- liftD (eventAt doc pos)
        if isEnd ev
          then pure (acc, pos)
          else do
            let valuePath = case ev of
                  DScalar _ k _ -> PMap path k
                  _ -> PUnknown path
            (k, pos') <- deStr doc path expected pos
            (v, pos'') <- deAny doc valuePath (depth - 1) pos'
            let acc' = case Map.lookup k acc of
                  Just (j, _) -> Map.insert k (j, v) acc
                  Nothing -> Map.insert k (i, v) acc
            go "a string" (i + 1) pos'' acc'
  (entries, pos) <- go "a string key" (0 :: Int) pos0 Map.empty
  _ <- liftD (eventAt doc pos)
  pure (Object [(k, v) | (k, (_, v)) <- sortOn (fst . snd) (Map.toList entries)], pos + 1)

-- | serde_yaml's deserialize_str, used for mapping keys.
deStr :: Doc -> Path -> Text -> Int -> De (Text, Int)
deStr doc path expected pos = do
  (ev, mark) <- liftD (eventAt doc pos)
  let next = pos + 1
  fixMark mark path $ case ev of
    DScalar _ v _ -> pure (v, next)
    DAlias ident -> do
      target <- jump doc ident
      (v, _) <- deStr doc (PAlias path) expected target
      pure (v, next)
    DSeqStart _ -> failD (Msg ("invalid type: sequence, expected " <> expected) Nothing)
    DMapStart _ -> failD (Msg ("invalid type: map, expected " <> expected) Nothing)
    DVoid -> failD EndOfStream
    DSeqEnd -> failD (Msg "unexpected end of sequence" Nothing)
    DMapEnd -> failD (Msg "unexpected end of mapping" Nothing)

------------------------------------------------------------------------------
-- serde_yaml's scalar resolution

-- | What serde_yaml sees in an untagged plain scalar.
data Kind
  = KNull
  | KBool Bool
  | KInt Integer
  | KWideInt
  | KFloat Double
  | KStr

-- | serde_yaml's visit_untagged_scalar, as a kind of value.
classify :: Text -> Kind
classify t
  | T.null t || parseNull s = KNull
  | Just b <- parseBool s = KBool b
  | Just k <- visitInt s = k
  | not (digitsButNotNumber s), Just f <- parseF64 s = KFloat f
  | otherwise = KStr
  where
    s = T.unpack t

-- | serde_yaml's parse_null.
parseNull :: String -> Bool
parseNull s = s `elem` ["null", "Null", "NULL", "~"]

-- | serde_yaml's parse_bool.
parseBool :: String -> Maybe Bool
parseBool s
  | s `elem` ["true", "True", "TRUE"] = Just True
  | s `elem` ["false", "False", "FALSE"] = Just False
  | otherwise = Nothing

-- | serde_yaml's visit_int: 64-bit integers, then the 128-bit ones serde_json refuses.
visitInt :: String -> Maybe Kind
visitInt s
  | Just n <- parseUnsignedInt u64 s = Just (KInt n)
  | Just n <- parseNegativeInt i64 s = Just (KInt n)
  | Just _ <- parseUnsignedInt u128 s = Just KWideInt
  | Just _ <- parseNegativeInt i128 s = Just KWideInt
  | otherwise = Nothing
  where
    u64 = (False, 0, 2 ^ (64 :: Int) - 1)
    i64 = (True, negate (2 ^ (63 :: Int)), 2 ^ (63 :: Int) - 1)
    u128 = (False, 0, 2 ^ (128 :: Int) - 1)
    i128 = (True, negate (2 ^ (127 :: Int)), 2 ^ (127 :: Int) - 1)

type IntType = (Bool, Integer, Integer)

-- | Rust's from_str_radix for an integer type.
fromStrRadix :: IntType -> String -> Int -> Maybe Integer
fromStrRadix (signed, lo, hi) src radix = do
  (positive, digits) <- case src of
    [c] | c == '+' || c == '-' -> Nothing
    ('+' : rest) -> Just (True, rest)
    ('-' : rest) | signed -> Just (False, rest)
    _ -> Just (True, src)
  if null digits || not (all validDigit digits)
    then Nothing
    else do
      let magnitude = foldl (\a d -> a * toInteger radix + toInteger (digitToInt d)) 0 digits
          value = if positive then magnitude else negate magnitude
      if value < lo || value > hi then Nothing else Just value
  where
    validDigit c = isHexDigit c && digitToInt c < radix && (radix > 10 || isDigit c)

-- | Whether text starts with + or -.
startsWithSign :: String -> Bool
startsWithSign = \case
  (c : _) -> c == '+' || c == '-'
  [] -> False

-- | serde_yaml's parse_unsigned_int.
parseUnsignedInt :: IntType -> String -> Maybe Integer
parseUnsignedInt ty scalar =
  prefixed "0x" 16 $ prefixed "0o" 8 $ prefixed "0b" 2 $
    if startsWithSign unpositive || digitsButNotNumber scalar
      then Nothing
      else fromStrRadix ty unpositive 10
  where
    unpositive = case scalar of ('+' : rest) -> rest; _ -> scalar
    prefixed p radix rest = case stripPrefixS p unpositive of
      Just digits
        | startsWithSign digits -> Nothing
        | Just n <- fromStrRadix ty digits radix -> Just n
      _ -> rest

-- | serde_yaml's parse_negative_int.
parseNegativeInt :: IntType -> String -> Maybe Integer
parseNegativeInt ty scalar =
  prefixed "-0x" 16 $ prefixed "-0o" 8 $ prefixed "-0b" 2 $
    if digitsButNotNumber scalar then Nothing else fromStrRadix ty scalar 10
  where
    prefixed p radix rest = case stripPrefixS p scalar of
      Just digits | Just n <- fromStrRadix ty ('-' : digits) radix -> Just n
      _ -> rest

-- | Drops a prefix when it is there.
stripPrefixS :: String -> String -> Maybe String
stripPrefixS p s = if take (length p) s == p then Just (drop (length p) s) else Nothing

-- | Leading zeros before more digits: a string in YAML 1.2.
digitsButNotNumber :: String -> Bool
digitsButNotNumber scalar = case t of
  ('0' : rest@(_ : _)) -> all isDigit rest
  _ -> False
  where
    t = case scalar of
      (c : rest) | c == '+' || c == '-' -> rest
      _ -> scalar

-- | serde_yaml's parse_f64.
parseF64 :: String -> Maybe Double
parseF64 scalar = do
  unpositive <- case scalar of
    ('+' : rest) -> if startsWithSign rest then Nothing else Just rest
    _ -> Just scalar
  if
    | unpositive `elem` [".inf", ".Inf", ".INF"] -> Just (1 / 0)
    | scalar `elem` ["-.inf", "-.Inf", "-.INF"] -> Just (-1 / 0)
    | scalar `elem` [".nan", ".NaN", ".NAN"] -> Just (0 / 0)
    | otherwise -> rustParseF64 unpositive

-- | Rust's f64 parsing, keeping only finite results.
rustParseF64 :: String -> Maybe Double
rustParseF64 src = do
  let (negative, body) = case src of
        ('-' : rest) -> (True, rest)
        ('+' : rest) -> (False, rest)
        _ -> (False, src)
      (intPart, afterInt) = span isDigit body
  (fracPart, afterFrac) <- case afterInt of
    ('.' : rest) -> Just (span isDigit rest)
    _ -> Just ("", afterInt)
  if null intPart && null fracPart
    then Nothing
    else do
      expo <- case afterFrac of
        [] -> Just 0
        (e : rest) | e == 'e' || e == 'E' -> case rest of
          ('+' : ds) | not (null ds) && all isDigit ds -> Just (read ds :: Integer)
          ('-' : ds) | not (null ds) && all isDigit ds -> Just (negate (read ds))
          ds | not (null ds) && all isDigit ds -> Just (read ds)
          _ -> Nothing
        _ -> Nothing
      let digits = dropWhile (== '0') (intPart ++ fracPart)
          mantissa = if null digits then 0 else read digits :: Integer
          e10 = expo - toInteger (length fracPart)
          magnitude = toInteger (length digits) + e10
          value
            | mantissa == 0 = 0
            | magnitude > 400 = 1 / 0
            | magnitude < -400 = 0
            | e10 >= 0 = fromInteger (mantissa * 10 ^ e10)
            | otherwise = fromRational (mantissa % (10 ^ negate e10))
          signed = if negative then negate value else value
      if isInfinite signed then Nothing else Just signed

-- | serde_yaml's visit_scalar into a serde_json value.
visitScalar :: Maybe Text -> Text -> Style -> Either SErr Value
visitScalar tag v sty = case tag of
  Just t
    | t == "tag:yaml.org,2002:bool" -> maybe (invalid "a boolean") (Right . Bool) (parseBool s)
    | t == "tag:yaml.org,2002:int" -> case visitInt s of
        Just k -> fromKind k
        Nothing -> invalid "an integer"
    | t == "tag:yaml.org,2002:float" -> maybe (invalid "a float") (Right . floatValue) (parseF64 s)
    | t == "tag:yaml.org,2002:null" -> if parseNull s then Right Null else invalid "null"
    | otherwise -> Right (String v)
  Nothing
    | sty == Plain -> fromKind (classify v)
    | otherwise -> Right (String v)
  where
    s = T.unpack v
    invalid what = Left (Msg ("invalid value: string " <> rustDebug v <> ", expected " <> what) Nothing)
    fromKind = \case
      KNull -> Right Null
      KBool b -> Right (Bool b)
      KInt n -> Right (Number (I n))
      KWideInt -> Left (Msg "JSON number out of range" Nothing)
      KFloat f -> Right (floatValue f)
      KStr -> Right (String v)

-- | serde_json's value for a double: null when not finite.
floatValue :: Double -> Value
floatValue f = if isNaN f || isInfinite f then Null else Number (D f)

-- | A string as Rust's Debug formatting writes it.
rustDebug :: Text -> Text
rustDebug t = "\"" <> T.concatMap esc t <> "\""
  where
    esc c = case c of
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      '\r' -> "\\r"
      '\t' -> "\\t"
      '\0' -> "\\0"
      _
        | needsEscape c -> T.pack ("\\u{" ++ showHex (ord c) "}")
        | otherwise -> T.singleton c
    needsEscape c = case generalCategory c of
      Control -> True
      Format -> True
      Surrogate -> True
      PrivateUse -> True
      NotAssigned -> True
      LineSeparator -> True
      ParagraphSeparator -> True
      Space -> c /= ' '
      NonSpacingMark -> True
      EnclosingMark -> True
      _ -> False

------------------------------------------------------------------------------
-- Decoding

-- | YAML text to a JSON value as @serde_yaml::from_str::<serde_json::Value>@
-- gives it, with serde_yaml's error message on failure.
decodeYaml :: Text -> Either Text Value
decodeYaml input = either (Left . showSErr) Right $
  case nextDocument (LoaderLive (initialState input) 0) of
    Nothing -> Left EndOfStream
    Just (doc, loader) -> do
      ((v, _), _) <- runDe (deAny doc Root 128 0) 0
      maybe (Right ()) Left (docError doc)
      case nextDocument loader of
        Nothing -> Right v
        Just _ -> Left MoreThanOneDocument

------------------------------------------------------------------------------
-- The emitter

-- | The scalar style serde_yaml asks libyaml for.
data Want = WAny | WPlain | WSingle | WLiteral
  deriving (Eq)

-- | What libyaml's analysis allows for a scalar.
data Analysis = Analysis
  { anMultiline :: Bool
  , anFlowPlain :: Bool
  , anBlockPlain :: Bool
  , anSingle :: Bool
  , anBlock :: Bool
  }

-- | libyaml's IS_PRINTABLE.
isPrintable :: Char -> Bool
isPrintable c =
  n == 0x0A || (n >= 0x20 && n <= 0x7E) || (n >= 0xA0 && n <= 0xD7FF)
    || (n >= 0xE000 && n <= 0xFFFD && n /= 0xFEFF)
    || (n >= 0x10000 && n <= 0x10FFFF)
  where
    n = ord c

-- | libyaml's yaml_emitter_analyze_scalar.
analyzeScalar :: String -> Analysis
analyzeScalar [] = Analysis False False True True False
analyzeScalar cs =
  Analysis
    { anMultiline = lineBreaks
    , anFlowPlain = not (edges || breakSpace || spaceBreak || special || lineBreaks || flowInd)
    , anBlockPlain = not (edges || breakSpace || spaceBreak || special || lineBreaks || blockInd)
    , anSingle = not (breakSpace || spaceBreak || special)
    , anBlock = not (trailingSpace || spaceBreak || special)
    }
  where
    indexed = zip3 [0 :: Int ..] cs (map Just (drop 1 cs) ++ [Nothing])
    precededList = True : map isBlankZ cs
    docStart = take 3 cs == "---" || take 3 cs == "..."
    followed = maybe True isBlankZ
    indicators =
      [ (fi, bi)
      | ((i, c, nxt), preceded) <- zip indexed precededList
      , let fw = followed nxt
            (fi, bi)
              | i == 0 =
                  ( c `elem` ("#,[]{}&*!|>'\"%@`?:" :: String) || (c == '-' && fw)
                  , c `elem` ("#,[]{}&*!|>'\"%@`" :: String) || ((c == '?' || c == ':') && fw) || (c == '-' && fw)
                  )
              | otherwise =
                  ( c `elem` (",?[]{}:" :: String) || (c == '#' && preceded)
                  , (c == ':' && fw) || (c == '#' && preceded)
                  )
      ]
    flowInd = docStart || any fst indicators
    blockInd = docStart || any snd indicators
    special = any (not . isPrintable) cs
    lineBreaks = any isBreak cs
    leadingSpace = take 1 cs == " "
    leadingBreak = any isBreak (take 1 cs)
    trailingSpace = take 1 (reverse cs) == " "
    trailingBreak = any isBreak (take 1 (reverse cs))
    edges = leadingSpace || leadingBreak || trailingSpace || trailingBreak
    pairs = zip cs (drop 1 cs)
    breakSpace = any (\(a, b) -> isBreak a && b == ' ') pairs
    spaceBreak = any (\(a, b) -> a == ' ' && isBreak b) pairs

-- | The emitter state.
data Em = Em
  { emOut :: [Text]
  , emCol :: !Int
  , emWs :: !Bool
  , emIndention :: !Bool
  , emIndent :: !Int
  , emIndents :: [Int]
  , emFlow :: !Int
  }

-- | The emitter's state monad.
newtype E a = E {runE :: Em -> (a, Em)}

instance Functor E where
  fmap f (E g) = E (\s -> let (a, s') = g s in (f a, s'))

instance Applicative E where
  pure a = E (\s -> (a, s))
  (<*>) = ap

instance Monad E where
  E g >>= k = E (\s -> let (a, s') = g s in runE (k a) s')

-- | Reads the emitter state.
getE :: E Em
getE = E (\s -> (s, s))

-- | Changes the emitter state.
modifyE :: (Em -> Em) -> E ()
modifyE f = E (\s -> let s' = f s in s' `seq` ((), s'))

-- | Writes text that holds no line break, one column per character.
put :: Text -> E ()
put t = modifyE (\s -> s {emOut = t : emOut s, emCol = emCol s + T.length t})

-- | Writes a line break.
putBreak :: E ()
putBreak = modifyE (\s -> s {emOut = "\n" : emOut s, emCol = 0})

-- | libyaml's WRITE_BREAK.
writeBreak :: Char -> E ()
writeBreak c
  | c == '\n' = putBreak
  | otherwise = modifyE (\s -> s {emOut = T.singleton c : emOut s, emCol = 0})

-- | libyaml's yaml_emitter_write_indent.
writeIndent :: E ()
writeIndent = do
  s <- getE
  let indent = max 0 (emIndent s)
  when (not (emIndention s) || emCol s > indent || (emCol s == indent && not (emWs s))) putBreak
  col <- emCol <$> getE
  when (col < indent) $ put (T.replicate (indent - col) " ")
  modifyE (\st -> st {emWs = True, emIndention = True})

-- | libyaml's yaml_emitter_write_indicator.
writeIndicator :: Text -> Bool -> Bool -> Bool -> E ()
writeIndicator t needWs isWs isIndention = do
  s <- getE
  when (needWs && not (emWs s)) (put " ")
  put t
  modifyE (\st -> st {emWs = isWs, emIndention = emIndention st && isIndention})

-- | libyaml's yaml_emitter_increase_indent.
increaseIndent :: Bool -> Bool -> E ()
increaseIndent flow indentless = modifyE $ \s ->
  let i = emIndent s
      i'
        | i < 0 = if flow then 2 else 0
        | not indentless = i + 2
        | otherwise = i
   in s {emIndents = i : emIndents s, emIndent = i'}

-- | Restores the previous indentation.
popIndent :: E ()
popIndent = modifyE (\s -> case emIndents s of (i : is) -> s {emIndent = i, emIndents = is}; [] -> s)

-- | Sets whether the last output was whitespace and indentation.
setFlags :: Bool -> Bool -> E ()
setFlags ws ind = modifyE (\s -> s {emWs = ws, emIndention = ind})

-- | A JSON value as serde_yaml hands it to the emitter.
data Node = NScalar Text Want | NSeq [Node] | NMap [(Text, Node)]

-- | A JSON value as serde_yaml serializes it.
toNode :: Value -> Node
toNode = \case
  Null -> NScalar "null" WPlain
  Bool b -> NScalar (if b then "true" else "false") WPlain
  Number (I n) -> NScalar (tshow n) WPlain
  Number (D d)
    | isNaN d -> NScalar ".nan" WPlain
    | isInfinite d -> NScalar (if d > 0 then ".inf" else "-.inf") WPlain
    | otherwise -> NScalar (formatRyu d) WPlain
  String s -> NScalar s (stringWant s)
  Array items -> NSeq (map toNode items)
  Object pairs -> NMap [(k, toNode v) | (k, v) <- pairs]

-- | A finite double as the ryu crate writes it, which is how serde_yaml
-- writes floats; serde_json now writes exponents differently.
formatRyu :: Double -> Text
formatRyu d
  | d == 0 = if isNegativeZero d then "-0.0" else "0.0"
  | d < 0 = "-" <> formatRyu (negate d)
  | otherwise = T.pack layout
  where
    (mantissa, k) = shortestDigits d
    ds = show mantissa
    len = length ds
    kk = len + k
    layout
      | k >= 0 && kk <= 16 = ds ++ replicate k '0' ++ ".0"
      | kk > 0 && kk <= 16 = take kk ds ++ "." ++ drop kk ds
      | kk > -5 && kk <= 0 = "0." ++ replicate (negate kk) '0' ++ ds
      | otherwise = case ds of
          [c] -> c : 'e' : show (kk - 1)
          (c : rest) -> c : '.' : rest ++ "e" ++ show (kk - 1)
          [] -> "0.0"

-- | The shortest decimal digits that read back as a positive double, and
-- the power of ten of the last digit, chosen as ryu chooses them: the
-- rounding interval includes its ends when the mantissa is even, and among
-- the shortest candidates the one nearest the exact value wins.
shortestDigits :: Double -> (Integer, Int)
shortestDigits v = search (estimate + 2)
  where
    bits = castDoubleToWord64 v
    biased = fromIntegral ((bits `shiftR` 52) .&. 0x7FF) :: Int
    fraction = toInteger (bits .&. 0xFFFFFFFFFFFFF)
    (m, e)
      | biased == 0 = (fraction, -1074)
      | otherwise = (fraction + 2 ^ (52 :: Int), biased - 1075)
    exact = toRational v
    pow2 :: Int -> Rational
    pow2 n = if n >= 0 then fromInteger (2 ^ n) else 1 % (2 ^ negate n)
    pow10 :: Int -> Rational
    pow10 n = if n >= 0 then fromInteger (10 ^ n) else 1 % (10 ^ negate n)
    upperGap = pow2 (e - 1)
    lowerGap = if fraction == 0 && biased > 1 then pow2 (e - 2) else upperGap
    lo = exact - lowerGap
    hi = exact + upperGap
    inclusive = even m
    inRange x = if inclusive then lo <= x && x <= hi else lo < x && x < hi
    estimate = floor (fromIntegral e * logBase 10 2 + logBase 10 (fromInteger m) :: Double) :: Int
    search k =
      let unit = pow10 k
          below = floor (exact / unit) :: Integer
          candidates = [c | c <- [below, below + 1], c > 0, inRange (fromInteger c * unit)]
       in case candidates of
            [] -> search (k - 1)
            [c] -> (c, k)
            (a : b : _) ->
              let da = abs (exact - fromInteger a * unit)
                  db = abs (fromInteger b * unit - exact)
               in if da < db || (da == db && even a) then (a, k) else (b, k)

-- | serde_yaml's serialize_str: quote what would read back as another type.
stringWant :: Text -> Want
stringWant s
  | T.any (== '\n') s = WLiteral
  | otherwise = case classify s of
      KStr -> if digitsButNotNumber (T.unpack s) then WSingle else WAny
      _ -> WSingle

-- | Whether a node is in a mapping and whether it is a simple key.
data Ctx = Ctx {cMapping :: Bool, cSimpleKey :: Bool}

-- | libyaml's yaml_emitter_emit_node for a whole node.
emitNode :: Ctx -> Node -> E ()
emitNode ctx = \case
  NScalar t want -> emitScalar ctx t want
  NSeq [] -> emitEmpty "[" "]"
  NMap [] -> emitEmpty "{" "}"
  NSeq items -> do
    ind <- emIndention <$> getE
    increaseIndent False (cMapping ctx && not ind)
    forM_ items $ \item -> do
      writeIndent
      writeIndicator "-" True False True
      emitNode (Ctx False False) item
    popIndent
  NMap pairs -> do
    increaseIndent False False
    forM_ pairs $ \(k, v) -> do
      writeIndent
      let an = analyzeScalar (T.unpack k)
          keyNode = NScalar k (stringWant k)
      if not (anMultiline an) && BS.length (TE.encodeUtf8 k) <= 128
        then do
          emitNode (Ctx True True) keyNode
          writeIndicator ":" False False False
        else do
          writeIndicator "?" True False True
          emitNode (Ctx True False) keyNode
          writeIndent
          writeIndicator ":" True False True
      emitNode (Ctx True False) v
    popIndent

-- | An empty collection, written in flow style.
emitEmpty :: Text -> Text -> E ()
emitEmpty open close = do
  writeIndicator open True True False
  increaseIndent True False
  modifyE (\s -> s {emFlow = emFlow s + 1})
  modifyE (\s -> s {emFlow = emFlow s - 1})
  popIndent
  writeIndicator close False False False

-- | A scalar in the style libyaml selects for it.
emitScalar :: Ctx -> Text -> Want -> E ()
emitScalar ctx t want = do
  flow <- emFlow <$> getE
  let cs = T.unpack t
      an = analyzeScalar cs
      inFlow = flow /= 0
      style0 = if want == WLiteral then Literal else if want == WSingle then SingleQ else Plain
      style1 = if cSimpleKey ctx && anMultiline an then DoubleQ else style0
      style2
        | style1 == Plain =
            if (inFlow && not (anFlowPlain an)) || (not inFlow && not (anBlockPlain an)) || (null cs && (inFlow || cSimpleKey ctx))
              then SingleQ
              else Plain
        | otherwise = style1
      style3 = if style2 == SingleQ && not (anSingle an) then DoubleQ else style2
      style
        | style3 == Literal && (not (anBlock an) || inFlow || cSimpleKey ctx) = DoubleQ
        | otherwise = style3
  increaseIndent True False
  case style of
    Plain -> writePlain cs
    SingleQ -> writeSingle cs
    DoubleQ -> writeDouble cs
    _ -> writeLiteral cs
  popIndent

-- | libyaml's plain scalar writer.
writePlain :: String -> E ()
writePlain cs = do
  s <- getE
  when (not (emWs s) && (not (null cs) || emFlow s /= 0)) (put " ")
  let go _ [] = pure ()
      go breaks (c : rest)
        | c == ' ' = put " " >> go breaks rest
        | isBreak c = do
            when (not breaks && c == '\n') putBreak
            writeBreak c
            modifyE (\st -> st {emIndention = True})
            go True rest
        | otherwise = do
            when breaks writeIndent
            put (T.singleton c)
            modifyE (\st -> st {emIndention = False})
            go False rest
  go False cs
  setFlags False False

-- | libyaml's single quoted scalar writer.
writeSingle :: String -> E ()
writeSingle cs = do
  writeIndicator "'" True False False
  let go breaks [] = when breaks writeIndent
      go breaks (c : rest)
        | c == ' ' = put " " >> go breaks rest
        | isBreak c = do
            when (not breaks && c == '\n') putBreak
            writeBreak c
            modifyE (\st -> st {emIndention = True})
            go True rest
        | otherwise = do
            when breaks writeIndent
            when (c == '\'') (put "'")
            put (T.singleton c)
            modifyE (\st -> st {emIndention = False})
            go False rest
  go False cs
  writeIndicator "'" False False False
  setFlags False False

-- | libyaml's double quoted scalar writer.
writeDouble :: String -> E ()
writeDouble cs = do
  writeIndicator "\"" True False False
  forM_ cs $ \c ->
    if not (isPrintable c) || c == '\xFEFF' || isBreak c || c == '"' || c == '\\'
      then put (doubleEscape c)
      else put (T.singleton c)
  writeIndicator "\"" False False False
  setFlags False False

-- | A character escaped for a double quoted scalar.
doubleEscape :: Char -> Text
doubleEscape c = "\\" <> case c of
  '\0' -> "0"
  '\x07' -> "a"
  '\x08' -> "b"
  '\t' -> "t"
  '\n' -> "n"
  '\x0B' -> "v"
  '\x0C' -> "f"
  '\r' -> "r"
  '\x1B' -> "e"
  '"' -> "\""
  '\\' -> "\\"
  '\x85' -> "N"
  '\xA0' -> "_"
  '\x2028' -> "L"
  '\x2029' -> "P"
  _
    | n <= 0xFF -> "x" <> hex 2
    | n <= 0xFFFF -> "u" <> hex 4
    | otherwise -> "U" <> hex 8
  where
    n = ord c
    hex w = let h = map toUpperHex (showHex n "") in T.pack (replicate (w - length h) '0' ++ h)
    toUpperHex x = if x >= 'a' && x <= 'f' then chr (ord x - 32) else x

-- | libyaml's literal block scalar writer.
writeLiteral :: String -> E ()
writeLiteral cs = do
  writeIndicator "|" True False False
  case cs of
    (c : _) | c == ' ' || isBreak c -> writeIndicator "2" False False False
    _ -> pure ()
  let rev = reverse cs
      chomp = case rev of
        [] -> Just "-"
        (l : rest)
          | not (isBreak l) -> Just "-"
          | null rest -> Just "+"
          | any isBreak (take 1 rest) -> Just "+"
          | otherwise -> Nothing
  forM_ chomp $ \h -> writeIndicator h False False False
  putBreak
  setFlags True True
  let go _ [] = pure ()
      go breaks (c : rest)
        | isBreak c = do
            writeBreak c
            modifyE (\st -> st {emIndention = True})
            go True rest
        | otherwise = do
            when breaks writeIndent
            put (T.singleton c)
            modifyE (\st -> st {emIndention = False})
            go False rest
  go True cs

-- | A JSON value as YAML text, exactly as @serde_yaml::to_string@ writes it.
encodeYaml :: Value -> Text
encodeYaml v = T.concat (reverse (emOut final))
  where
    start = Em [] 0 True True (-1) [] 0
    ((), final) = runE (emitNode (Ctx False False) (toNode v) >> writeIndent) start
