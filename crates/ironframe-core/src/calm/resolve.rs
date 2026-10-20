//! Resolving one environment of a decorated CALM architecture: every application node with the
//! LawSpec package it implements, every dependency node with the contract its binding must satisfy
//! and the binding it has in the environment, and every connects relationship from an application
//! to a dependency with the application abilities it carries and the settings the application reads
//! it through. Whatever cannot be resolved, or resolves to a binding that does not satisfy its
//! contract, is refused with every problem named by element. The resolved topology is lowered onto
//! the manifest model, so the podman, OpenTofu, sync and attestation machinery `ironframe.yaml`
//! uses serves it unchanged. ref:DEC-calm-resolution ref:DEC-calm-refusals ref:DEC-manifest-compat

use crate::calm::model::{
    Architecture, BINDING_TYPE, CONTRACT_TYPE, CalmError, CalmProblem, Decorator, Decorators, ENVIRONMENT_TYPE,
    RelationshipKind, calm_problem, digest, target_problems,
};
use crate::manifest::{
    Binding, Cloud, ConfigService, ConformanceReport, DependencyDecl, Environment, MANIFEST_VERSION, Manifest, Real,
    Runtime, SyncTarget, Twin, is_name,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

/// The value of `format` in a resolved topology document. ref:DEC-calm-resolution
pub const TOPOLOGY_FORMAT: &str = "ironframe-resolved-topology";

/// The resolved topology version this release writes. ref:DEC-calm-resolution
pub const TOPOLOGY_VERSION: u32 = 1;

/// A LawSpec contract identity: a package, a version or version requirement, and the abilities by
/// their resolved identity. ref:DEC-calm-identity
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContractIdentity {
    /// The package, such as `lawtwin.kafka`.
    pub package: String,
    /// An exact version, or for a dependency's contract a requirement such as `>=0.1.0, <0.2.0`.
    pub version: String,
    /// The abilities, such as `lawtwin.kafka::ability::Broker`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub abilities: Vec<String>,
}

/// The identity of the architecture a topology was resolved from: each document by name and
/// digest. ref:DEC-calm-identity
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArchitectureIdentity {
    /// The architecture document's file name.
    pub document: String,
    /// Its `sha256:` digest.
    pub digest: String,
    /// The architecture's own unique-id, when it gives one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unique_id: Option<String>,
    /// The decorators document's file name.
    pub decorators: String,
    /// Its `sha256:` digest.
    pub decorators_digest: String,
}

/// How an application is deployed in an environment. ref:DEC-calm-deployment
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "deployment")]
pub enum Deployment {
    /// By its own tooling, which reads the settings Ironframe injects.
    External,
    /// By Ironframe, as a local process run with the settings in its environment.
    Process {
        /// The command and its arguments.
        command: Vec<String>,
        /// The working directory, relative to the architecture.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        dir: Option<String>,
    },
    /// By Ironframe, as a podman container run with the settings in its environment.
    Image {
        /// The image, with its tag.
        image: String,
        /// Arguments after the image.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        args: Vec<String>,
        /// Where to build the image from when podman does not have it, relative to the architecture.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        build_context: Option<String>,
        /// The Containerfile in that context.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        containerfile: Option<String>,
    },
}

/// An application node, resolved. ref:DEC-calm-resolution
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResolvedApplication {
    /// The node's unique-id.
    pub node: String,
    /// The node's name.
    pub name: String,
    /// The LawSpec package it implements.
    pub contract: ContractIdentity,
    /// How it is deployed here.
    pub deployment: Deployment,
    /// Its implementation's version, the contract's unless the binding says otherwise.
    pub version: String,
    /// Its implementation's commit, when the binding names one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
    /// The relationships it reaches its dependencies through.
    pub edges: Vec<String>,
}

/// Whether a dependency is the real provider or a fixture standing in for it. ref:DEC-calm-resolution
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, PartialOrd, Ord)]
#[serde(rename_all = "lowercase")]
pub enum BoundKind {
    /// The real provider.
    Real,
    /// A LawTwin fixture.
    Twin,
}

impl BoundKind {
    /// The word for it.
    pub fn as_str(self) -> &'static str {
        match self {
            BoundKind::Real => "real",
            BoundKind::Twin => "twin",
        }
    }
}

