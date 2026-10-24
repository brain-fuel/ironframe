-- | The command's corpus through the native build: each case starts from the
-- examples it names, runs its steps with fake podman and OpenTofu scripts,
-- and must print exactly what the Rust command printed and leave the same
-- files. ref:DEC-haskell-wasm-core
module CliCorpusSpec (spec) where

import Control.Monad (forM, forM_, when)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.Text.IO as TIO
import qualified Data.ByteString as B
import qualified Data.Text.Encoding as TE
import Ironframe.Corpus (normalise)
import Ironframe.Json
import NativeHost
import System.Directory
import System.Environment (getEnvironment)
import System.FilePath ((</>), makeRelative, takeFileName)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

fakePodman, fakeTofu, brokenPodman :: Text
fakePodman = "#!/bin/sh\necho \"podman $*\" >> \"$IRONFRAME_FAKE_LOG\"\ncase \"$1 $2\" in\n  \"image inspect\") echo null ;;\n  \"ps \"*|\"ps -a\") echo \"[]\" ;;\nesac\nexit 0\n"
fakeTofu = "#!/bin/sh\necho \"tofu $*\" >> \"$IRONFRAME_FAKE_LOG\"\ncase \"$2\" in\n  output) echo '{\"adoptions-log\": \"adoptions.elb.example:9092\", \"kafka\": \"kafka.elb.example:9092\"}' ;;\nesac\nexit 0\n"
brokenPodman = "#!/bin/sh\necho \"podman $*\" >> \"$IRONFRAME_FAKE_LOG\"\nif [ \"$1\" = compose ]; then echo \"Error: looking up compose provider failed\" >&2; exit 125; fi\nexit 0\n"

copyTree :: FilePath -> FilePath -> IO ()
copyTree from to = do
  createDirectoryIfMissing True to
  names <- listDirectory from
  forM_ names $ \name -> when (take 1 name /= "." && name /= "src" && name /= "Cargo.toml" && name /= "app.mjs") $ do
    isDir <- doesDirectoryExist (from </> name)
    if isDir then copyTree (from </> name) (to </> name) else copyFile (from </> name) (to </> name)

filesUnder :: FilePath -> IO (Map FilePath B.ByteString)
filesUnder root = go root
  where
    go dir = do
      names <- listDirectory dir
      fmap Map.unions $ forM names $ \name -> do
        let path = dir </> name
        isDir <- doesDirectoryExist path
        if isDir then go path else Map.singleton (makeRelative root path) <$> B.readFile path

spec :: Spec
spec = do
  text <- runIO (TIO.readFile "corpus/cli.json")
  repo <- runIO getCurrentDirectory
  base <- runIO getEnvironment
  let cases = case decode text of
        Right (Array cs) -> cs
        _ -> []
  describe "corpus/cli.json" $ forM_ cases $ \c -> it (T.unpack (textOf "name" c)) $
    withSystemTempDirectory "ironframe-cli" $ \tmp -> do
      root <- canonicalizePath tmp
      forM_ [e | String e <- arrayOf (keyOr "examples" (keyOr "input" c))] $ \name ->
        if name == "calm-shop"
          then copyTree (repo </> "examples/calm-shop/architecture") (root </> "calm-shop/architecture")
          else copyTree (repo </> "examples" </> T.unpack name) (root </> T.unpack name)
      let tools = root </> ".tools"
      createDirectoryIfMissing True tools
      forM_ [("podman", fakePodman), ("tofu", fakeTofu), ("broken-podman", brokenPodman)] $ \(name, script) -> do
        TIO.writeFile (tools </> name) script
        p <- getPermissions (tools </> name)
        setPermissions (tools </> name) (setOwnerExecutable True p)
      initial <- filesUnder root
      let env0 =
            Map.insert "NO_COLOR" "1" $
              Map.insert "IRONFRAME_FAKE_LOG" (T.pack (tools </> "log")) $
                Map.insert "IRONFRAME_TOFU" (T.pack (tools </> "tofu")) $
                  Map.insert "IRONFRAME_PODMAN" (T.pack (tools </> "podman")) $
                    Map.insert "PATH" "/usr/bin:/bin" $
                      Map.delete "IRONFRAME_CALM" (Map.fromList [(T.pack k, T.pack v) | (k, v) <- base])
          steps = arrayOf (keyOr "steps" (keyOr "input" c))
          expectedSteps = arrayOf (keyOr "steps" (keyOr "expected" c))
      forM_ (zip steps expectedSteps) $ \(step, expected) -> do
        let extra = case keyOr "env" step of
              Object ps -> Map.fromList [(k, T.replace "$ROOT" (T.pack root) v) | (k, String v) <- ps]
              _ -> Map.empty
            env = Map.union extra env0
            argv = [a | String a <- arrayOf (keyOr "args" step)]
        captured <- runNative "cli" (Object ["argv" .= Array (map String argv), "cwd" .= String (T.pack (root </> T.unpack (textOf "cwd" step)))]) (root </> T.unpack (textOf "cwd" step)) env
        expectedOutput <- case dropWhile (/= "schema") argv of
          ["schema", "attestation"] -> TIO.readFile "schema/attestation-v1.schema.json"
          ["schema", "contract"] -> TIO.readFile "schema/calm/ironframe-contract.decorator.schema.json"
          ["schema", "binding"] -> TIO.readFile "schema/calm/ironframe-binding.decorator.schema.json"
          _ -> pure (textOf "stdout" expected)
        let norm t = normalise (T.replace (T.pack root) "/work" t)
            code = keyOr "exitCode" (capturedResult captured)
        (norm (capturedStdout captured), norm (capturedStderr captured), code)
          `shouldBe` (expectedOutput, textOf "stderr" expected, keyOr "code" expected)
      final <- filesUnder root
      let changed =
            Map.fromList
              [ (normalise (T.pack path), normalise (T.replace (T.pack root) "/work" (either (const "<binary>") id (TE.decodeUtf8' bytes))))
              | (path, bytes) <- Map.toList final
              , Map.lookup path initial /= Just bytes
              ]
          expectedFiles = case keyOr "files" (keyOr "expected" c) of
            Object ps -> Map.fromList [(k, v) | (k, String v) <- ps]
            _ -> Map.empty
      changed `shouldBe` expectedFiles
  where
    textOf k v = case keyOr k v of
      String t -> t
      _ -> ""
    arrayOf = \case
      Array xs -> xs
      _ -> []

_unused :: FilePath -> FilePath
_unused = takeFileName
