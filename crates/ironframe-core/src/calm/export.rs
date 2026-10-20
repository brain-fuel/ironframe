//! What Ironframe generates from one resolved topology, each on its own and usable by other tools:
//! the settings each application reads, as dotenv or JSON; a Mermaid or Graphviz diagram marking
//! each dependency real or twin; a copy of the CALM architecture annotated with each binding, for
//! CALM's own diagram tooling; and the comparison of each export against the topology, so a
//! diagram, a root module or a settings file that does not show the topology is caught.
//! ref:DEC-calm-exports

use crate::calm::resolve::{BoundKind, Resolution, ResolvedDependencyNode, ResolvedTopology};
use crate::settings::{ResolveError, resolve as resolve_settings};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

/// The settings each application reads in the environment, by application node: for each of its
/// edges, the edge's templates rendered over the endpoint its dependency is bound to. `deployed`
/// holds the endpoints a cloud deployment reported, by dependency node. ref:DEC-calm-exports
pub fn application_settings(
    resolution: &Resolution,
    deployed: &BTreeMap<String, String>,
) -> Result<BTreeMap<String, BTreeMap<String, String>>, ResolveError> {
    let environment = resolve_settings(&resolution.manifest, &resolution.topology.environment, deployed)?;
    let mut by_application: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
    for application in &resolution.topology.applications {
        let settings = by_application.entry(application.node.clone()).or_default();
        for edge in resolution.topology.edges_of(&application.node) {
            let Some(dependency) = environment.dependencies.iter().find(|d| d.name == edge.destination) else {
                continue;
            };
            for key in edge.settings.keys() {
                if let Some(value) = dependency.settings.get(key) {
                    settings.insert(key.clone(), value.clone());
                }
            }
        }
    }
    Ok(by_application)
}

/// What a dependency is bound to, in a few words: `twin lawtwin/kafka:0.1.0 (answers)` or
/// `real apache/kafka 4.1.0`. ref:DEC-calm-exports
pub fn binding_label(dependency: &ResolvedDependencyNode) -> String {
    match (&dependency.twin, &dependency.provider) {
        (Some(twin), _) => format!("twin {}:{} ({})", twin.image, twin.version, twin.conformance),
        (None, Some(provider)) => format!("real {} {}", provider.name, provider.version),
        (None, None) => "real".to_string(),
    }
}

/// An ability's name without its unit, for a label.
fn short_ability(identity: &str) -> &str {
    identity.rsplit("::").next().unwrap_or(identity)
}

/// A unique-id as a Mermaid node id.
fn mermaid_id(id: &str) -> String {
    id.replace('-', "_")
}

/// The topology as a Mermaid flowchart: applications, dependencies labelled with their binding and
/// classed `real` or `twin`, and an edge per application edge labelled with the abilities it
/// carries. ref:DEC-calm-exports
pub fn mermaid(topology: &ResolvedTopology) -> String {
    let mut out = format!(
        "%% {} environment {} of {} ({})\nflowchart LR\n",
        topology.project, topology.environment, topology.architecture.document, topology.architecture.digest
    );
    for application in &topology.applications {
        out.push_str(&format!(
            "  {}([\"{}<br/>{} {}\"])\n",
            mermaid_id(&application.node),
            application.name,
            application.contract.package,
            application.version
        ));
    }
    for dependency in &topology.dependencies {
        out.push_str(&format!(
            "  {}[(\"{}<br/>{}\")]:::{}\n",
            mermaid_id(&dependency.node),
            dependency.name,
            binding_label(dependency),
            dependency.kind.as_str()
        ));
    }
    for edge in &topology.edges {
        let abilities: Vec<&str> = edge.consumes.iter().map(|a| short_ability(a)).collect();
        out.push_str(&format!(
            "  {} -->|\"{}{}\"| {}\n",
            mermaid_id(&edge.source),
            abilities.join(", "),
            edge.protocol.as_deref().map(|p| format!(" over {p}")).unwrap_or_default(),
            mermaid_id(&edge.destination)
        ));
    }
    out.push_str("  classDef real fill:#e8f5e9,stroke:#2e7d32\n");
    out.push_str("  classDef twin fill:#e3f2fd,stroke:#1565c0,stroke-dasharray: 4 2\n");
    out
}

/// The topology as a Graphviz digraph, with the nodes, labels and edges of [`mermaid`].
/// ref:DEC-calm-exports
pub fn dot(topology: &ResolvedTopology) -> String {
    let mut out = format!(
        "// {} environment {} of {} ({})\ndigraph \"{}-{}\" {{\n  rankdir=LR;\n",
        topology.project,
        topology.environment,
        topology.architecture.document,
        topology.architecture.digest,
        topology.project,
        topology.environment
    );
    for application in &topology.applications {
        out.push_str(&format!(
            "  \"{}\" [shape=box, style=rounded, label=\"{}\\n{} {}\"];\n",
            application.node, application.name, application.contract.package, application.version
        ));
    }
    for dependency in &topology.dependencies {
        let style = match dependency.kind {
            BoundKind::Real => "style=filled, fillcolor=\"#e8f5e9\"",
            BoundKind::Twin => "style=\"filled,dashed\", fillcolor=\"#e3f2fd\"",
        };
        out.push_str(&format!(
            "  \"{}\" [shape=cylinder, {style}, class=\"{}\", label=\"{}\\n{}\"];\n",
            dependency.node,
            dependency.kind.as_str(),
            dependency.name,
            binding_label(dependency)
        ));
    }
    for edge in &topology.edges {
        let abilities: Vec<&str> = edge.consumes.iter().map(|a| short_ability(a)).collect();
        out.push_str(&format!("  \"{}\" -> \"{}\" [label=\"{}\"];\n", edge.source, edge.destination, abilities.join(", ")));
    }
    out.push_str("}\n");
    out
}

