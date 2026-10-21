-- | A twin's control plane, spoken over its admin API: wait for a twin to
-- answer, check its seed, force a state and raise faults, and read the seed
-- and history an attestation records. Ironframe knows the API, never what a
-- twin does behind it. ref:DEC-twin-control-plane ref:DEC-history-digest
module Ironframe.Twin
  ( TwinError (..)
  , renderTwinError
  , twinExitCode
  , Reply (..)
  , replyOk
  , pretty
  , Observation (..)
  , TwinRecord (..)
  , emptyTwinRecord
  , encodeTwinRecord
  , decodeTwinRecord
  , historyDigest
  , ControlPlane (..)
  , controlPlane
  , cpRequest
  , healthy
  , waitHealthy
  , describe
  , inspect
  , force
  , raise
  , clearFaults
  , faults
  , advance
  , history
  , replay
  , reset
  , setSeed
  , observe
  , setUp
  , parseFault
  ) where

import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as TR
import Ironframe.Digest (digestOf)
import Ironframe.Effect
import Ironframe.Json
import Ironframe.Json.Serde
import Ironframe.Manifest (Fault (..), Twin (..))
import qualified Ironframe.Path as Path
import Ironframe.Rust (debugStr)

data TwinError
  = Unreachable Text Text
  | Refused Text Text
  | Answered Text
  | Input Text
  deriving (Show, Eq)

renderTwinError :: TwinError -> Text
renderTwinError = \case
  Unreachable url reason -> "the control plane at " <> url <> " does not answer: " <> reason
  Refused law reason -> "refused: the law `" <> law <> "` forbids this state: " <> reason
  Answered t -> t
  Input t -> t

-- | The exit status @lawtwin@ gives the same failure.
twinExitCode :: TwinError -> Int
twinExitCode = \case
  Refused _ _ -> 2
  _ -> 1

data Reply = Reply {replyStatusCode :: Int, replyText :: Text}

-- | The body of a success, else the twin's @error@ as @lawtwin@ reports it.
replyOk :: Reply -> Either TwinError Text
replyOk (Reply status body)
  | status >= 200 && status < 300 = Right body
  | otherwise =
      let v = either (const Null) id (decode body)
       in Left $ Answered $ case keyOr "error" v of
            String e -> e
            _ -> "the twin answered " <> T.pack (show status) <> ": " <> body

-- | The body as indented JSON when it is JSON, else as it is.
pretty :: Text -> Text
pretty body = either (const body) encodePretty (decode body)

data Observation = Observation
  { obsSeed :: Maybe Integer
  , obsHistoryDigest :: Maybe Text
  , obsHistoryEntries :: Maybe Integer
  , obsHistory :: Maybe Text
  }

-- | What @up@ learnt of a twin it started.
data TwinRecord = TwinRecord
  { trAdmin :: Maybe Text
  , trSeed :: Maybe Integer
  , trConformance :: Maybe Text
  , trFaults :: [Text]
  , trForced :: Bool
  }
  deriving (Show, Eq)

emptyTwinRecord :: TwinRecord
emptyTwinRecord = TwinRecord Nothing Nothing Nothing [] False

encodeTwinRecord :: TwinRecord -> Value
encodeTwinRecord r =
  Object $
    maybe [] (\a -> ["admin" .= String a]) (trAdmin r)
      ++ maybe [] (\s -> ["seed" .= Number (I s)]) (trSeed r)
      ++ maybe [] (\c -> ["conformance" .= String c]) (trConformance r)
      ++ ["faults" .= Array (map String (trFaults r)) | not (null (trFaults r))]
      ++ ["forced" .= Bool True | trForced r]

decodeTwinRecord :: Decoder TwinRecord
decodeTwinRecord =
  struct "TwinRecord" False $
    TwinRecord
      <$> optional "admin" string
      <*> optional "seed" u64
      <*> optional "conformance" string
      <*> defaulted "faults" [] (vec string)
      <*> defaulted "forced" False bool

-- | The @sha256:<hex>@ digest of a history.
historyDigest :: Text -> Text
historyDigest = digestOf

-- | A twin's control plane at a URL.
newtype ControlPlane = ControlPlane {cpUrl :: Text}

