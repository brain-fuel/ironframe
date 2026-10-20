//! A CALM 1.2 architecture and the decorators attached to it: reading both, checking the
//! architecture against the CALM 1.2 meta schemas embedded from FINOS, and checking each Ironframe
//! decorator against its own JSON Schema, which extends CALM's base decorator. Every problem is
//! reported at once and names the element or decorator at fault by its unique-id.
//! ref:DEC-calm-architecture ref:DEC-calm-decorators

use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::path::{Path, PathBuf};

/// The CALM release whose meta schemas Ironframe embeds and checks architectures against.
/// ref:DEC-calm-architecture
pub const CALM_RELEASE: &str = "1.2";

/// The base URI of the embedded CALM 1.2 meta schemas. ref:DEC-calm-architecture
pub const CALM_META: &str = "https://calm.finos.org/release/1.2/meta/";

/// The CALM 1.2 meta schemas, by file name, as FINOS publishes them. ref:DEC-calm-architecture
pub const CALM_SCHEMAS: [(&str, &str); 5] = [
    ("core.json", include_str!("../../../../schema/calm/1.2/core.json")),
    ("control.json", include_str!("../../../../schema/calm/1.2/control.json")),
    ("flow.json", include_str!("../../../../schema/calm/1.2/flow.json")),
    ("interface.json", include_str!("../../../../schema/calm/1.2/interface.json")),
    ("decorators.json", include_str!("../../../../schema/calm/1.2/decorators.json")),
];

/// The decorator type of an Ironframe contract decorator. ref:DEC-calm-decorators
pub const CONTRACT_TYPE: &str = "ironframe-contract";
/// The decorator type of an Ironframe binding decorator. ref:DEC-calm-decorators
pub const BINDING_TYPE: &str = "ironframe-binding";
/// The decorator type of an Ironframe environment decorator. ref:DEC-calm-decorators
pub const ENVIRONMENT_TYPE: &str = "ironframe-environment";

/// Each Ironframe decorator type and its JSON Schema. ref:DEC-calm-decorators
pub const DECORATOR_SCHEMAS: [(&str, &str); 3] = [
    (CONTRACT_TYPE, include_str!("../../../../schema/calm/ironframe-contract.decorator.schema.json")),
    (BINDING_TYPE, include_str!("../../../../schema/calm/ironframe-binding.decorator.schema.json")),
    (ENVIRONMENT_TYPE, include_str!("../../../../schema/calm/ironframe-environment.decorator.schema.json")),
];

/// One problem with an architecture or a decorator: the element or decorator at fault and what is
/// wrong. ref:DEC-calm-refusals
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct CalmProblem {
    /// What is at fault, such as `node "kafka"` or `decorator "kafka-local"`.
    pub at: String,
    /// What is wrong with it.
    pub message: String,
}

impl fmt::Display for CalmProblem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.at.is_empty() { f.write_str(&self.message) } else { write!(f, "{}: {}", self.at, self.message) }
    }
}

/// Every problem found in an architecture, its decorators or their resolution, reported together.
/// ref:DEC-calm-refusals
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CalmError {
    /// The file the problems were found in, when there is one.
    pub origin: Option<PathBuf>,
    /// What was found.
    pub problems: Vec<CalmProblem>,
}

impl fmt::Display for CalmError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.origin {
            Some(origin) => writeln!(f, "{} is refused:", origin.display())?,
            None => writeln!(f, "refused:")?,
        }
        for (i, problem) in self.problems.iter().enumerate() {
            if i + 1 == self.problems.len() {
                write!(f, "  - {problem}")?;
            } else {
                writeln!(f, "  - {problem}")?;
            }
        }
        Ok(())
    }
}

impl std::error::Error for CalmError {}

/// A problem at `at`. ref:DEC-calm-refusals
pub fn calm_problem(at: impl Into<String>, message: impl Into<String>) -> CalmProblem {
    CalmProblem { at: at.into(), message: message.into() }
}

/// `sha256:<hex>` of some bytes, the digest form of every identity Ironframe records.
/// ref:DEC-calm-identity
pub fn digest(bytes: &[u8]) -> String {
    let hash = Sha256::digest(bytes);
    let mut text = String::from("sha256:");
    for byte in hash {
        text.push_str(&format!("{byte:02x}"));
    }
    text
}

