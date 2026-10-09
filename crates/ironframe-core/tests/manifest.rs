//! The manifest is read in two passes, shape and then rules across fields, and each pass reports
//! every problem with the dotted path of the field at fault. The schema and the Rust types accept
//! the same manifests. ref:DEC-manifest-shape

mod common;

use ironframe_core::manifest::{Binding, Manifest, Runtime, SCHEMA};

fn problems(text: &str) -> Vec<String> {
    match Manifest::parse(text) {
        Ok(_) => Vec::new(),
        Err(error) => error.problems.iter().map(|p| p.to_string()).collect(),
    }
}

fn with_environment(environment: &str) -> String {
    format!(
        "version: 1\nproject: shop\ndependencies:\n  kafka:\n    settings:\n      KAFKA_BOOTSTRAP_SERVERS: ${{endpoint}}\nenvironments:\n  local:\n{}",
        environment.lines().map(|l| format!("    {l}\n")).collect::<String>()
    )
}

fn assert_problem(text: &str, at: &str, needle: &str) {
    let found = problems(text);
    assert!(
        found.iter().any(|p| p.starts_with(&format!("{at}: ")) && p.contains(needle)),
        "expected a problem at {at} containing {needle:?}, got {found:#?}"
    );
}

/// ref:REQ-manifest-validation
#[test]
fn the_shared_and_example_manifests_are_valid() {
    let manifest = common::manifest();
    assert_eq!(manifest.project, "shop");
    assert_eq!(manifest.environments["staging"].runtime, Runtime::Aws);
    assert!(matches!(manifest.environments["local"].dependencies["kafka"], Binding::Twin(_)));
    let example = Manifest::load(&common::example_manifest_path()).unwrap();
    assert_eq!(example.environments.len(), 4);
}

/// ref:REQ-manifest-validation
#[test]
fn every_shape_problem_is_reported_at_once_with_its_path() {
    let found = problems(
        "version: 2\nproject: Shop\ndependencies: {}\nenvironments:\n  local:\n    runtime: kubernetes\n    dependencies: {}\n    extra: true\n",
    );
    assert!(found.len() >= 4, "{found:#?}");
    for at in ["version", "project", "environments.local.runtime", "environments.local"] {
        assert!(found.iter().any(|p| p.starts_with(&format!("{at}: "))), "nothing at {at}: {found:#?}");
    }
}

/// ref:REQ-manifest-validation
#[test]
fn a_binding_is_exactly_one_of_real_or_twin() {
    assert_problem(
        &with_environment("runtime: podman\ndependencies:\n  kafka: {}\n"),
        "environments.local.dependencies.kafka",
        "",
    );
    assert_problem(
        &with_environment(
            "runtime: podman\ndependencies:\n  kafka:\n    real: {endpoint: a:1}\n    twin: {image: t, version: '1', conformance: c, ports: [1]}\n",
        ),
        "environments.local.dependencies.kafka",
        "",
    );
}

/// ref:REQ-manifest-validation
#[test]
fn a_twin_needs_its_version_conformance_and_ports() {
    let text = with_environment("runtime: podman\ndependencies:\n  kafka:\n    twin: {image: lawtwin/kafka}\n");
    for property in ["version", "conformance", "ports"] {
        assert_problem(&text, "environments.local.dependencies.kafka.twin", property);
    }
}

/// ref:REQ-manifest-validation
#[test]
fn a_twin_image_names_no_tag_because_its_version_is_the_tag() {
    assert_problem(
        &with_environment(
            "runtime: podman\ndependencies:\n  kafka:\n    twin: {image: 'lawtwin/kafka:0.1.0', version: 0.1.0, conformance: c, ports: [9092]}\n",
        ),
        "environments.local.dependencies.kafka.twin.image",
        "without a tag",
    );
}

/// ref:REQ-manifest-validation
#[test]
fn every_declared_dependency_is_bound_and_nothing_undeclared_is() {
    let text = with_environment("runtime: podman\ndependencies:\n  redis:\n    real: {endpoint: 'localhost:6379'}\n");
    assert_problem(&text, "environments.local.dependencies", "\"kafka\" is declared but not bound");
    assert_problem(&text, "environments.local.dependencies.redis", "not declared");
}

/// ref:REQ-manifest-validation
#[test]
fn an_unknown_placeholder_is_caught_when_the_manifest_is_read() {
    let text = "version: 1\nproject: shop\ndependencies:\n  kafka:\n    settings:\n      KAFKA: ${endpiont}\nenvironments:\n  local:\n    runtime: podman\n    dependencies:\n      kafka:\n        real: {endpoint: 'localhost:9092'}\n";
    assert_problem(text, "dependencies.kafka.settings.KAFKA", "unknown placeholder ${endpiont}");
}

/// ref:REQ-manifest-validation
#[test]
fn a_setting_read_by_two_dependencies_is_refused() {
    let text = "version: 1\nproject: shop\ndependencies:\n  a:\n    settings: {URL: '${endpoint}'}\n  b:\n    settings: {URL: '${endpoint}'}\nenvironments:\n  local:\n    runtime: podman\n    dependencies:\n      a: {real: {endpoint: 'x:1'}}\n      b: {real: {endpoint: 'y:1'}}\n";
    assert_problem(text, "dependencies.b.settings.URL", "also declared by dependency \"a\"");
}

