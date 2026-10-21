//! Captures the golden corpus: inputs and the exact outputs of the Rust implementation, written
//! under corpus/ at the repository root. The Haskell port reproduces every case byte for byte.
//! Run with `cargo test -p ironframe-core --test corpus -- --ignored`. ref:DEC-haskell-wasm-core

mod common;

use ironframe_attestation::{
    ApplicationRef, ArchitectureRef, Attestation, Completed, ContractRef, DependencyRecord, Execution,
    ExecutionStatus, Implementation, Kind, Producer, Run, StandIn,
};
use ironframe_core::calm::export::{
    annotated_architecture, application_settings, dot, mermaid, mermaid_problems, settings_problems, tofu_problems,
};
use ironframe_core::calm::model::{Architecture, Decorators};
use ironframe_core::calm::resolve::resolve as calm_resolve;
use ironframe_core::manifest::{Binding, ConfigService, ConformanceReport, Manifest};
use ironframe_core::ops::{self, Clouds, UpOptions};
use ironframe_core::process::{CommandOutput, CommandRunner};
use ironframe_core::settings::{
    ResolvedEnvironment, parse_dotenv, qualify_image, render_dotenv, resolve, split_endpoint,
};
use ironframe_core::sync::aws::AppConfigApi;
use ironframe_core::sync::azure::{AppConfigurationApi, ConnectionString};
use ironframe_core::sync::gcp::{ParameterManagerApi, VersionCreated, version_id};
use ironframe_core::sync::{SyncOutcome, describe, settings_json};
use ironframe_core::tofu::{RELEASED_MODULES, deployment_name, module_source, root_module};
use ironframe_core::twin::{ControlPlane, Reply, history_digest, parse_fault, pretty};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").canonicalize().unwrap()
}

/// The cases of each area, in the order captured.
#[derive(Default)]
struct Corpus {
    areas: BTreeMap<String, Vec<Value>>,
}

impl Corpus {
    fn add(&mut self, area: &str, name: &str, method: &str, input: Value, expected: Value) {
        let cases = self.areas.entry(area.to_string()).or_default();
        let name = format!("{area}/{:03}-{name}", cases.len() + 1);
        cases.push(json!({"name": name, "method": method, "input": input, "expected": expected}));
    }

    fn write(&self) {
        let dir = repo().join("corpus");
        std::fs::create_dir_all(&dir).unwrap();
        for (area, cases) in &self.areas {
            let text = serde_json::to_string_pretty(&Value::Array(cases.clone())).unwrap() + "\n";
            std::fs::write(dir.join(format!("{area}.json")), text).unwrap();
        }
    }
}

/// Replaces the volatile parts of a captured text: the temporary directory, UUIDs and RFC 3339
/// times. The Haskell side applies the same normalisation to its own output.
fn normalise(text: &str, dirs: &[&Path]) -> String {
    let mut text = text.to_string();
    for dir in dirs {
        let canonical = dir.canonicalize().unwrap_or_else(|_| dir.to_path_buf());
        text = text.replace(&canonical.display().to_string(), "/work");
        text = text.replace(&dir.display().to_string(), "/work");
    }
    replace_times(&replace_uuids(&text))
}

fn replace_uuids(text: &str) -> String {
    let bytes: Vec<char> = text.chars().collect();
    let shape = [8, 4, 4, 4, 12];
    let mut out = String::new();
    let mut i = 0;
    'scan: while i < bytes.len() {
        let mut j = i;
        let mut ok = true;
        for (k, n) in shape.iter().enumerate() {
            for _ in 0..*n {
                if j < bytes.len() && bytes[j].is_ascii_hexdigit() && !bytes[j].is_ascii_uppercase() {
                    j += 1;
                } else {
                    ok = false;
                    break;
                }
            }
            if !ok {
                break;
            }
            if k < 4 {
                if j < bytes.len() && bytes[j] == '-' {
                    j += 1;
                } else {
                    ok = false;
                    break;
                }
            }
        }
        if ok && (i == 0 || !bytes[i - 1].is_ascii_alphanumeric()) {
            out.push_str("<uuid>");
            i = j;
            continue 'scan;
        }
        out.push(bytes[i]);
        i += 1;
    }
    out
}

fn replace_times(text: &str) -> String {
    let c: Vec<char> = text.chars().collect();
    let digit = |i: usize| i < c.len() && c[i].is_ascii_digit();
    let at = |i: usize, ch: char| i < c.len() && c[i] == ch;
    let mut out = String::new();
    let mut i = 0;
    while i < c.len() {
        let date = (0..4).all(|k| digit(i + k))
            && at(i + 4, '-')
            && digit(i + 5)
            && digit(i + 6)
            && at(i + 7, '-')
            && digit(i + 8)
            && digit(i + 9)
            && at(i + 10, 'T')
            && digit(i + 11)
            && digit(i + 12)
            && at(i + 13, ':')
            && digit(i + 14)
            && digit(i + 15)
            && at(i + 16, ':')
            && digit(i + 17)
            && digit(i + 18);
        if date {
            let mut j = i + 19;
            if at(j, '.') {
                j += 1;
                while digit(j) {
                    j += 1;
                }
            }
            if at(j, 'Z') {
                j += 1;
            } else if (at(j, '+') || at(j, '-')) && digit(j + 1) && digit(j + 2) && at(j + 3, ':') {
                j += 6;
            }
            out.push_str("<time>");
            i = j;
            continue;
        }
        out.push(c[i]);
        i += 1;
    }
    out
}

fn manifest_result(result: Result<Manifest, ironframe_core::manifest::ManifestError>) -> Value {
    match result {
        Ok(manifest) => {
            let mut levels = serde_json::Map::new();
            for (environment, declared) in &manifest.environments {
                for (dependency, binding) in &declared.dependencies {
                    if let Binding::Twin(twin) = binding {
                        levels.insert(format!("{environment}.{dependency}"), json!(twin.conformance_level()));
                    }
                }
            }
            json!({"ok": serde_json::to_string_pretty(&manifest).unwrap(), "levels": levels})
        }
        Err(error) => json!({
            "error": error.to_string(),
            "problems": error.problems.iter().map(|p| json!({"at": p.at, "message": p.message})).collect::<Vec<_>>(),
        }),
    }
}

fn resolved_json(environment: &ResolvedEnvironment) -> Value {
    json!({
        "project": environment.project,
        "environment": environment.environment,
        "runtime": environment.runtime.as_str(),
        "stack_name": environment.stack_name(),
        "settings": environment.settings(),
        "dependencies": environment.dependencies.iter().map(|d| json!({
            "name": d.name,
            "kind": d.kind.as_str(),
            "endpoint": d.endpoint,
            "image": d.image,
            "ports": d.ports,
            "container_env": d.container_env,
            "stand_in": d.stand_in,
            "credentials": d.credentials,
            "settings": d.settings,
            "admin_url": d.admin_url,
            "admin_port": d.admin_port.map(|(h, c)| json!([h, c])),
            "twin": d.twin.is_some(),
        })).collect::<Vec<_>>(),
    })
}

const SHOP: &str = common::MANIFEST;

fn with_environment(environment: &str) -> String {
    format!(
        "version: 1\nproject: shop\ndependencies:\n  kafka:\n    settings:\n      KAFKA_BOOTSTRAP_SERVERS: ${{endpoint}}\nenvironments:\n  local:\n{}",
        environment.lines().map(|l| format!("    {l}\n")).collect::<String>()
    )
}

fn manifest_with_twin(runtime: &str, twin: &str) -> String {
    let cloud = match runtime {
        "gcp" => "    cloud: {project: p, region: europe-west1}\n",
        "aws" => "    cloud: {region: eu-west-1, vpc_id: v, subnet_ids: [s]}\n",
        _ => "",
    };
    format!(
        "version: 1\nproject: shop\ndependencies:\n  kafka:\n    settings: {{K: '${{endpoint}}'}}\nenvironments:\n  local:\n    runtime: {runtime}\n{cloud}    dependencies:\n      kafka:\n        twin:\n{}",
        twin.lines().map(|l| format!("          {l}\n")).collect::<String>()
    )
}

fn cloud_manifest(runtime: &str, cloud: &str) -> String {
    format!(
        "version: 1\nproject: shop\ndependencies:\n  orders_api:\n    settings: {{ORDERS: '${{endpoint}}'}}\nenvironments:\n  dev:\n    runtime: {runtime}\n    cloud: {cloud}\n    dependencies:\n      orders_api:\n        twin: {{image: lawtwin/http, version: 0.1.0, conformance: L1, ports: [8080], config: {{spec: orders}}}}\n"
    )
}

const GCP_TCP: &str = "version: 1\nproject: shop\ndependencies:\n  kafka:\n    settings: {K: '${endpoint}'}\n  orders:\n    settings: {O: '${endpoint}'}\nenvironments:\n  dev:\n    runtime: gcp\n    cloud: {modules: ../modules, project: p, region: europe-west1, zone: europe-west1-c, cpu: '2', allowed_cidr_blocks: [10.0.0.0/8]}\n    dependencies:\n      kafka:\n        twin: {image: lawtwin/kafka, version: 0.1.0, conformance: answers, ports: [9092], protocol: tcp, seed: 42, advertise_variable: LAWTWIN_ADVERTISE}\n      orders:\n        twin: {image: lawtwin/http, version: 0.1.0, conformance: conformant, ports: [8080], contract: petstore}\n";

const HOSTED: &str = "version: 1\nproject: shop\ndependencies:\n  kafka:\n    settings: {K: '${endpoint}'}\n  db:\n    settings: {D: '${endpoint}'}\nenvironments:\n  local:\n    runtime: podman\n    dependencies:\n      kafka: {real: {endpoint: 'localhost:9092', image: 'apache/kafka:4.1.0', ports: [9092]}}\n      db: {real: {endpoint: 'db.example.com:5432'}}\n";