/// A node of the architecture, as much of it as Ironframe reads. ref:DEC-calm-architecture
#[derive(Debug, Clone, PartialEq)]
pub struct Node {
    /// Its unique-id.
    pub id: String,
    /// Its node-type, such as `service` or `database`.
    pub node_type: String,
    /// Its name.
    pub name: String,
    /// Its description.
    pub description: String,
}

/// What a relationship relates. ref:DEC-calm-architecture
#[derive(Debug, Clone, PartialEq)]
pub enum RelationshipKind {
    /// `connects`: a source node reaching a destination node, the edge a dependency is bound on.
    Connects {
        /// The node that connects.
        source: String,
        /// The node it connects to.
        destination: String,
    },
    /// `interacts`: an actor and the nodes it uses.
    Interacts {
        /// The actor.
        actor: String,
        /// The nodes.
        nodes: Vec<String>,
    },
    /// `composed-of` or `deployed-in`: a container and what it holds.
    Contains {
        /// The CALM word, `composed-of` or `deployed-in`.
        kind: String,
        /// The container.
        container: String,
        /// What it holds.
        nodes: Vec<String>,
    },
    /// `options`, which Ironframe does not read.
    Options,
}

/// A relationship of the architecture. ref:DEC-calm-architecture
#[derive(Debug, Clone, PartialEq)]
pub struct Relationship {
    /// Its unique-id.
    pub id: String,
    /// Its description, if any.
    pub description: Option<String>,
    /// Its protocol, such as `TCP` or `HTTP`, if any.
    pub protocol: Option<String>,
    /// What it relates.
    pub kind: RelationshipKind,
}

/// A CALM 1.2 architecture document: its nodes and relationships, the document as read, and its
/// identity, the digest of its bytes. ref:DEC-calm-architecture ref:DEC-calm-identity
#[derive(Debug, Clone, PartialEq)]
pub struct Architecture {
    /// Where it was read from, if from a file.
    pub path: Option<PathBuf>,
    /// The document's `sha256:` digest, over the bytes read.
    pub digest: String,
    /// The document's `unique-id`, if it gives one at the top level.
    pub unique_id: Option<String>,
    /// Its nodes, in order.
    pub nodes: Vec<Node>,
    /// Its relationships, in order.
    pub relationships: Vec<Relationship>,
    /// The document as read.
    pub document: Value,
}

fn compile_calm_core() -> jsonschema::Validator {
    let mut options = jsonschema::options();
    for (name, text) in CALM_SCHEMAS {
        let value: Value = serde_json::from_str(text).expect("an embedded CALM schema is JSON");
        let resource = jsonschema::Resource::from_contents(value).expect("an embedded CALM schema is a schema");
        options = options.with_resource(format!("{CALM_META}{name}"), resource);
    }
    let core: Value = serde_json::from_str(CALM_SCHEMAS[0].1).expect("core.json is JSON");
    options.build(&core).expect("the embedded CALM 1.2 core schema compiles")
}

fn schema_errors(validator: &jsonschema::Validator, value: &Value, at: &str) -> Vec<CalmProblem> {
    let mut seen = BTreeSet::new();
    validator
        .iter_errors(value)
        .map(|error| {
            let path = error.instance_path.to_string();
            let place = if path.is_empty() { at.to_string() } else { format!("{at} at {path}") };
            calm_problem(place, error.to_string())
        })
        .filter(|p| seen.insert(p.to_string()))
        .collect()
}

fn text(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_string)
}

fn texts(value: &Value, key: &str) -> Vec<String> {
    value
        .get(key)
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
        .unwrap_or_default()
}

impl Architecture {
    /// Reads and checks the architecture at `path`. ref:DEC-calm-architecture
    pub fn load(path: &Path) -> Result<Architecture, CalmError> {
        let bytes = std::fs::read(path).map_err(|error| CalmError {
            origin: Some(path.to_path_buf()),
            problems: vec![calm_problem("", format!("cannot read the architecture: {error}"))],
        })?;
        let mut architecture = Architecture::parse(&bytes).map_err(|mut error| {
            error.origin = Some(path.to_path_buf());
            error
        })?;
        architecture.path = Some(path.to_path_buf());
        Ok(architecture)
    }