/// ref:REQ-manifest-validation
#[test]
fn settings_using_credentials_need_a_reference_in_every_binding() {
    let text = "version: 1\nproject: shop\ndependencies:\n  db:\n    settings: {DB_PASSWORD_REF: '${credentials}'}\nenvironments:\n  local:\n    runtime: podman\n    dependencies:\n      db: {real: {endpoint: 'localhost:5432'}}\n";
    assert_problem(text, "environments.local.dependencies.db.real.credentials", "${credentials}");
    let bad_scheme =
        text.replace("{endpoint: 'localhost:5432'}", "{endpoint: 'localhost:5432', credentials: 'hunter2'}");
    assert_problem(&bad_scheme, "environments.local.dependencies.db.real.credentials", "");
}

/// ref:REQ-manifest-validation
#[test]
fn a_cloud_environment_needs_its_inputs_and_takes_no_unknown_ones() {
    let text = with_environment(
        "runtime: aws\ncloud: {region: us-east-1, subnets: [a]}\ndependencies:\n  kafka:\n    twin: {image: lawtwin/kafka, version: 0.1.0, conformance: c, ports: [9092]}\n",
    );
    assert_problem(&text, "environments.local.cloud.vpc_id", "needs vpc_id");
    assert_problem(&text, "environments.local.cloud.subnet_ids", "needs subnet_ids");
    assert_problem(&text, "environments.local.cloud.subnets", "takes no input \"subnets\"");
    assert_problem(
        &with_environment("runtime: aws\ndependencies:\n  kafka:\n    real: {endpoint: 'b:9092'}\n"),
        "environments.local.cloud",
        "needs `cloud`",
    );
}

/// ref:REQ-manifest-validation
#[test]
fn a_real_image_runs_only_on_podman_and_needs_ports() {
    assert_problem(
        &with_environment(
            "runtime: gcp\ncloud: {project: p, region: r}\ndependencies:\n  kafka:\n    real: {endpoint: 'b:9092', image: 'apache/kafka:4.1.0', ports: [9092]}\n",
        ),
        "environments.local.dependencies.kafka.real.image",
        "only on podman",
    );
    assert_problem(
        &with_environment(
            "runtime: podman\ndependencies:\n  kafka:\n    real: {endpoint: 'localhost:9092', image: 'apache/kafka:4.1.0'}\n",
        ),
        "environments.local.dependencies.kafka.real.ports",
        "ports to publish",
    );
}

/// ref:REQ-manifest-validation
#[test]
fn two_containers_publishing_one_port_are_refused_on_podman() {
    let text = "version: 1\nproject: shop\ndependencies:\n  a:\n    settings: {A: '${endpoint}'}\n  b:\n    settings: {B: '${endpoint}'}\nenvironments:\n  local:\n    runtime: podman\n    dependencies:\n      a: {twin: {image: t/a, version: '1', conformance: c, ports: [9092]}}\n      b: {twin: {image: t/b, version: '1', conformance: c, ports: [9092]}}\n";
    assert_problem(
        text,
        "environments.local.dependencies.b.ports",
        "port 9092 is already published by dependency \"a\"",
    );
}

/// ref:REQ-manifest-validation
#[test]
fn cloud_run_serves_one_port_per_twin() {
    assert_problem(
        &with_environment(
            "runtime: gcp\ncloud: {project: p, region: r}\ndependencies:\n  kafka:\n    twin: {image: t/k, version: '1', conformance: c, ports: [9092, 9093]}\n",
        ),
        "environments.local.dependencies.kafka.twin.ports",
        "one port",
    );
}

/// ref:REQ-manifest-validation
#[test]
fn an_unknown_environment_names_the_ones_there_are() {
    let error = common::manifest().environment("production").unwrap_err().to_string();
    assert!(error.contains("\"local\", \"staging\""), "{error}");
}

/// ref:REQ-manifest-validation
#[test]
fn the_file_name_heads_every_report() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("ironframe.yaml");
    std::fs::write(&path, "version: 1\n").unwrap();
    let error = Manifest::load(&path).unwrap_err().to_string();
    assert!(error.starts_with(&path.display().to_string()), "{error}");
    let missing = Manifest::load(&directory.path().join("nope.yaml")).unwrap_err().to_string();
    assert!(missing.contains("cannot read the manifest"), "{missing}");
}

/// ref:REQ-manifest-validation
#[test]
fn the_schema_accepts_every_valid_manifest_and_names_its_own_id() {
    let schema: serde_json::Value = serde_json::from_str(SCHEMA).unwrap();
    assert_eq!(schema["$id"], "https://github.com/brain-fuel/ironframe/schema/ironframe-v1.schema.json");
    let validator = jsonschema::validator_for(&schema).unwrap();
    for text in [common::MANIFEST.to_string(), std::fs::read_to_string(common::example_manifest_path()).unwrap()] {
        let value: serde_json::Value = serde_yaml::from_str(&text).unwrap();
        assert!(validator.is_valid(&value));
        let typed: Manifest = serde_json::from_value(value.clone()).unwrap();
        assert_eq!(serde_json::to_value(&typed).unwrap()["project"], value["project"]);
    }
}