/// Every manifest text the parse cases read: the tests' own, the examples', and texts that break
/// each schema keyword and each rule across fields.
fn manifest_texts() -> Vec<(&'static str, String)> {
    let example = |name: &str| std::fs::read_to_string(repo().join("examples").join(name).join("ironframe.yaml")).unwrap();
    let twin_k = "twin: {image: lawtwin/kafka, version: 0.1.0, conformance: c, ports: [9092]}";
    let mut texts: Vec<(&'static str, String)> = vec![
        ("shop", SHOP.to_string()),
        ("kafka-app", example("kafka-app")),
        ("petstore-app", example("petstore-app")),
        ("hosted", HOSTED.to_string()),
        ("gcp-tcp", GCP_TCP.to_string()),
        ("cloud-gcp", cloud_manifest("gcp", "{project: shop-dev, region: europe-west1, modules: /m}")),
        ("cloud-azure", cloud_manifest("azure", "{location: westeurope, resource_group_name: shop-dev, modules: /m}")),
        ("cloud-gcp-released", cloud_manifest("gcp", "{project: p, region: r}")),
        (
            "shape-everything",
            "version: 2\nproject: Shop\ndependencies: {}\nenvironments:\n  local:\n    runtime: kubernetes\n    dependencies: {}\n    extra: true\n".into(),
        ),
        ("binding-empty", with_environment("runtime: podman\ndependencies:\n  kafka: {}\n")),
        (
            "binding-both",
            with_environment("runtime: podman\ndependencies:\n  kafka:\n    real: {endpoint: a:1}\n    twin: {image: t, version: '1', conformance: c, ports: [1]}\n"),
        ),
        ("twin-missing", with_environment("runtime: podman\ndependencies:\n  kafka:\n    twin: {image: lawtwin/kafka}\n")),
        (
            "twin-tag",
            with_environment("runtime: podman\ndependencies:\n  kafka:\n    twin: {image: 'lawtwin/kafka:0.1.0', version: 0.1.0, conformance: c, ports: [9092]}\n"),
        ),
        (
            "twin-digest",
            with_environment("runtime: podman\ndependencies:\n  kafka:\n    twin: {image: 'lawtwin/kafka@sha256:00', version: 0.1.0, conformance: c, ports: [9092]}\n"),
        ),
        ("undeclared", with_environment("runtime: podman\ndependencies:\n  redis:\n    real: {endpoint: 'localhost:6379'}\n")),
        (
            "unknown-placeholder",
            "version: 1\nproject: shop\ndependencies:\n  kafka:\n    settings:\n      KAFKA: ${endpiont}\nenvironments:\n  local:\n    runtime: podman\n    dependencies:\n      kafka:\n        real: {endpoint: 'localhost:9092'}\n".into(),
        ),
        (
            "unclosed-placeholder",
            "version: 1\nproject: shop\ndependencies:\n  kafka:\n    settings:\n      KAFKA: 'x${endpoint'\nenvironments:\n  local:\n    runtime: podman\n    dependencies:\n      kafka:\n        real: {endpoint: 'localhost:9092'}\n".into(),
        ),
        (
            "setting-twice",
            "version: 1\nproject: shop\ndependencies:\n  a:\n    settings: {URL: '${endpoint}'}\n  b:\n    settings: {URL: '${endpoint}'}\nenvironments:\n  local:\n    runtime: podman\n    dependencies:\n      a: {real: {endpoint: 'x:1'}}\n      b: {real: {endpoint: 'y:1'}}\n".into(),
        ),
        (
            "credentials-needed",
            "version: 1\nproject: shop\ndependencies:\n  db:\n    settings: {DB_PASSWORD_REF: '${credentials}'}\nenvironments:\n  local:\n    runtime: podman\n    dependencies:\n      db: {real: {endpoint: 'localhost:5432'}}\n".into(),
        ),
        (
            "credentials-scheme",
            "version: 1\nproject: shop\ndependencies:\n  db:\n    settings: {DB_PASSWORD_REF: '${credentials}'}\nenvironments:\n  local:\n    runtime: podman\n    dependencies:\n      db: {real: {endpoint: 'localhost:5432', credentials: 'hunter2'}}\n".into(),
        ),
        (
            "cloud-inputs",
            with_environment(&format!("runtime: aws\ncloud: {{region: us-east-1, subnets: [a]}}\ndependencies:\n  kafka:\n    {twin_k}\n")),
        ),
        ("cloud-missing", with_environment("runtime: aws\ndependencies:\n  kafka:\n    real: {endpoint: 'b:9092'}\n")),
        ("cloud-on-podman", with_environment("runtime: podman\ncloud: {region: x}\ndependencies:\n  kafka:\n    real: {endpoint: 'b:9092'}\n")),
        (
            "real-image-cloud",
            with_environment("runtime: gcp\ncloud: {project: p, region: r}\ndependencies:\n  kafka:\n    real: {endpoint: 'b:9092', image: 'apache/kafka:4.1.0', ports: [9092]}\n"),
        ),
        (
            "real-image-no-ports",
            with_environment("runtime: podman\ndependencies:\n  kafka:\n    real: {endpoint: 'localhost:9092', image: 'apache/kafka:4.1.0'}\n"),
        ),
        (
            "real-ports-no-image",
            with_environment("runtime: podman\ndependencies:\n  kafka:\n    real: {endpoint: 'localhost:9092', ports: [1], env: {A: b}}\n"),
        ),
        ("real-blank-endpoint", with_environment("runtime: podman\ndependencies:\n  kafka:\n    real: {endpoint: '  '}\n")),
        (
            "port-clash",
            "version: 1\nproject: shop\ndependencies:\n  a:\n    settings: {A: '${endpoint}'}\n  b:\n    settings: {B: '${endpoint}'}\nenvironments:\n  local:\n    runtime: podman\n    dependencies:\n      a: {twin: {image: t/a, version: '1', conformance: c, ports: [9092]}}\n      b: {twin: {image: t/b, version: '1', conformance: c, ports: [9092]}}\n".into(),
        ),
        (
            "config-service-port-clash",
            with_environment(&format!("runtime: podman\nconfig_service: {{port: 9092}}\ndependencies:\n  kafka:\n    {twin_k}\n")),
        ),
        (
            "config-service-cloud",
            with_environment(&format!("runtime: gcp\ncloud: {{project: p, region: r}}\nconfig_service: {{}}\ndependencies:\n  kafka:\n    {twin_k}\n")),
        ),
        (
            "cloud-run-ports",
            with_environment("runtime: gcp\ncloud: {project: p, region: r}\ndependencies:\n  kafka:\n    twin: {image: t/k, version: '1', conformance: c, ports: [9092, 9093]}\n"),
        ),
        ("empty-document", String::new()),
        ("version-only", "version: 1\n".into()),
        ("top-level-list", "- a\n- b\n".into()),
        ("not-yaml", "version: 1\nproject: [shop\n".into()),
        ("version-string", "version: '1'\nproject: shop\ndependencies: {}\nenvironments: {}\n".into()),
        ("project-number", "version: 1\nproject: 123\ndependencies: {}\nenvironments:\n  local: {runtime: podman, dependencies: {}}\n".into()),
        (
            "dependency-names",
            "version: 1\nproject: shop\ndependencies:\n  Kafka:\n    settings: {}\n  db:\n    settings: {1BAD: x, OK: 5}\n    other: 1\nenvironments: {}\nextra: 1\n".into(),
        ),
        ("cloud-modules-number", with_environment("runtime: aws\ncloud: {modules: 5, region: r, vpc_id: v, subnet_ids: [s]}\ndependencies:\n  kafka:\n    real: {endpoint: 'b:1'}\n")),
        (
            "real-shapes",
            with_environment("runtime: podman\ndependencies:\n  kafka:\n    real: {endpoint: '', credentials: 'nope', image: '', ports: [0, 70000, a], env: {A: 1}, other: x}\n"),
        ),
        ("real-missing-endpoint", with_environment("runtime: podman\ndependencies:\n  kafka:\n    real: {}\n")),
        (
            "twin-conformance-shapes",
            "version: 1\nproject: shop\ndependencies:\n  a: {settings: {A: x}}\n  b: {settings: {B: x}}\n  c: {settings: {C: x}}\n  d: {settings: {D: x}}\nenvironments:\n  local:\n    runtime: podman\n    dependencies:\n      a: {twin: {image: t/a, version: '1', conformance: {}, ports: [1]}}\n      b: {twin: {image: t/b, version: '1', conformance: 5, ports: [2]}}\n      c: {twin: {image: t/c, version: '1', conformance: {level: ''}, ports: [3]}}\n      d: {twin: {image: t/d, version: '1', conformance: {foo: 1}, ports: [4]}}\n".into(),
        ),
        (
            "twin-field-shapes",
            with_environment("runtime: podman\ndependencies:\n  kafka:\n    twin: {image: t/k, version: '1', conformance: c, ports: [], seed: -1, state: 5, faults: [{}, {name: x, params: {a: 1.5, b: [1]}}], admin: {port: 0, url: '', foo: 1}, protocol: udp, config: [], env: {A: 1}, contract: '', advertise_variable: ''}\n"),
        ),
        ("twin-seed-float", with_environment("runtime: podman\ndependencies:\n  kafka:\n    twin: {image: t/k, version: '1', conformance: c, ports: [1], seed: 1.5}\n")),
        ("twin-state-blank", with_environment("runtime: podman\ndependencies:\n  kafka:\n    twin: {image: t/k, version: '1', conformance: c, ports: [1], state: ''}\n")),
        (
            "sync-shapes",
            with_environment(&format!(
                "runtime: podman\nsync:\n  - {{}}\n  - env_file: {{}}\n  - env_file: {{path: a}}\n    aws_appconfig: {{region: r, application: a, profile: p}}\n  - gcp_parameter_manager: {{project: p, parameter: 'bad name!'}}\n  - azure_app_configuration: {{endpoint: 'http://x'}}\n  - aws_appconfig: {{region: r}}\n  - nope: {{}}\ndependencies:\n  kafka:\n    {twin_k}\n"
            )),
        ),
        (
            "sync-rules",
            with_environment(&format!(
                "runtime: podman\nsync:\n  - env_file: {{path: '  '}}\n  - aws_appconfig: {{region: ' ', application: a, profile: p}}\n  - gcp_parameter_manager: {{project: ' ', location: ' ', parameter: x}}\n  - azure_app_configuration: {{endpoint: 'https:// ', connection_string_env: ' '}}\ndependencies:\n  kafka:\n    {twin_k}\n"
            )),
        ),
        (
            "sync-all-valid",
            with_environment(&format!(
                "runtime: podman\nsync:\n  - env_file: {{path: config/.env}}\n  - aws_appconfig: {{region: eu-west-1, application: shop, environment: Staging-EU, profile: connections, deployment_strategy: AppConfig.Linear50PercentEvery30Seconds}}\n  - gcp_parameter_manager: {{project: shop-prod, parameter: shop-staging}}\n  - gcp_parameter_manager: {{project: shop-prod, location: europe-west1, parameter: shop-eu}}\n  - azure_app_configuration: {{endpoint: 'https://shop.azconfig.io', prefix: 'shop:'}}\n  - azure_app_configuration: {{endpoint: 'https://shop.azconfig.io', label: green, connection_string_env: SHOP_APPCONFIG}}\nconfig_service: {{image: 'ghcr.io/x/config:1', port: 8800}}\ndependencies:\n  kafka:\n    {twin_k}\n"
            )),
        ),
        (
            "config-service-shapes",
            with_environment(&format!("runtime: podman\nconfig_service: {{image: '', port: 0, extra: 1}}\ndependencies:\n  kafka:\n    {twin_k}\n")),
        ),
        ("environments-empty", "version: 1\nproject: shop\ndependencies: {}\nenvironments: {}\n".into()),
        (
            "environment-name",
            "version: 1\nproject: shop\ndependencies: {}\nenvironments:\n  Local: {runtime: podman, dependencies: {}}\n".into(),
        ),
        (
            "twin-rules",
            "version: 1\nproject: shop\ndependencies:\n  a: {settings: {A: x}}\n  b: {settings: {B: x}}\n  c: {settings: {C: x}}\n  d: {settings: {D: x}}\nenvironments:\n  local:\n    runtime: podman\n    dependencies:\n      a: {twin: {image: t/a, version: ' ', conformance: ' ', ports: [1], contract: ' ', env: {TWIN_CONFIG: x}}}\n      b: {twin: {image: t/b, version: '1', conformance: {level: ' ', image_label: ' '}, ports: [2], admin: {url: 'ftp://x'}, state: ' '}}\n      c: {twin: {image: t/c, version: '1', conformance: c, ports: [3, 9644], admin: {}, faults: [{name: ' '}]}}\n      d: {twin: {image: t/d, version: '1', conformance: c, ports: [4], seed: 1, contract: k, config: {seed: 2, contract: j}, advertise_variable: 1X, env: {1X: y}}}\n".into(),
        ),
        (
            "twin-cloud-rules",
            "version: 1\nproject: shop\ndependencies:\n  a: {settings: {A: x}}\n  b: {settings: {B: x}}\nenvironments:\n  stage:\n    runtime: aws\n    cloud: {region: r, vpc_id: v, subnet_ids: [s]}\n    dependencies:\n      a: {twin: {image: t/a, version: '1', conformance: c, ports: [1], admin: {}, state: {x: 1}, faults: [{name: f}], advertise_variable: ADV}}\n      b: {twin: {image: t/b, version: '1', conformance: c, ports: [2], admin: {url: 'https://admin.example/'}, state: s.json, protocol: tcp}}\n".into(),
        ),
        (
            "twin-config-json",
            with_environment("runtime: podman\ndependencies:\n  kafka:\n    twin: {image: t/k, version: '1', conformance: c, ports: [1], seed: 18446744073709551615, contract: k, config: {clock: frozen, ratio: 0.5, big: 1e3, n: -3, flag: true, none: null, list: [1, 'a', 2.25], nested: {z: 1, a: 2}, unicode: \"caf\u{e9} \\u2603\", quote: 'say \"hi\"'}}\n"),
        ),
        (
            "yaml-scalars",
            "version: 1\nproject: shop\ndependencies:\n  kafka:\n    description: yes\n    settings: {K: '${endpoint}', ON: on, NUM: '1'}\nenvironments:\n  local:\n    runtime: podman\n    dependencies:\n      kafka: {real: {endpoint: \"host:9092\", env: {}}}\n".into(),
        ),
        (
            "yaml-anchor",
            "version: 1\nproject: shop\ndependencies:\n  kafka:\n    settings: &s {K: '${endpoint}'}\nenvironments:\n  a: &e\n    runtime: podman\n    dependencies:\n      kafka: {real: {endpoint: 'x:1'}}\n  b: *e\n".into(),
        ),
        (
            "all-placeholders",
            "version: 1\nproject: shop\ndependencies:\n  api:\n    settings: {E: '${endpoint}', H: '${host}', P: '${port}', C: '${credentials}', K: '${kind}', N: '${name}', MIX: 'pre-${host}-${port}-post', PLAIN: literal}\nenvironments:\n  local:\n    runtime: podman\n    dependencies:\n      api: {real: {endpoint: 'https://user@api.example.com/v1?x=1', credentials: 'vault:kv/api'}}\n  noport:\n    runtime: podman\n    dependencies:\n      api: {real: {endpoint: 'broker', credentials: 'env:X'}}\n".into(),
        ),
        (
            "advertise-podman",
            manifest_with_twin(
                "podman",
                "image: lawtwin/http\nversion: 0.1.0\nconformance: conformant\nports: [8080]\nseed: 7\ncontract: petstore\nconfig: {clock: frozen}\nadvertise_variable: LAWTWIN_ADVERTISE",
            ),
        ),
        (
            "advertise-pinned",
            manifest_with_twin(
                "podman",
                "image: lawtwin/http\nversion: 0.1.0\nconformance: conformant\nports: [8080]\nendpoint: 'http://twin.local'\nadvertise_variable: LAWTWIN_ADVERTISE",
            ),
        ),
        (
            "advertise-aws",
            manifest_with_twin("aws", "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092]\nadvertise_variable: LAWTWIN_ADVERTISE"),
        ),
        (
            "advertise-gcp-tcp",
            manifest_with_twin(
                "gcp",
                "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092, 9093]\nprotocol: tcp\nadvertise_variable: LAWTWIN_ADVERTISE",
            ),
        ),
        (
            "advertise-gcp-http",
            manifest_with_twin(
                "gcp",
                "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092, 9093]\nprotocol: http\nadvertise_variable: LAWTWIN_ADVERTISE",
            ),
        ),
        (
            "state-needs-admin",
            manifest_with_twin(
                "podman",
                "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092]\nstate: {topics: []}\nfaults: [{name: consumer-lag}]",
            ),
        ),
        (
            "state-with-admin",
            manifest_with_twin(
                "podman",
                "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092]\nadmin: {port: 9644}\nstate: {topics: []}\nfaults: [{name: consumer-lag, params: {lag: 5, topic: orders}}]",
            ),
        ),
        (
            "admin-port-in-ports",
            manifest_with_twin("podman", "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092, 9644]\nadmin: {}"),
        ),
        (
            "admin-port-clash",
            manifest_with_twin("podman", "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092]\nadmin: {port: 9092}"),
        ),
        (
            "admin-cloud-no-url",
            manifest_with_twin("aws", "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092]\nadmin: {}\nfaults: [{name: x}]"),
        ),
        (
            "seed-twice",
            manifest_with_twin("podman", "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092]\nseed: 1\nconfig: {seed: 2}"),
        ),
        (
            "seed-same",
            manifest_with_twin("podman", "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092]\nseed: 2\nconfig: {seed: 2, contract: x}\ncontract: x"),
        ),
        (
            "label-conformance",
            manifest_with_twin("podman", "image: lawtwin/kafka\nversion: 0.1.0\nconformance: {image_label: io.lawtwin.conformance}\nports: [19092]"),
        ),
        (
            "admin-url-podman",
            manifest_with_twin("podman", "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092]\nadmin: {url: 'http://127.0.0.1:1/', port: 7000, container_port: 7001}"),
        ),
        (
            "admin-podman-ports",
            manifest_with_twin("podman", "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092]\nadmin: {port: 9700, container_port: 9644}\nenv: {LOG: debug, A: b}"),
        ),
    ];
    texts.push((
        "azure-cloud",
        with_environment(&format!(
            "runtime: azure\ncloud: {{location: westeurope, resource_group_name: rg, subscription_id: sub, transport: tcp, external: true, infrastructure_subnet_id: s, cpu: 0.5, memory: 1Gi}}\ndependencies:\n  kafka:\n    {twin_k}\n"
        )),
    ));
    texts.push((
        "gcp-unknown-input",
        with_environment(&format!("runtime: gcp\ncloud: {{project: p, region: r, vpc_id: x}}\ndependencies:\n  kafka:\n    {twin_k}\n")),
    ));
    texts
}

/// A command runner that answers from a function and logs every call with its answer.
#[derive(Clone)]
struct Logged {
    log: Arc<Mutex<Vec<Value>>>,
    answer: Arc<dyn Fn(&[String]) -> CommandOutput + Send + Sync>,
}

