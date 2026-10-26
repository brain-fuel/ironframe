module Ironframe.RevisionSpec (spec) where

import Data.Either (isLeft, isRight)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Ironframe.Attestation as A
import Ironframe.Digest (digestOf)
import Ironframe.Json
import Ironframe.Revision
import Ironframe.Time (fromUnix)
import Test.Hspec

configuration :: Text -> Value
configuration kind = Object ["format" .= String "ironframe-configuration","version" .= Number (I 1),"revision" .= String (identify payload),"payload" .= payload]
  where
    topology = Object
      ["format" .= String "ironframe-resolved-topology","version" .= Number (I 1)
      ,"project" .= String "notifications","environment" .= String kind
      ,"architecture" .= Object ["digest" .= String (digestOf "architecture")]
      ,"applications" .= Array [Object ["node" .= String "worker"]]
      ,"dependencies" .= Array [Object ["node" .= String "mail","contract" .= Object ["package" .= String "example.mail","version" .= String "0.1.0"]]]
      ,"edges" .= Array [Object ["relationship" .= String "send","source" .= String "worker","destination" .= String "mail","kind" .= String kind,"consumes" .= Array [String "mail"]]]]
    payload = Object ["project" .= String "notifications","environment" .= String kind,"topology" .= topology,"topologyDigest" .= String (digestOf (encode topology))
      ,"applications" .= Object ["worker" .= Object ["implementation" .= String "build-1","version" .= String "0.1.0"]]
      ,"settings" .= Object ["worker" .= Object ["EMAIL_URL" .= String ("http://" <> kind <> ":8080")]]
      ,"bindings" .= Object ["mail" .= Object ["endpoint" .= String ("http://" <> kind <> ":8080"),"kind" .= String kind]]]

observations :: Text -> Value
observations kind = Object
  ["format" .= String "lawtwin-observation","version" .= Number (I 1),"runId" .= String "observation-1"
  ,"topologyDigest" .= keyOr "topologyDigest" payload,"status" .= String "complete","lost" .= Number (I 0),"reasons" .= Array []
  ,"producers" .= producers,"counts" .= Object ["worker" .= counts],"checkpoints" .= Object ["worker" .= checkpoint]
  ,"journal" .= Array journal,"journalDigest" .= String (digestOf (T.concat [encode row <> "\n" | row <- journal]))]
  where
    config = configuration kind
    payload = keyOr "payload" config
    counts = Object ["logs" .= Number (I 1),"spans" .= Number (I 0)]
    checkpoint = Object ["producer" .= String "worker","counts" .= counts,"flushed" .= Bool True,"dropped" .= Number (I 0)]
    producers = Object ["worker" .= Object ["node" .= String "worker","implementation" .= String "build-1","revision" .= keyOr "revision" config]]
    attributes = Array [Object ["key" .= String name,"value" .= Object ["stringValue" .= value]] | (name,value) <-
      [("lawtwin.producer.id",String "worker"),("ironframe.run.id",String "observation-1"),("ironframe.execution.id",String ("run-" <> kind))
      ,("ironframe.topology.digest",keyOr "topologyDigest" payload),("ironframe.node.id",String "worker"),("service.version",String "build-1"),("ironframe.configuration.revision",keyOr "revision" config)]]
    resource = Object ["resource" .= Object ["attributes" .= attributes],"scopeLogs" .= Array [Object ["logRecords" .= Array [Object ["body" .= Object ["stringValue" .= String "provider accepted"]]]]]]
    journal = [Object ["kind" .= String "start","config" .= Object ["runId" .= String "observation-1","topologyDigest" .= keyOr "topologyDigest" payload,"producers" .= producers]]
      ,Object ["kind" .= String "export","signal" .= String "logs","request" .= Object ["resourceLogs" .= Array [resource]]]
      ,Object ["kind" .= String "checkpoint","checkpoint" .= checkpoint]
      ,Object ["kind" .= String "seal","status" .= String "complete","reasons" .= Array []]]

