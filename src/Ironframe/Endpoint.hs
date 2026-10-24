-- | Endpoint parsing and local publication are shared by settings, validation
-- and Compose, so the advertised host port cannot disagree with deployment.
module Ironframe.Endpoint (splitEndpoint, publishedPorts) where

import Data.Char (isDigit)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

-- | The host and port of an endpoint, @host:port@ or a URL; a URL without a
-- port takes its scheme's.
splitEndpoint :: Text -> (Text, Maybe Integer)
splitEndpoint endpoint =
  let (scheme, rest) = case T.breakOn "://" endpoint of
        (s, r) | not (T.null r) -> (Just s, T.drop 3 r)
        _ -> (Nothing, endpoint)
      authority0 = T.takeWhile (`notElem` ("/?#" :: String)) rest
      authority = last (T.splitOn "@" authority0)
      fallback = case scheme of
        Just "https" -> Just 443
        Just "http" -> Just 80
        _ -> Nothing
   in case T.breakOnEnd ":" authority of
        ("", _) -> (authority, fallback)
        (before, port)
          | Just p <- parseU16 port -> (T.dropEnd 1 before, Just p)
          | otherwise -> (authority, fallback)
  where
    parseU16 t
      | not (T.null t) && T.all isDigit t && T.length t <= 5 =
          let n = read (T.unpack t) :: Integer in if n <= 65535 then Just n else Nothing
      | T.length t > 1 && T.head t == '+' && T.all isDigit (T.tail t) && T.length t <= 6 =
          let n = read (T.unpack (T.tail t)) :: Integer in if n <= 65535 then Just n else Nothing
      | otherwise = Nothing

-- | Only the first container port is advertised by the endpoint.
publishedPorts :: Text -> [Integer] -> [Integer]
publishedPorts _ [] = []
publishedPorts endpoint (first:remaining) =
  let (host,port) = splitEndpoint endpoint
      local = T.toLower host `elem` ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"]
   in (if local then fromMaybe first port else first) : remaining