controlPlane :: Text -> ControlPlane
controlPlane = ControlPlane . T.dropWhileEnd (== '/')

-- | Sends a request and returns the answer, whatever its status.
cpRequest :: ControlPlane -> Text -> Text -> Maybe Text -> Eff (Either TwinError Reply)
cpRequest cp method path body = do
  let headers = maybe [] (const [("content-type", "application/json")]) body
  r <- httpRequest method (cpUrl cp <> path) headers body 30000
  pure $ case r of
    Left reason -> Left (Unreachable (cpUrl cp) reason)
    Right reply -> Right (Reply (replyStatus reply) (replyBody reply))

okOf :: Eff (Either TwinError Reply) -> Eff (Either TwinError Text)
okOf request = (>>= replyOk) <$> request

healthy :: ControlPlane -> Eff Bool
healthy cp = do
  r <- cpRequest cp "GET" "/healthz" Nothing
  pure $ case r of
    Right reply -> replyStatusCode reply == 200
    Left _ -> False

-- | Waits until @/healthz@ answers or the deadline passes, trying every
-- quarter second.
waitHealthy :: ControlPlane -> Integer -> Eff Bool
waitHealthy cp seconds = do
  start <- monotonicMs
  let until' = start + seconds * 1000
      loop = do
        ok <- healthy cp
        if ok
          then pure True
          else do
            t <- monotonicMs
            if t >= until' then pure False else sleepMs 250 >> loop
  loop

-- | @GET /v1/twin@: what the twin says it is.
describe :: ControlPlane -> Eff (Either TwinError Value)
describe cp = do
  r <- okOf (cpRequest cp "GET" "/v1/twin" Nothing)
  pure (r >>= \body -> either (\e -> Left (Answered ("/v1/twin is not JSON: " <> e))) Right (decode body))

inspect :: ControlPlane -> Bool -> Eff (Either TwinError Text)
inspect cp records = okOf (cpRequest cp "GET" (if records then "/v1/state?records=true" else "/v1/state") Nothing)

-- | @POST /v1/state@: forces a state, or reports the law that refuses it.
force :: ControlPlane -> Text -> Eff (Either TwinError Text)
force cp state = do
  r <- cpRequest cp "POST" "/v1/state" (Just state)
  pure $ case r of
    Left e -> Left e
    Right reply
      | replyStatusCode reply == 422 ->
          let v = either (const Null) id (decode (replyText reply))
              word k = case keyOr k v of
                String t -> t
                _ -> "?"
           in Left (Refused (word "law") (word "reason"))
      | otherwise -> replyOk reply

-- | @POST /v1/faults/{name}@ with its parameters.
raise :: ControlPlane -> Fault -> Eff (Either TwinError Text)
raise cp fault =
  okOf (cpRequest cp "POST" ("/v1/faults/" <> faultName fault) (Just (encode (Object (Map.toAscList (faultParams fault))))))

-- | @DELETE /v1/faults[/{name}]@.
clearFaults :: ControlPlane -> Maybe Text -> Eff (Either TwinError Text)
clearFaults cp name = okOf (cpRequest cp "DELETE" (maybe "/v1/faults" ("/v1/faults/" <>) name) Nothing)

faults :: ControlPlane -> Eff (Either TwinError Text)
faults cp = okOf (cpRequest cp "GET" "/v1/faults" Nothing)

advance :: ControlPlane -> Text -> Eff (Either TwinError Text)
advance cp by = okOf (cpRequest cp "POST" "/v1/clock/advance" (Just (encode (Object ["by" .= String by]))))

-- | @GET /v1/history@: JSON lines, or one JSON array.
history :: ControlPlane -> Maybe Integer -> Maybe Integer -> Bool -> Eff (Either TwinError Text)
history cp since limit array =
  let query =
        maybe [] (\s -> ["since=" <> T.pack (show s)]) since
          ++ maybe [] (\l -> ["limit=" <> T.pack (show l)]) limit
          ++ ["format=jsonl" | not array]
      path = if null query then "/v1/history" else "/v1/history?" <> T.intercalate "&" query
   in okOf (cpRequest cp "GET" path Nothing)

