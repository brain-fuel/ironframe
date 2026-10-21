-- | A CALM 1.2 architecture and the decorators attached to it: reading both,
-- checking the architecture against the CALM 1.2 meta schemas embedded from
-- FINOS, and checking each Ironframe decorator against its own JSON Schema.
-- Every problem is reported at once and names the element or decorator at
-- fault by its unique-id. ref:DEC-calm-architecture ref:DEC-calm-decorators
module Ironframe.Calm.Model
  ( calmRelease
  , calmMeta
  , contractType
  , bindingType
  , environmentType
  , CalmProblem (..)
  , CalmError (..)
  , renderCalmProblem
  , renderCalmError
  , calmProblem
  , digest
  , Node (..)
  , RelationshipKind (..)
  , Relationship (..)
  , Architecture (..)
  , parseArchitecture
  , architectureProblems
  , elementIds
  , nodeOf
  , relationshipOf
  , architectureFileName
  , Decorator (..)
  , Decorators (..)
  , parseDecorators
  , ofType
  , targetProblems
  , loadArchitecture
  , loadDecorators
  ) where

import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Ironframe.Digest (digestOf)
import Ironframe.Effect
import qualified Ironframe.Embedded as Embedded
import Ironframe.Json
import qualified Ironframe.Json.Schema as Schema
import qualified Ironframe.Path as Path
import Ironframe.Rust (debugStr)

calmRelease :: Text
calmRelease = "1.2"

calmMeta :: Text
calmMeta = "https://calm.finos.org/release/1.2/meta/"

contractType, bindingType, environmentType :: Text
contractType = "ironframe-contract"
bindingType = "ironframe-binding"
environmentType = "ironframe-environment"

-- | One problem: what is at fault and what is wrong with it.
data CalmProblem = CalmProblem {calmAt :: Text, calmMessage :: Text}
  deriving (Show, Eq, Ord)

calmProblem :: Text -> Text -> CalmProblem
calmProblem = CalmProblem

renderCalmProblem :: CalmProblem -> Text
renderCalmProblem (CalmProblem at msg)
  | T.null at = msg
  | otherwise = at <> ": " <> msg

-- | Every problem found, and the file they were found in.
data CalmError = CalmError {calmOrigin :: Maybe Text, calmProblems :: [CalmProblem]}
  deriving (Show, Eq)

renderCalmError :: CalmError -> Text
renderCalmError (CalmError origin problems) =
  maybe "refused:\n" (\o -> Path.display o <> " is refused:\n") origin
    <> T.intercalate "\n" ["  - " <> renderCalmProblem p | p <- problems]

-- | @sha256:<hex>@ of some text's UTF-8 bytes.
digest :: Text -> Text
digest = digestOf

data Node = Node {nodeId :: Text, nodeType :: Text, nodeName :: Text, nodeDescription :: Text}
  deriving (Show, Eq)

data RelationshipKind
  = Connects Text Text
  | Interacts Text [Text]
  | Contains Text Text [Text]
  | Options
  deriving (Show, Eq)

data Relationship = Relationship
  { relId :: Text
  , relDescription :: Maybe Text
  , relProtocol :: Maybe Text
  , relKind :: RelationshipKind
  }
  deriving (Show, Eq)

data Architecture = Architecture
  { archPath :: Maybe Text
  , archDigest :: Text
  , archUniqueId :: Maybe Text
  , archNodes :: [Node]
  , archRelationships :: [Relationship]
  , archDocument :: Value
  }
  deriving (Show, Eq)

compileOrDie :: [(Text, Value)] -> Value -> Schema.Schema
compileOrDie resources root = case Schema.compile resources root of
  Right s -> s
  Left e -> error ("an embedded schema does not compile: " <> T.unpack e)

parsed :: Text -> Value
parsed text = either (\e -> error ("an embedded schema is not JSON: " <> T.unpack e)) id (decode text)

calmCoreSchema :: Schema.Schema
calmCoreSchema =
  compileOrDie
    [ (calmMeta <> name, parsed text)
    | (name, text) <-
        [ ("core.json", Embedded.calmCore)
        , ("control.json", Embedded.calmControl)
        , ("flow.json", Embedded.calmFlow)
        , ("interface.json", Embedded.calmInterface)
        , ("decorators.json", Embedded.calmDecorators)
        ]
    ]
    (parsed Embedded.calmCore)

baseDecoratorSchema :: Schema.Schema
baseDecoratorSchema = compileOrDie [] (keyOr "decorator" (keyOr "defs" (parsed Embedded.calmDecorators)))

