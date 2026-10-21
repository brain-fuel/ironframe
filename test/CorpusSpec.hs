-- | Every case of the golden corpus, except the command's, through the core
-- natively: each must reproduce the Rust output byte for byte, or be one of
-- the deliberate differences. ref:DEC-haskell-wasm-core
module CorpusSpec (spec, fixtures) where

import Control.Monad (forM_)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Ironframe.Api (dispatch, resolvedJson)
import qualified Ironframe.Corpus as Corpus
import Ironframe.Json
import System.Directory (listDirectory)
import System.FilePath ((</>))
import Test.Hspec

-- | The example files cases name rather than copy.
fixtures :: IO Value
fixtures = do
  let dir = "examples/calm-shop/architecture"
  names <- listDirectory dir
  conformance <- listDirectory (dir </> "conformance")
  let files = [n | n <- names, ".json" `T.isSuffixOf` T.pack n] ++ ["conformance" </> n | n <- conformance]
  pairs <- mapM (\f -> (,) (T.pack (dir </> f)) . String <$> TIO.readFile (dir </> f)) files
  pure (Object pairs)

spec :: Spec
spec = do
  files <- runIO (filter (\f -> ".json" `T.isSuffixOf` T.pack f && f /= "cli.json") <$> listDirectory "corpus")
  given <- runIO fixtures
  forM_ files $ \file -> describe ("corpus/" <> file) $ do
    text <- runIO (TIO.readFile ("corpus" </> file))
    let cases = case decode text of
          Right (Array cs) -> cs
          _ -> []
    forM_ (zip [1 :: Int ..] cases) $ \(i, c) -> do
      let name = case keyOr "name" c of
            String n -> T.unpack n
            _ -> file <> " #" <> show i
      it name $ case Corpus.check dispatch resolvedJson c given of
        o | keyOr "pass" o == Bool True -> pure ()
        o -> expectationFailure (T.unpack (case keyOr "diff" o of String d -> d; other -> encode other))