-- | @POST /v1/history/replay@: replays a history, or the twin's own.
replay :: ControlPlane -> Maybe Text -> Eff (Either TwinError Text)
replay cp body = okOf (cpRequest cp "POST" "/v1/history/replay" body)

reset :: ControlPlane -> Eff (Either TwinError Text)
reset cp = okOf (cpRequest cp "DELETE" "/v1/reset" Nothing)

setSeed :: ControlPlane -> Integer -> Eff (Either TwinError Text)
setSeed cp seed = okOf (cpRequest cp "POST" "/v1/seed" (Just (encode (Object ["seed" .= Number (I seed)]))))

seedOf :: Value -> Maybe Integer
seedOf v = case keyOr "seed" v of
  Number (I n) | n >= 0 -> Just n
  _ -> Nothing

-- | The seed and the history's digest, read now.
observe :: ControlPlane -> Eff (Either TwinError Observation)
observe cp = do
  described <- describe cp
  case described of
    Left e -> pure (Left e)
    Right v -> do
      h <- history cp Nothing Nothing False
      pure $ case h of
        Left e -> Left e
        Right text ->
          let entries = toInteger (length (filter (not . T.null . T.strip) (rustLines text)))
           in Right (Observation (seedOf v) (Just (historyDigest text)) (Just entries) (Just text))

rustLines :: Text -> [Text]
rustLines t
  | T.null t = []
  | otherwise =
      let parts = T.splitOn "\n" t
       in map (\l -> fromMaybe l (T.stripSuffix "\r" l)) (if T.null (last parts) then init parts else parts)

-- | Sets a twin up as its binding asks: the seed checked and set again when
-- the twin reports another, then the state forced and each fault raised.
setUp :: ControlPlane -> Twin -> Text -> Eff (Either TwinError TwinRecord)
setUp cp twin manifestDir = do
  described <- describe cp
  case described of
    Left e -> pure (Left e)
    Right v -> do
      let reported = seedOf v
          record0 = emptyTwinRecord {trAdmin = Just (cpUrl cp), trSeed = reported}
      seeded <- case twinSeed twin of
        Just seed | reported /= Just seed -> fmap (const record0 {trSeed = Just seed}) <$> setSeed cp seed
        _ -> pure (Right record0)
      case seeded of
        Left e -> pure (Left e)
        Right record1 -> do
          forced <- case twinState twin of
            Nothing -> pure (Right record1)
            Just state -> do
              text <- case state of
                String path -> do
                  let full = Path.join manifestDir path
                  r <- readFileE full
                  pure (either (\e -> Left (Input (Path.display full <> ": " <> ioMessage e))) Right r)
                other -> pure (Right (encode other))
              case text of
                Left e -> pure (Left e)
                Right t -> fmap (const record1 {trForced = True}) <$> force cp t
          case forced of
            Left e -> pure (Left e)
            Right record2 -> raiseAll record2 (twinFaults twin)
  where
    raiseAll record [] = pure (Right record)
    raiseAll record (fault : rest) = do
      r <- raise cp fault
      case r of
        Left e -> pure (Left (Answered ("raising fault " <> debugStr (faultName fault) <> ": " <> renderTwinError e)))
        Right _ -> raiseAll record {trFaults = trFaults record ++ [faultName fault]} rest

-- | Parses @name=value@ fault parameters as @lawtwin fault@ does: a whole
-- number is a number, anything else a string.
parseFault :: Text -> [Text] -> Either TwinError Fault
parseFault name params = Fault name . Map.fromList <$> mapM one params
  where
    one param = case T.breakOn "=" param of
      (_, "") -> Left (Input (param <> " is not a parameter; write name=value"))
      (k, rest) ->
        let v = T.drop 1 rest
         in Right (k, maybe (String v) (Number . I) (parseI64 v))
    parseI64 t = case TR.signed TR.decimal t of
      Right (n, "")
        | n >= -9223372036854775808 && n <= 9223372036854775807 && validSign t -> Just n
      _ -> Nothing
    validSign t = case T.uncons t of
      Just ('+', r) -> not (T.null r)
      Just ('-', r) -> not (T.null r)
      _ -> True