/// A dependency node, resolved: its contract and what it is bound to here. ref:DEC-calm-resolution
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResolvedDependencyNode {
    /// The node's unique-id, also the dependency's name in the lowered manifest.
    pub node: String,
    /// The node's name.
    pub name: String,
    /// The contract its binding must satisfy, the version a requirement.
    pub contract: ContractIdentity,
    /// The binding decorator that binds it here.
    pub binding: String,
    /// Real or twin.
    pub kind: BoundKind,
    /// For a real dependency, the provider it is, as the binding names it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<Provider>,
    /// For a twin, its image and version, the contract identity it stands in for, and its
    /// conformance level.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub twin: Option<TwinIdentity>,
    /// How many application edges reach it: more than one is a shared dependency.
    pub consumers: usize,
}

/// A real provider's name and version. ref:DEC-calm-identity
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Provider {
    /// Its name, such as `apache/kafka`.
    pub name: String,
    /// Its version.
    pub version: String,
}

/// What a twin is: its image, version and seed, the contract it stands in for, and its declared
/// conformance level. ref:DEC-calm-identity
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TwinIdentity {
    /// The image without its tag.
    pub image: String,
    /// The image tag.
    pub version: String,
    /// The contract identity it stands in for.
    pub stands_in_for: ContractIdentity,
    /// Its conformance level, as declared or read from its report.
    pub conformance: String,
    /// Its seed, when the binding fixes one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seed: Option<u64>,
    /// The faults raised when it starts, by name.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub faults: Vec<String>,
}

/// A connects relationship from an application to a dependency, resolved. ref:DEC-calm-resolution
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResolvedEdge {
    /// The relationship's unique-id.
    pub relationship: String,
    /// The application node.
    pub source: String,
    /// The dependency node.
    pub destination: String,
    /// The relationship's protocol, when it gives one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub protocol: Option<String>,
    /// The application's abilities whose production handler reaches the dependency.
    pub consumes: Vec<String>,
    /// Setting name to template, as the application reads them.
    pub settings: BTreeMap<String, String>,
    /// What the destination is bound to here.
    pub kind: BoundKind,
}

/// One environment of an architecture, resolved: the planned wiring, before anything runs.
/// ref:DEC-calm-resolution ref:DEC-calm-planned-vs-completed
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResolvedTopology {
    /// Always [`TOPOLOGY_FORMAT`].
    pub format: String,
    /// Always [`TOPOLOGY_VERSION`].
    pub version: u32,
    /// The architecture and decorators it was resolved from.
    pub architecture: ArchitectureIdentity,
    /// The environment.
    pub environment: String,
    /// The project name resources are prefixed with.
    pub project: String,
    /// Where its twins run.
    pub runtime: Runtime,
    /// The application nodes.
    pub applications: Vec<ResolvedApplication>,
    /// The dependency nodes.
    pub dependencies: Vec<ResolvedDependencyNode>,
    /// The application-to-dependency edges.
    pub edges: Vec<ResolvedEdge>,
}

impl ResolvedTopology {
    /// The topology's `sha256:` digest, over its JSON, the planned wiring's identity.
    /// ref:DEC-calm-identity
    pub fn digest(&self) -> String {
        digest(serde_json::to_string(self).expect("a topology serialises").as_bytes())
    }

    /// The application node `node`.
    pub fn application(&self, node: &str) -> Option<&ResolvedApplication> {
        self.applications.iter().find(|a| a.node == node)
    }

    /// The dependency node `node`.
    pub fn dependency(&self, node: &str) -> Option<&ResolvedDependencyNode> {
        self.dependencies.iter().find(|d| d.node == node)
    }

    /// The edges leaving application `node`.
    pub fn edges_of<'a>(&'a self, node: &'a str) -> impl Iterator<Item = &'a ResolvedEdge> + 'a {
        self.edges.iter().filter(move |e| e.source == node)
    }
}