    /// Reads and checks an architecture from its JSON bytes: its shape against CALM 1.2, then
    /// that every unique-id is unique and every relationship names nodes the architecture has.
    /// ref:DEC-calm-architecture ref:DEC-calm-refusals
    pub fn parse(bytes: &[u8]) -> Result<Architecture, CalmError> {
        let fail = |problems| CalmError { origin: None, problems };
        let document: Value = serde_json::from_slice(bytes)
            .map_err(|error| fail(vec![calm_problem("", format!("not JSON: {error}"))]))?;
        if !document.is_object() {
            return Err(fail(vec![calm_problem("", "a CALM architecture is a JSON object")]));
        }
        let shape = schema_errors(&compile_calm_core(), &document, "architecture");
        if !shape.is_empty() {
            return Err(fail(shape));
        }
        let nodes: Vec<Node> = document["nodes"]
            .as_array()
            .map(|nodes| {
                nodes
                    .iter()
                    .map(|n| Node {
                        id: text(n, "unique-id").unwrap_or_default(),
                        node_type: text(n, "node-type").unwrap_or_default(),
                        name: text(n, "name").unwrap_or_default(),
                        description: text(n, "description").unwrap_or_default(),
                    })
                    .collect()
            })
            .unwrap_or_default();
        let relationships: Vec<Relationship> = document["relationships"]
            .as_array()
            .map(|relationships| relationships.iter().map(read_relationship).collect())
            .unwrap_or_default();
        let architecture = Architecture {
            path: None,
            digest: digest(bytes),
            unique_id: text(&document, "unique-id"),
            nodes,
            relationships,
            document,
        };
        let problems = architecture.problems();
        if problems.is_empty() { Ok(architecture) } else { Err(fail(problems)) }
    }

    /// The rules CALM's schema cannot state: unique-ids are unique across nodes, interfaces,
    /// relationships and flows, and every relationship names nodes that exist.
    /// ref:DEC-calm-refusals
    pub fn problems(&self) -> Vec<CalmProblem> {
        let mut found = Vec::new();
        let mut ids: BTreeMap<String, usize> = BTreeMap::new();
        for id in self.element_ids() {
            *ids.entry(id).or_default() += 1;
        }
        for (id, count) in &ids {
            if *count > 1 {
                found.push(calm_problem(
                    format!("unique-id {id:?}"),
                    format!("is used by {count} elements; each element needs its own"),
                ));
            }
        }
        let nodes: BTreeSet<&str> = self.nodes.iter().map(|n| n.id.as_str()).collect();
        for relationship in &self.relationships {
            let at = format!("relationship {:?}", relationship.id);
            let named: Vec<&String> = match &relationship.kind {
                RelationshipKind::Connects { source, destination } => vec![source, destination],
                RelationshipKind::Interacts { actor, nodes } => std::iter::once(actor).chain(nodes).collect(),
                RelationshipKind::Contains { container, nodes, .. } => {
                    std::iter::once(container).chain(nodes).collect()
                }
                RelationshipKind::Options => Vec::new(),
            };
            for node in named {
                if !nodes.contains(node.as_str()) {
                    found.push(calm_problem(&at, format!("names node {node:?}, which the architecture does not have")));
                }
            }
            if let RelationshipKind::Connects { source, destination } = &relationship.kind
                && source == destination
            {
                found.push(calm_problem(&at, "connects a node to itself"));
            }
        }
        found
    }

    /// Every unique-id the document gives an element: its nodes, their interfaces, its
    /// relationships and its flows. ref:DEC-calm-identity
    pub fn element_ids(&self) -> Vec<String> {
        let mut ids = Vec::new();
        for node in self.document["nodes"].as_array().into_iter().flatten() {
            ids.extend(text(node, "unique-id"));
            for interface in node["interfaces"].as_array().into_iter().flatten() {
                ids.extend(text(interface, "unique-id"));
            }
        }
        for key in ["relationships", "flows"] {
            for element in self.document[key].as_array().into_iter().flatten() {
                ids.extend(text(element, "unique-id"));
            }
        }
        ids
    }

