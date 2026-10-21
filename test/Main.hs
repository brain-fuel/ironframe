module Main (main) where

import qualified CliCorpusSpec
import qualified CorpusSpec
import qualified Ironframe.DigestSpec
import qualified Ironframe.JsonSpec
import qualified Ironframe.RustSpec
import qualified Ironframe.SchemaSpec
import qualified Ironframe.SemverSpec
import qualified Ironframe.SerdeSpec
import qualified Ironframe.TimeSpec
import qualified Ironframe.YamlSpec
import Test.Hspec

main :: IO ()
main = hspec $ do
  Ironframe.JsonSpec.spec
  Ironframe.RustSpec.spec
  Ironframe.SerdeSpec.spec
  Ironframe.SchemaSpec.spec
  Ironframe.YamlSpec.spec
  Ironframe.SemverSpec.spec
  Ironframe.TimeSpec.spec
  Ironframe.DigestSpec.spec
  CorpusSpec.spec
  CliCorpusSpec.spec
