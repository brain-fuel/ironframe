//! The CALM chain: the shop example's architecture and decorators resolve in every environment to
//! the bindings they declare, every unresolved, ambiguous or incompatible binding is refused naming
//! the element at fault, and each export agrees with the topology it came from.
//! ref:DEC-calm-resolution ref:DEC-calm-refusals ref:DEC-calm-compatibility ref:DEC-calm-exports

use ironframe_core::calm::export::{
    annotated_architecture, application_settings, dot, mermaid, mermaid_problems, settings_problems, tofu_problems,
};
use ironframe_core::calm::model::{Architecture, Decorators};
use ironframe_core::calm::resolve::{BoundKind, Resolution, resolve};
use ironframe_core::calm::{CalmError, load_and_resolve};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::PathBuf;

/// The example's architecture directory.
fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../examples/calm-shop/architecture")
}

/// The example's architecture and decorators as JSON, to change before resolving.
fn documents() -> (Value, Value) {
    let read = |name: &str| serde_json::from_str(&std::fs::read_to_string(dir().join(name)).unwrap()).unwrap();
    (read("shop.calm.json"), read("shop.decorators.json"))
}

/// Resolves changed documents as if they were the example's files.
fn resolve_documents(architecture: &Value, decorators: &Value, environment: &str) -> Result<Resolution, CalmError> {
    let mut model = Architecture::parse(serde_json::to_string(architecture).unwrap().as_bytes())?;
    model.path = Some(dir().join("shop.calm.json"));
    let decorations = Decorators::parse(serde_json::to_string(decorators).unwrap().as_bytes())?;
    resolve(&model, &decorations, environment, &dir())
}

/// The decorator with this unique-id.
fn decorator<'a>(decorators: &'a mut Value, id: &str) -> &'a mut Value {
    decorators["decorators"].as_array_mut().unwrap().iter_mut().find(|d| d["unique-id"] == id).unwrap()
}

/// Asserts a refusal whose message contains every one of `needles`.
fn refused(result: Result<Resolution, CalmError>, needles: &[&str]) {
    let error = result.expect_err("the architecture should be refused").to_string();
    for needle in needles {
        assert!(error.contains(needle), "expected {needle:?} in:\n{error}");
    }
}

/// Every environment of the example resolves to the bindings it declares. ref:DEC-calm-resolution
#[test]
fn every_environment_resolves_to_its_bindings() {
    let expected = [
        ("twin", BoundKind::Twin, BoundKind::Twin),
        ("real", BoundKind::Real, BoundKind::Real),
        ("mixed", BoundKind::Real, BoundKind::Twin),
        ("staging", BoundKind::Twin, BoundKind::Real),
    ];
    for (environment, log, registry) in expected {
        let resolution = load_and_resolve(&dir().join("shop.calm.json"), None, environment).unwrap();
        let topology = &resolution.topology;
        assert_eq!(topology.dependency("adoptions-log").unwrap().kind, log, "{environment}");
        assert_eq!(topology.dependency("pet-registry").unwrap().kind, registry, "{environment}");
        assert_eq!(topology.dependency("adoptions-log").unwrap().consumers, 2, "the log is shared");
        assert_eq!(topology.edges.len(), 3);
        assert_eq!(topology.architecture.document, "shop.calm.json");
        assert!(topology.architecture.digest.starts_with("sha256:"));
        assert_eq!(resolution.manifest.environments.len(), 1);
    }
}

/// The application laws do not change with the binding: every environment hands each application
/// the same setting names, and its edges carry the same abilities. ref:DEC-calm-resolution
#[test]
fn bindings_change_endpoints_not_what_the_application_reads() {
    let mut shapes = Vec::new();
    for environment in ["twin", "real", "mixed"] {
        let resolution = load_and_resolve(&dir().join("shop.calm.json"), None, environment).unwrap();
        let settings = application_settings(&resolution, &BTreeMap::new()).unwrap();
        let keys: Vec<(String, Vec<String>)> =
            settings.iter().map(|(app, s)| (app.clone(), s.keys().cloned().collect())).collect();
        let abilities: Vec<Vec<String>> = resolution.topology.edges.iter().map(|e| e.consumes.clone()).collect();
        shapes.push((keys, abilities));
        if environment == "real" {
            assert_eq!(settings["adoptions-service"]["PETSTORE_URL"], "http://localhost:8080/api/v3");
        }
        if environment == "twin" {
            assert_eq!(settings["adoptions-service"]["PETSTORE_URL"], "http://localhost:8080");
        }
    }
    assert!(shapes.windows(2).all(|w| w[0] == w[1]));
}

