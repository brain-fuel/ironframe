-- | SHA-256 digests as Ironframe writes them: lowercase hex, a history's
-- @sha256:@ digest, and a parameter version id. The hashing is the pure
-- Haskell SHA package.
-- ref:DEC-haskell-wasm-core
module Ironframe.Digest
  ( sha256Hex
  , digestOf
  , versionId
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Digest.Pure.SHA (sha256, showDigest)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

-- | The SHA-256 digest of some bytes, in lowercase hex.
sha256Hex :: B.ByteString -> Text
sha256Hex = T.pack . showDigest . sha256 . BL.fromStrict

-- | The @sha256:<hex>@ digest of text's UTF-8 bytes, as a history digest.
digestOf :: Text -> Text
digestOf t = "sha256:" <> sha256Hex (TE.encodeUtf8 t)

-- | A parameter version id: @sha256-@ and the first 32 hex digits of the
-- digest of the content's UTF-8 bytes.
versionId :: Text -> Text
versionId t = "sha256-" <> T.take 32 (sha256Hex (TE.encodeUtf8 t))
