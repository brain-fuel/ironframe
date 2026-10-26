-- | One native core protocol request, for comparisons with the shipped WASM.
-- Run with stack exec -- runghc -package=ironframe tools/native-call.hs.
module Main (main) where

import qualified Data.Text.IO as T
import Ironframe.Api (call)

main :: IO ()
main = T.getContents >>= T.putStrLn . call