impl Logged {
    fn new(answer: impl Fn(&[String]) -> CommandOutput + Send + Sync + 'static) -> Self {
        Logged { log: Arc::default(), answer: Arc::new(answer) }
    }
    fn log(&self, dirs: &[&Path]) -> Value {
        Value::Array(
            self.log
                .lock()
                .unwrap()
                .iter()
                .map(|v| serde_json::from_str(&normalise(&v.to_string(), dirs)).unwrap())
                .collect(),
        )
    }
}

impl CommandRunner for Logged {
    fn run(&self, program: &Path, args: &[String], stream: bool) -> std::io::Result<CommandOutput> {
        let output = (self.answer)(args);
        self.log.lock().unwrap().push(json!({
            "program": program.display().to_string(),
            "args": args,
            "stream": stream,
            "success": output.success,
            "stdout": output.stdout,
            "stderr": output.stderr,
        }));
        Ok(output)
    }
}

fn ok(stdout: &str) -> CommandOutput {
    CommandOutput { success: true, stdout: stdout.into(), stderr: String::new() }
}

fn failed(stderr: &str) -> CommandOutput {
    CommandOutput { success: false, stdout: String::new(), stderr: stderr.into() }
}

/// Cloud clients that behave as the tests' fakes and log every call with its result.
#[derive(Clone, Default)]
struct LoggedClouds {
    log: Arc<Mutex<Vec<Value>>>,
    aws: Arc<common::FakeAppConfig>,
    gcp: Arc<common::FakeParameterManager>,
    azure: Arc<common::FakeAppConfiguration>,
}

struct LogAws(Arc<Mutex<Vec<Value>>>, Arc<common::FakeAppConfig>, String);
struct LogGcp(Arc<Mutex<Vec<Value>>>, Arc<common::FakeParameterManager>);
struct LogAzure(Arc<Mutex<Vec<Value>>>, Arc<common::FakeAppConfiguration>, String, String);

fn record(log: &Arc<Mutex<Vec<Value>>>, call: Value) {
    log.lock().unwrap().push(call);
}

#[async_trait::async_trait]
impl AppConfigApi for LogAws {
    async fn find_application(&self, name: &str) -> Result<Option<String>, String> {
        let r = self.1.find_application(name).await;
        record(&self.0, json!({"effect": "aws.findApplication", "region": self.2, "name": name, "result": r}));
        r
    }
    async fn create_application(&self, name: &str) -> Result<String, String> {
        let r = self.1.create_application(name).await;
        record(&self.0, json!({"effect": "aws.createApplication", "region": self.2, "name": name, "result": r}));
        r
    }
    async fn find_environment(&self, a: &str, n: &str) -> Result<Option<String>, String> {
        let r = self.1.find_environment(a, n).await;
        record(&self.0, json!({"effect": "aws.findEnvironment", "region": self.2, "application": a, "name": n, "result": r}));
        r
    }
    async fn create_environment(&self, a: &str, n: &str) -> Result<String, String> {
        let r = self.1.create_environment(a, n).await;
        record(&self.0, json!({"effect": "aws.createEnvironment", "region": self.2, "application": a, "name": n, "result": r}));
        r
    }
    async fn find_profile(&self, a: &str, n: &str) -> Result<Option<String>, String> {
        let r = self.1.find_profile(a, n).await;
        record(&self.0, json!({"effect": "aws.findProfile", "region": self.2, "application": a, "name": n, "result": r}));
        r
    }
    async fn create_profile(&self, a: &str, n: &str) -> Result<String, String> {
        let r = self.1.create_profile(a, n).await;
        record(&self.0, json!({"effect": "aws.createProfile", "region": self.2, "application": a, "name": n, "result": r}));
        r
    }
    async fn latest_version(&self, a: &str, p: &str) -> Result<Option<(i32, Vec<u8>)>, String> {
        let r = self.1.latest_version(a, p).await;
        let shown = r.as_ref().map(|v| {
            v.as_ref().map(|(n, c)| json!({"number": n, "content": String::from_utf8_lossy(c)}))
        });
        record(&self.0, json!({"effect": "aws.latestVersion", "region": self.2, "application": a, "profile": p, "result": shown}));
        r
    }
    async fn create_version(&self, a: &str, p: &str, c: Vec<u8>) -> Result<i32, String> {
        let text = String::from_utf8_lossy(&c).into_owned();
        let r = self.1.create_version(a, p, c).await;
        record(&self.0, json!({"effect": "aws.createVersion", "region": self.2, "application": a, "profile": p, "content": text, "result": r}));
        r
    }
    async fn deploy(&self, a: &str, e: &str, p: &str, v: i32, s: &str) -> Result<i32, String> {
        let r = self.1.deploy(a, e, p, v, s).await;
        record(&self.0, json!({"effect": "aws.deploy", "region": self.2, "application": a, "environment": e, "profile": p, "version": v, "strategy": s, "result": r}));
        r
    }
}

#[async_trait::async_trait]
impl ParameterManagerApi for LogGcp {
    async fn parameter_exists(&self, n: &str) -> Result<bool, String> {
        let r = self.1.parameter_exists(n).await;
        record(&self.0, json!({"effect": "gcp.parameterExists", "name": n, "result": r}));
        r
    }
    async fn create_parameter(&self, p: &str, i: &str) -> Result<(), String> {
        let r = self.1.create_parameter(p, i).await;
        record(&self.0, json!({"effect": "gcp.createParameter", "parent": p, "id": i, "result": r}));
        r
    }
    async fn create_version(&self, p: &str, i: &str, d: Vec<u8>) -> Result<VersionCreated, String> {
        let text = String::from_utf8_lossy(&d).into_owned();
        let r = self.1.create_version(p, i, d).await;
        let shown = r.as_ref().map(|c| if *c == VersionCreated::Created { "created" } else { "exists" });
        record(&self.0, json!({"effect": "gcp.createVersion", "parameter": p, "id": i, "data": text, "result": shown}));
        r
    }
}

#[async_trait::async_trait]
impl AppConfigurationApi for LogAzure {
    async fn get(&self, k: &str, l: &str) -> Result<Option<String>, String> {
        let r = self.1.get(k, l).await;
        record(&self.0, json!({"effect": "azure.get", "endpoint": self.2, "connectionStringEnv": self.3, "key": k, "label": l, "result": r}));
        r
    }
    async fn put(&self, k: &str, l: &str, v: &str) -> Result<(), String> {
        let r = self.1.put(k, l, v).await;
        record(&self.0, json!({"effect": "azure.put", "endpoint": self.2, "connectionStringEnv": self.3, "key": k, "label": l, "value": v, "result": r}));
        r
    }
}

#[async_trait::async_trait]
impl Clouds for LoggedClouds {
    async fn aws(&self, region: &str) -> Result<Box<dyn AppConfigApi>, String> {
        Ok(Box::new(LogAws(self.log.clone(), self.aws.clone(), region.into())))
    }
    async fn gcp(&self) -> Result<Box<dyn ParameterManagerApi>, String> {
        Ok(Box::new(LogGcp(self.log.clone(), self.gcp.clone())))
    }
    async fn azure(&self, endpoint: &str, env: &str) -> Result<Box<dyn AppConfigurationApi>, String> {
        Ok(Box::new(LogAzure(self.log.clone(), self.azure.clone(), endpoint.into(), env.into())))
    }
}

fn outcome_json(outcome: &SyncOutcome) -> Value {
    match outcome {
        SyncOutcome::Unchanged => json!({"unchanged": true}),
        SyncOutcome::Updated(detail) => json!({"updated": detail}),
    }
}

/// Every file under `dir`, by path relative to it, normalised.
fn files_under(dir: &Path, dirs: &[&Path]) -> BTreeMap<String, String> {
    let mut found = BTreeMap::new();
    fn walk(root: &Path, at: &Path, found: &mut BTreeMap<String, String>, dirs: &[&Path]) {
        let Ok(entries) = std::fs::read_dir(at) else { return };
        for entry in entries {
            let entry = entry.unwrap();
            let path = entry.path();
            if path.is_dir() {
                walk(root, &path, found, dirs);
            } else {
                let relative = path.strip_prefix(root).unwrap().display().to_string();
                let text = std::fs::read_to_string(&path).unwrap_or_default();
                found.insert(relative, normalise(&text, dirs));
            }
        }
    }
    walk(dir, dir, &mut found, dirs);
    found
}

/// A fake twin control plane that logs every request and its answer, as LawTwin's answers.
#[derive(Clone, Default)]
struct FakeTwin {
    log: Arc<Mutex<Vec<Value>>>,
    seed: Arc<Mutex<u64>>,
    history: Arc<Mutex<Vec<String>>>,
}