typedDecoratorSchemas :: [(Text, Schema.Schema)]
typedDecoratorSchemas =
  [ (contractType, compileOrDie [] (parsed Embedded.contractDecoratorSchema))
  , (bindingType, compileOrDie [] (parsed Embedded.bindingDecoratorSchema))
  , (environmentType, compileOrDie [] (parsed Embedded.environmentDecoratorSchema))
  ]

schemaErrors :: Schema.Schema -> Value -> Text -> [CalmProblem]
schemaErrors schema value at = dedupe [place e | e <- Schema.validate schema value]
  where
    place e =
      let path = Schema.errorInstancePath e
       in calmProblem (if T.null path then at else at <> " at " <> path) (Schema.errorMessage e)

dedupe :: [CalmProblem] -> [CalmProblem]
dedupe = go Set.empty
  where
    go _ [] = []
    go seen (p : ps)
      | renderCalmProblem p `Set.member` seen = go seen ps
      | otherwise = p : go (Set.insert (renderCalmProblem p) seen) ps

textOf :: Text -> Value -> Maybe Text
textOf = textAt

-- | Reads and checks an architecture from its JSON text: its shape against
-- CALM 1.2, then the rules CALM's schema cannot state.
parseArchitecture :: Text -> Either CalmError Architecture
parseArchitecture text = do
  let failed ps = Left (CalmError Nothing ps)
  document <- either (\e -> failed [calmProblem "" ("not JSON: " <> e)]) Right (decode text)
  if isObject document then Right () else failed [calmProblem "" "a CALM architecture is a JSON object"]
  case schemaErrors calmCoreSchema document "architecture" of
    [] -> Right ()
    shape -> failed shape
  let nodes = case keyOr "nodes" document of
        Array items -> [Node (fromMaybe "" (textOf "unique-id" n)) (fromMaybe "" (textOf "node-type" n)) (fromMaybe "" (textOf "name" n)) (fromMaybe "" (textOf "description" n)) | n <- items]
        _ -> []
      relationships = case keyOr "relationships" document of
        Array items -> map readRelationship items
        _ -> []
      architecture = Architecture Nothing (digest text) (textOf "unique-id" document) nodes relationships document
  case architectureProblems architecture of
    [] -> Right architecture
    problems -> failed problems

readRelationship :: Value -> Relationship
readRelationship v =
  let kinds = keyOr "relationship-type" v
      kind = case key "connects" kinds of
        Just c -> Connects (textNode (keyOr "source" c)) (textNode (keyOr "destination" c))
        Nothing -> case key "interacts" kinds of
          Just i -> Interacts (fromMaybe "" (textOf "actor" i)) (textsAt "nodes" i)
          Nothing -> case [(k, c) | k <- ["composed-of", "deployed-in"], Just c <- [key k kinds]] of
            ((k, c) : _) -> Contains k (fromMaybe "" (textOf "container" c)) (textsAt "nodes" c)
            [] -> Options
   in Relationship (fromMaybe "" (textOf "unique-id" v)) (textOf "description" v) (textOf "protocol" v) kind
  where
    textNode x = fromMaybe "" (textOf "node" x)

-- | Unique-ids are unique, and every relationship names nodes that exist.
architectureProblems :: Architecture -> [CalmProblem]
architectureProblems a =
  [ calmProblem ("unique-id " <> debugStr i) ("is used by " <> T.pack (show n) <> " elements; each element needs its own")
  | (i, n) <- Map.toAscList (Map.fromListWith (+) [(i, 1 :: Int) | i <- elementIds a])
  , n > 1
  ]
    ++ concatMap relationshipProblems (archRelationships a)
  where
    nodes = Set.fromList (map nodeId (archNodes a))
    relationshipProblems r =
      let at = "relationship " <> debugStr (relId r)
          named = case relKind r of
            Connects s d -> [s, d]
            Interacts actor ns -> actor : ns
            Contains _ container ns -> container : ns
            Options -> []
       in [calmProblem at ("names node " <> debugStr n <> ", which the architecture does not have") | n <- named, not (n `Set.member` nodes)]
            ++ case relKind r of
              Connects s d | s == d -> [calmProblem at "connects a node to itself"]
              _ -> []

-- | Every unique-id the document gives an element.
elementIds :: Architecture -> [Text]
elementIds a =
  concat
    [ maybe [] pure (textOf "unique-id" node) ++ mapMaybe (textOf "unique-id") (arrayAt "interfaces" node)
    | node <- arrayAt "nodes" doc
    ]
    ++ concat [mapMaybe (textOf "unique-id") (arrayAt k doc) | k <- ["relationships", "flows"]]
  where
    doc = archDocument a
    arrayAt k v = case keyOr k v of
      Array items -> items
      _ -> []