/// The topology's digest identifies the planned wiring: the same documents give the same digest,
/// another binding another. ref:DEC-calm-identity
#[test]
fn the_topology_digest_identifies_the_wiring() {
    let a = load_and_resolve(&dir().join("shop.calm.json"), None, "twin").unwrap().topology.digest();
    let b = load_and_resolve(&dir().join("shop.calm.json"), None, "twin").unwrap().topology.digest();
    let c = load_and_resolve(&dir().join("shop.calm.json"), None, "mixed").unwrap().topology.digest();
    assert_eq!(a, b);
    assert_ne!(a, c);
}

/// A twin for another package is refused. ref:DEC-calm-compatibility
#[test]
fn a_twin_for_another_package_is_refused() {
    let (architecture, mut decorators) = documents();
    decorator(&mut decorators, "pet-registry-twin")["data"]["twin"]["stands-in-for"]["package"] =
        json!("lawtwin.kafka");
    refused(
        resolve_documents(&architecture, &decorators, "twin"),
        &[
            "decorator \"pet-registry-twin\"",
            "stands in for package lawtwin.kafka",
            "requires lawtwin.petstore",
            "incompatible",
        ],
    );
}

/// A twin outside the version requirement is refused. ref:DEC-calm-compatibility
#[test]
fn a_twin_outside_the_version_requirement_is_refused() {
    let (architecture, mut decorators) = documents();
    decorator(&mut decorators, "adoptions-log-twin")["data"]["twin"]["stands-in-for"]["version"] = json!("0.2.0");
    refused(
        resolve_documents(&architecture, &decorators, "twin"),
        &["adoptions-log-twin", "lawtwin.kafka 0.2.0", ">=0.1.0, <0.2.0", "incompatible"],
    );
}

/// A twin that does not stand in for every ability the node requires is refused.
/// ref:DEC-calm-compatibility
#[test]
fn a_twin_missing_an_ability_is_refused() {
    let (architecture, mut decorators) = documents();
    decorator(&mut decorators, "adoptions-log-twin")["data"]["twin"]["stands-in-for"]["abilities"] =
        json!(["lawtwin.kafka::ability::Admin"]);
    refused(
        resolve_documents(&architecture, &decorators, "twin"),
        &["requires ability lawtwin.kafka::ability::Broker", "does not stand in for"],
    );
}

/// A twin whose conformance level the node does not accept is refused. ref:DEC-calm-compatibility
#[test]
fn a_twin_below_the_accepted_conformance_is_refused() {
    let (architecture, mut decorators) = documents();
    decorator(&mut decorators, "adoptions-log-contract")["data"]["dependency"]["conformance"]["accept"] =
        json!(["exact"]);
    refused(
        resolve_documents(&architecture, &decorators, "twin"),
        &["accepts conformance exact", "level 3 (answers)", "incompatible"],
    );
}

/// A twin whose conformance report checked another contract is refused. ref:DEC-calm-compatibility
#[test]
fn a_report_about_another_contract_is_refused() {
    let (architecture, mut decorators) = documents();
    decorator(&mut decorators, "adoptions-log-twin")["data"]["twin"]["conformance"]["report"] =
        json!("conformance/lawtwin-http-0.1.0-petstore.json");
    refused(resolve_documents(&architecture, &decorators, "twin"), &["adoptions-log-twin", "report"]);
}

/// A dependency without a binding in the environment is unresolved. ref:DEC-calm-refusals
#[test]
fn a_dependency_without_a_binding_is_unresolved() {
    let (architecture, mut decorators) = documents();
    decorators["decorators"].as_array_mut().unwrap().retain(|d| d["unique-id"] != "adoptions-log-twin");
    refused(
        resolve_documents(&architecture, &decorators, "twin"),
        &["node \"adoptions-log\"", "no binding in environment \"twin\"", "unresolved"],
    );
}

/// Two bindings of one node in one environment are ambiguous. ref:DEC-calm-refusals
#[test]
fn two_bindings_of_a_node_are_ambiguous() {
    let (architecture, mut decorators) = documents();
    let mut extra = decorator(&mut decorators, "adoptions-log-twin").clone();
    extra["unique-id"] = json!("adoptions-log-twin-again");
    decorators["decorators"].as_array_mut().unwrap().push(extra);
    refused(
        resolve_documents(&architecture, &decorators, "twin"),
        &["node \"adoptions-log\"", "two bindings", "ambiguous"],
    );
}

/// Two contracts on one element are ambiguous. ref:DEC-calm-refusals
#[test]
fn two_contracts_on_an_element_are_ambiguous() {
    let (architecture, mut decorators) = documents();
    let mut extra = decorator(&mut decorators, "adoptions-log-contract").clone();
    extra["unique-id"] = json!("adoptions-log-contract-again");
    decorators["decorators"].as_array_mut().unwrap().push(extra);
    refused(resolve_documents(&architecture, &decorators, "twin"), &["element \"adoptions-log\"", "two contracts"]);
}