    /// The node with unique-id `id`.
    pub fn node(&self, id: &str) -> Option<&Node> {
        self.nodes.iter().find(|n| n.id == id)
    }

    /// The relationship with unique-id `id`.
    pub fn relationship(&self, id: &str) -> Option<&Relationship> {
        self.relationships.iter().find(|r| r.id == id)
    }

    /// The file name decorators name the architecture by in their `target`. ref:DEC-calm-decorators
    pub fn file_name(&self) -> Option<String> {
        self.path.as_ref().and_then(|p| p.file_name()).map(|n| n.to_string_lossy().into_owned())
    }
}

fn read_relationship(value: &Value) -> Relationship {
    let kinds = &value["relationship-type"];
    let kind = if let Some(connects) = kinds.get("connects") {
        RelationshipKind::Connects {
            source: connects["source"]["node"].as_str().unwrap_or_default().to_string(),
            destination: connects["destination"]["node"].as_str().unwrap_or_default().to_string(),
        }
    } else if let Some(interacts) = kinds.get("interacts") {
        RelationshipKind::Interacts {
            actor: text(interacts, "actor").unwrap_or_default(),
            nodes: texts(interacts, "nodes"),
        }
    } else if let Some((kind, contains)) =
        ["composed-of", "deployed-in"].iter().find_map(|k| kinds.get(*k).map(|v| (k.to_string(), v)))
    {
        RelationshipKind::Contains {
            kind,
            container: text(contains, "container").unwrap_or_default(),
            nodes: texts(contains, "nodes"),
        }
    } else {
        RelationshipKind::Options
    };
    Relationship {
        id: text(value, "unique-id").unwrap_or_default(),
        description: text(value, "description"),
        protocol: text(value, "protocol"),
        kind,
    }
}

/// A CALM decorator: a standalone object attaching typed data to architecture elements by their
/// unique-id. ref:DEC-calm-decorators
#[derive(Debug, Clone, PartialEq)]
pub struct Decorator {
    /// Its unique-id.
    pub id: String,
    /// Its type, such as `ironframe-binding`.
    pub kind: String,
    /// The CALM documents it decorates, as paths or URLs.
    pub target: Vec<String>,
    /// The unique-ids of the elements it applies to.
    pub applies_to: Vec<String>,
    /// Its data, whose shape its type's schema gives.
    pub data: Value,
}

/// The decorators of an architecture, as read from one file, with that file's identity.
/// ref:DEC-calm-decorators ref:DEC-calm-identity
#[derive(Debug, Clone, PartialEq)]
pub struct Decorators {
    /// Where they were read from, if from a file.
    pub path: Option<PathBuf>,
    /// The file's `sha256:` digest.
    pub digest: String,
    /// The decorators, in order.
    pub items: Vec<Decorator>,
}

impl Decorators {
    /// Reads and checks the decorators at `path`: a JSON array of decorators, or an object with a
    /// `decorators` array. ref:DEC-calm-decorators
    pub fn load(path: &Path) -> Result<Decorators, CalmError> {
        let bytes = std::fs::read(path).map_err(|error| CalmError {
            origin: Some(path.to_path_buf()),
            problems: vec![calm_problem("", format!("cannot read the decorators: {error}"))],
        })?;
        let mut decorators = Decorators::parse(&bytes).map_err(|mut error| {
            error.origin = Some(path.to_path_buf());
            error
        })?;
        decorators.path = Some(path.to_path_buf());
        Ok(decorators)
    }

