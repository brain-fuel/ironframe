-- | The effects the core asks its host for. The core is pure: a command is a
-- program that, run over the results the host has fed back so far, either
-- finishes or names the next effect it needs. The host performs that effect
-- and calls again with one more result, so the same inputs always give the
-- same requests. ref:DEC-haskell-wasm-core ref:DEC-host-protocol
module Ironframe.Effect
  ( Eff
  , Step (..)
  , runEff
  , perform
  , failWith
  , catchError
  , liftEither
  , IoError (..)
  , ioResult
    -- * Files
  , readFileE
  , writeAtomically
  , writeFileE
  , removeFileE
  , removeTree
  , createDirE
  , canonicalize
  , cwd
    -- * The environment and tools
  , getEnv
  , locate
  , ProcessOutput (..)
  , runProcess
  , runInherited
  , readStdin
  , tempDir
  , processId
    -- * Network and time
  , HttpReply (..)
  , httpRequest
  , tcpProbe
  , sleepMs
  , now
  , monotonicMs
  , newUuid
    -- * Output
  , printOut
  , printErr
  , progress
  , cloudCall
  ) where

import Ironframe.Json
import Data.Text (Text)
import qualified Data.Text as T

-- | What a program does next: finish, or wait for an effect.
data Step a = Done a | Need Value

-- | A program over the results fed back so far. It fails with a message,
-- which a command turns into its exit status.
newtype Eff a = Eff {unEff :: [Value] -> (Step (Either Text a), [Value])}

instance Functor Eff where
  fmap f (Eff g) = Eff $ \rs -> case g rs of
    (Done r, rest) -> (Done (fmap f r), rest)
    (Need q, rest) -> (Need q, rest)

instance Applicative Eff where
  pure a = Eff $ \rs -> (Done (Right a), rs)
  Eff f <*> Eff g = Eff $ \rs -> case f rs of
    (Need q, rest) -> (Need q, rest)
    (Done (Left e), rest) -> (Done (Left e), rest)
    (Done (Right h), rest) -> case g rest of
      (Need q, rest') -> (Need q, rest')
      (Done r, rest') -> (Done (fmap h r), rest')

instance Monad Eff where
  Eff g >>= k = Eff $ \rs -> case g rs of
    (Need q, rest) -> (Need q, rest)
    (Done (Left e), rest) -> (Done (Left e), rest)
    (Done (Right a), rest) -> unEff (k a) rest

-- | Runs a program over the results so far.
runEff :: Eff a -> [Value] -> Step (Either Text a)
runEff (Eff g) rs = fst (g rs)

-- | Asks the host for an effect and returns its result.
perform :: Value -> Eff Value
perform request = Eff $ \case
  (r : rest) -> (Done (Right r), rest)
  [] -> (Need request, [])

failWith :: Text -> Eff a
failWith e = Eff $ \rs -> (Done (Left e), rs)

liftEither :: Either Text a -> Eff a
liftEither = either failWith pure

-- | Runs a program, handing its failure to a handler.
catchError :: Eff a -> (Text -> Eff a) -> Eff a
catchError (Eff g) handler = Eff $ \rs -> case g rs of
  (Done (Left e), rest) -> unEff (handler e) rest
  other -> other

-- | An operating-system error as the host reports it, in the words Rust's
-- io::Error gives it, such as @No such file or directory (os error 2)@.
data IoError = IoError {ioMessage :: Text, ioNotFound :: Bool}

-- | Reads a result that is either @{"ok": ...}@ or @{"error": ...}@.
ioResult :: Value -> Either IoError Value
ioResult v = case key "error" v of
  Just (String e) -> Left (IoError e (key "notFound" v == Just (Bool True)))
  _ -> Right (keyOr "ok" v)

effect :: Text -> [(Text, Value)] -> Value
effect name fields = Object (("effect", String name) : fields)

readFileE :: Text -> Eff (Either IoError Text)
readFileE path = do
  r <- perform (effect "readFile" ["path" .= String path])
  pure $ case ioResult r of
    Left e -> Left e
    Right (String t) -> Right t
    Right _ -> Left (IoError "stream did not contain valid UTF-8" False)