/// A resolution: the topology and the manifest it lowers to, for the rest of Ironframe.
/// ref:DEC-manifest-compat
#[derive(Debug, Clone)]
pub struct Resolution {
    /// The resolved topology.
    pub topology: ResolvedTopology,
    /// The manifest holding the one environment, with each dependency node a dependency.
    pub manifest: Manifest,
    /// The directory relative paths in bindings are read against: the decorators'.
    pub dir: PathBuf,
    /// The architecture it was resolved from.
    pub architecture: Architecture,
}

/// The contract decorator's data, by what it applies to. ref:DEC-calm-decorators
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ContractData {
    Application { package: String, version: String },
    Dependency { package: String, version: String, abilities: Vec<String>, conformance: Option<Accept> },
    Connection { consumes: Vec<String>, settings: BTreeMap<String, String> },
}

/// A dependency node's contract as read: package, version requirement, abilities and the
/// conformance levels it accepts.
type DependencyContract = (String, String, Vec<String>, Option<Vec<String>>);

#[derive(Debug, Clone, Deserialize)]
struct Accept {
    accept: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct EnvironmentData {
    project: String,
    runtime: Runtime,
    #[serde(default)]
    cloud: Option<Cloud>,
    #[serde(default)]
    sync: Vec<SyncTarget>,
    #[serde(default)]
    config_service: Option<ConfigService>,
}

fn contract_data(decorator: &Decorator) -> Result<ContractData, CalmProblem> {
    let data = &decorator.data;
    let parse = |key: &str| -> Result<ContractData, CalmProblem> {
        let mut map = serde_json::Map::new();
        map.insert(key.to_string(), data[key].clone());
        serde_json::from_value(Value::Object(map))
            .map_err(|e| calm_problem(format!("decorator {:?}", decorator.id), e.to_string()))
    };
    if data.get("application").is_some() {
        parse("application")
    } else if data.get("dependency").is_some() {
        parse("dependency")
    } else {
        parse("connection")
    }
}

/// Whether `identity` is an ability's resolved identity, `unit::ability::Name`. ref:DEC-calm-identity
pub fn is_ability_identity(identity: &str) -> bool {
    let Some((unit, name)) = identity.split_once("::ability::") else { return false };
    let unit_ok = !unit.is_empty()
        && unit.split('.').all(|part| {
            part.chars().next().is_some_and(|c| c.is_ascii_lowercase())
                && part.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
        });
    let name_ok = name.chars().next().is_some_and(|c| c.is_ascii_uppercase())
        && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
    unit_ok && name_ok
}

/// The unit of an ability identity.
pub fn ability_unit(identity: &str) -> &str {
    identity.split_once("::ability::").map_or(identity, |(unit, _)| unit)
}

/// Whether a unit belongs to a package: it is the package's name or starts with it and a dot.
pub fn unit_in_package(unit: &str, package: &str) -> bool {
    unit == package || unit.strip_prefix(package).is_some_and(|rest| rest.starts_with('.'))
}

/// Resolves environment `environment` of an architecture and its decorators, or refuses with every
/// problem found. `dir` is where relative paths in bindings, such as conformance reports, are read
/// from. ref:DEC-calm-resolution ref:DEC-calm-refusals
pub fn resolve(
    architecture: &Architecture,
    decorators: &Decorators,
    environment: &str,
    dir: &Path,
) -> Result<Resolution, CalmError> {
    let mut found = target_problems(architecture, decorators);
    let refuse = |problems: Vec<CalmProblem>| CalmError { origin: None, problems };

    // The environment.
    let environments: Vec<&Decorator> = decorators.of_type(ENVIRONMENT_TYPE).collect();
    let declared: BTreeSet<String> =
        environments.iter().filter_map(|d| d.data["environment"].as_str().map(str::to_string)).collect();
    let mine: Vec<&&Decorator> =
        environments.iter().filter(|d| d.data["environment"].as_str() == Some(environment)).collect();
    let environment_data = match mine.as_slice() {
        [] => {
            found.push(calm_problem(
                format!("environment {environment:?}"),
                format!(
                    "no ironframe-environment decorator declares it; the decorators declare {}",
                    if declared.is_empty() {
                        "none".to_string()
                    } else {
                        declared.iter().map(|e| format!("{e:?}")).collect::<Vec<_>>().join(", ")
                    }
                ),
            ));
            None
        }
        [one] => match serde_json::from_value::<EnvironmentData>(one.data.clone()) {
            Ok(data) => {
                for element in &one.applies_to {
                    if architecture.node(element).is_none() {
                        found.push(calm_problem(
                            format!("decorator {:?}", one.id),
                            format!("an environment applies to nodes, and {element:?} is not one"),
                        ));
                    }
                }
                Some(data)
            }
            Err(error) => {
                found.push(calm_problem(format!("decorator {:?}", one.id), error.to_string()));
                None
            }
        },
        many => {
            found.push(calm_problem(
                format!("environment {environment:?}"),
                format!(
                    "is declared by {} decorators ({}); it is ambiguous",
                    many.len(),
                    many.iter().map(|d| format!("{:?}", d.id)).collect::<Vec<_>>().join(", ")
                ),
            ));
            None
        }
    };
    if !is_name(environment) {
        found.push(calm_problem(
            format!("environment {environment:?}"),
            "an environment name is lowercase letters, digits and -",
        ));
    }

    // Contracts, one per element.
    let mut contracts: BTreeMap<String, (String, ContractData)> = BTreeMap::new();
    for decorator in decorators.of_type(CONTRACT_TYPE) {
        let data = match contract_data(decorator) {
            Ok(data) => data,
            Err(problem) => {
                found.push(problem);
                continue;
            }
        };
        for element in &decorator.applies_to {
            if let Some((other, _)) = contracts.get(element) {
                found.push(calm_problem(
                    format!("element {element:?}"),
                    format!("has two contracts, decorators {other:?} and {:?}; it is ambiguous", decorator.id),
                ));
                continue;
            }
            contracts.insert(element.clone(), (decorator.id.clone(), data.clone()));
        }
    }

    // Classify nodes, and check contracts are on the right kind of element.
    let mut applications: BTreeMap<String, (String, String)> = BTreeMap::new();
    let mut dependencies: BTreeMap<String, DependencyContract> = BTreeMap::new();
    for (element, (decorator, data)) in &contracts {
        let at = format!("decorator {decorator:?}");
        let is_node = architecture.node(element).is_some();
        match data {
            ContractData::Application { package, version } => {
                if !is_node {
                    found.push(calm_problem(
                        &at,
                        format!("an application contract applies to a node, and {element:?} is not one"),
                    ));
                } else if semver::Version::parse(version).is_err() {
                    found.push(calm_problem(&at, format!("version {version:?} is not an exact semantic version")));
                } else {
                    applications.insert(element.clone(), (package.clone(), version.clone()));
                }
            }
            ContractData::Dependency { package, version, abilities, conformance } => {
                if !is_node {
                    found.push(calm_problem(
                        &at,
                        format!("a dependency contract applies to a node, and {element:?} is not one"),
                    ));
                    continue;
                }
                if semver::VersionReq::parse(version).is_err() {
                    found.push(calm_problem(&at, format!("version {version:?} is not a semantic version requirement")));
                    continue;
                }
                for ability in abilities {
                    if !is_ability_identity(ability) {
                        found.push(calm_problem(
                            &at,
                            format!("{ability:?} is not an ability identity, unit::ability::Name"),
                        ));
                    } else if !unit_in_package(ability_unit(ability), package) {
                        found.push(calm_problem(&at, format!("{ability} is not an ability of package {package}")));
                    }
                }
                if !is_name(element) {
                    found.push(calm_problem(
                        format!("node {element:?}"),
                        "a dependency node's unique-id names it in settings and resources: lowercase letters, digits and -",
                    ));
                }
                dependencies.insert(
                    element.clone(),
                    (
                        package.clone(),
                        version.clone(),
                        abilities.clone(),
                        conformance.as_ref().map(|c| c.accept.clone()),
                    ),
                );
            }
            ContractData::Connection { .. } => {
                if architecture.relationship(element).is_none() {
                    found.push(calm_problem(
                        &at,
                        format!("a connection contract applies to a relationship, and {element:?} is not one"),
                    ));
                }
            }
        }
    }

    // Edges from applications to dependencies.
    let mut edges = Vec::new();
    let mut consumed: BTreeMap<(String, String), String> = BTreeMap::new();
    let mut app_settings: BTreeMap<(String, String), String> = BTreeMap::new();
    for relationship in &architecture.relationships {
        let at = format!("relationship {:?}", relationship.id);
        let connection = match contracts.get(&relationship.id) {
            Some((decorator, ContractData::Connection { consumes, settings })) => Some((decorator, consumes, settings)),
            _ => None,
        };
        let RelationshipKind::Connects { source, destination } = &relationship.kind else {
            if connection.is_some() {
                found.push(calm_problem(
                    &at,
                    "carries a connection contract, but only a connects relationship reaches a dependency",
                ));
            }
            continue;
        };
        let source_is_app = applications.contains_key(source);
        let destination_is_dependency = dependencies.contains_key(destination);
        match (source_is_app, destination_is_dependency, connection) {
            (true, true, Some((_, consumes, settings))) => {
                let (package, _) = &applications[source];
                for ability in consumes {
                    if !is_ability_identity(ability) {
                        found.push(calm_problem(&at, format!("consumes {ability:?}, which is not an ability identity, unit::ability::Name")));
                    } else if !unit_in_package(ability_unit(ability), package) {
                        found.push(calm_problem(
                            &at,
                            format!("consumes {ability}, which is not an ability of {source:?}'s package {package}"),
                        ));
                    }
                    if let Some(other) = consumed.insert((source.clone(), ability.clone()), relationship.id.clone()) {
                        found.push(calm_problem(
                            &at,
                            format!("consumes {ability}, which relationship {other:?} of {source:?} carries too; which endpoint it reaches is ambiguous"),
                        ));
                    }
                }
                for key in settings.keys() {
                    if let Some(other) = app_settings.insert((source.clone(), key.clone()), relationship.id.clone()) {
                        found.push(calm_problem(&at, format!("hands {source:?} setting {key}, which relationship {other:?} hands it too")));
                    }
                }
                edges.push((relationship, source.clone(), destination.clone(), consumes.clone(), settings.clone()));
            }
            (true, true, None) => found.push(calm_problem(
                &at,
                format!(
                    "connects application {source:?} to dependency {destination:?} but has no ironframe-contract connection decorator saying which abilities it carries and which settings the application reads; it is unresolved"
                ),
            )),
            (_, _, Some(_)) => found.push(calm_problem(
                &at,
                format!(
                    "carries a connection contract, but {}",
                    if !source_is_app {
                        format!("its source {source:?} has no application contract")
                    } else {
                        format!("its destination {destination:?} has no dependency contract")
                    }
                ),
            )),
            _ => {}
        }
    }

    // Bindings in this environment, one per node.
    let mut bindings: BTreeMap<String, &Decorator> = BTreeMap::new();
    for decorator in decorators.of_type(BINDING_TYPE) {
        let at = format!("decorator {:?}", decorator.id);
        let bound_environment = decorator.data["environment"].as_str().unwrap_or_default();
        if !declared.contains(bound_environment) {
            found.push(calm_problem(
                &at,
                format!("binds environment {bound_environment:?}, which no ironframe-environment decorator declares"),
            ));
            continue;
        }
        if bound_environment != environment {
            continue;
        }
        for element in &decorator.applies_to {
            let is_application = applications.contains_key(element);
            let is_dependency = dependencies.contains_key(element);
            let says_application = decorator.data.get("application").is_some();
            if !is_application && !is_dependency {
                found.push(calm_problem(
                    &at,
                    format!("binds {element:?}, which has no application or dependency contract"),
                ));
                continue;
            }
            if is_application && !says_application {
                found.push(calm_problem(&at, format!("binds application {element:?} as a dependency, real or twin")));
                continue;
            }
            if is_dependency && says_application {
                found.push(calm_problem(&at, format!("binds dependency {element:?} as an application")));
                continue;
            }
            if let Some(other) = bindings.insert(element.clone(), decorator) {
                found.push(calm_problem(
                    format!("node {element:?}"),
                    format!(
                        "has two bindings in environment {environment:?}, decorators {:?} and {:?}; it is ambiguous",
                        other.id, decorator.id
                    ),
                ));
            }
        }
    }

    // Resolve each dependency's binding against its contract.
    let mut resolved_dependencies = Vec::new();
    let mut manifest_bindings: BTreeMap<String, Binding> = BTreeMap::new();
    for (node, (package, requirement, abilities, accept)) in &dependencies {
        let at = format!("node {node:?}");
        let consumers = edges.iter().filter(|(_, _, d, _, _)| d == node).count();
        if consumers == 0 {
            found.push(calm_problem(
                &at,
                "has a dependency contract, but no application's connects relationship reaches it",
            ));
        }
        let Some(decorator) = bindings.get(node) else {
            found.push(calm_problem(&at, format!("has no binding in environment {environment:?}; it is unresolved")));
            continue;
        };
        let contract =
            ContractIdentity { package: package.clone(), version: requirement.clone(), abilities: abilities.clone() };
        let binding_at = format!("decorator {:?}", decorator.id);
        if let Some(real) = decorator.data.get("real") {
            let mut fields = real.clone();
            let provider = fields.as_object_mut().and_then(|f| f.remove("provider"));
            let provider: Option<Provider> = provider.and_then(|p| serde_json::from_value(p).ok());
            match serde_json::from_value::<Real>(fields) {
                Ok(real) => {
                    manifest_bindings.insert(node.clone(), Binding::Real(real));
                    resolved_dependencies.push(ResolvedDependencyNode {
                        node: node.clone(),
                        name: architecture.node(node).map(|n| n.name.clone()).unwrap_or_default(),
                        contract,
                        binding: decorator.id.clone(),
                        kind: BoundKind::Real,
                        provider,
                        twin: None,
                        consumers,
                    });
                }
                Err(error) => found.push(calm_problem(&binding_at, format!("real: {error}"))),
            }
            continue;
        }
        let mut fields = decorator.data["twin"].clone();
        let stands_in_for = fields.as_object_mut().and_then(|f| f.remove("stands-in-for"));
        let stands_in_for: ContractIdentity = match stands_in_for.map(serde_json::from_value) {
            Some(Ok(identity)) => identity,
            _ => {
                found
                    .push(calm_problem(&binding_at, "a twin says which contract it stands in for under stands-in-for"));
                continue;
            }
        };
        let mut twin: Twin = match serde_json::from_value(fields) {
            Ok(twin) => twin,
            Err(error) => {
                found.push(calm_problem(&binding_at, format!("twin: {error}")));
                continue;
            }
        };
        let before = found.len();
        found.extend(compatibility_problems(
            &binding_at,
            node,
            &contract,
            accept.as_deref(),
            &mut twin,
            &stands_in_for,
            dir,
        ));
        if found.len() > before {
            continue;
        }
        let identity = TwinIdentity {
            image: twin.image.clone(),
            version: twin.version.clone(),
            stands_in_for,
            conformance: twin.conformance_level(),
            seed: twin.seed,
            faults: twin.faults.iter().map(|f| f.name.clone()).collect(),
        };
        manifest_bindings.insert(node.clone(), Binding::Twin(twin));
        resolved_dependencies.push(ResolvedDependencyNode {
            node: node.clone(),
            name: architecture.node(node).map(|n| n.name.clone()).unwrap_or_default(),
            contract,
            binding: decorator.id.clone(),
            kind: BoundKind::Twin,
            provider: None,
            twin: Some(identity),
            consumers,
        });
    }

    // Applications and their deployment.
    let mut resolved_applications = Vec::new();
    for (node, (package, version)) in &applications {
        let mut application = ResolvedApplication {
            node: node.clone(),
            name: architecture.node(node).map(|n| n.name.clone()).unwrap_or_default(),
            contract: ContractIdentity { package: package.clone(), version: version.clone(), abilities: Vec::new() },
            deployment: Deployment::External,
            version: version.clone(),
            commit: None,
            edges: edges.iter().filter(|(_, s, _, _, _)| s == node).map(|(r, _, _, _, _)| r.id.clone()).collect(),
        };
        if let Some(decorator) = bindings.get(node) {
            let data = &decorator.data["application"];
            if let Some(managed) = data.get("managed") {
                if let Some(process) = managed.get("process") {
                    application.deployment = Deployment::Process {
                        command: serde_json::from_value(process["command"].clone()).unwrap_or_default(),
                        dir: process["dir"].as_str().map(str::to_string),
                    };
                } else if let Some(image) = managed.get("image") {
                    application.deployment = Deployment::Image {
                        image: image["image"].as_str().unwrap_or_default().to_string(),
                        args: serde_json::from_value(image["args"].clone()).unwrap_or_default(),
                        build_context: image["build"]["context"].as_str().map(str::to_string),
                        containerfile: image["build"]["containerfile"].as_str().map(str::to_string),
                    };
                }
            }
            if let Some(v) = data["implementation"]["version"].as_str() {
                application.version = v.to_string();
            }
            application.commit = data["implementation"]["commit"].as_str().map(str::to_string);
        }
        resolved_applications.push(application);
    }

    let resolved_edges: Vec<ResolvedEdge> = edges
        .iter()
        .map(|(relationship, source, destination, consumes, settings)| ResolvedEdge {
            relationship: relationship.id.clone(),
            source: source.clone(),
            destination: destination.clone(),
            protocol: relationship.protocol.clone(),
            consumes: consumes.clone(),
            settings: settings.clone(),
            kind: resolved_dependencies.iter().find(|d| &d.node == destination).map_or(BoundKind::Real, |d| d.kind),
        })
        .collect();

    // Settings per dependency, as the manifest declares them: the same templates from every edge.
    let mut declarations: BTreeMap<String, DependencyDecl> = BTreeMap::new();
    for edge in &resolved_edges {
        let declaration = declarations.entry(edge.destination.clone()).or_insert_with(|| DependencyDecl {
            description: architecture.node(&edge.destination).map(|n| n.description.clone()),
            settings: BTreeMap::new(),
        });
        for (key, template) in &edge.settings {
            if let Some(other) = declaration.settings.insert(key.clone(), template.clone())
                && &other != template
            {
                found.push(calm_problem(
                    format!("relationship {:?}", edge.relationship),
                    format!(
                        "reads setting {key} of {:?} as {template:?}, but another relationship reads it as {other:?}",
                        edge.destination
                    ),
                ));
            }
        }
    }

    let Some(environment_data) = environment_data else { return Err(refuse(found)) };
    if !found.is_empty() {
        return Err(refuse(found));
    }

    let manifest = Manifest {
        version: MANIFEST_VERSION,
        project: environment_data.project.clone(),
        dependencies: declarations,
        environments: BTreeMap::from([(
            environment.to_string(),
            Environment {
                runtime: environment_data.runtime,
                cloud: environment_data.cloud.clone(),
                dependencies: manifest_bindings,
                sync: environment_data.sync.clone(),
                config_service: environment_data.config_service.clone(),
            },
        )]),
    };
    let lowered: Vec<CalmProblem> = manifest
        .problems()
        .into_iter()
        .map(|p| translate(&p.at, &p.message, environment, &resolved_dependencies))
        .collect();
    if !lowered.is_empty() {
        return Err(refuse(lowered));
    }

    let topology = ResolvedTopology {
        format: TOPOLOGY_FORMAT.to_string(),
        version: TOPOLOGY_VERSION,
        architecture: ArchitectureIdentity {
            document: architecture.file_name().unwrap_or_else(|| "architecture.json".into()),
            digest: architecture.digest.clone(),
            unique_id: architecture.unique_id.clone(),
            decorators: decorators
                .path
                .as_ref()
                .and_then(|p| p.file_name())
                .map_or_else(|| "decorators.json".into(), |n| n.to_string_lossy().into_owned()),
            decorators_digest: decorators.digest.clone(),
        },
        environment: environment.to_string(),
        project: environment_data.project,
        runtime: environment_data.runtime,
        applications: resolved_applications,
        dependencies: resolved_dependencies,
        edges: resolved_edges,
    };
    Ok(Resolution { topology, manifest, dir: dir.to_path_buf(), architecture: architecture.clone() })
}

/// Names a problem of the lowered manifest by the CALM element and decorator it came from.
fn translate(at: &str, message: &str, environment: &str, dependencies: &[ResolvedDependencyNode]) -> CalmProblem {
    let prefix = format!("environments.{environment}.dependencies.");
    if let Some(rest) = at.strip_prefix(&prefix) {
        let node = rest.split('.').next().unwrap_or(rest);
        let field = rest.strip_prefix(node).unwrap_or_default().trim_start_matches('.');
        let decorator = dependencies.iter().find(|d| d.node == node).map(|d| d.binding.clone()).unwrap_or_default();
        return calm_problem(
            format!(
                "binding of node {node:?} in environment {environment:?} (decorator {decorator:?}){}",
                if field.is_empty() { String::new() } else { format!(" at {field}") }
            ),
            message,
        );
    }
    if let Some(rest) = at.strip_prefix("dependencies.") {
        let node = rest.split('.').next().unwrap_or(rest);
        return calm_problem(format!("settings of node {node:?}"), message);
    }
    calm_problem(
        format!("environment {environment:?}{}", if at.is_empty() { String::new() } else { format!(" at {at}") }),
        message,
    )
}

/// How a twin fails to satisfy the contract of the node it is bound to: another package, a
/// version outside the requirement, missing abilities, a conformance report about something else,
/// or a level the contract does not accept. Reads the twin's conformance report against `dir`.
/// ref:DEC-calm-compatibility
fn compatibility_problems(
    at: &str,
    node: &str,
    contract: &ContractIdentity,
    accept: Option<&[String]>,
    twin: &mut Twin,
    stands_in_for: &ContractIdentity,
    dir: &Path,
) -> Vec<CalmProblem> {
    let mut found = Vec::new();
    if stands_in_for.package != contract.package {
        found.push(calm_problem(
            at,
            format!(
                "the twin stands in for package {}, but node {node:?} requires {}; it is incompatible",
                stands_in_for.package, contract.package
            ),
        ));
    }
    match (semver::Version::parse(&stands_in_for.version), semver::VersionReq::parse(&contract.version)) {
        (Ok(version), Ok(requirement)) if !requirement.matches(&version) => found.push(calm_problem(
            at,
            format!(
                "the twin stands in for {} {}, outside node {node:?}'s requirement {}; it is incompatible",
                stands_in_for.package, stands_in_for.version, contract.version
            ),
        )),
        (Err(_), _) => found.push(calm_problem(
            at,
            format!("stands-in-for version {:?} is not an exact semantic version", stands_in_for.version),
        )),
        _ => {}
    }
    for ability in &contract.abilities {
        if !stands_in_for.abilities.contains(ability) {
            found.push(calm_problem(
                at,
                format!(
                    "node {node:?} requires ability {ability}, which the twin does not stand in for; it is incompatible"
                ),
            ));
        }
    }
    let mut report: Option<ConformanceReport> = None;
    if let Some(relative) = twin.conformance.report() {
        let path = dir.join(relative);
        match std::fs::read_to_string(&path)
            .map_err(|e| format!("cannot read it: {e}"))
            .and_then(|t| ConformanceReport::parse(&t))
        {
            Ok(read) => {
                for problem in crate::manifest::report_problems(at, twin, &read) {
                    found.push(calm_problem(at, problem.message));
                }
                if let Some(package) = &read.contract
                    && package != &stands_in_for.package
                {
                    found.push(calm_problem(
                        at,
                        format!("the twin's conformance report checked package {package}, but the twin says it stands in for {}", stands_in_for.package),
                    ));
                }
                report = Some(read);
            }
            Err(reason) => found.push(calm_problem(at, format!("conformance report {}: {reason}", relative.display()))),
        }
    }
    if let Some(accepted) = accept {
        let ok = match (&report, twin.conformance.declared()) {
            (Some(report), _) => accepted.iter().any(|level| report.matches(level)),
            (None, Some(declared)) => accepted.iter().any(|level| level.eq_ignore_ascii_case(declared)),
            (None, None) => false,
        };
        if !ok {
            let has = report
                .as_ref()
                .map(ConformanceReport::describe)
                .or_else(|| twin.conformance.declared().map(|d| format!("level {d}")));
            found.push(calm_problem(
                at,
                format!(
                    "node {node:?} accepts conformance {}, and the twin has {}; it is incompatible",
                    accepted.join(" or "),
                    has.unwrap_or_else(|| "no level known before it runs".into())
                ),
            ));
        }
    }
    twin.report = report;
    found
}
