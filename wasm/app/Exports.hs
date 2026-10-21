{-# LANGUAGE ForeignFunctionInterface #-}
-- | The WASM core's one export: a JSON request in, a JSON response out, as
-- UTF-8 through linear memory. Mirrors LawSpec's wasm/app/Exports.hs.
-- https://ghc.gitlab.haskell.org/ghc/doc/users_guide/wasm.html#javascript-ffi
module Main (main) where

import qualified Data.ByteString as Strict
import qualified Data.ByteString.Internal as Strict
import qualified Data.ByteString.Unsafe as Strict
import Foreign.C.Types (CChar)
import Foreign.Ptr (Ptr, castPtr)
import GHC.Wasm.Prim (JSString (..))
import qualified Data.Text.Encoding as TE
import Ironframe.Api (call)

foreign import javascript unsafe "$1.length"
  stringLength :: JSString -> IO Int
foreign import javascript unsafe "(new TextEncoder()).encodeInto($1, new Uint8Array(__exports.memory.buffer, $2 >>> 0, $3)).written"
  encodeUtf8 :: JSString -> Ptr CChar -> Int -> IO Int
foreign import javascript unsafe "(new TextDecoder('utf-8', {fatal: true})).decode(new Uint8Array(__exports.memory.buffer, $1 >>> 0, $2))"
  decodeUtf8 :: Ptr CChar -> Int -> IO JSString
foreign export javascript "ironframe_call" wasmCall :: JSString -> IO JSString

wasmCall :: JSString -> IO JSString
wasmCall input = do
  units <- stringLength input
  -- Three bytes per UTF-16 code unit also bounds supplementary characters.
  let capacity = 3 * units
  request <- Strict.createAndTrim capacity $ \pointer -> encodeUtf8 input (castPtr pointer) capacity
  let response = TE.encodeUtf8 (call (TE.decodeUtf8 request))
  Strict.unsafeUseAsCStringLen (Strict.copy response) $ \(pointer, size) -> decodeUtf8 pointer size

main :: IO ()
main = pure ()