-- | Writes through a temporary file beside the target, creating its directory,
-- unless the file already holds the text; returns whether it changed.
writeAtomically :: Text -> Text -> Eff (Either IoError Bool)
writeAtomically path text = do
  r <- perform (effect "writeAtomically" ["path" .= String path, "text" .= String text])
  pure $ case ioResult r of
    Left e -> Left e
    Right (Bool b) -> Right b
    Right _ -> Right True

-- | Writes a file directly, as Rust's fs::write.
writeFileE :: Text -> Text -> Eff (Either IoError ())
writeFileE path text = do
  r <- perform (effect "writeFile" ["path" .= String path, "text" .= String text])
  pure (() <$ ioResult r)

removeFileE :: Text -> Eff (Either IoError ())
removeFileE path = do
  r <- perform (effect "removeFile" ["path" .= String path])
  pure (() <$ ioResult r)

-- | Removes a directory and everything in it, as Rust's remove_dir_all.
removeTree :: Text -> Eff (Either IoError ())
removeTree path = do
  r <- perform (effect "removeTree" ["path" .= String path])
  pure (() <$ ioResult r)

createDirE :: Text -> Eff (Either IoError ())
createDirE path = do
  r <- perform (effect "createDir" ["path" .= String path])
  pure (() <$ ioResult r)

-- | The canonical absolute path, symbolic links resolved.
canonicalize :: Text -> Eff (Either IoError Text)
canonicalize path = do
  r <- perform (effect "canonicalize" ["path" .= String path])
  pure $ case ioResult r of
    Right (String t) -> Right t
    Right _ -> Left (IoError "no path" False)
    Left e -> Left e

cwd :: Eff Text
cwd = do
  r <- perform (effect "cwd" [])
  pure $ case keyOr "ok" r of
    String t -> t
    _ -> "."

getEnv :: Text -> Eff (Maybe Text)
getEnv name = do
  r <- perform (effect "env" ["name" .= String name])
  pure $ case keyOr "ok" r of
    String t -> Just t
    _ -> Nothing

-- | A tool: the path in @variable@ if set and not empty, else the first of
-- @names@ on PATH that is a file, else the first of @fallbacks@ that is one.
locate :: Text -> [Text] -> [Text] -> Eff (Maybe Text)
locate variable names fallbacks = do
  r <-
    perform
      ( effect
          "locate"
          [ "variable" .= String variable
          , "names" .= Array (map String names)
          , "fallbacks" .= Array (map String fallbacks)
          ]
      )
  pure $ case keyOr "ok" r of
    String t -> Just t
    _ -> Nothing

-- | What a finished process reported.
data ProcessOutput = ProcessOutput
  { procSuccess :: Bool
  , procCode :: Maybe Integer
  , procStdout :: Text
  , procStderr :: Text
  }

-- | Runs a program with arguments, its standard input closed. @stream@ sends
-- its output to the terminal rather than capturing it.
runProcess :: Text -> [Text] -> Bool -> Eff (Either IoError ProcessOutput)
runProcess program args stream = do
  r <-
    perform
      ( effect
          "run"
          [ "program" .= String program
          , "args" .= Array (map String args)
          , "stream" .= Bool stream
          ]
      )
  pure (processOutput <$> ioResult r)

-- | Runs a program with the terminal's standard streams, extra environment
-- and an optional working directory, as a run's command is run.
runInherited :: Text -> [Text] -> [(Text, Text)] -> Maybe Text -> Eff (Either IoError ProcessOutput)
runInherited program args env dir = do
  r <-
    perform
      ( effect
          "run"
          ( [ "program" .= String program
            , "args" .= Array (map String args)
            , "stream" .= Bool True
            , "inheritStdin" .= Bool True
            , "env" .= Object [(k, String v) | (k, v) <- env]
            ]
              ++ maybe [] (\d -> ["cwd" .= String d]) dir
          )
      )
  pure (processOutput <$> ioResult r)

processOutput :: Value -> ProcessOutput
processOutput v =
  ProcessOutput
    { procSuccess = key "success" v == Just (Bool True)
    , procCode = case key "code" v of
        Just (Number (I c)) -> Just c
        _ -> Nothing
    , procStdout = maybe "" id (textAt "stdout" v)
    , procStderr = maybe "" id (textAt "stderr" v)
    }

