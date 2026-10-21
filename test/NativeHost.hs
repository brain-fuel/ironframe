-- | A native host for tests: performs the core's effects with IO, as the
-- Node host does, so the CLI corpus runs through the native build too.
-- Network effects answer as if nothing listens. ref:DEC-host-protocol
module NativeHost (Captured (..), runNative) where

import Control.Exception (IOException, try)
import qualified Data.ByteString as B
import Data.IORef
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Ironframe.Api (callValue)
import Ironframe.Json
import System.Directory
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError, isPermissionError)
import System.Process

-- | What a run printed.
data Captured = Captured {capturedStdout :: Text, capturedStderr :: Text, capturedResult :: Value}

-- | Runs a method to its end with real effects, in a working directory and
-- an environment.
runNative :: Text -> Value -> FilePath -> Map Text Text -> IO Captured
runNative method params dir environment = do
  out <- newIORef []
  err <- newIORef []
  counter <- newIORef (0 :: Integer)
  let loop results = case callValue (Object ["method" .= String method, "params" .= params, "effects" .= Array results]) of
        Object pairs
          | Just e <- lookup "effect" pairs -> do
              r <- perform out err counter e
              loop (results ++ [r])
          | Just v <- lookup "done" pairs -> pure v
          | Just (String f) <- lookup "failed" pairs -> do
              modifyIORef err (("ironframe: " <> f <> "\n") :)
              pure (Object ["exitCode" .= Number (I 2)])
        other -> pure other
  previous <- getCurrentDirectory
  setCurrentDirectory dir
  result <- loop []
  setCurrentDirectory previous
  o <- readIORef out
  e <- readIORef err
  pure (Captured (T.concat (reverse o)) (T.concat (reverse e)) result)
  where
    text' k v = case keyOr k v of
      String t -> t
      _ -> ""
    ok v = pure (Object ["ok" .= v])
    failIo :: IOException -> IO Value
    failIo e = pure (Object (["error" .= String (rustMessage e)] ++ ["notFound" .= Bool True | isDoesNotExistError e]))
    attempt :: IO Value -> IO Value
    attempt action = try action >>= either failIo pure
    path e = T.unpack (text' "path" e)
    perform out err counter e = case text' "effect" e of
      "readFile" -> attempt $ do
        bytes <- B.readFile (path e)
        case TE.decodeUtf8' bytes of
          Right t -> ok (String t)
          Left _ -> pure (Object ["error" .= String "stream did not contain valid UTF-8"])
      "writeAtomically" -> attempt $ do
        existing <- try (B.readFile (path e)) :: IO (Either IOException B.ByteString)
        let new = TE.encodeUtf8 (text' "text" e)
        if either (const False) (== new) existing
          then ok (Bool False)
          else do
            createDirectoryIfMissing True (takeDirectory (path e))
            B.writeFile (path e <> ".tmp") new
            renameFile (path e <> ".tmp") (path e)
            ok (Bool True)
      "writeFile" -> attempt (B.writeFile (path e) (TE.encodeUtf8 (text' "text" e)) >> ok Null)
      "removeFile" -> attempt (removeFile (path e) >> ok Null)
      "removeTree" -> attempt (removeDirectoryRecursive (path e) >> ok Null)
      "createDir" -> attempt (createDirectoryIfMissing True (path e) >> ok Null)
      "canonicalize" -> attempt $ do
        exists <- (||) <$> doesPathExist (path e) <*> pure False
        if exists then canonicalizePath (path e) >>= ok . String . T.pack else ioError (userError "missing") >> ok Null
      "cwd" -> getCurrentDirectory >>= ok . String . T.pack
      "env" -> ok (maybe Null String (Map.lookup (text' "name" e) environment))
      "locate" -> do
        let variable = text' "variable" e
            names = [n | String n <- arrayOf (keyOr "names" e)]
            fallbacks = [n | String n <- arrayOf (keyOr "fallbacks" e)]
            dirs = maybe [] (T.splitOn ":") (Map.lookup "PATH" environment)
        case Map.lookup variable environment of
          Just v | not (T.null v) -> ok (String v)
          _ -> do
            onPath <- firstFile [d <> "/" <> n | n <- names, d <- dirs]
            case onPath of
              Just p -> ok (String p)
              Nothing -> firstFile fallbacks >>= ok . maybe Null String
      "run" -> attempt $ do
        let program = T.unpack (text' "program" e)
            args = map T.unpack [a | String a <- arrayOf (keyOr "args" e)]
            extra = case keyOr "env" e of
              Object ps -> [(T.unpack k, T.unpack v) | (k, String v) <- ps]
              _ -> []
            childEnv = Map.toList (Map.fromList ([(T.unpack k, T.unpack v) | (k, v) <- Map.toList environment] ++ extra))
            stream = keyOr "stream" e == Bool True
            process' = (proc (resolveProgram program) args) {env = Just childEnv, cwd = T.unpack <$> textAt "cwd" e}
        (code, stdout', stderr') <- readCreateProcessWithExitCode process' ""
        let success = code == ExitSuccess
            number = case code of
              ExitSuccess -> 0
              ExitFailure n -> toInteger n
        if stream
          then do
            modifyIORef out (T.pack stdout' :)
            modifyIORef err (T.pack stderr' :)
            ok (Object ["success" .= Bool success, "code" .= Number (I number), "stdout" .= String "", "stderr" .= String ""])
          else ok (Object ["success" .= Bool success, "code" .= Number (I number), "stdout" .= String (T.pack stdout'), "stderr" .= String (T.pack stderr')])
      "http" -> pure (Object ["error" .= String "Connection refused (os error 61)"])
      "tcpProbe" -> ok (Bool False)
      "sleep" -> ok Null
      "now" -> do
        t <- getPOSIXTime
        let nanos = floor (t * 1000000000) :: Integer
        ok (Object ["seconds" .= Number (I (nanos `div` 1000000000)), "nanos" .= Number (I (nanos `mod` 1000000000))])
      "monotonic" -> do
        modifyIORef counter (+ 1000)
        readIORef counter >>= ok . Number . I
      "uuid" -> do
        modifyIORef counter (+ 1)
        n <- readIORef counter
        let hex = T.justifyRight 12 '0' (T.pack (show n))
        ok (String ("00000000-0000-4000-8000-" <> hex))
      "print" -> do
        if text' "stream" e == "stdout" then modifyIORef out (text' "text" e :) else modifyIORef err (text' "text" e :)
        ok Null
      "progress" -> modifyIORef err (("ironframe: " <> text' "text" e <> "\n") :) >> ok Null
      "readStdin" -> ok (String "")
      "tempDir" -> getTemporaryDirectory >>= ok . String . T.pack
      "processId" -> ok (Number (I 4242))
      other -> pure (Object ["error" .= String ("the native test host has no " <> other)])
    resolveProgram p = p
    arrayOf = \case
      Array xs -> xs
      _ -> []
    firstFile [] = pure Nothing
    firstFile (p : ps) = do
      isFile <- doesFileExist (T.unpack p)
      if isFile then pure (Just p) else firstFile ps

-- | An IO error in the words Rust's io::Error gives it.
rustMessage :: IOException -> Text
rustMessage e
  | isDoesNotExistError e = "No such file or directory (os error 2)"
  | isPermissionError e = "Permission denied (os error 13)"
  | isAlreadyExistsError e = "File exists (os error 17)"
  | otherwise = T.pack (show e)

_unused :: FilePath
_unused = "a" </> "b"