/// An edge from an application to a dependency without a connection contract is unresolved.
/// ref:DEC-calm-refusals
#[test]
fn an_edge_without_a_connection_contract_is_unresolved() {
    let (architecture, mut decorators) = documents();
    decorators["decorators"].as_array_mut().unwrap().retain(|d| d["unique-id"] != "audit-reads-adoptions-contract");
    refused(
        resolve_documents(&architecture, &decorators, "twin"),
        &["relationship \"audit-reads-adoptions\"", "no ironframe-contract connection decorator", "unresolved"],
    );
}

/// An environment no decorator declares is refused, naming those declared. ref:DEC-calm-refusals
#[test]
fn an_undeclared_environment_is_refused() {
    let (architecture, decorators) = documents();
    refused(
        resolve_documents(&architecture, &decorators, "production"),
        &["environment \"production\"", "\"mixed\", \"real\", \"staging\", \"twin\""],
    );
}

/// A binding of an environment no decorator declares is refused. ref:DEC-calm-refusals
#[test]
fn a_binding_of_an_undeclared_environment_is_refused() {
    let (architecture, mut decorators) = documents();
    decorator(&mut decorators, "adoptions-log-staging")["data"]["environment"] = json!("prod");
    refused(
        resolve_documents(&architecture, &decorators, "twin"),
        &["adoptions-log-staging", "binds environment \"prod\""],
    );
}

/// A decorator that applies to an element the architecture does not have is refused.
/// ref:DEC-calm-refusals
#[test]
fn a_decorator_on_a_missing_element_is_refused() {
    let (architecture, mut decorators) = documents();
    decorator(&mut decorators, "adoptions-log-twin")["applies-to"] = json!(["adoption-log"]);
    refused(
        resolve_documents(&architecture, &decorators, "twin"),
        &["decorator \"adoptions-log-twin\"", "applies to \"adoption-log\"", "does not have"],
    );
}

/// A decorator that targets another architecture is refused. ref:DEC-calm-refusals
#[test]
fn a_decorator_for_another_architecture_is_refused() {
    let (architecture, mut decorators) = documents();
    decorator(&mut decorators, "adoptions-log-twin")["target"] = json!(["other.calm.json"]);
    refused(resolve_documents(&architecture, &decorators, "twin"), &["adoptions-log-twin", "targets other.calm.json"]);
}

/// A decorator whose data breaks its type's schema is refused by name. ref:DEC-calm-decorators
#[test]
fn a_decorator_breaking_its_schema_is_refused() {
    let (architecture, mut decorators) = documents();
    decorator(&mut decorators, "service-publishes-adoptions-contract")["data"]["connection"]["consumes"] =
        json!(["Adoptions"]);
    refused(
        resolve_documents(&architecture, &decorators, "twin"),
        &["service-publishes-adoptions-contract", "Adoptions"],
    );
}

/// A connection that consumes an ability of another package is refused. ref:DEC-calm-refusals
#[test]
fn consuming_another_packages_ability_is_refused() {
    let (architecture, mut decorators) = documents();
    decorator(&mut decorators, "service-registers-pets-contract")["data"]["connection"]["consumes"] =
        json!(["billing::ability::Pets"]);
    refused(
        resolve_documents(&architecture, &decorators, "twin"),
        &["service-registers-pets", "billing::ability::Pets", "not an ability of"],
    );
}

/// One application consuming one ability over two edges is ambiguous. ref:DEC-calm-refusals
#[test]
fn one_ability_over_two_edges_is_ambiguous() {
    let (architecture, mut decorators) = documents();
    decorator(&mut decorators, "service-registers-pets-contract")["data"]["connection"]["consumes"] =
        json!(["shop.adoptions::ability::Adoptions"]);
    refused(
        resolve_documents(&architecture, &decorators, "twin"),
        &["consumes shop.adoptions::ability::Adoptions", "ambiguous"],
    );
}

/// A twin binding without the contract it stands in for is refused. ref:DEC-calm-decorators
#[test]
fn a_twin_without_stands_in_for_is_refused() {
    let (architecture, mut decorators) = documents();
    decorator(&mut decorators, "adoptions-log-twin")["data"]["twin"].as_object_mut().unwrap().remove("stands-in-for");
    refused(resolve_documents(&architecture, &decorators, "twin"), &["adoptions-log-twin", "stands-in-for"]);
}

/// An architecture that gives two elements one unique-id is refused. ref:DEC-calm-refusals
#[test]
fn a_duplicate_unique_id_is_refused() {
    let (mut architecture, decorators) = documents();
    architecture["relationships"][0]["unique-id"] = json!("adoptions-log");
    refused(
        resolve_documents(&architecture, &decorators, "twin"),
        &["unique-id \"adoptions-log\"", "used by 2 elements"],
    );
}