readStdin :: Eff (Either IoError Text)
readStdin = do
  r <- perform (effect "readStdin" [])
  pure $ case ioResult r of
    Right (String t) -> Right t
    Right _ -> Right ""
    Left e -> Left e

tempDir :: Eff Text
tempDir = do
  r <- perform (effect "tempDir" [])
  pure (maybe "/tmp" id (textAt "ok" r))

processId :: Eff Integer
processId = do
  r <- perform (effect "processId" [])
  pure $ case keyOr "ok" r of
    Number (I n) -> n
    _ -> 0

-- | An HTTP answer: its status and body.
data HttpReply = HttpReply {replyStatus :: Int, replyBody :: Text}

-- | Sends an HTTP request; fails with the root cause when nothing answers.
httpRequest :: Text -> Text -> [(Text, Text)] -> Maybe Text -> Int -> Eff (Either Text HttpReply)
httpRequest method url headers body timeoutMs = do
  r <-
    perform
      ( effect
          "http"
          ( [ "method" .= String method
            , "url" .= String url
            , "headers" .= Object [(k, String v) | (k, v) <- headers]
            , "timeoutMs" .= Number (I (toInteger timeoutMs))
            ]
              ++ maybe [] (\b -> ["body" .= String b]) body
          )
      )
  pure $ case ioResult r of
    Left e -> Left (ioMessage e)
    Right v ->
      Right
        HttpReply
          { replyStatus = case key "status" v of
              Just (Number (I s)) -> fromInteger s
              _ -> 0
          , replyBody = maybe "" id (textAt "body" v)
          }

-- | Whether a TCP connection to the host and port opens within the timeout
-- and stays open a moment, as a port forwarder's immediate close does not.
-- The endpoint it was split from rides along for a scripted host.
tcpProbe :: Text -> Text -> Int -> Int -> Eff Bool
tcpProbe endpoint host port timeoutMs = do
  r <-
    perform
      ( effect
          "tcpProbe"
          [ "endpoint" .= String endpoint
          , "host" .= String host
          , "port" .= Number (I (toInteger port))
          , "timeoutMs" .= Number (I (toInteger timeoutMs))
          ]
      )
  pure (keyOr "ok" r == Bool True)

sleepMs :: Int -> Eff ()
sleepMs ms = () <$ perform (effect "sleep" ["ms" .= Number (I (toInteger ms))])

-- | The time now, as seconds and nanoseconds since the Unix epoch, in UTC.
now :: Eff (Integer, Integer)
now = do
  r <- perform (effect "now" [])
  pure $ case keyOr "ok" r of
    Object _ ->
      let num k' = case key k' (keyOr "ok" r) of
            Just (Number (I n)) -> n
            _ -> 0
       in (num "seconds", num "nanos")
    _ -> (0, 0)

-- | A monotonic clock in milliseconds, for deadlines.
monotonicMs :: Eff Integer
monotonicMs = do
  r <- perform (effect "monotonic" [])
  pure $ case keyOr "ok" r of
    Number (I n) -> n
    _ -> 0

newUuid :: Eff Text
newUuid = do
  r <- perform (effect "uuid" [])
  pure (maybe "" id (textAt "ok" r))

printOut :: Text -> Eff ()
printOut t = () <$ perform (effect "print" ["stream" .= String "stdout", "text" .= String t])

printErr :: Text -> Eff ()
printErr t = () <$ perform (effect "print" ["stream" .= String "stderr", "text" .= String t])

-- | A step of a long command, reported as it happens.
progress :: Text -> Eff ()
progress t = () <$ perform (effect "progress" ["text" .= String t])

-- | A call into a cloud's SDK, such as @aws.findApplication@; the result, or
-- the SDK's reason.
cloudCall :: Text -> [(Text, Value)] -> Eff (Either Text Value)
cloudCall name fields = do
  r <- perform (effect name fields)
  pure $ case key "error" r of
    Just (String e) -> Left e
    Just other -> Left (T.pack (show other))
    Nothing -> Right (keyOr "ok" r)