    /// Reads and checks decorators from JSON bytes: each against CALM 1.2's base decorator, and
    /// each Ironframe decorator against its type's schema. A decorator of another type is kept
    /// unread, so a file may hold other tools' decorators too. ref:DEC-calm-decorators
    pub fn parse(bytes: &[u8]) -> Result<Decorators, CalmError> {
        let fail = |problems| CalmError { origin: None, problems };
        let value: Value = serde_json::from_slice(bytes)
            .map_err(|error| fail(vec![calm_problem("", format!("not JSON: {error}"))]))?;
        let list = match &value {
            Value::Array(items) => items.clone(),
            Value::Object(map) => match map.get("decorators") {
                Some(Value::Array(items)) => items.clone(),
                _ => {
                    return Err(fail(vec![calm_problem(
                        "",
                        "expected an array of decorators, or an object with one under \"decorators\"",
                    )]));
                }
            },
            _ => return Err(fail(vec![calm_problem("", "expected an array of decorators")])),
        };
        let base = base_decorator_validator();
        let typed: BTreeMap<&str, jsonschema::Validator> = DECORATOR_SCHEMAS
            .iter()
            .map(|(kind, text)| {
                let schema: Value = serde_json::from_str(text).expect("an embedded decorator schema is JSON");
                (*kind, jsonschema::validator_for(&schema).expect("an embedded decorator schema compiles"))
            })
            .collect();
        let mut problems = Vec::new();
        let mut items = Vec::new();
        let mut seen = BTreeSet::new();
        for (index, item) in list.iter().enumerate() {
            let id = text(item, "unique-id").unwrap_or_else(|| format!("#{index}"));
            let at = format!("decorator {id:?}");
            // CALM's documentation gives a decorator a `$schema`, which its base schema's closed
            // top level does not list; the base is checked without it.
            let mut bare = item.clone();
            if let Some(map) = bare.as_object_mut() {
                map.remove("$schema");
            }
            let shape = schema_errors(&base, &bare, &at);
            if !shape.is_empty() {
                problems.extend(shape);
                continue;
            }
            let kind = text(item, "type").unwrap_or_default();
            if let Some(validator) = typed.get(kind.as_str()) {
                let shape = schema_errors(validator, item, &at);
                if !shape.is_empty() {
                    problems.extend(shape);
                    continue;
                }
            }
            if !seen.insert(id.clone()) {
                problems.push(calm_problem(&at, "is declared twice; each decorator needs its own unique-id"));
                continue;
            }
            items.push(Decorator {
                id,
                kind,
                target: texts(item, "target"),
                applies_to: texts(item, "applies-to"),
                data: item["data"].clone(),
            });
        }
        if problems.is_empty() {
            Ok(Decorators { path: None, digest: digest(bytes), items })
        } else {
            Err(fail(problems))
        }
    }

    /// The decorators of one type.
    pub fn of_type<'a>(&'a self, kind: &'a str) -> impl Iterator<Item = &'a Decorator> + 'a {
        self.items.iter().filter(move |d| d.kind == kind)
    }
}

fn base_decorator_validator() -> jsonschema::Validator {
    let schema: Value = serde_json::from_str(CALM_SCHEMAS[4].1).expect("decorators.json is JSON");
    let decorator = schema["defs"]["decorator"].clone();
    jsonschema::validator_for(&decorator).expect("CALM's base decorator schema compiles")
}

/// Checks that every decorator of Ironframe's types targets this architecture and applies only to
/// elements it has: a decorator may name the architecture by its file name, by a path ending in
/// it, or by the architecture's own unique-id. ref:DEC-calm-decorators ref:DEC-calm-refusals
pub fn target_problems(architecture: &Architecture, decorators: &Decorators) -> Vec<CalmProblem> {
    let mut found = Vec::new();
    let ids: BTreeSet<String> = architecture.element_ids().into_iter().collect();
    let file = architecture.file_name();
    for decorator in &decorators.items {
        if ![CONTRACT_TYPE, BINDING_TYPE, ENVIRONMENT_TYPE].contains(&decorator.kind.as_str()) {
            continue;
        }
        let at = format!("decorator {:?}", decorator.id);
        let targets_this = decorator.target.iter().any(|target| {
            let name = target.rsplit('/').next().unwrap_or(target);
            file.as_deref() == Some(name) || architecture.unique_id.as_deref() == Some(target.as_str())
        });
        if !targets_this {
            found.push(calm_problem(
                &at,
                format!(
                    "targets {}, not this architecture ({})",
                    decorator.target.join(", "),
                    file.clone().or_else(|| architecture.unique_id.clone()).unwrap_or_else(|| "unnamed".into())
                ),
            ));
        }
        for element in &decorator.applies_to {
            if !ids.contains(element) {
                found.push(calm_problem(&at, format!("applies to {element:?}, which the architecture does not have")));
            }
        }
    }
    found
}