/// A relationship naming a node the architecture does not have is refused. ref:DEC-calm-refusals
#[test]
fn a_relationship_to_a_missing_node_is_refused() {
    let (mut architecture, decorators) = documents();
    architecture["relationships"][1]["relationship-type"]["connects"]["destination"]["node"] = json!("petstore");
    refused(
        resolve_documents(&architecture, &decorators, "twin"),
        &["relationship \"service-registers-pets\"", "names node \"petstore\""],
    );
}

/// An architecture that is not CALM 1.2 is refused by CALM's own schema. ref:DEC-calm-architecture
#[test]
fn an_architecture_breaking_calm_is_refused() {
    let (mut architecture, decorators) = documents();
    architecture["nodes"][1].as_object_mut().unwrap().remove("node-type");
    refused(resolve_documents(&architecture, &decorators, "twin"), &["architecture", "node-type"]);
}

/// A dependency binding's own fields are checked as `ironframe.yaml`'s are, and the problem is
/// named by node and decorator. ref:DEC-manifest-compat
#[test]
fn a_bad_binding_field_is_named_by_node_and_decorator() {
    let (architecture, mut decorators) = documents();
    decorator(&mut decorators, "adoptions-log-twin")["data"]["twin"]["ports"] = json!([]);
    refused(resolve_documents(&architecture, &decorators, "twin"), &["adoptions-log", "adoptions-log-twin"]);
}

/// The diagrams draw the topology, and a diagram that does not is caught. ref:DEC-calm-exports
#[test]
fn diagrams_agree_with_the_topology() {
    for environment in ["twin", "real", "mixed", "staging"] {
        let resolution = load_and_resolve(&dir().join("shop.calm.json"), None, environment).unwrap();
        let diagram = mermaid(&resolution.topology);
        assert_eq!(mermaid_problems(&resolution.topology, &diagram), Vec::<String>::new());
        let graph = dot(&resolution.topology);
        for dependency in &resolution.topology.dependencies {
            assert!(graph.contains(&format!("class=\"{}\"", dependency.kind.as_str())));
        }
    }
    let resolution = load_and_resolve(&dir().join("shop.calm.json"), None, "mixed").unwrap();
    let tampered = mermaid(&resolution.topology).replace(":::twin", ":::real");
    assert!(!mermaid_problems(&resolution.topology, &tampered).is_empty());
    let missing = mermaid(&resolution.topology).replace("adoptions_audit -->", "%% ");
    assert!(mermaid_problems(&resolution.topology, &missing).iter().any(|p| p.contains("no edge adoptions_audit")));
}

/// The annotated architecture is still CALM 1.2 and names each binding. ref:DEC-calm-exports
#[test]
fn the_annotated_architecture_is_still_calm() {
    let resolution = load_and_resolve(&dir().join("shop.calm.json"), None, "mixed").unwrap();
    let annotated = annotated_architecture(&resolution.architecture.document, &resolution.topology);
    let reread = Architecture::parse(serde_json::to_string(&annotated).unwrap().as_bytes()).unwrap();
    let log = reread.node("adoptions-log").unwrap();
    assert!(log.name.contains("real apache/kafka 4.1.0"));
    assert!(reread.node("pet-registry").unwrap().name.contains("twin lawtwin/http:0.1.0"));
}

/// The OpenTofu root deploys exactly the topology's twins. ref:DEC-calm-exports
#[test]
fn the_tofu_root_deploys_the_topologys_twins() {
    let resolution = load_and_resolve(&dir().join("shop.calm.json"), None, "staging").unwrap();
    let root = ironframe_core::tofu::root_module(&resolution.manifest, "staging", &resolution.dir).unwrap();
    assert_eq!(tofu_problems(&resolution.topology, &root), Vec::<String>::new());
    let mut extra = root.clone();
    extra["module"]["twin_pet_registry"] = json!({});
    assert!(!tofu_problems(&resolution.topology, &extra).is_empty());
}

/// Each application is handed exactly the settings its edges read. ref:DEC-calm-exports
#[test]
fn each_application_gets_the_settings_of_its_edges() {
    let resolution = load_and_resolve(&dir().join("shop.calm.json"), None, "twin").unwrap();
    let settings = application_settings(&resolution, &BTreeMap::new()).unwrap();
    for (application, given) in &settings {
        assert_eq!(settings_problems(&resolution.topology, application, given), Vec::<String>::new());
    }
    assert!(!settings["adoptions-audit"].contains_key("PETSTORE_URL"));
    let mut wrong = settings["adoptions-audit"].clone();
    wrong.insert("PETSTORE_URL".into(), "x".into());
    assert!(!settings_problems(&resolution.topology, "adoptions-audit", &wrong).is_empty());
}