/// A copy of the CALM architecture with each resolved node's binding in its name and under its
/// `metadata`, still a CALM 1.2 architecture, so `calm template`, `calm docify` and any other CALM
/// tool draw the environment as resolved. ref:DEC-calm-exports
pub fn annotated_architecture(document: &Value, topology: &ResolvedTopology) -> Value {
    let mut annotated = document.clone();
    for node in annotated["nodes"].as_array_mut().into_iter().flatten() {
        let id = node["unique-id"].as_str().unwrap_or_default().to_string();
        let (suffix, binding) = if let Some(dependency) = topology.dependency(&id) {
            (
                format!(" [{}]", binding_label(dependency)),
                serde_json::json!({
                    "environment": topology.environment,
                    "kind": dependency.kind.as_str(),
                    "binding": binding_label(dependency),
                    "contract": dependency.contract,
                }),
            )
        } else if let Some(application) = topology.application(&id) {
            (
                format!(" [{} {}]", application.contract.package, application.version),
                serde_json::json!({
                    "environment": topology.environment,
                    "contract": application.contract,
                    "deployment": application.deployment,
                }),
            )
        } else {
            continue;
        };
        if let Some(name) = node["name"].as_str() {
            node["name"] = Value::String(format!("{name}{suffix}"));
        }
        match node.get_mut("metadata") {
            Some(Value::Array(items)) => items.push(serde_json::json!({ "ironframe-binding": binding })),
            Some(Value::Object(map)) => {
                map.insert("ironframe-binding".into(), binding);
            }
            _ => node["metadata"] = serde_json::json!([{ "ironframe-binding": binding }]),
        }
    }
    annotated
}

/// The template `calm template` renders the annotated architecture with: CALM's own
/// block-architecture widget, a Mermaid diagram of every node and relationship. ref:DEC-calm-exports
pub const CALM_DIAGRAM_TEMPLATE: &str = "{{block-architecture this}}\n";

/// Where a Mermaid diagram written by [`mermaid`] disagrees with the topology: a dependency
/// missing or drawn with another binding, or an edge missing or extra. ref:DEC-calm-exports
pub fn mermaid_problems(topology: &ResolvedTopology, diagram: &str) -> Vec<String> {
    let mut found = Vec::new();
    for dependency in &topology.dependencies {
        let start = format!("{}[(", mermaid_id(&dependency.node));
        match diagram.lines().find(|l| l.trim_start().starts_with(&start)) {
            None => found.push(format!("the diagram does not draw dependency {}", dependency.node)),
            Some(line) => {
                if !line.ends_with(&format!(":::{}", dependency.kind.as_str())) || !line.contains(&binding_label(dependency)) {
                    found.push(format!("the diagram draws {} other than as {}", dependency.node, binding_label(dependency)));
                }
            }
        }
    }
    let drawn: BTreeSet<(String, String)> = diagram
        .lines()
        .filter_map(|l| {
            let (from, rest) = l.trim().split_once(" -->|")?;
            let to = rest.rsplit_once("| ")?.1;
            Some((from.to_string(), to.to_string()))
        })
        .collect();
    let expected: BTreeSet<(String, String)> =
        topology.edges.iter().map(|e| (mermaid_id(&e.source), mermaid_id(&e.destination))).collect();
    for missing in expected.difference(&drawn) {
        found.push(format!("the diagram has no edge {} --> {}", missing.0, missing.1));
    }
    for extra in drawn.difference(&expected) {
        found.push(format!("the diagram has an edge {} --> {} the topology does not", extra.0, extra.1));
    }
    found
}

/// Where an OpenTofu root written for the topology disagrees with it: every twin, and only the
/// twins, has a module instance, `twin_<node>`. ref:DEC-calm-exports
pub fn tofu_problems(topology: &ResolvedTopology, root: &Value) -> Vec<String> {
    let modules: BTreeSet<String> = root["module"].as_object().map(|m| m.keys().cloned().collect()).unwrap_or_default();
    let twins: BTreeSet<String> = topology
        .dependencies
        .iter()
        .filter(|d| d.kind == BoundKind::Twin)
        .map(|d| format!("twin_{}", d.node.replace('-', "_")))
        .collect();
    let mut found = Vec::new();
    for missing in twins.difference(&modules) {
        found.push(format!("the root deploys no module {missing} for a twin of the topology"));
    }
    for extra in modules.difference(&twins) {
        found.push(format!("the root deploys module {extra}, which is no twin of the topology"));
    }
    found
}

/// Where the settings handed to an application disagree with the topology: every setting of every
/// edge of the application, and no other. ref:DEC-calm-exports
pub fn settings_problems(
    topology: &ResolvedTopology,
    application: &str,
    settings: &BTreeMap<String, String>,
) -> Vec<String> {
    let expected: BTreeSet<&String> = topology.edges_of(application).flat_map(|e| e.settings.keys()).collect();
    let given: BTreeSet<&String> = settings.keys().collect();
    let mut found = Vec::new();
    for key in expected.difference(&given) {
        found.push(format!("{application} is not handed {key}"));
    }
    for key in given.difference(&expected) {
        found.push(format!("{application} is handed {key}, which none of its edges reads"));
    }
    found
}