entry :: Text -> Value
entry kind = Object
  ["role" .= String (if kind == "twin" then "fixture" else "provider"),"configuration" .= config,"attestation" .= A.encodeAttestation attestation
  ,"observations" .= observations kind
  ,"laws" .= Array [Object ["stage" .= String "law","status" .= String "property-tested","nativeEvidence" .= Object
    ["status" .= String "passed","observations" .= Array [Object ["outcome" .= String "passed","freshness" .= String "matching-inputs","attempt" .= Object ["executionRun" .= String ("run-" <> kind)]]]]]]
  ,"histories" .= Object ["format" .= String "ironframe-run-histories","version" .= Number (I 1),"run" .= String ("run-" <> kind)
    ,"dependencies" .= Object ["mail" .= Object ["status" .= String "retained","digest" .= String (digestOf "{}\n"),"raw" .= String "{}\n"]]]]
  where
    config = configuration kind
    stamp = fromUnix 0 0
    attestation = (A.newAttestation kind (A.Run ("run-" <> kind) stamp stamp))
      {A.attArchitecture = Just (A.ArchitectureRef "architecture.json" (digestOf "architecture") Nothing Nothing Nothing (textAt "topologyDigest" (keyOr "payload" config)) [])
      ,A.attApplication = Just (A.ApplicationRef "worker" (Just (A.ContractRef "example.worker" "0.1.0" [] Nothing)) (A.Implementation "application" "worker" "0.1.0" (Just "build-1") Nothing) Nothing)
      ,A.attExecution = Just (A.Execution A.CompletedRun ["lawspec","test"] (Just 0) (Just stamp) Nothing)
      ,A.attDependencies = [A.emptyRecord
        {A.depName="mail",A.depEndpoint="http://" <> kind <> ":8080",A.depReached=True,A.depNode=Just "mail",A.depEdge=Just "send"
        ,A.depKind=if kind=="twin" then A.KindStandIn else A.KindReal
        ,A.depStandIn=if kind=="twin" then Just (A.emptyStandIn {A.standProduct="example/mail",A.standVersion="0.1.0",A.standConformance="answers"}) else Nothing
        ,A.depCompleted=Just (A.Completed True (if kind=="twin" then Just (digestOf "{}\n") else Nothing) Nothing)}]}

evidence :: [Value] -> Value
evidence entries = Object ["format" .= String "ironframe-promotion-evidence","version" .= Number (I 1),"runs" .= Array entries]

spec :: Spec
spec = describe "configuration revision policy" $ do
  it "is insensitive to object ordering but changes with settings" $ do
    identify (Object [("b",Bool True),("a",String "x")]) `shouldBe` identify (Object [("a",String "x"),("b",Bool True)])
    identify (configuration "real") `shouldNotBe` identify (configuration "twin")
  it "rejects content that no longer matches its address" $
    validateRevision (insert "revision" (String "different") (configuration "real")) `shouldSatisfy` isLeft
  it "requires both isolated fixture tests and exact real-provider tests" $ do
    assess (configuration "real") (evidence [entry "twin",entry "real"]) `shouldSatisfy` isRight
    assess (configuration "real") (evidence [entry "twin"]) `shouldSatisfy` isLeft
    assess (configuration "real") (evidence [entry "real"]) `shouldSatisfy` isLeft
  it "rejects planned, failed, stale and unobserved native runs" $
    mapM_ (\bad -> assess (configuration "real") (evidence [entry "twin",bad]) `shouldSatisfy` isLeft)
      [insert "attestation" (insert "execution" Null (keyOr "attestation" (entry "real"))) (entry "real")
      ,insert "laws" (Array []) (entry "real")
      ,insert "observations" (insert "status" (String "incomplete") (observations "real")) (entry "real")]
  it "rejects a rewritten collection status when its journal is incomplete" $ do
    let bad = insert "checkpoints" (Object []) (observations "real")
    assess (configuration "real") (evidence [entry "twin",insert "observations" bad (entry "real")]) `shouldSatisfy` isLeft
  it "requires the exact fixture history captured at execution completion" $ do
    let bad = insert "histories" (Object []) (entry "twin")
    assess (configuration "real") (evidence [bad,entry "real"]) `shouldSatisfy` isLeft
  it "records adoption only after draining and acknowledging exact settings" $ do
    let config=configuration "real"
        state=Object ["format" .= String "ironframe-activation","version" .= Number (I 1),"desired" .= keyOr "revision" config,"previous" .= Null,"transition" .= String "activation-1","adopted" .= Object []]
        acknowledgement=Object ["node" .= String "worker","revision" .= keyOr "revision" config,"implementation" .= String "build-1","transition" .= String "activation-1","settingsDigest" .= String (identify (keyOr "worker" (keyOr "settings" (keyOr "payload" config)))),"drainedFrom" .= Null,"drained" .= Bool True]
    textAt "phase" <$> adoption config state acknowledgement `shouldBe` Right (Just "active")
    adoption config state (insert "drained" (Bool False) acknowledgement) `shouldSatisfy` isLeft
    adoption config state (insert "settingsDigest" (String "wrong") acknowledgement) `shouldSatisfy` isLeft
    adoption config state (insert "transition" (String "old") acknowledgement) `shouldSatisfy` isLeft
