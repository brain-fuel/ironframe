//! `up`, `down` and `attest` drive podman and OpenTofu in the right order: every image is checked
//! before anything starts, so a missing image leaves the machine untouched and names what is
//! missing; a started environment leaves its compose file, settings, synced env file and
//! attestation behind; a cloud environment reads its twins' endpoints back from OpenTofu.
//! ref:DEC-podman-compose ref:DEC-opentofu

mod common;

use common::{FakeClouds, Recorder, failed, fake_tools, ok};
use ironframe_attestation::{Attestation, Kind, SCHEMA_V1};
use ironframe_core::manifest::Manifest;
use ironframe_core::ops::{self, OpsError, UpOptions};
use ironframe_core::podman::PodmanError;
use ironframe_core::settings::parse_dotenv;
use std::time::Duration;

fn quick() -> UpOptions {
    UpOptions { sync: true, wait: Duration::ZERO }
}

fn podman_with_missing(missing: &'static [&'static str]) -> Recorder {
    Recorder::new(move |args| match args.first().map(String::as_str) {
        Some("image") if missing.iter().any(|m| args[2].contains(m)) => failed(""),
        Some("pull") if missing.iter().any(|m| args[2].contains(m)) => failed(
            "Error: initializing source docker://lawtwin/kafka:0.1.0: requested access to the resource is denied",
        ),
        Some("ps") => ok("[]"),
        _ => ok(""),
    })
}

/// ref:REQ-missing-image-fails-clearly
#[tokio::test]
async fn a_missing_image_stops_up_before_anything_starts_and_says_which() {
    fake_tools();
    let directory = tempfile::tempdir().unwrap();
    let podman = podman_with_missing(&["lawtwin/kafka"]);
    let error =
        ops::up(&common::manifest(), directory.path(), "local", &podman, &FakeClouds::default(), &quick(), &mut |_| {})
            .await
            .unwrap_err();
    let OpsError::Podman(PodmanError::ImagesUnavailable(missing)) = &error else { panic!("{error}") };
    assert_eq!(missing.len(), 1);
    assert_eq!(missing[0].needed_by, "dependency \"kafka\"");
    assert_eq!(missing[0].image, "docker.io/lawtwin/kafka:0.1.0");
    let message = error.to_string();
    assert!(message.contains("nothing was started"), "{message}");
    assert!(message.contains("requested access to the resource is denied"), "{message}");
    assert!(!podman.calls().iter().any(|c| c.starts_with("compose -f")), "{:?}", podman.calls());
    assert!(!directory.path().join(".ironframe").exists());
    assert!(!directory.path().join(".env.local").exists());
}

/// ref:REQ-missing-image-fails-clearly
#[tokio::test]
async fn every_missing_image_is_reported_not_just_the_first() {
    fake_tools();
    let directory = tempfile::tempdir().unwrap();
    let podman = podman_with_missing(&["lawtwin/kafka", "payments-twin"]);
    let error =
        ops::up(&common::manifest(), directory.path(), "local", &podman, &FakeClouds::default(), &quick(), &mut |_| {})
            .await
            .unwrap_err();
    let OpsError::Podman(PodmanError::ImagesUnavailable(missing)) = error else { panic!() };
    assert_eq!(
        missing.iter().map(|m| m.image.as_str()).collect::<Vec<_>>(),
        ["docker.io/lawtwin/kafka:0.1.0", "ghcr.io/example/payments-twin:2.0.0"]
    );
}

/// ref:REQ-missing-image-fails-clearly
#[tokio::test]
async fn a_compose_provider_that_does_not_work_is_named_before_any_image_is_pulled() {
    fake_tools();
    let directory = tempfile::tempdir().unwrap();
    let podman =
        Recorder::new(
            |args| if args[0] == "compose" { failed("Error: looking up compose provider failed") } else { ok("") },
        );
    let error =
        ops::up(&common::manifest(), directory.path(), "local", &podman, &FakeClouds::default(), &quick(), &mut |_| {})
            .await
            .unwrap_err();
    assert!(error.to_string().contains("install podman-compose or docker-compose"), "{error}");
    assert_eq!(podman.calls(), ["compose version"]);
}

