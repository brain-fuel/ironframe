-- | The host protocol: one JSON request in, one JSON response out. A request
-- names a method, its parameters and the results of the effects performed so
-- far; the response is the method's result, or the next effect to perform.
-- ref:DEC-host-protocol
module Ironframe.Api (call, callValue) where

import Data.Text (Text)
import Ironframe.Effect
import Ironframe.Json

-- | Answers one request, as JSON text.
call :: Text -> Text
call input = encode $ case decode input of
  Left e -> object ["error" .= String ("the request is not JSON: " <> e)]
  Right request -> callValue request

-- | Answers one request.
callValue :: Value -> Value
callValue request =
  let method = keyOr "method" request
      params = keyOr "params" request
      results = case key "effects" request of
        Just (Array rs) -> rs
        _ -> []
   in case dispatch method params of
        Nothing -> object ["error" .= String "no such method"]
        Just program -> case runEff program results of
          Need effect -> object ["effect" .= effect, "index" .= Number (I (toInteger (length results)))]
          Done (Right v) -> object ["done" .= v]
          Done (Left e) -> object ["failed" .= String e]

dispatch :: Value -> Value -> Maybe (Eff Value)
dispatch (String "version") _ = Just (pure (String "0.1.0"))
dispatch _ _ = Nothing