nodeOf :: Architecture -> Text -> Maybe Node
nodeOf a i = case filter ((== i) . nodeId) (archNodes a) of
  (n : _) -> Just n
  [] -> Nothing

relationshipOf :: Architecture -> Text -> Maybe Relationship
relationshipOf a i = case filter ((== i) . relId) (archRelationships a) of
  (r : _) -> Just r
  [] -> Nothing

architectureFileName :: Architecture -> Maybe Text
architectureFileName a = archPath a >>= Path.fileName

-- | A CALM decorator.
data Decorator = Decorator
  { decId :: Text
  , decKind :: Text
  , decTarget :: [Text]
  , decAppliesTo :: [Text]
  , decData :: Value
  }
  deriving (Show, Eq)

data Decorators = Decorators {decsPath :: Maybe Text, decsDigest :: Text, decsItems :: [Decorator]}
  deriving (Show, Eq)

-- | Reads and checks decorators from JSON text: each against CALM's base
-- decorator, and each Ironframe decorator against its type's schema.
parseDecorators :: Text -> Either CalmError Decorators
parseDecorators text = do
  let failed ps = Left (CalmError Nothing ps)
  value <- either (\e -> failed [calmProblem "" ("not JSON: " <> e)]) Right (decode text)
  list <- case value of
    Array items -> Right items
    Object _ -> case key "decorators" value of
      Just (Array items) -> Right items
      _ -> failed [calmProblem "" "expected an array of decorators, or an object with one under \"decorators\""]
    _ -> failed [calmProblem "" "expected an array of decorators"]
  let step (problems, items, seen) (index, item) =
        let i = fromMaybe ("#" <> T.pack (show (index :: Int))) (textOf "unique-id" item)
            at = "decorator " <> debugStr i
            bare = delete "$schema" item
            kind = fromMaybe "" (textOf "type" item)
         in case schemaErrors baseDecoratorSchema bare at of
              shape@(_ : _) -> (problems ++ shape, items, seen)
              [] -> case lookup kind typedDecoratorSchemas of
                Just schema | typed@(_ : _) <- schemaErrors schema item at -> (problems ++ typed, items, seen)
                _
                  | i `Set.member` seen -> (problems ++ [calmProblem at "is declared twice; each decorator needs its own unique-id"], items, seen)
                  | otherwise ->
                      (problems, items ++ [Decorator i kind (textsAt "target" item) (textsAt "applies-to" item) (keyOr "data" item)], Set.insert i seen)
      (found, decorators, _) = foldl step ([], [], Set.empty) (zip [0 ..] list)
  if null found then Right (Decorators Nothing (digest text) decorators) else failed found

ofType :: Decorators -> Text -> [Decorator]
ofType ds kind = filter ((== kind) . decKind) (decsItems ds)

-- | Every Ironframe decorator targets this architecture and applies only to
-- elements it has.
targetProblems :: Architecture -> Decorators -> [CalmProblem]
targetProblems a ds = concatMap one (decsItems ds)
  where
    ids = Set.fromList (elementIds a)
    file = architectureFileName a
    one d
      | decKind d `notElem` [contractType, bindingType, environmentType] = []
      | otherwise =
          let at = "decorator " <> debugStr (decId d)
              targetsThis =
                any (\t -> file == Just (last (T.splitOn "/" t)) || archUniqueId a == Just t) (decTarget d)
           in [ calmProblem
                  at
                  ( "targets " <> T.intercalate ", " (decTarget d) <> ", not this architecture ("
                      <> fromMaybe "unnamed" (maybe (archUniqueId a) Just file)
                      <> ")"
                  )
              | not targetsThis
              ]
                ++ [calmProblem at ("applies to " <> debugStr e <> ", which the architecture does not have") | e <- decAppliesTo d, not (e `Set.member` ids)]

-- | Reads and checks the architecture at a path.
loadArchitecture :: Text -> Eff (Either CalmError Architecture)
loadArchitecture path = do
  r <- readFileE path
  pure $ case r of
    Left e -> Left (CalmError (Just path) [calmProblem "" ("cannot read the architecture: " <> ioMessage e)])
    Right text -> case parseArchitecture text of
      Left err -> Left err {calmOrigin = Just path}
      Right a -> Right a {archPath = Just path}

-- | Reads and checks the decorators at a path.
loadDecorators :: Text -> Eff (Either CalmError Decorators)
loadDecorators path = do
  r <- readFileE path
  pure $ case r of
    Left e -> Left (CalmError (Just path) [calmProblem "" ("cannot read the decorators: " <> ioMessage e)])
    Right text -> case parseDecorators text of
      Left err -> Left err {calmOrigin = Just path}
      Right d -> Right d {decsPath = Just path}