/// ref:REQ-compose-generation
#[tokio::test]
async fn up_starts_the_compose_project_then_syncs_and_attests() {
    fake_tools();
    let directory = tempfile::tempdir().unwrap();
    let podman = podman_with_missing(&[]);
    let mut steps = Vec::new();
    let report =
        ops::up(&common::manifest(), directory.path(), "local", &podman, &FakeClouds::default(), &quick(), &mut |s| {
            steps.push(s.to_string())
        })
        .await
        .unwrap();
    let calls = podman.calls();
    let compose = directory.path().join(".ironframe/local/compose.yaml");
    assert_eq!(calls[0], "compose version");
    assert_eq!(calls[1], "image exists docker.io/lawtwin/kafka:0.1.0");
    assert_eq!(calls.last().unwrap(), &format!("compose -f {} -p ironframe-shop-local up -d", compose.display()));
    assert!(compose.exists());
    assert_eq!(steps[0], "checking images");
    let env = parse_dotenv(&std::fs::read_to_string(directory.path().join(".env.local")).unwrap());
    assert_eq!(env["KAFKA_BOOTSTRAP_SERVERS"], "localhost:9092");
    assert_eq!(report.synced.len(), 1);
    let text = std::fs::read_to_string(&report.attestation_path).unwrap();
    let attestation = Attestation::from_json(&text).unwrap();
    assert_eq!(attestation.environment, "local");
    assert!(attestation.dependencies.iter().all(|d| d.kind == Kind::StandIn));
    let unreached: Vec<&str> =
        attestation.dependencies.iter().filter(|d| !d.reached).map(|d| d.name.as_str()).collect();
    assert_eq!(report.unreached, unreached, "the report and the attestation agree on what answered");
    let schema: serde_json::Value = serde_json::from_str(SCHEMA_V1).unwrap();
    assert!(jsonschema::validator_for(&schema).unwrap().is_valid(&serde_json::from_str(&text).unwrap()));
}

/// ref:REQ-attestation-round-trip
#[tokio::test]
async fn attest_records_the_same_run_that_up_started() {
    fake_tools();
    let directory = tempfile::tempdir().unwrap();
    let report = ops::up(
        &common::manifest(),
        directory.path(),
        "local",
        &podman_with_missing(&[]),
        &FakeClouds::default(),
        &quick(),
        &mut |_| {},
    )
    .await
    .unwrap();
    let output = directory.path().join("evidence/attestation.json");
    let (attestation, path) = ops::attest_now(&common::manifest(), directory.path(), "local", Some(&output)).unwrap();
    assert_eq!(path, output);
    assert_eq!(attestation.run.id, report.attestation.run.id);
    assert_eq!(attestation.run.started_at, report.attestation.run.started_at);
    assert_eq!(Attestation::from_json(&std::fs::read_to_string(output).unwrap()).unwrap(), attestation);
}

/// ref:REQ-attestation-round-trip
#[tokio::test]
async fn a_reachable_endpoint_is_attested_as_reached() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let manifest = Manifest::parse(&format!(
        "version: 1\nproject: shop\ndependencies:\n  db:\n    settings: {{D: '${{endpoint}}'}}\nenvironments:\n  local:\n    runtime: podman\n    dependencies:\n      db: {{real: {{endpoint: '127.0.0.1:{port}'}}}}\n"
    ))
    .unwrap();
    let directory = tempfile::tempdir().unwrap();
    let held = std::thread::spawn(move || listener.accept().map(|(stream, _)| stream));
    let (attestation, _) = ops::attest_now(&manifest, directory.path(), "local", None).unwrap();
    drop(held.join());
    assert!(attestation.dependencies[0].reached);
    assert_eq!(attestation.dependencies[0].kind, Kind::Real);
    assert_eq!(attestation.dependencies[0].stand_in, None);
}