impl FakeTwin {
    async fn serve(self) -> String {
        use axum::body::Bytes;
        use axum::extract::State;
        use axum::http::{Method, StatusCode, Uri};
        use axum::response::IntoResponse;
        async fn handle(State(t): State<FakeTwin>, method: Method, uri: Uri, body: Bytes) -> axum::response::Response {
            let body = String::from_utf8_lossy(&body).into_owned();
            let path = uri.path().to_string();
            let query = uri.query().unwrap_or("").to_string();
            let (status, answer): (u16, String) = match (method.as_str(), path.as_str()) {
                ("GET", "/healthz") => (200, "ok".into()),
                ("GET", "/v1/twin") => {
                    let seed = *t.seed.lock().unwrap();
                    (200, json!({"twin": "fake", "version": "0.1.0", "contract": {}, "seed": seed, "clock": {"mode": "frozen", "nowMs": 0}, "bootstrap": "localhost:1"}).to_string())
                }
                ("POST", "/v1/seed") => {
                    let value: Value = serde_json::from_str(&body).unwrap();
                    *t.seed.lock().unwrap() = value["seed"].as_u64().unwrap();
                    (200, json!({"seed": value["seed"], "reset": true}).to_string())
                }
                ("POST", "/v1/state") => {
                    if body.contains("impossible") {
                        (422, json!({"forced": false, "law": "partitions only grow", "reason": "3 cannot become 2"}).to_string())
                    } else {
                        t.history.lock().unwrap().push(r#"{"seq":1,"source":"force"}"#.into());
                        (200, json!({"forced": true, "operations": 1}).to_string())
                    }
                }
                ("POST", p) if p.starts_with("/v1/faults/") => {
                    let name = p.trim_start_matches("/v1/faults/");
                    if name == "undeclared" {
                        (400, json!({"error": "no fault undeclared"}).to_string())
                    } else {
                        (201, json!({"id": 1, "name": name}).to_string())
                    }
                }
                ("GET", "/v1/history") => {
                    let history = t.history.lock().unwrap().clone();
                    if query.contains("format=jsonl") {
                        (200, history.iter().map(|l| format!("{l}\n")).collect())
                    } else {
                        (200, format!("[{}]", history.join(",")))
                    }
                }
                ("GET", "/v1/state") => (200, r#"{"topics":[],"records":0}"#.into()),
                ("GET", "/v1/faults") => (200, r#"{"declared":["latency"],"active":[]}"#.into()),
                ("DELETE", "/v1/faults") => (200, r#"{"cleared":2}"#.into()),
                ("DELETE", p) if p.starts_with("/v1/faults/") => (404, r#"{"error":"no active fault x"}"#.into()),
                ("POST", "/v1/clock/advance") => (200, r#"{"nowMs":5000}"#.into()),
                ("DELETE", "/v1/reset") => (200, r#"{"reset":true}"#.into()),
                ("POST", "/v1/history/replay") => (200, r#"{"divergences":[],"violations":{"state":[],"history":[]}}"#.into()),
                ("GET", "/v1/laws") => (200, r#"{"holds":false,"laws":[]}"#.into()),
                ("GET", "/v1/seed") => (200, "not json".into()),
                _ => (404, String::new()),
            };
            let target = if query.is_empty() { path.clone() } else { format!("{path}?{query}") };
            t.log.lock().unwrap().push(json!({"method": method.as_str(), "path": target, "body": body, "status": status, "response": answer}));
            (StatusCode::from_u16(status).unwrap(), answer).into_response()
        }
        let app = axum::Router::new().fallback(handle).with_state(self);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        url
    }

    fn log(&self, url: &str) -> Value {
        let text = Value::Array(self.log.lock().unwrap().clone()).to_string().replace(url, "http://twin.test");
        serde_json::from_str(&text).unwrap()
    }
}

fn manifests(corpus: &mut Corpus) {
    for (name, text) in manifest_texts() {
        corpus.add("manifest", name, "manifest.parse", json!({"text": text}), manifest_result(Manifest::parse(&text)));
    }
    let shop = common::manifest();
    for environment in ["local", "staging", "production"] {
        let result = match shop.environment(environment) {
            Ok(_) => json!({"ok": true}),
            Err(error) => json!({"error": error.to_string()}),
        };
        corpus.add("manifest", "environment", "manifest.environment", json!({"text": SHOP, "environment": environment}), result);
    }
    // Loading reads conformance reports beside the manifest.
    const KAFKA_REPORT: &str = r#"{"twin": "kafka", "release": "0.1.0", "contract": {"package": "lawtwin.kafka", "version": "0.1.0"},
  "level": {"number": 3, "name": "answers", "means": "..."}}"#;
    const HTTP_REPORT: &str = r#"{"contract": "lawtwin.petstore", "real": {}, "divergences": [], "level": "conformant"}"#;
    let loads: Vec<(&str, String, Vec<(&str, &str)>)> = vec![
        ("report", manifest_with_twin("podman", "image: lawtwin/kafka\nversion: 0.1.0\nconformance: {report: report.json}\nports: [9092]"), vec![("report.json", KAFKA_REPORT)]),
        ("report-number", manifest_with_twin("podman", "image: lawtwin/kafka\nversion: 0.1.0\nconformance: {level: '3', report: report.json}\nports: [9092]"), vec![("report.json", KAFKA_REPORT)]),
        ("report-both", manifest_with_twin("podman", "image: lawtwin/kafka\nversion: 0.1.0\nconformance: {level: 3-Answers, report: report.json}\nports: [9092]"), vec![("report.json", KAFKA_REPORT)]),
        ("report-level-differs", manifest_with_twin("podman", "image: lawtwin/kafka\nversion: 0.1.0\nconformance: {level: exact, report: report.json}\nports: [9092]"), vec![("report.json", KAFKA_REPORT)]),
        ("report-release", manifest_with_twin("podman", "image: lawtwin/kafka\nversion: 0.2.0\nconformance: {report: report.json}\nports: [9092]"), vec![("report.json", KAFKA_REPORT)]),
        ("report-twin", manifest_with_twin("podman", "image: lawtwin/http\nversion: 0.1.0\nconformance: {report: report.json}\nports: [9092]"), vec![("report.json", KAFKA_REPORT)]),
        ("report-contract", manifest_with_twin("podman", "image: lawtwin/http\nversion: 0.1.0\ncontract: github\nconformance: {report: report.json}\nports: [8080]"), vec![("report.json", HTTP_REPORT)]),
        ("report-contract-ok", manifest_with_twin("podman", "image: lawtwin/http\nversion: 0.1.0\ncontract: petstore\nconformance: {report: report.json}\nports: [8080]"), vec![("report.json", HTTP_REPORT)]),
        ("report-missing", manifest_with_twin("podman", "image: lawtwin/kafka\nversion: 0.1.0\nconformance: {report: nowhere.json}\nports: [9092]"), vec![]),
        ("report-not-json", manifest_with_twin("podman", "image: lawtwin/kafka\nversion: 0.1.0\nconformance: {report: report.json}\nports: [9092]"), vec![("report.json", "{not json")]),
        ("report-no-level", manifest_with_twin("podman", "image: lawtwin/kafka\nversion: 0.1.0\nconformance: {report: report.json}\nports: [9092]"), vec![("report.json", r#"{"twin": "kafka"}"#)]),
        ("report-empty-level", manifest_with_twin("podman", "image: lawtwin/kafka\nversion: 0.1.0\nconformance: {report: report.json}\nports: [9092]"), vec![("report.json", r#"{"level": " "}"#)]),
        ("report-level-no-name", manifest_with_twin("podman", "image: lawtwin/kafka\nversion: 0.1.0\nconformance: {report: report.json}\nports: [9092]"), vec![("report.json", r#"{"level": {"number": 2}}"#)]),
        ("report-subdir", manifest_with_twin("podman", "image: lawtwin/kafka\nversion: 0.1.0\nconformance: {report: conformance/k.json}\nports: [9092]"), vec![("conformance/k.json", KAFKA_REPORT)]),
        ("only-header", "version: 1\n".to_string(), vec![]),
    ];
    for (name, text, files) in loads {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("ironframe.yaml");
        std::fs::write(&path, &text).unwrap();
        let mut given = serde_json::Map::new();
        given.insert("/work/ironframe.yaml".into(), json!(text));
        for (file, contents) in &files {
            let at = directory.path().join(file);
            std::fs::create_dir_all(at.parent().unwrap()).unwrap();
            std::fs::write(&at, contents).unwrap();
            given.insert(format!("/work/{file}"), json!(contents));
        }
        let result = manifest_result(Manifest::load(&path));
        let result: Value = serde_json::from_str(&normalise(&result.to_string(), &[directory.path()])).unwrap();
        corpus.add("manifest", name, "manifest.load", json!({"path": "/work/ironframe.yaml", "files": given}), result);
    }
    let directory = tempfile::tempdir().unwrap();
    let result = manifest_result(Manifest::load(&directory.path().join("nope.yaml")));
    let result: Value = serde_json::from_str(&normalise(&result.to_string(), &[directory.path()])).unwrap();
    corpus.add("manifest", "missing-file", "manifest.load", json!({"path": "/work/nope.yaml", "files": {}}), result);
    // A relative manifest path with no directory part.
    corpus.add(
        "manifest",
        "placeholders",
        "manifest.placeholders",
        json!({"template": "a${endpoint}b${host}${port}"}),
        json!({"ok": ironframe_core::manifest::placeholders("a${endpoint}b${host}${port}").unwrap()}),
    );
    for template in ["plain", "${", "x${a}${", "${}", "$endpoint}"] {
        let result = match ironframe_core::manifest::placeholders(template) {
            Ok(names) => json!({"ok": names}),
            Err(error) => json!({"error": error}),
        };
        corpus.add("manifest", "placeholders", "manifest.placeholders", json!({"template": template}), result);
    }
}

fn settings(corpus: &mut Corpus) {
    let deployed_kafka = BTreeMap::from([("kafka".to_string(), "kafka-nlb.elb.amazonaws.com:9092".to_string())]);
    let mut resolves: Vec<(&str, String, &str, BTreeMap<String, String>)> = vec![
        ("shop-local", SHOP.into(), "local", BTreeMap::new()),
        ("shop-staging-undeployed", SHOP.into(), "staging", BTreeMap::new()),
        ("shop-staging-deployed", SHOP.into(), "staging", deployed_kafka.clone()),
        ("shop-unknown", SHOP.into(), "production", BTreeMap::new()),
        ("hosted", HOSTED.into(), "local", BTreeMap::new()),
        ("gcp-tcp-deployed", GCP_TCP.into(), "dev", BTreeMap::from([("kafka".into(), "10.0.0.5:9092".into()), ("orders".into(), "https://orders-xyz.run.app".into())])),
    ];
    for (name, text) in manifest_texts() {
        if Manifest::parse(&text).is_ok() && !["shop", "hosted", "gcp-tcp"].contains(&name) {
            let manifest = Manifest::parse(&text).unwrap();
            for environment in manifest.environments.keys() {
                resolves.push((name, text.clone(), Box::leak(environment.clone().into_boxed_str()), BTreeMap::new()));
            }
        }
    }
    resolves.push(("all-placeholders-deployed", manifest_texts().into_iter().find(|(n, _)| *n == "all-placeholders").unwrap().1, "local", deployed_kafka));
    for (name, text, environment, deployed) in resolves {
        let manifest = Manifest::parse(&text).unwrap();
        let result = match resolve(&manifest, environment, &deployed) {
            Ok(resolved) => json!({"ok": resolved_json(&resolved)}),
            Err(error) => json!({"error": error.to_string()}),
        };
        corpus.add(
            "settings",
            name,
            "settings.resolve",
            json!({"text": text, "environment": environment, "deployed": deployed}),
            result,
        );
    }
    for endpoint in [
        "localhost:9092",
        "https://user@api.example.com/v1?x=1",
        "http://api.example.com",
        "broker",
        "https://api.example.com:8443/x",
        "http://[::1]:80",
        "tcp://host:notaport",
        "host:99999",
        "a@b:1#frag",
        "ftp://files.example.com/x",
        "",
    ] {
        let (host, port) = split_endpoint(endpoint);
        corpus.add("settings", "split", "endpoint.split", json!({"endpoint": endpoint}), json!({"host": host, "port": port}));
    }
    for image in [
        "apache/kafka:4.1.0",
        "redis:7",
        "redis",
        "ghcr.io/brain-fuel/x:1",
        "localhost/ironframe-config-service:0.1.0",
        "registry:5000/team/x:1",
        "lawtwin/kafka",
        "a/b/c:1",
        "docker.io/library/x",
    ] {
        corpus.add("settings", "qualify", "image.qualify", json!({"image": image}), json!(qualify_image(image)));
    }
    let dotenv = BTreeMap::from([
        ("PLAIN".to_string(), "localhost:9092,localhost:9093".to_string()),
        ("SPACED".to_string(), "a value with # and \"quotes\"".to_string()),
        ("DOLLAR".to_string(), "$HOME\\path".to_string()),
        ("EMPTY".to_string(), String::new()),
        ("NEWLINE".to_string(), "two\nlines".to_string()),
        ("UNICODE".to_string(), "caf\u{e9}".to_string()),
        ("URL".to_string(), "https://user@host:1/a_b.c+d-e".to_string()),
    ]);
    for header in ["header line one\nline two", "", "one"] {
        let text = render_dotenv(header, &dotenv);
        corpus.add("settings", "dotenv-render", "dotenv.render", json!({"header": header, "settings": dotenv}), json!(text));
    }
    for text in [
        render_dotenv("h", &dotenv),
        "# c\n\nA=1\n  B = two  \nC=\"q\\\"x\\n\\\\\"\nnoequals\nD=\"\nE=\"a\\\"\n=empty\nF=\"un\\".to_string(),
    ] {
        corpus.add("settings", "dotenv-parse", "dotenv.parse", json!({"text": text}), json!(parse_dotenv(&text)));
    }
}

fn compose(corpus: &mut Corpus) {
    let texts = manifest_texts();
    let shop_service = ConfigService { image: "localhost/ironframe-config-service:0.1.0".into(), port: 8700 };
    let mut cases: Vec<(&str, String, String, Option<ConfigService>)> = vec![
        ("shop", SHOP.into(), "local".into(), None),
        ("shop-config-service", SHOP.into(), "local".into(), Some(shop_service)),
        ("hosted", HOSTED.into(), "local".into(), None),
    ];
    for (name, text) in &texts {
        let Ok(manifest) = Manifest::parse(text) else { continue };
        for (environment, declared) in &manifest.environments {
            if !declared.runtime.is_cloud() {
                cases.push((name, text.clone(), environment.clone(), declared.config_service.clone()));
            }
        }
    }
    for (name, text, environment, service) in cases {
        let manifest = Manifest::parse(&text).unwrap();
        let Ok(resolved) = resolve(&manifest, &environment, &BTreeMap::new()) else { continue };
        let path = Path::new("/work/.ironframe").join(&environment).join("settings.json");
        let output = ironframe_core::compose::compose_file(&resolved, service.as_ref().map(|s| (s, path.as_path())));
        corpus.add(
            "compose",
            name,
            "compose.file",
            json!({"text": text, "environment": environment, "configService": service.map(|s| json!({"image": s.image, "port": s.port})), "settingsPath": path.display().to_string()}),
            json!(output),
        );
    }
}

fn tofu(corpus: &mut Corpus) {
    let mut cases: Vec<(&str, String, String, &str)> = vec![
        ("shop-staging", SHOP.into(), "staging".into(), "/work/app"),
        ("shop-local", SHOP.into(), "local".into(), "/work/app"),
        ("shop-unknown", SHOP.into(), "production".into(), "/work/app"),
        ("gcp-tcp", GCP_TCP.into(), "dev".into(), "/work/app"),
        ("kafka-app-relative", std::fs::read_to_string(repo().join("examples/kafka-app/ironframe.yaml")).unwrap(), "staging".into(), "relative/dir"),
    ];
    for (name, text) in manifest_texts() {
        let Ok(manifest) = Manifest::parse(&text) else { continue };
        for (environment, declared) in &manifest.environments {
            if declared.runtime.is_cloud() {
                cases.push((name, text.clone(), environment.clone(), "/w"));
            }
        }
    }
    for (name, text, environment, dir) in cases {
        let manifest = Manifest::parse(&text).unwrap();
        let result = match root_module(&manifest, &environment, Path::new(dir)) {
            Ok(root) => json!({"ok": serde_json::to_string_pretty(&root).unwrap() + "\n"}),
            Err(error) => json!({"error": error.to_string()}),
        };
        corpus.add("tofu", name, "tofu.root", json!({"text": text, "environment": environment, "manifestDir": dir}), result);
    }
    for (base, module, dir) in [
        (RELEASED_MODULES, "aws-ecs-fargate", "/"),
        ("git::ssh://git@example.com/m.git//modules", "x", "/"),
        ("../modules", "gcp-cloud-run", "/work/app"),
        ("/abs/modules/", "azure-container-apps", "/work/app"),
        ("modules", "x", "relative"),
        ("github.com/org/repo//modules?ref=v1", "x", "/"),
        ("https://example.com/m.zip//modules/", "x", "/"),
        ("./m", "x", "/work/app/"),
    ] {
        corpus.add(
            "tofu",
            "module-source",
            "tofu.moduleSource",
            json!({"base": base, "module": module, "manifestDir": dir}),
            json!(module_source(base, module, Path::new(dir))),
        );
    }
    for (p, e, d) in [("shop", "dev", "orders_api"), ("a_b", "c_d", "e-f")] {
        corpus.add("tofu", "deployment-name", "tofu.deploymentName", json!({"project": p, "environment": e, "dependency": d}), json!(deployment_name(p, e, d)));
    }
}

fn sync(corpus: &mut Corpus, runtime: &tokio::runtime::Runtime) {
    let settings = |bootstrap: &str| {
        BTreeMap::from([
            ("KAFKA_BOOTSTRAP_SERVERS".to_string(), bootstrap.to_string()),
            ("PAYMENTS_URL".to_string(), "https://payments.example.com".to_string()),
        ])
    };
    // Each flow: one target synced several times over shared fake state.
    let targets = [
        ("aws", "aws_appconfig: {region: eu-west-1, application: shop, profile: connections}"),
        ("aws-named", "aws_appconfig: {region: eu-west-1, application: shop, environment: Staging-EU, profile: connections, deployment_strategy: AppConfig.Linear50PercentEvery30Seconds}"),
        ("gcp", "gcp_parameter_manager: {project: shop-prod, parameter: shop-staging}"),
        ("gcp-located", "gcp_parameter_manager: {project: shop-prod, location: europe-west1, parameter: shop-eu}"),
        ("azure", "azure_app_configuration: {endpoint: 'https://shop.azconfig.io', prefix: 'shop:'}"),
        ("azure-labelled", "azure_app_configuration: {endpoint: 'https://shop.azconfig.io', label: green, connection_string_env: SHOP_APPCONFIG}"),
    ];
    for (name, target) in targets {
        let text = format!(
            "version: 1\nproject: shop\ndependencies:\n  kafka:\n    settings: {{KAFKA_BOOTSTRAP_SERVERS: '${{endpoint}}'}}\n  payments:\n    settings: {{PAYMENTS_URL: '${{endpoint}}'}}\nenvironments:\n  staging:\n    runtime: podman\n    dependencies:\n      kafka: {{real: {{endpoint: 'k:9092'}}}}\n      payments: {{real: {{endpoint: 'https://payments.example.com'}}}}\n    sync:\n      - {target}\n"
        );
        let manifest = Manifest::parse(&text).unwrap();
        let clouds = LoggedClouds::default();
        let mut steps = Vec::new();
        for bootstrap in ["k:9092", "k:9092", "k2:9092"] {
            let mut environment = resolve(&manifest, "staging", &BTreeMap::new()).unwrap();
            for d in &mut environment.dependencies {
                if d.name == "kafka" {
                    d.settings.insert("KAFKA_BOOTSTRAP_SERVERS".into(), bootstrap.into());
                }
            }
            let done = runtime
                .block_on(ops::sync_environment(&manifest, Path::new("/work"), &environment, &clouds))
                .unwrap();
            steps.push(json!({
                "settings": settings(bootstrap),
                "outcomes": done.iter().map(|(t, o)| json!({"target": t, "outcome": outcome_json(o)})).collect::<Vec<_>>(),
            }));
        }
        let log = clouds.log.lock().unwrap().clone();
        corpus.add("sync", name, "sync.flow", json!({"text": text, "environment": "staging"}), json!({"steps": steps, "effects": log}));
    }
    let content = settings_json(&settings("k:9092"));
    corpus.add("sync", "settings-json", "sync.settingsJson", json!({"settings": settings("k:9092")}), json!(String::from_utf8(content.clone()).unwrap()));
    corpus.add("sync", "settings-json-empty", "sync.settingsJson", json!({"settings": {}}), json!(String::from_utf8(settings_json(&BTreeMap::new())).unwrap()));
    corpus.add("sync", "version-id", "gcp.versionId", json!({"content": String::from_utf8(content.clone()).unwrap()}), json!(version_id(&content)));
    let manifest = Manifest::parse(&manifest_texts().into_iter().find(|(n, _)| *n == "sync-all-valid").unwrap().1).unwrap();
    for target in &manifest.environments["local"].sync {
        corpus.add("sync", "describe", "sync.describe", json!({"target": serde_json::to_value(target).unwrap(), "environment": "local"}), json!(describe(target, "local")));
    }
    let secret = ["MDEyMzQ1Njc4OWFi", "Y2RlZjAxMjM0NTY3", "ODlhYmNkZWY="].concat();
    for text in [
        format!("Endpoint=https://shop.azconfig.io;Id=key-1;Secret={secret}"),
        "Endpoint=https://x;Id=a".to_string(),
        "Endpoint=https://x;garbage;Id=a;Secret=b".to_string(),
        " endpoint = https://x ; ID=a;SECRET=b;; ".to_string(),
    ] {
        let result = match ConnectionString::parse(&text) {
            Ok(c) => json!({"ok": {"endpoint": c.endpoint, "id": c.id, "secretLength": c.secret.len()}}),
            Err(error) => json!({"error": error}),
        };
        let input = text.replace(&secret, "<secret>");
        corpus.add("sync", "connection-string", "azure.connectionString", json!({"text": input}), result);
    }
    // The env file sync, through the whole sync of an environment.
    let directory = tempfile::tempdir().unwrap();
    let text = with_environment("runtime: podman\nsync:\n  - env_file: {path: config/.env.local}\ndependencies:\n  kafka:\n    real: {endpoint: 'localhost:9092'}\n");
    let manifest = Manifest::parse(&text).unwrap();
    let environment = resolve(&manifest, "local", &BTreeMap::new()).unwrap();
    let clouds = LoggedClouds::default();
    let first = runtime.block_on(ops::sync_environment(&manifest, directory.path(), &environment, &clouds)).unwrap();
    let second = runtime.block_on(ops::sync_environment(&manifest, directory.path(), &environment, &clouds)).unwrap();
    let dirs = [directory.path()];
    let shown = |done: &Vec<(String, SyncOutcome)>| {
        serde_json::from_str::<Value>(&normalise(
            &json!(done.iter().map(|(t, o)| json!({"target": t, "outcome": outcome_json(o)})).collect::<Vec<_>>()).to_string(),
            &dirs,
        ))
        .unwrap()
    };
    corpus.add(
        "sync",
        "env-file",
        "sync.envFile",
        json!({"text": text, "environment": "local", "manifestDir": "/work"}),
        json!({"first": shown(&first), "second": shown(&second), "files": files_under(directory.path(), &dirs)}),
    );
}

fn sample() -> Attestation {
    let started = time::macros::datetime!(2026-10-09 12:00:00 UTC);
    let mut attestation = Attestation::new(
        "local",
        Run {
            id: "0b7c4f5e-9a51-4d7e-8f53-0c3f4a2b6d10".into(),
            started_at: started,
            recorded_at: time::macros::datetime!(2026-10-09 12:00:05 UTC),
        },
    );
    attestation.producer = Some(Producer { name: "ironframe".into(), version: "0.1.0".into() });
    attestation.dependencies = vec![
        DependencyRecord {
            name: "kafka".into(),
            endpoint: "localhost:9092".into(),
            reached: true,
            kind: Kind::StandIn,
            stand_in: Some(StandIn {
                product: "lawtwin/kafka".into(),
                version: "0.1.0".into(),
                conformance: "unrated".into(),
                ..StandIn::default()
            }),
            node: None,
            edge: None,
            contract: None,
            implementation: None,
            completed: None,
        },
        DependencyRecord {
            name: "payments".into(),
            endpoint: "https://payments.example.com".into(),
            reached: false,
            kind: Kind::Real,
            stand_in: None,
            node: None,
            edge: None,
            contract: None,
            implementation: None,
            completed: None,
        },
    ];
    attestation
}

fn completed_run() -> Attestation {
    let mut attestation = sample();
    attestation.architecture = Some(ArchitectureRef {
        document: "shop.calm.json".into(),
        digest: format!("sha256:{}", "a".repeat(64)),
        unique_id: Some("calm-shop".into()),
        decorators: Some("shop.decorators.json".into()),
        decorators_digest: Some(format!("sha256:{}", "b".repeat(64))),
        topology_digest: Some(format!("sha256:{}", "c".repeat(64))),
        elements: vec!["adoptions-service".into(), "service-publishes-adoptions".into(), "adoptions-log".into()],
    });
    attestation.application = Some(ApplicationRef {
        node: "adoptions-service".into(),
        contract: ContractRef { package: "shop.adoptions".into(), version: "0.1.0".into(), abilities: vec![] },
        implementation: Implementation {
            kind: "application".into(),
            product: "shop.adoptions".into(),
            version: "0.1.0".into(),
            commit: Some("69f9de1".into()),
            image_digest: None,
        },
    });
    let first = &mut attestation.dependencies[0];
    first.node = Some("adoptions-log".into());
    first.edge = Some("service-publishes-adoptions".into());
    first.contract = Some(ContractRef {
        package: "lawtwin.kafka".into(),
        version: ">=0.1.0, <0.2.0".into(),
        abilities: vec!["lawtwin.kafka::ability::Broker".into()],
    });
    first.implementation = Some(Implementation {
        kind: "fixture".into(),
        product: "lawtwin/kafka".into(),
        version: "0.1.0".into(),
        ..Implementation::default()
    });
    first.stand_in.as_mut().unwrap().seed = Some(42);
    first.stand_in.as_mut().unwrap().history_digest = Some(format!("sha256:{}", "e".repeat(64)));
    first.stand_in.as_mut().unwrap().history_entries = Some(7);
    first.stand_in.as_mut().unwrap().stands_in_for = Some(ContractRef {
        package: "lawtwin.kafka".into(),
        version: "0.1.0".into(),
        abilities: vec!["lawtwin.kafka::ability::Broker".into()],
    });
    first.completed = Some(Completed {
        reached: true,
        history_digest: Some(format!("sha256:{}", "d".repeat(64))),
        history_entries: Some(12),
    });
    attestation.execution = Some(Execution {
        status: ExecutionStatus::Completed,
        command: vec!["lawspec".into(), "test".into()],
        exit_code: Some(0),
        finished_at: Some(time::macros::datetime!(2026-10-09 12:00:05.25 UTC)),
        environment_run: Some("up-run".into()),
    });
    attestation
}

fn attestations(corpus: &mut Corpus) {
    let from_json = |corpus: &mut Corpus, name: &str, text: String| {
        let result = match Attestation::from_json(&text) {
            Ok(attestation) => match attestation.to_json() {
                Ok(out) => json!({"ok": out}),
                Err(error) => json!({"error": error.to_string()}),
            },
            Err(error) => json!({"error": error.to_string()}),
        };
        corpus.add("attestation", name, "attestation.fromJson", json!({"text": text}), result);
    };
    let to_value = |a: &Attestation| serde_json::to_value(a).unwrap();
    let base = sample().to_json().unwrap();
    from_json(corpus, "sample", base.clone());
    from_json(corpus, "completed", completed_run().to_json().unwrap());
    let mut value = to_value(&sample());
    value["unknown"] = json!({"later": true});
    value["dependencies"][0]["extra"] = json!(1);
    from_json(corpus, "unknown-fields", value.to_string());
    let edits: Vec<(&str, Box<dyn Fn(&mut Value)>)> = vec![
        ("stand-in-missing", Box::new(|v| { v["dependencies"][0].as_object_mut().unwrap().remove("stand_in"); })),
        ("stand-in-on-real", Box::new(|v| { v["dependencies"][1]["stand_in"] = json!({"product": "p", "version": "1", "conformance": "c"}); })),
        ("version-2", Box::new(|v| { v["version"] = json!(2); })),
        ("version-huge", Box::new(|v| { v["version"] = json!(99999999999u64); })),
        ("version-string", Box::new(|v| { v["version"] = json!("1"); })),
        ("format-other", Box::new(|v| { v["format"] = json!("something-else"); })),
        ("format-number", Box::new(|v| { v["format"] = json!(5); })),
        ("duplicate", Box::new(|v| { let d = v["dependencies"][0].clone(); v["dependencies"].as_array_mut().unwrap().push(d); })),
        ("bad-digest", Box::new(|v| { v["dependencies"][0]["stand_in"]["history_digest"] = json!("sha256:XYZ"); })),
        ("upper-digest", Box::new(|v| { v["dependencies"][0]["stand_in"]["history_digest"] = json!(format!("sha256:{}", "A".repeat(64))); })),
        ("empty-environment", Box::new(|v| { v["environment"] = json!(""); })),
        ("empty-run-id", Box::new(|v| { v["run"]["id"] = json!(""); })),
        ("recorded-before", Box::new(|v| { v["run"]["recorded_at"] = json!("2026-10-09T11:00:00Z"); })),
        ("offset-times", Box::new(|v| { v["run"]["started_at"] = json!("2026-10-09T13:00:00+01:00"); v["run"]["recorded_at"] = json!("2026-10-09T12:00:00.123456789-00:30"); })),
        ("fraction-times", Box::new(|v| { v["run"]["started_at"] = json!("2026-10-09T12:00:00.100Z"); v["run"]["recorded_at"] = json!("2026-10-09T12:00:00.5Z"); })),
        ("lowercase-time", Box::new(|v| { v["run"]["started_at"] = json!("2026-10-09t12:00:00z"); })),
        ("bad-time", Box::new(|v| { v["run"]["started_at"] = json!("yesterday"); })),
        ("empty-name", Box::new(|v| { v["dependencies"][0]["name"] = json!(""); })),
        ("empty-endpoint", Box::new(|v| { v["dependencies"][1]["endpoint"] = json!(""); })),
        ("kind-other", Box::new(|v| { v["dependencies"][1]["kind"] = json!("mock"); })),
        ("missing-run", Box::new(|v| { v.as_object_mut().unwrap().remove("run"); })),
        ("missing-dependencies", Box::new(|v| { v.as_object_mut().unwrap().remove("dependencies"); })),
        ("reached-string", Box::new(|v| { v["dependencies"][0]["reached"] = json!("yes"); })),
        ("seed-negative", Box::new(|v| { v["dependencies"][0]["stand_in"]["seed"] = json!(-1); })),
        ("completed-not-completed", Box::new(|v| { v["dependencies"][0]["completed"] = json!({"reached": true}); })),
        ("no-dependencies", Box::new(|v| { v["dependencies"] = json!([]); })),
        ("producer-null", Box::new(|v| { v["producer"] = Value::Null; })),
    ];
    for (name, edit) in edits {
        let mut value = to_value(&sample());
        edit(&mut value);
        from_json(corpus, name, value.to_string());
    }
    let completed_edits: Vec<(&str, Box<dyn Fn(&mut Value)>)> = vec![
        ("no-exit", Box::new(|v| { v["execution"].as_object_mut().unwrap().remove("exit_code"); })),
        ("running-with-outcome", Box::new(|v| { v["execution"]["status"] = json!("running"); })),
        ("running", Box::new(|v| { v["execution"] = json!({"status": "running", "command": ["x"]}); })),
        ("early", Box::new(|v| { v["execution"]["finished_at"] = json!("2026-10-09T11:00:00Z"); })),
        ("bad-completed-digest", Box::new(|v| { v["dependencies"][0]["completed"]["history_digest"] = json!("sha256:XYZ"); })),
        ("wired", Box::new(|v| { v["execution"] = json!({"status": "wired"}); for d in v["dependencies"].as_array_mut().unwrap() { d.as_object_mut().unwrap().remove("completed"); } })),
        ("status-other", Box::new(|v| { v["execution"]["status"] = json!("done"); })),
        ("exit-negative", Box::new(|v| { v["execution"]["exit_code"] = json!(-9); })),
    ];
    for (name, edit) in completed_edits {
        let mut value = to_value(&completed_run());
        edit(&mut value);
        from_json(corpus, name, value.to_string());
    }
    for text in ["", "not json", "[]", "{\"format\": \"environment-attestation\"}", "{\"a\": 1,}", "{\"version\": 1, \"format\": \"x\"}"] {
        from_json(corpus, "malformed", text.to_string());
    }
    for (name, history) in [("empty", ""), ("lines", "{\"seq\":1}\n{\"seq\":2}\n"), ("unicode", "caf\u{e9}\n")] {
        corpus.add("attestation", name, "attestation.historyDigest", json!({"history": history}), json!(history_digest(history)));
    }
    for digest in ["sha256:".to_string() + &"a".repeat(64), "sha256:XYZ".into(), "sha256:".to_string() + &"a".repeat(63), "md5:".to_string() + &"a".repeat(64)] {
        corpus.add("attestation", "is-digest", "attestation.isHistoryDigest", json!({"digest": digest}), json!(ironframe_attestation::is_history_digest(&digest)));
    }
}

fn attest_build(corpus: &mut Corpus) {
    use ironframe_core::attest::{RunRecord, attest};
    use ironframe_core::twin::{Observation, TwinRecord};
    let cases: Vec<(&str, String, &str, BTreeMap<String, String>)> = vec![
        ("shop-local", SHOP.into(), "local", BTreeMap::new()),
        ("shop-staging", SHOP.into(), "staging", BTreeMap::from([("kafka".into(), "k.elb:9092".into())])),
        ("hosted", HOSTED.into(), "local", BTreeMap::new()),
    ];
    for (name, text, environment, deployed) in cases {
        let manifest = Manifest::parse(&text).unwrap();
        let resolved = resolve(&manifest, environment, &deployed).unwrap();
        let run = RunRecord {
            id: "run-1".into(),
            started_at: time::macros::datetime!(2099-01-01 00:00:00.5 UTC),
        };
        let reached: BTreeMap<String, bool> =
            resolved.dependencies.iter().enumerate().map(|(i, d)| (d.endpoint.clone(), i % 2 == 0)).collect();
        let mut observed = BTreeMap::new();
        let mut records = BTreeMap::new();
        if let Some(first) = resolved.dependencies.iter().find(|d| d.twin.is_some()) {
            observed.insert(
                first.name.clone(),
                Observation {
                    seed: Some(9),
                    history_digest: Some(history_digest("x\n")),
                    history_entries: Some(1),
                    history: Some("x\n".into()),
                },
            );
            records.insert(
                first.name.clone(),
                TwinRecord { admin: Some("http://a".into()), seed: Some(3), conformance: Some("answers".into()), faults: vec!["f".into()], forced: true },
            );
        }
        if let Some(second) = resolved.dependencies.iter().filter(|d| d.twin.is_some()).nth(1) {
            records.insert(second.name.clone(), TwinRecord { seed: Some(5), ..TwinRecord::default() });
        }
        let attestation = attest(&resolved, &run, &|e| reached.get(e).copied().unwrap_or(false), &observed, &records);
        let observed_json: BTreeMap<String, Value> = observed
            .iter()
            .map(|(k, o)| (k.clone(), json!({"seed": o.seed, "history_digest": o.history_digest, "history_entries": o.history_entries})))
            .collect();
        corpus.add(
            "attest",
            name,
            "attest.build",
            json!({
                "text": text, "environment": environment, "deployed": deployed,
                "run": {"id": "run-1", "started_at": "2099-01-01T00:00:00.5Z"},
                "now": "2026-10-20T00:00:00Z",
                "reached": reached, "observed": observed_json,
                "records": serde_json::to_value(&records).unwrap(),
            }),
            json!(attestation.to_json().unwrap()),
        );
    }
}

/// The calm-shop architecture directory.
fn calm_dir() -> PathBuf {
    repo().join("examples/calm-shop/architecture")
}

fn calm_files() -> serde_json::Map<String, Value> {
    let mut files = serde_json::Map::new();
    for name in ["lawtwin-kafka-0.1.0.json", "lawtwin-http-0.1.0-petstore.json"] {
        files.insert(
            format!("/work/architecture/conformance/{name}"),
            json!(std::fs::read_to_string(calm_dir().join("conformance").join(name)).unwrap()),
        );
    }
    files
}

fn calm_case(corpus: &mut Corpus, name: &str, architecture: &str, decorators: &str, environment: &str) {
    let dir = calm_dir();
    // The example's own documents and conformance reports are named rather than copied; the
    // Haskell side reads them from examples/calm-shop/architecture.
    let original = |name: &str, text: &str| {
        if std::fs::read_to_string(dir.join(name)).unwrap() == text { Value::Null } else { json!(text) }
    };
    let _ = calm_files;
    let input = json!({
        "architecture": {"path": "/work/architecture/shop.calm.json", "text": original("shop.calm.json", architecture)},
        "decorators": {"path": "/work/architecture/shop.decorators.json", "text": original("shop.decorators.json", decorators)},
        "environment": environment,
        "dir": "/work/architecture",
        "files": "examples/calm-shop/architecture",
    });
    let result = (|| {
        let mut model = Architecture::parse(architecture.as_bytes())?;
        model.path = Some(dir.join("shop.calm.json"));
        let mut decorations = Decorators::parse(decorators.as_bytes())?;
        decorations.path = Some(dir.join("shop.decorators.json"));
        calm_resolve(&model, &decorations, environment, &dir)
    })();
    let expected = match result {
        Ok(resolution) => {
            let topology = serde_json::to_string_pretty(&resolution.topology).unwrap() + "\n";
            let settings = application_settings(&resolution, &BTreeMap::new())
                .map(|s| serde_json::to_string_pretty(&s).unwrap() + "\n")
                .unwrap_or_else(|e| format!("error: {e}"));
            let root = ironframe_core::tofu::root_module(&resolution.manifest, environment, Path::new("/work/architecture"))
                .map(|r| serde_json::to_string_pretty(&r).unwrap() + "\n")
                .unwrap_or_else(|e| format!("error: {e}"));
            let annotated = serde_json::to_string_pretty(&annotated_architecture(&resolution.architecture.document, &resolution.topology)).unwrap() + "\n";
            let diagram = mermaid(&resolution.topology);
            json!({
                "topology": topology,
                "digest": resolution.topology.digest(),
                "manifest": serde_json::to_string_pretty(&resolution.manifest).unwrap(),
                "mermaid": diagram,
                "dot": dot(&resolution.topology),
                "annotated": annotated,
                "settings": settings,
                "tofu": root,
                "mermaidProblems": mermaid_problems(&resolution.topology, &diagram),
                "tamperedProblems": mermaid_problems(&resolution.topology, &diagram.replace(":::twin", ":::real").replace("adoptions_audit -->", "%% ")),
                "tofuProblems": ironframe_core::tofu::root_module(&resolution.manifest, environment, Path::new("/w")).map(|mut r| { r["module"]["twin_extra"] = json!({}); tofu_problems(&resolution.topology, &r) }).unwrap_or_default(),
                "settingsProblems": settings_problems(&resolution.topology, "adoptions-audit", &BTreeMap::from([("PETSTORE_URL".to_string(), "x".to_string())])),
            })
        }
        Err(mut error) => {
            if error.origin.is_some() {
                error.origin = Some(PathBuf::from("/work/architecture/shop.decorators.json"));
            }
            json!({"error": error.to_string()})
        }
    };
    corpus.add("calm", name, "calm.resolve", input, expected);
}

fn calm(corpus: &mut Corpus) {
    let architecture = std::fs::read_to_string(calm_dir().join("shop.calm.json")).unwrap();
    let decorators = std::fs::read_to_string(calm_dir().join("shop.decorators.json")).unwrap();
    for environment in ["twin", "real", "mixed", "staging", "production", "Bad_Env"] {
        calm_case(corpus, environment, &architecture, &decorators, environment);
    }
    let arch: Value = serde_json::from_str(&architecture).unwrap();
    let decs: Value = serde_json::from_str(&decorators).unwrap();
    let edit_dec = |id: &str, edit: &dyn Fn(&mut Value)| {
        let mut d = decs.clone();
        for x in d["decorators"].as_array_mut().unwrap() {
            if x["unique-id"] == id {
                edit(x);
            }
        }
        serde_json::to_string(&d).unwrap()
    };
    let arch_text = |a: &Value| serde_json::to_string_pretty(a).unwrap();
    let mut cases: Vec<(&str, String, String, &str)> = vec![
        ("other-package", architecture.clone(), edit_dec("pet-registry-twin", &|d| d["data"]["twin"]["stands-in-for"]["package"] = json!("lawtwin.kafka")), "twin"),
        ("outside-version", architecture.clone(), edit_dec("adoptions-log-twin", &|d| d["data"]["twin"]["stands-in-for"]["version"] = json!("0.2.0")), "twin"),
        ("prerelease-version", architecture.clone(), edit_dec("adoptions-log-twin", &|d| d["data"]["twin"]["stands-in-for"]["version"] = json!("0.1.5-beta.1")), "twin"),
        ("missing-ability", architecture.clone(), edit_dec("adoptions-log-twin", &|d| d["data"]["twin"]["stands-in-for"]["abilities"] = json!(["lawtwin.kafka::ability::Admin"])), "twin"),
        ("accept-exact", architecture.clone(), edit_dec("adoptions-log-contract", &|d| d["data"]["dependency"]["conformance"]["accept"] = json!(["exact"])), "twin"),
        ("accept-number", architecture.clone(), edit_dec("adoptions-log-contract", &|d| d["data"]["dependency"]["conformance"]["accept"] = json!(["3"])), "twin"),
        ("report-other-contract", architecture.clone(), edit_dec("adoptions-log-twin", &|d| d["data"]["twin"]["conformance"]["report"] = json!("conformance/lawtwin-http-0.1.0-petstore.json")), "twin"),
        ("report-missing", architecture.clone(), edit_dec("adoptions-log-twin", &|d| d["data"]["twin"]["conformance"]["report"] = json!("conformance/none.json")), "twin"),
        ("declared-no-report", architecture.clone(), edit_dec("adoptions-log-twin", &|d| d["data"]["twin"]["conformance"] = json!("answers")), "twin"),
        ("declared-low", architecture.clone(), edit_dec("adoptions-log-twin", &|d| d["data"]["twin"]["conformance"] = json!("matches")), "twin"),
        ("label-only", architecture.clone(), edit_dec("adoptions-log-twin", &|d| d["data"]["twin"]["conformance"] = json!({"image_label": "io.lawtwin.conformance"})), "twin"),
        ("no-stands-in-for", architecture.clone(), edit_dec("adoptions-log-twin", &|d| { d["data"]["twin"].as_object_mut().unwrap().remove("stands-in-for"); }), "twin"),
        ("bad-stands-in-for-version", architecture.clone(), edit_dec("adoptions-log-twin", &|d| d["data"]["twin"]["stands-in-for"]["version"] = json!("1.0")), "twin"),
        ("binding-undeclared-env", architecture.clone(), edit_dec("adoptions-log-staging", &|d| d["data"]["environment"] = json!("prod")), "twin"),
        ("missing-element", architecture.clone(), edit_dec("adoptions-log-twin", &|d| d["applies-to"] = json!(["adoption-log"])), "twin"),
        ("other-target", architecture.clone(), edit_dec("adoptions-log-twin", &|d| d["target"] = json!(["other.calm.json"])), "twin"),
        ("target-by-id", architecture.clone(), edit_dec("adoptions-log-twin", &|d| d["target"] = json!(["calm-shop"])), "twin"),
        ("target-by-path", architecture.clone(), edit_dec("adoptions-log-twin", &|d| d["target"] = json!(["https://example.com/arch/shop.calm.json"])), "twin"),
        ("schema-consumes", architecture.clone(), edit_dec("service-publishes-adoptions-contract", &|d| d["data"]["connection"]["consumes"] = json!(["Adoptions"])), "twin"),
        ("other-package-ability", architecture.clone(), edit_dec("service-registers-pets-contract", &|d| d["data"]["connection"]["consumes"] = json!(["billing::ability::Pets"])), "twin"),
        ("ability-twice", architecture.clone(), edit_dec("service-registers-pets-contract", &|d| d["data"]["connection"]["consumes"] = json!(["shop.adoptions::ability::Adoptions"])), "twin"),
        ("setting-twice", architecture.clone(), edit_dec("service-registers-pets-contract", &|d| d["data"]["connection"]["settings"] = json!({"KAFKA_BOOTSTRAP_SERVERS": "${endpoint}"})), "twin"),
        ("ports-empty", architecture.clone(), edit_dec("adoptions-log-twin", &|d| d["data"]["twin"]["ports"] = json!([])), "twin"),
        ("twin-unknown-field", architecture.clone(), edit_dec("adoptions-log-twin", &|d| d["data"]["twin"]["colour"] = json!("blue")), "twin"),
        ("twin-wrong-type", architecture.clone(), edit_dec("adoptions-log-twin", &|d| d["data"]["twin"]["seed"] = json!("seven")), "twin"),
        ("real-unknown-field", architecture.clone(), edit_dec("adoptions-log-real", &|d| d["data"]["real"]["colour"] = json!("blue")), "real"),
        ("real-provider-bad", architecture.clone(), edit_dec("adoptions-log-real", &|d| d["data"]["real"]["provider"] = json!({"name": "x"})), "real"),
        ("real-image-ports", architecture.clone(), edit_dec("adoptions-log-real", &|d| { d["data"]["real"].as_object_mut().unwrap().remove("ports"); }), "real"),
        ("environment-bad-runtime", architecture.clone(), edit_dec("twin-environment", &|d| d["data"]["runtime"] = json!("kubernetes")), "twin"),
        ("environment-on-relationship", architecture.clone(), edit_dec("twin-environment", &|d| d["applies-to"] = json!(["service-publishes-adoptions"])), "twin"),
        ("application-as-dependency", architecture.clone(), edit_dec("adoptions-service-twin", &|d| { let e = d["data"]["environment"].clone(); d["data"] = json!({"environment": e, "real": {"endpoint": "x:1"}}); }), "twin"),
        ("dependency-as-application", architecture.clone(), edit_dec("adoptions-log-twin", &|d| { let e = d["data"]["environment"].clone(); d["data"] = json!({"environment": e, "application": {}}); }), "twin"),
        ("bind-uncontracted", architecture.clone(), edit_dec("adoptions-log-twin", &|d| d["applies-to"] = json!(["calm-shop"])), "twin"),
        ("application-bad-version", architecture.clone(), edit_dec("shop-application-contract", &|d| d["data"]["application"]["version"] = json!("1.0")), "twin"),
        ("dependency-bad-requirement", architecture.clone(), edit_dec("adoptions-log-contract", &|d| d["data"]["dependency"]["version"] = json!(">=x")), "twin"),
        ("dependency-other-ability", architecture.clone(), edit_dec("adoptions-log-contract", &|d| d["data"]["dependency"]["abilities"] = json!(["lawtwin.petstore::ability::Pets"])), "twin"),
        ("contract-on-relationship", architecture.clone(), edit_dec("adoptions-log-contract", &|d| d["applies-to"] = json!(["service-publishes-adoptions"])), "twin"),
        ("connection-on-node", architecture.clone(), edit_dec("service-publishes-adoptions-contract", &|d| d["applies-to"] = json!(["adoptions-log"])), "twin"),
    ];
    let removed = |ids: &[&str]| {
        let mut d = decs.clone();
        d["decorators"].as_array_mut().unwrap().retain(|x| !ids.iter().any(|id| x["unique-id"] == *id));
        serde_json::to_string(&d).unwrap()
    };
    let added = |id: &str, new: &str| {
        let mut d = decs.clone();
        let mut extra = d["decorators"].as_array().unwrap().iter().find(|x| x["unique-id"] == id).unwrap().clone();
        extra["unique-id"] = json!(new);
        d["decorators"].as_array_mut().unwrap().push(extra);
        serde_json::to_string(&d).unwrap()
    };
    cases.push(("no-binding", architecture.clone(), removed(&["adoptions-log-twin"]), "twin"));
    cases.push(("no-connection", architecture.clone(), removed(&["audit-reads-adoptions-contract"]), "twin"));
    cases.push(("no-environment", architecture.clone(), removed(&["twin-environment", "real-environment", "mixed-environment", "staging-environment"]), "twin"));
    cases.push(("app-unbound", architecture.clone(), removed(&["adoptions-audit-twin"]), "twin"));
    cases.push(("two-bindings", architecture.clone(), added("adoptions-log-twin", "adoptions-log-twin-again"), "twin"));
    cases.push(("two-contracts", architecture.clone(), added("adoptions-log-contract", "adoptions-log-contract-again"), "twin"));
    cases.push(("two-environments", architecture.clone(), added("twin-environment", "twin-environment-again"), "twin"));
    cases.push(("same-decorator-id", architecture.clone(), added("adoptions-log-twin", "adoptions-log-twin"), "twin"));
    let mut a = arch.clone();
    a["relationships"][0]["unique-id"] = json!("adoptions-log");
    cases.push(("duplicate-id", arch_text(&a), decorators.clone(), "twin"));
    let mut a = arch.clone();
    a["relationships"][1]["relationship-type"]["connects"]["destination"]["node"] = json!("petstore");
    cases.push(("missing-node", arch_text(&a), decorators.clone(), "twin"));
    let mut a = arch.clone();
    a["relationships"][1]["relationship-type"]["connects"]["destination"]["node"] = json!("adoptions-service");
    cases.push(("self-connect", arch_text(&a), decorators.clone(), "twin"));
    let mut a = arch.clone();
    a["nodes"][1].as_object_mut().unwrap().remove("node-type");
    cases.push(("breaks-calm", arch_text(&a), decorators.clone(), "twin"));
    let mut a = arch.clone();
    a["nodes"][2]["unique-id"] = json!(5);
    a["relationships"][0]["relationship-type"] = json!({"teleports": {}});
    a["extra"] = json!(true);
    cases.push(("breaks-calm-more", arch_text(&a), decorators.clone(), "twin"));
    let mut a = arch.clone();
    a["nodes"][3]["metadata"] = json!({"owner": "ops"});
    a["nodes"][4]["metadata"] = json!([{"owner": "ops"}]);
    cases.push(("node-metadata", arch_text(&a), decorators.clone(), "mixed"));
    cases.push(("not-json", "{\"nodes\": [".into(), decorators.clone(), "twin"));
    cases.push(("not-object", "[1, 2]".into(), decorators.clone(), "twin"));
    cases.push(("decorators-not-json", architecture.clone(), "{".into(), "twin"));
    cases.push(("decorators-object", architecture.clone(), "{\"other\": []}".into(), "twin"));
    cases.push(("decorators-scalar", architecture.clone(), "5".into(), "twin"));
    cases.push(("decorators-array", architecture.clone(), serde_json::to_string(&decs["decorators"]).unwrap(), "twin"));
    cases.push(("decorator-bad-base", architecture.clone(), edit_dec("adoptions-log-twin", &|d| { d.as_object_mut().unwrap().remove("target"); d["extra"] = json!(1); }), "twin"));
    cases.push(("decorator-schema-key", architecture.clone(), edit_dec("adoptions-log-twin", &|d| d["$schema"] = json!("https://example.com/x.json")), "twin"));
    cases.push(("decorator-other-type", architecture.clone(), edit_dec("adoptions-log-twin", &|d| d["type"] = json!("someone-else")), "twin"));
    cases.push(("decorator-binding-schema", architecture.clone(), edit_dec("adoptions-log-twin", &|d| { d["data"]["environment"] = json!("Twin"); d["data"]["real"] = json!({"endpoint": ""}); }), "twin"));
    cases.push(("decorator-contract-schema", architecture.clone(), edit_dec("adoptions-log-contract", &|d| { d["data"]["dependency"]["package"] = json!("Bad"); d["data"]["dependency"].as_object_mut().unwrap().remove("abilities"); }), "twin"));
    cases.push(("decorator-environment-schema", architecture.clone(), edit_dec("twin-environment", &|d| { d["data"]["project"] = json!(""); d["data"]["sync"] = json!("x"); }), "twin"));
    cases.push(("unicode-names", architecture.replace("Adoptions log", "Adoptions \u{e9}log \\\"q\\\""), decorators.clone(), "mixed"));
    for (name, a, d, environment) in cases {
        calm_case(corpus, name, &a, &d, environment);
    }
    // Parsing alone, with its summary.
    for (name, text) in [("shop", architecture.clone()), ("minimal", "{\"nodes\": [], \"relationships\": []}".to_string())] {
        let result = match Architecture::parse(text.as_bytes()) {
            Ok(a) => json!({"ok": {
                "digest": a.digest, "unique_id": a.unique_id, "nodes": a.nodes.len(), "relationships": a.relationships.len(),
                "element_ids": a.element_ids(),
            }}),
            Err(e) => json!({"error": e.to_string()}),
        };
        corpus.add("calm", name, "calm.parseArchitecture", json!({"text": text}), result);
    }
}

fn twins(corpus: &mut Corpus, runtime: &tokio::runtime::Runtime) {
    for (name, params) in [
        ("latency", vec!["delay=5ms", "count=3"]),
        ("none", vec![]),
        ("bad", vec!["delay"]),
        ("negative", vec!["n=-4", "big=99999999999999999999", "eq=a=b", "empty="]),
    ] {
        let params: Vec<String> = params.into_iter().map(String::from).collect();
        let result = match parse_fault(name, &params) {
            Ok(fault) => json!({"ok": serde_json::to_value(&fault).unwrap()}),
            Err(error) => json!({"error": error.to_string()}),
        };
        corpus.add("twin", name, "twin.parseFault", json!({"name": name, "params": params}), result);
    }
    for body in ["{\"a\":1,\"b\":[1,2,{}],\"c\":{}}", "not json", "[]", "{\"nowMs\":5000}", "\"s\"", "1.0", "{\"z\":1,\"a\":{\"y\":[]}}"] {
        corpus.add("twin", "pretty", "twin.pretty", json!({"body": body}), json!(pretty(body)));
    }
    for (status, body) in [(200, "ok"), (204, ""), (400, "{\"error\": \"no fault x\"}"), (500, "boom"), (404, "{\"other\": 1}"), (302, "{\"error\": 5}")] {
        let result = match (Reply { status, body: body.into() }).ok() {
            Ok(text) => json!({"ok": text}),
            Err(error) => json!({"error": error.to_string(), "code": error.exit_code()}),
        };
        corpus.add("twin", "reply", "twin.replyOk", json!({"status": status, "body": body}), result);
    }
    const KAFKA_REPORT: &str = r#"{"twin": "kafka", "release": "0.1.0", "contract": {"package": "lawtwin.kafka", "version": "0.1.0"},
  "level": {"number": 3, "name": "answers", "means": "..."}}"#;
    const HTTP_REPORT: &str = r#"{"contract": "lawtwin.petstore", "real": {}, "divergences": [], "level": "conformant"}"#;
    for report in [KAFKA_REPORT, HTTP_REPORT, r#"{"twin": "kafka"}"#, "nope", r#"{"level": {"name": 5}}"#, r#"{"level": {"name": "x", "number": -1}}"#] {
        let result = match ConformanceReport::parse(report) {
            Ok(r) => json!({"ok": {"level": r.level, "number": r.number, "release": r.release, "twin": r.twin, "contract": r.contract, "describe": r.describe(),
                "matches": (["answers", "Answers", "3", "3-answers", "3-ANSWERS", " answers ", "exact", "conformant", "4"].iter().map(|d| json!([d, r.matches(d)])).collect::<Vec<_>>())}}),
            Err(error) => json!({"error": error}),
        };
        corpus.add("twin", "report", "conformance.parse", json!({"text": report}), result);
    }
    // Setting a twin up through its control plane, and every control-plane command, against a
    // fake twin that logs each request.
    let fake = FakeTwin::default();
    let url = runtime.block_on(fake.clone().serve());
    let text = manifest_with_twin(
        "podman",
        &format!(
            "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092]\nseed: 42\nadmin: {{url: '{url}'}}\nstate: {{topics: [orders]}}\nfaults:\n  - {{name: latency, params: {{delay: 5ms}}}}\n  - {{name: duplicate-delivery, params: {{count: 2}}}}"
        ),
    );
    let manifest = Manifest::parse(&text).unwrap();
    let Binding::Twin(twin) = &manifest.environments["local"].dependencies["kafka"] else { panic!() };
    let record = runtime.block_on(ControlPlane::new(url.clone()).set_up(twin, Path::new("."))).unwrap();
    corpus.add(
        "twin",
        "set-up",
        "twin.setUp",
        json!({"text": text.replace(&url, "http://twin.test"), "environment": "local", "dependency": "kafka", "manifestDir": "/work"}),
        json!({"record": serde_json::to_value(&record).unwrap().to_string().replace(&url, "http://twin.test"), "http": fake.log(&url)}),
    );
    let control = ControlPlane::new(url.clone());
    let commands: Vec<(&str, Value)> = vec![
        ("force-refused", json!(runtime.block_on(control.force(r#"{"impossible": true}"#.into())).map_err(|e| json!({"error": e.to_string(), "code": e.exit_code()})))),
        ("raise-undeclared", json!(runtime.block_on(control.raise(&parse_fault("undeclared", &[]).unwrap())).map_err(|e| json!({"error": e.to_string(), "code": e.exit_code()})))),
    ];
    let log_before = fake.log(&url).as_array().unwrap().len();
    let all = fake.log(&url);
    corpus.add(
        "twin",
        "commands",
        "twin.commands",
        json!({"url": "http://twin.test"}),
        json!({"results": commands.into_iter().map(|(n, r)| json!({"name": n, "result": r})).collect::<Vec<_>>(), "http": all.as_array().unwrap()[log_before - 2..].to_vec()}),
    );
    let unreachable = runtime.block_on(ControlPlane::new("http://127.0.0.1:1").describe()).unwrap_err();
    corpus.add("twin", "unreachable", "twin.unreachableMessage", json!({"url": "http://127.0.0.1:1"}), json!(unreachable.to_string()));
}

fn ops_flows(corpus: &mut Corpus, runtime: &tokio::runtime::Runtime) {
    common::fake_tools();
    let quick = UpOptions { sync: true, wait: Duration::ZERO };
    let podman_with_missing = |missing: &'static [&'static str]| {
        Logged::new(move |args| match args.first().map(String::as_str) {
            Some("image") if args.len() > 2 && missing.iter().any(|m| args[2].contains(m)) => failed(""),
            Some("pull") if missing.iter().any(|m| args[2].contains(m)) => failed(
                "Error: initializing source docker://lawtwin/kafka:0.1.0: requested access to the resource is denied\n",
            ),
            Some("ps") => ok("[]"),
            _ => ok(""),
        })
    };
    let probe = |endpoint: &str| ironframe_core::attest::tcp_reachable(endpoint, Duration::from_millis(500));
    let probes_of = |text: &str| -> BTreeMap<String, bool> {
        let manifest = Manifest::parse(text).unwrap();
        let mut found = BTreeMap::new();
        for (name, _) in &manifest.environments {
            if let Ok(resolved) = resolve(&manifest, name, &BTreeMap::new()) {
                for d in resolved.dependencies {
                    found.insert(d.endpoint.clone(), probe(&d.endpoint));
                }
            }
        }
        found
    };
    let env_tools = json!({"IRONFRAME_PODMAN": "/fake/podman", "IRONFRAME_TOFU": "/fake/tofu"});
    let up_case = |corpus: &mut Corpus, name: &str, text: String, environment: &str, runner: Logged, options: &UpOptions| {
        let directory = tempfile::tempdir().unwrap();
        let manifest = Manifest::parse(&text).unwrap();
        let clouds = LoggedClouds::default();
        let mut steps = Vec::new();
        let probes = probes_of(&text);
        let result = runtime.block_on(ops::up(&manifest, directory.path(), environment, &runner, &clouds, options, &mut |s| steps.push(s.to_string())));
        let dirs = [directory.path()];
        let result = match result {
            Ok(report) => json!({"ok": {
                "unreached": report.unreached,
                "synced": report.synced.iter().map(|(t, o)| json!({"target": normalise(t, &dirs), "outcome": serde_json::from_str::<Value>(&normalise(&outcome_json(o).to_string(), &dirs)).unwrap()})).collect::<Vec<_>>(),
                "attestationPath": normalise(&report.attestation_path.display().to_string(), &dirs),
            }}),
            Err(error) => json!({"error": normalise(&error.to_string(), &dirs)}),
        };
        corpus.add(
            "ops",
            name,
            "ops.up",
            json!({"text": text, "environment": environment, "manifestDir": "/work", "sync": options.sync, "waitSeconds": options.wait.as_secs(), "env": env_tools, "probes": probes}),
            json!({"result": result, "progress": steps, "processes": runner.log(&dirs), "clouds": clouds.log.lock().unwrap().clone(), "files": files_under(directory.path(), &dirs)}),
        );
    };
    up_case(corpus, "missing-image", SHOP.into(), "local", podman_with_missing(&["lawtwin/kafka"]), &quick);
    up_case(corpus, "missing-images", SHOP.into(), "local", podman_with_missing(&["lawtwin/kafka", "payments-twin"]), &quick);
    up_case(
        corpus,
        "no-compose",
        SHOP.into(),
        "local",
        Logged::new(|args| if args[0] == "compose" { failed("Error: looking up compose provider failed\n") } else { ok("") }),
        &quick,
    );
    up_case(corpus, "podman-up", SHOP.into(), "local", podman_with_missing(&[]), &quick);
    up_case(corpus, "podman-up-no-sync", SHOP.into(), "local", podman_with_missing(&[]), &UpOptions { sync: false, wait: Duration::ZERO });
    up_case(
        corpus,
        "compose-up-fails",
        SHOP.into(),
        "local",
        Logged::new(|args| if args.len() > 4 && args[4] == "up" { failed("") } else { ok("") }),
        &quick,
    );
    let kafka_app = std::fs::read_to_string(repo().join("examples/kafka-app/ironframe.yaml")).unwrap();
    up_case(corpus, "broker-config-service", kafka_app.clone(), "local-broker", podman_with_missing(&[]), &quick);
    let tofu = || {
        Logged::new(|args| {
            if args.get(1).map(String::as_str) == Some("output") {
                ok(r#"{"kafka": "shop-staging-kafka.elb.eu-west-1.amazonaws.com:9092"}"#)
            } else {
                ok("")
            }
        })
    };
    up_case(corpus, "cloud-up", SHOP.into(), "staging", tofu(), &quick);
    up_case(
        corpus,
        "cloud-apply-fails",
        SHOP.into(),
        "staging",
        Logged::new(|args| if args.get(1).map(String::as_str) == Some("apply") { failed("Error: no credentials\n\n") } else { ok("") }),
        &quick,
    );
    up_case(
        corpus,
        "cloud-bad-output",
        SHOP.into(),
        "staging",
        Logged::new(|args| if args.get(1).map(String::as_str) == Some("output") { ok("[1]") } else { ok("") }),
        &quick,
    );
    let labelled = |level: &'static str| {
        Logged::new(move |args| {
            if args.len() > 1 && args[0] == "image" && args[1] == "inspect" {
                ok(&format!("{{\"io.lawtwin.conformance\": \"{level}\"}}\n"))
            } else {
                ok("")
            }
        })
    };
    let label_text = manifest_with_twin("podman", "image: lawtwin/kafka\nversion: 0.1.0\nconformance: {image_label: io.lawtwin.conformance}\nports: [19092]");
    let no_sync = UpOptions { sync: false, wait: Duration::ZERO };
    up_case(corpus, "label", label_text.clone(), "local", labelled("answers"), &no_sync);
    up_case(corpus, "label-declared-differs", label_text.replace("{image_label:", "{level: exact, image_label:"), "local", labelled("answers"), &no_sync);
    up_case(corpus, "label-declared-case", label_text.replace("{image_label:", "{level: ANSWERS, image_label:"), "local", labelled("answers"), &no_sync);
    up_case(corpus, "label-missing", label_text.clone(), "local", Logged::new(|args| if args.len() > 1 && args[1] == "inspect" { ok("null\n") } else { ok("") }), &no_sync);
    up_case(corpus, "label-blank", label_text.clone(), "local", labelled(" "), &no_sync);
    up_case(corpus, "label-inspect-fails", label_text.clone(), "local", Logged::new(|args| if args.len() > 1 && args[1] == "inspect" { failed("Error: no such image\n") } else { ok("") }), &no_sync);
    up_case(
        corpus,
        "twin-never-answers",
        manifest_with_twin("podman", "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092]\nadmin: {url: 'http://127.0.0.1:1'}"),
        "local",
        podman_with_missing(&[]),
        &no_sync,
    );
    // up with a fake twin control plane, then attest.
    let fake = FakeTwin::default();
    let url = runtime.block_on(fake.clone().serve());
    let text = manifest_with_twin(
        "podman",
        &format!("image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092]\nseed: 9\nadmin: {{url: '{url}'}}\nstate: {{topics: [orders]}}"),
    );
    let manifest = Manifest::parse(&text).unwrap();
    let directory = tempfile::tempdir().unwrap();
    let runner = Logged::new(|_| ok(""));
    let options = UpOptions { sync: true, wait: Duration::from_secs(2) };
    let mut steps = Vec::new();
    let report = runtime
        .block_on(ops::up(&manifest, directory.path(), "local", &runner, &LoggedClouds::default(), &options, &mut |s| steps.push(s.to_string())))
        .unwrap();
    let dirs = [directory.path()];
    let normal = |text: &str| normalise(&text.replace(&url, "http://twin.test"), &dirs);
    let files_up: BTreeMap<String, String> = files_under(directory.path(), &dirs).into_iter().map(|(k, v)| (k, v.replace(&url, "http://twin.test"))).collect();
    let http_up = fake.log(&url);
    fake.history.lock().unwrap().push(r#"{"seq":2,"source":"wire"}"#.into());
    let (attestation, _) = runtime.block_on(ops::attest_now(&manifest, directory.path(), "local", None)).unwrap();
    let files_attest: BTreeMap<String, String> = files_under(directory.path(), &dirs).into_iter().map(|(k, v)| (k, v.replace(&url, "http://twin.test"))).collect();
    let http_all = fake.log(&url);
    corpus.add(
        "ops",
        "twin-up-attest",
        "ops.upThenAttest",
        json!({"text": normal(&text), "environment": "local", "manifestDir": "/work", "sync": true, "waitSeconds": 2, "env": env_tools, "probes": {"localhost:9092": probe("localhost:9092")}}),
        json!({
            "up": {"progress": steps, "processes": runner.log(&dirs), "http": http_up, "files": files_up, "unreached": report.unreached},
            "attest": {"http": http_all.as_array().unwrap()[http_up.as_array().unwrap().len()..].to_vec(), "files": files_attest, "attestation": normal(&attestation.to_json().unwrap())},
        }),
    );
    // down, status, plan.
    let simple = |corpus: &mut Corpus, name: &str, method: &str, text: String, environment: &str, runner: Logged, prepared: Vec<(&str, &str)>| {
        let directory = tempfile::tempdir().unwrap();
        for (file, contents) in &prepared {
            let at = directory.path().join(file);
            std::fs::create_dir_all(at.parent().unwrap()).unwrap();
            std::fs::write(at, contents).unwrap();
        }
        let manifest = Manifest::parse(&text).unwrap();
        let dirs = [directory.path()];
        let result = match method {
            "ops.down" => ops::down(&manifest, directory.path(), environment, &runner).map(|_| json!(null)),
            "ops.plan" => ops::plan(&manifest, directory.path(), environment, &runner).map(|p| json!(normalise(&p.display().to_string(), &dirs))),
            "ops.status" => ops::status(&manifest, directory.path(), environment, &runner).map(|s| serde_json::to_value(s).unwrap()),
            _ => unreachable!(),
        };
        let result = match result {
            Ok(v) => json!({"ok": v}),
            Err(e) => json!({"error": normalise(&e.to_string(), &dirs)}),
        };
        let given: BTreeMap<String, String> = prepared.iter().map(|(f, c)| (f.to_string(), c.to_string())).collect();
        corpus.add(
            "ops",
            name,
            method,
            json!({"text": text, "environment": environment, "manifestDir": "/work", "env": env_tools, "probes": probes_of(&text), "files": given}),
            json!({"result": result, "processes": runner.log(&dirs), "files": files_under(directory.path(), &dirs)}),
        );
    };
    simple(corpus, "down-podman", "ops.down", SHOP.into(), "local", Logged::new(|_| ok("")), vec![]);
    simple(corpus, "down-config-service", "ops.down", kafka_app.clone(), "local-broker", Logged::new(|_| ok("")), vec![]);
    simple(corpus, "down-cloud", "ops.down", SHOP.into(), "staging", Logged::new(|_| ok("")), vec![(".ironframe/staging/endpoints.json", "{\"kafka\": \"k:9092\"}\n")]);
    simple(corpus, "down-cloud-fails", "ops.down", SHOP.into(), "staging", Logged::new(|a| if a.get(1).map(String::as_str) == Some("destroy") { failed("") } else { ok("") }), vec![]);
    simple(corpus, "plan-podman", "ops.plan", SHOP.into(), "local", Logged::new(|_| ok("")), vec![]);
    simple(corpus, "plan-cloud", "ops.plan", SHOP.into(), "staging", Logged::new(|_| ok("")), vec![]);
    simple(corpus, "plan-init-fails", "ops.plan", SHOP.into(), "staging", Logged::new(|a| if a.get(1).map(String::as_str) == Some("init") { failed("") } else { ok("") }), vec![]);
    simple(corpus, "plan-unknown", "ops.plan", SHOP.into(), "nope", Logged::new(|_| ok("")), vec![]);
    let ps = r#"[{"Names":["ironframe-shop-local-kafka"],"Image":"docker.io/lawtwin/kafka:0.1.0","State":"running","Labels":{"io.ironframe.dependency":"kafka","io.ironframe.kind":"twin"}}]"#;
    simple(corpus, "status-podman", "ops.status", SHOP.into(), "local", Logged::new(move |a| if a[0] == "ps" { ok(ps) } else { ok("") }), vec![]);
    simple(corpus, "status-ps-empty", "ops.status", SHOP.into(), "local", Logged::new(|_| ok("\n")), vec![]);
    simple(corpus, "status-ps-garbage", "ops.status", SHOP.into(), "local", Logged::new(|a| if a[0] == "ps" { ok("{") } else { ok("") }), vec![]);
    simple(corpus, "status-ps-labels-null", "ops.status", SHOP.into(), "local", Logged::new(|a| if a[0] == "ps" { ok(r#"[{"Names":[],"Labels":null}]"#) } else { ok("") }), vec![]);
    simple(corpus, "status-cloud", "ops.status", SHOP.into(), "staging", Logged::new(|_| ok("")), vec![]);
    simple(corpus, "status-cloud-deployed", "ops.status", SHOP.into(), "staging", Logged::new(|_| ok("")), vec![(".ironframe/staging/endpoints.json", "{\"kafka\": \"k:9092\"}\n")]);
    simple(corpus, "status-hosted", "ops.status", HOSTED.into(), "local", Logged::new(|_| ok("[]")), vec![]);
    simple(corpus, "status-bad-endpoints", "ops.status", SHOP.into(), "staging", Logged::new(|_| ok("")), vec![(".ironframe/staging/endpoints.json", "[")]);
    // attest without an up.
    let directory = tempfile::tempdir().unwrap();
    let dirs = [directory.path()];
    let manifest = Manifest::parse(HOSTED).unwrap();
    let (attestation, path) = runtime.block_on(ops::attest_now(&manifest, directory.path(), "local", Some(&directory.path().join("evidence/a.json")))).unwrap();
    corpus.add(
        "ops",
        "attest-fresh",
        "ops.attest",
        json!({"text": HOSTED, "environment": "local", "manifestDir": "/work", "output": "/work/evidence/a.json", "env": env_tools, "probes": probes_of(HOSTED), "files": {}}),
        json!({"attestation": normalise(&attestation.to_json().unwrap(), &dirs), "path": normalise(&path.display().to_string(), &dirs), "files": files_under(directory.path(), &dirs)}),
    );
    let directory = tempfile::tempdir().unwrap();
    let dirs = [directory.path()];
    std::fs::create_dir_all(directory.path().join(".ironframe/local")).unwrap();
    std::fs::write(directory.path().join(".ironframe/local/run.json"), "{\n  \"id\": \"kept-run\",\n  \"started_at\": \"2026-10-09T12:00:00+02:00\"\n}\n").unwrap();
    std::fs::write(directory.path().join(".ironframe/local/twins.json"), "{\n  \"payments\": {\n    \"seed\": 4,\n    \"conformance\": \"L2\"\n  }\n}\n").unwrap();
    let manifest = common::manifest();
    let (attestation, path) = runtime.block_on(ops::attest_now(&manifest, directory.path(), "local", None)).unwrap();
    corpus.add(
        "ops",
        "attest-kept-run",
        "ops.attest",
        json!({"text": SHOP, "environment": "local", "manifestDir": "/work", "output": null, "env": env_tools, "probes": probes_of(SHOP),
            "files": {".ironframe/local/run.json": "{\n  \"id\": \"kept-run\",\n  \"started_at\": \"2026-10-09T12:00:00+02:00\"\n}\n", ".ironframe/local/twins.json": "{\n  \"payments\": {\n    \"seed\": 4,\n    \"conformance\": \"L2\"\n  }\n}\n"}}),
        json!({"attestation": normalise(&attestation.to_json().unwrap(), &dirs), "path": normalise(&path.display().to_string(), &dirs), "files": files_under(directory.path(), &dirs)}),
    );
    // control_plane lookups.
    for (name, environment, dependency) in [("cp-no-admin", "local", "kafka"), ("cp-real", "staging", "payments"), ("cp-missing", "local", "nope")] {
        let directory = tempfile::tempdir().unwrap();
        let result = match ops::control_plane(&common::manifest(), directory.path(), environment, dependency) {
            Ok(c) => json!({"ok": c.url}),
            Err(e) => json!({"error": e.to_string()}),
        };
        corpus.add("ops", name, "ops.controlPlane", json!({"text": SHOP, "environment": environment, "dependency": dependency, "manifestDir": "/work", "files": {}}), result);
    }
}

fn config_service(corpus: &mut Corpus, runtime: &tokio::runtime::Runtime) {
    use axum::body::Body;
    use axum::http::Request;
    use http_body_util::BodyExt;
    use tower::ServiceExt;
    let document = json!({"project": "kafka-app", "environments": {
        "local": {"KAFKA_BOOTSTRAP_SERVERS": "localhost:9092", "QUOTED": "a b"},
        "staging": {"KAFKA_BOOTSTRAP_SERVERS": "b-1.example:9092"},
    }});
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("settings.json");
    std::fs::write(&path, document.to_string()).unwrap();
    let broken = directory.path().join("broken.json");
    std::fs::write(&broken, "{").unwrap();
    let dirs = [directory.path()];
    for (source, label) in [(path.clone(), "document"), (broken.clone(), "broken"), (directory.path().join("none.json"), "missing")] {
        for uri in [
            "/healthz",
            "/v1/environments",
            "/v1/environments/local",
            "/v1/environments/staging/env",
            "/v1/environments/local/settings/KAFKA_BOOTSTRAP_SERVERS",
            "/v1/environments/local/settings/NOPE",
            "/v1/environments/production",
            "/v1/environments/production/env",
            "/nothing",
        ] {
            let router = ironframe_config_service_router(source.clone());
            let response = runtime.block_on(router.oneshot(Request::get(uri).body(Body::empty()).unwrap())).unwrap();
            let status = response.status().as_u16();
            let content_type = response.headers().get("content-type").map(|v| v.to_str().unwrap().to_string());
            let body = runtime.block_on(response.into_body().collect()).unwrap().to_bytes();
            corpus.add(
                "config-service",
                label,
                "configService.get",
                json!({"settingsPath": normalise(&source.display().to_string(), &dirs), "document": if label == "document" { json!(document.to_string()) } else if label == "broken" { json!("{") } else { Value::Null }, "path": uri}),
                json!({"status": status, "contentType": content_type, "body": normalise(&String::from_utf8_lossy(&body), &dirs)}),
            );
        }
    }
}

fn ironframe_config_service_router(path: PathBuf) -> axum::Router {
    ironframe_config_service::router(ironframe_config_service::Source::File(path))
}

#[test]
#[ignore = "writes the golden corpus; run with --ignored"]
fn capture() {
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
    let mut corpus = Corpus::default();
    manifests(&mut corpus);
    settings(&mut corpus);
    compose(&mut corpus);
    tofu(&mut corpus);
    sync(&mut corpus, &runtime);
    attestations(&mut corpus);
    attest_build(&mut corpus);
    calm(&mut corpus);
    twins(&mut corpus, &runtime);
    ops_flows(&mut corpus, &runtime);
    config_service(&mut corpus, &runtime);
    corpus.write();
}