/// ref:REQ-cloud-root-module
#[tokio::test]
async fn a_cloud_up_applies_reads_endpoints_back_and_syncs_them() {
    fake_tools();
    let directory = tempfile::tempdir().unwrap();
    let tofu = Recorder::new(|args| {
        if args.get(1).map(String::as_str) == Some("output") {
            ok(r#"{"kafka": "shop-staging-kafka.elb.eu-west-1.amazonaws.com:9092"}"#)
        } else {
            ok("")
        }
    });
    let clouds = FakeClouds::default();
    let report =
        ops::up(&common::manifest(), directory.path(), "staging", &tofu, &clouds, &quick(), &mut |_| {}).await.unwrap();
    let root = directory.path().join(".ironframe/staging/tofu");
    let calls = tofu.calls();
    let chdir = format!("-chdir={}", root.display());
    assert_eq!(
        calls,
        [
            format!("{chdir} init -input=false"),
            format!("{chdir} apply -input=false -auto-approve"),
            format!("{chdir} output -json endpoints"),
        ]
    );
    assert!(root.join("main.tf.json").exists());
    assert_eq!(
        report.environment.settings()["KAFKA_BOOTSTRAP_SERVERS"],
        "shop-staging-kafka.elb.eu-west-1.amazonaws.com:9092"
    );
    let synced: std::collections::BTreeMap<String, String> =
        serde_json::from_slice(&clouds.aws.versions.lock().unwrap()[0]).unwrap();
    assert_eq!(synced["KAFKA_BOOTSTRAP_SERVERS"], "shop-staging-kafka.elb.eu-west-1.amazonaws.com:9092");
    let resolved = ops::resolve_in(&common::manifest(), directory.path(), "staging").unwrap();
    assert_eq!(resolved.settings(), report.environment.settings(), "later commands see the deployed endpoints");
    ops::down(&common::manifest(), directory.path(), "staging", &tofu).unwrap();
    assert!(tofu.calls().contains(&format!("{chdir} destroy -input=false -auto-approve")));
    assert!(ops::resolve_in(&common::manifest(), directory.path(), "staging").is_err());
}

/// ref:REQ-cloud-root-module
#[test]
fn plan_refuses_a_podman_environment() {
    fake_tools();
    let directory = tempfile::tempdir().unwrap();
    let error = ops::plan(&common::manifest(), directory.path(), "local", &Recorder::new(|_| ok(""))).unwrap_err();
    assert!(error.to_string().contains("runs on podman"), "{error}");
}

/// ref:REQ-compose-generation
#[test]
fn status_reads_container_states_from_their_labels() {
    fake_tools();
    let directory = tempfile::tempdir().unwrap();
    let podman = Recorder::new(|args| {
        if args[0] == "ps" {
            ok(
                r#"[{"Names":["ironframe-shop-local-kafka"],"Image":"docker.io/lawtwin/kafka:0.1.0","State":"running","Labels":{"io.ironframe.dependency":"kafka","io.ironframe.kind":"twin"}}]"#,
            )
        } else {
            ok("")
        }
    });
    let states = ops::status(&common::manifest(), directory.path(), "local", &podman).unwrap();
    assert_eq!(
        states.iter().map(|s| (s.name.as_str(), s.state.as_str())).collect::<Vec<_>>(),
        [("kafka", "running"), ("payments", "absent")]
    );
    assert!(
        podman.calls()[0]
            .contains("--filter label=io.ironframe.project=shop --filter label=io.ironframe.environment=local")
    );
    let cloud = ops::status(&common::manifest(), directory.path(), "staging", &podman).unwrap();
    assert_eq!(cloud.iter().map(|s| s.state.as_str()).collect::<Vec<_>>(), ["not deployed", "hosted"]);
}
