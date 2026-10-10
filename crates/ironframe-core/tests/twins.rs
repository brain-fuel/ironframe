//! Twins wired through their control plane: the manifest's twin rules, conformance read from a
//! report and checked against the declared level, a twin set up at start (seed, forced state,
//! faults) through a fake admin API, and the seed and history digest an attestation records.
//! ref:DEC-twin-control-plane ref:DEC-conformance-from-report ref:DEC-history-digest

mod common;

use axum::Router;
use axum::extract::{Path as UrlPath, Query, State};
use axum::http::StatusCode;
use axum::routing::{get, post};
use common::{FakeClouds, Recorder, fake_tools, ok};
use ironframe_attestation::{Attestation, is_history_digest};
use ironframe_core::manifest::{ConformanceReport, Manifest};
use ironframe_core::ops::{self, OpsError, UpOptions};
use ironframe_core::twin::{ControlPlane, TwinError, history_digest, parse_fault};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// A fake twin control plane that records what it is asked and answers as LawTwin's does.
#[derive(Clone, Default)]
struct FakeTwin {
    calls: Arc<Mutex<Vec<String>>>,
    seed: Arc<Mutex<u64>>,
    history: Arc<Mutex<Vec<String>>>,
}

impl FakeTwin {
    fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }

    async fn serve(self) -> String {
        let app = Router::new()
            .route("/healthz", get(|| async { "ok" }))
            .route(
                "/v1/twin",
                get(|State(t): State<FakeTwin>| async move {
                    let seed = *t.seed.lock().unwrap();
                    axum::Json(serde_json::json!({"twin": "fake", "version": "0.1.0", "contract": {}, "seed": seed,
                        "clock": {"mode": "frozen", "nowMs": 0}, "bootstrap": "localhost:1"}))
                }),
            )
            .route(
                "/v1/seed",
                post(|State(t): State<FakeTwin>, body: String| async move {
                    let value: serde_json::Value = serde_json::from_str(&body).unwrap();
                    *t.seed.lock().unwrap() = value["seed"].as_u64().unwrap();
                    t.calls.lock().unwrap().push(format!("seed {}", value["seed"]));
                    axum::Json(serde_json::json!({"seed": value["seed"], "reset": true}))
                }),
            )
            .route(
                "/v1/state",
                post(|State(t): State<FakeTwin>, body: String| async move {
                    t.calls.lock().unwrap().push(format!("force {body}"));
                    if body.contains("impossible") {
                        return (
                            StatusCode::UNPROCESSABLE_ENTITY,
                            axum::Json(serde_json::json!({"forced": false, "law": "partitions only grow", "reason": "3 cannot become 2"})),
                        );
                    }
                    t.history.lock().unwrap().push(r#"{"seq":1,"source":"force"}"#.into());
                    (StatusCode::OK, axum::Json(serde_json::json!({"forced": true, "operations": 1})))
                }),
            )
            .route(
                "/v1/faults/{name}",
                post(|State(t): State<FakeTwin>, UrlPath(name): UrlPath<String>, body: String| async move {
                    t.calls.lock().unwrap().push(format!("fault {name} {body}"));
                    if name == "undeclared" {
                        return (StatusCode::BAD_REQUEST, axum::Json(serde_json::json!({"error": "no fault undeclared"})));
                    }
                    (StatusCode::CREATED, axum::Json(serde_json::json!({"id": 1, "name": name})))
                }),
            )
            .route(
                "/v1/history",
                get(|State(t): State<FakeTwin>, Query(q): Query<BTreeMap<String, String>>| async move {
                    let history = t.history.lock().unwrap().clone();
                    if q.get("format").map(String::as_str) == Some("jsonl") {
                        history.iter().map(|l| format!("{l}\n")).collect::<String>()
                    } else {
                        format!("[{}]", history.join(","))
                    }
                }),
            )
            .with_state(self);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        url
    }
}

fn problems(text: &str) -> Vec<String> {
    match Manifest::parse(text) {
        Ok(_) => Vec::new(),
        Err(error) => error.problems.iter().map(|p| p.to_string()).collect(),
    }
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

fn assert_problem(text: &str, at: &str, needle: &str) {
    let found = problems(text);
    assert!(
        found.iter().any(|p| p.starts_with(&format!("{at}: ")) && p.contains(needle)),
        "expected a problem at {at} containing {needle:?}, got {found:#?}"
    );
}

const TWIN_AT: &str = "environments.local.dependencies.kafka.twin";

/// ref:REQ-twin-start-setup
#[test]
fn faults_and_a_state_need_a_control_plane() {
    let text = manifest_with_twin(
        "podman",
        "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092]\nstate: {topics: []}\nfaults: [{name: consumer-lag}]",
    );
    assert_problem(&text, &format!("{TWIN_AT}.state"), "needs `admin`");
    assert_problem(&text, &format!("{TWIN_AT}.faults"), "needs `admin`");
    let fixed = text.replace("ports: [9092]", "ports: [9092]\n          admin: {port: 9644}");
    assert!(problems(&fixed).is_empty(), "{:#?}", problems(&fixed));
}

/// ref:REQ-twin-start-setup
#[test]
fn the_control_plane_port_is_checked_with_every_other_published_port() {
    let text = manifest_with_twin(
        "podman",
        "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092, 9644]\nadmin: {}",
    );
    assert_problem(&text, &format!("{TWIN_AT}.ports"), "control plane's");
    let clash = manifest_with_twin(
        "podman",
        "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092]\nadmin: {port: 9092}",
    );
    assert_problem(&clash, "environments.local.dependencies.kafka.ports", "already published");
}

/// ref:REQ-twin-start-setup
#[test]
fn a_cloud_twin_s_control_plane_is_a_url_and_a_seed_is_given_once() {
    let cloud = manifest_with_twin(
        "aws",
        "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092]\nadmin: {}\nfaults: [{name: x}]",
    );
    assert_problem(&cloud, &format!("{TWIN_AT}.admin.url"), "give the URL");
    let twice = manifest_with_twin(
        "podman",
        "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092]\nseed: 1\nconfig: {seed: 2}",
    );
    assert_problem(&twice, &format!("{TWIN_AT}.config.seed"), "give it once");
}

/// ref:REQ-twin-start-setup
#[test]
fn seed_and_contract_reach_the_twin_in_twin_config() {
    let manifest = Manifest::parse(&manifest_with_twin(
        "podman",
        "image: lawtwin/http\nversion: 0.1.0\nconformance: conformant\nports: [8080]\nseed: 7\ncontract: petstore\nconfig: {clock: frozen}\nadvertise_variable: LAWTWIN_ADVERTISE",
    ))
    .unwrap();
    let resolved = ironframe_core::settings::resolve(&manifest, "local", &BTreeMap::new()).unwrap();
    let env = &resolved.dependencies[0].container_env;
    let config: serde_json::Value = serde_json::from_str(&env["TWIN_CONFIG"]).unwrap();
    assert_eq!(config, serde_json::json!({"clock": "frozen", "seed": 7, "contract": "petstore"}));
    assert_eq!(env["LAWTWIN_ADVERTISE"], "localhost:8080");
    assert_eq!(resolved.dependencies[0].stand_in.as_ref().unwrap().seed, Some(7));
}

/// ref:REQ-twin-start-setup
#[test]
fn an_advertised_address_is_set_only_where_ironframe_knows_it() {
    let aws = manifest_with_twin(
        "aws",
        "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092]\nadvertise_variable: LAWTWIN_ADVERTISE",
    );
    assert_problem(&aws, &format!("{TWIN_AT}.advertise_variable"), "on aws");
    let gcp = manifest_with_twin(
        "gcp",
        "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092, 9093]\nprotocol: tcp\nadvertise_variable: LAWTWIN_ADVERTISE",
    );
    assert!(problems(&gcp).is_empty(), "{:#?}", problems(&gcp));
    let cloud_run = gcp.replace("protocol: tcp", "protocol: http");
    assert_problem(&cloud_run, &format!("{TWIN_AT}.ports"), "Cloud Run serves one port");
}

const KAFKA_REPORT: &str = r#"{"twin": "kafka", "release": "0.1.0", "contract": {"package": "lawtwin.kafka", "version": "0.1.0"},
  "level": {"number": 3, "name": "answers", "means": "..."}}"#;
const HTTP_REPORT: &str = r#"{"contract": "lawtwin.petstore", "real": {}, "divergences": [], "level": "conformant"}"#;

/// ref:REQ-conformance-matches-report
#[test]
fn both_report_shapes_are_read_and_a_level_matches_by_name_or_number() {
    let kafka = ConformanceReport::parse(KAFKA_REPORT).unwrap();
    assert_eq!((kafka.level.as_str(), kafka.number), ("answers", Some(3)));
    assert_eq!(kafka.release.as_deref(), Some("0.1.0"));
    assert_eq!(kafka.contract.as_deref(), Some("lawtwin.kafka"));
    for declared in ["answers", "Answers", "3", "3-answers"] {
        assert!(kafka.matches(declared), "{declared}");
    }
    assert!(!kafka.matches("exact"));
    let http = ConformanceReport::parse(HTTP_REPORT).unwrap();
    assert_eq!((http.level.as_str(), http.number), ("conformant", None));
    assert_eq!(http.contract.as_deref(), Some("lawtwin.petstore"));
    assert!(ConformanceReport::parse(r#"{"twin": "kafka"}"#).is_err());
}

fn load_with_report(twin: &str, report: &str) -> Result<Manifest, Vec<String>> {
    let directory = tempfile::tempdir().unwrap();
    std::fs::write(directory.path().join("report.json"), report).unwrap();
    let path = directory.path().join("ironframe.yaml");
    std::fs::write(&path, manifest_with_twin("podman", twin)).unwrap();
    Manifest::load(&path).map_err(|e| e.problems.iter().map(|p| p.to_string()).collect())
}

/// ref:REQ-conformance-matches-report
#[test]
fn a_twin_s_level_is_read_from_its_report_and_recorded() {
    let manifest = load_with_report(
        "image: lawtwin/kafka\nversion: 0.1.0\nconformance: {report: report.json}\nports: [9092]",
        KAFKA_REPORT,
    )
    .unwrap();
    let resolved = ironframe_core::settings::resolve(&manifest, "local", &BTreeMap::new()).unwrap();
    assert_eq!(resolved.dependencies[0].stand_in.as_ref().unwrap().conformance, "answers");
    let declared = load_with_report(
        "image: lawtwin/kafka\nversion: 0.1.0\nconformance: {level: '3', report: report.json}\nports: [9092]",
        KAFKA_REPORT,
    );
    assert!(declared.is_ok(), "{declared:?}");
}

/// ref:REQ-conformance-matches-report
#[test]
fn a_declared_level_the_report_does_not_give_is_refused() {
    let found = load_with_report(
        "image: lawtwin/kafka\nversion: 0.1.0\nconformance: {level: exact, report: report.json}\nports: [9092]",
        KAFKA_REPORT,
    )
    .unwrap_err();
    assert!(
        found.iter().any(|p| p.contains("declares conformance \"exact\", but its report gives level 3 (answers)")),
        "{found:#?}"
    );
}

/// ref:REQ-conformance-matches-report
#[test]
fn a_report_for_another_release_twin_or_contract_is_refused() {
    let found = load_with_report(
        "image: lawtwin/kafka\nversion: 0.2.0\nconformance: {report: report.json}\nports: [9092]",
        KAFKA_REPORT,
    )
    .unwrap_err();
    assert!(found.iter().any(|p| p.contains("for release 0.1.0, but the twin is version 0.2.0")), "{found:#?}");
    let found = load_with_report(
        "image: lawtwin/http\nversion: 0.1.0\nconformance: {report: report.json}\nports: [9092]",
        KAFKA_REPORT,
    )
    .unwrap_err();
    assert!(found.iter().any(|p| p.contains("for the kafka twin")), "{found:#?}");
    let found = load_with_report(
        "image: lawtwin/http\nversion: 0.1.0\ncontract: github\nconformance: {report: report.json}\nports: [8080]",
        HTTP_REPORT,
    )
    .unwrap_err();
    assert!(
        found.iter().any(|p| p.contains("checked contract lawtwin.petstore, but the twin serves github")),
        "{found:#?}"
    );
    let missing = load_with_report(
        "image: lawtwin/kafka\nversion: 0.1.0\nconformance: {report: nowhere.json}\nports: [9092]",
        KAFKA_REPORT,
    )
    .unwrap_err();
    assert!(missing.iter().any(|p| p.contains("nowhere.json: cannot read it")), "{missing:#?}");
}

/// ref:REQ-twin-start-setup
#[tokio::test]
async fn set_up_sets_the_seed_forces_the_state_and_raises_each_fault_in_order() {
    let fake = FakeTwin::default();
    let url = fake.clone().serve().await;
    let manifest = Manifest::parse(&manifest_with_twin(
        "podman",
        &format!(
            "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092]\nseed: 42\nadmin: {{url: '{url}'}}\nstate: {{topics: [orders]}}\nfaults:\n  - {{name: latency, params: {{delay: 5ms}}}}\n  - {{name: duplicate-delivery, params: {{count: 2}}}}"
        ),
    ))
    .unwrap();
    let ironframe_core::manifest::Binding::Twin(twin) = &manifest.environments["local"].dependencies["kafka"] else {
        panic!()
    };
    let record = ControlPlane::new(url).set_up(twin, std::path::Path::new(".")).await.unwrap();
    assert_eq!(record.seed, Some(42));
    assert!(record.forced);
    assert_eq!(record.faults, ["latency", "duplicate-delivery"]);
    assert_eq!(
        fake.calls(),
        [
            "seed 42",
            r#"force {"topics":["orders"]}"#,
            r#"fault latency {"delay":"5ms"}"#,
            r#"fault duplicate-delivery {"count":2}"#
        ]
    );
}

/// ref:REQ-twin-start-setup
#[tokio::test]
async fn a_refused_state_names_the_law_and_exits_2_like_lawtwin() {
    let url = FakeTwin::default().serve().await;
    let control = ControlPlane::new(url);
    let error = control.force(r#"{"impossible": true}"#.into()).await.unwrap_err();
    assert!(matches!(&error, TwinError::Refused { law, .. } if law == "partitions only grow"));
    assert_eq!(error.exit_code(), 2);
    assert_eq!(error.to_string(), "refused: the law `partitions only grow` forbids this state: 3 cannot become 2");
    let undeclared = control.raise(&parse_fault("undeclared", &[]).unwrap()).await.unwrap_err();
    assert_eq!(undeclared.to_string(), "no fault undeclared");
    assert_eq!(undeclared.exit_code(), 1);
}

/// ref:REQ-twin-start-setup
#[test]
fn fault_parameters_are_read_as_lawtwin_reads_them() {
    let fault = parse_fault("latency", &["delay=5ms".into(), "count=3".into()]).unwrap();
    assert_eq!(fault.params["delay"], "5ms");
    assert_eq!(fault.params["count"], 3);
    assert!(parse_fault("latency", &["delay".into()]).is_err());
}

/// ref:REQ-attestation-stand-in-run
#[tokio::test]
async fn up_sets_the_twin_up_and_attest_records_its_seed_and_history_digest() {
    fake_tools();
    let fake = FakeTwin::default();
    let url = fake.clone().serve().await;
    let manifest = Manifest::parse(&manifest_with_twin(
        "podman",
        &format!(
            "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092]\nseed: 9\nadmin: {{url: '{url}'}}\nstate: {{topics: [orders]}}"
        ),
    ))
    .unwrap();
    let directory = tempfile::tempdir().unwrap();
    let podman = Recorder::new(|_| ok(""));
    let options = UpOptions { sync: true, wait: Duration::from_secs(2) };
    let report = ops::up(&manifest, directory.path(), "local", &podman, &FakeClouds::default(), &options, &mut |_| {})
        .await
        .unwrap();
    let stand_in = report.attestation.dependencies[0].stand_in.clone().unwrap();
    assert_eq!(stand_in.seed, Some(9));
    assert_eq!(stand_in.conformance, "answers");
    assert_eq!(stand_in.history_entries, Some(1));
    let kept = std::fs::read_to_string(directory.path().join(".ironframe/local/history/kafka.jsonl")).unwrap();
    assert_eq!(stand_in.history_digest.as_deref(), Some(history_digest(&kept).as_str()));
    assert!(is_history_digest(stand_in.history_digest.as_deref().unwrap()));

    fake.history.lock().unwrap().push(r#"{"seq":2,"source":"wire"}"#.into());
    let (attestation, path) = ops::attest_now(&manifest, directory.path(), "local", None).await.unwrap();
    let later = attestation.dependencies[0].stand_in.clone().unwrap();
    assert_eq!(later.history_entries, Some(2));
    assert_ne!(later.history_digest, stand_in.history_digest, "the digest follows what the app did");
    assert_eq!(attestation.run.id, report.attestation.run.id);
    assert_eq!(Attestation::from_json(&std::fs::read_to_string(path).unwrap()).unwrap(), attestation);
    let control = ops::control_plane(&manifest, directory.path(), "local", "kafka").unwrap();
    assert_eq!(control.url, url);
}

/// ref:REQ-twin-start-setup
#[tokio::test]
async fn a_twin_whose_control_plane_never_answers_stops_up() {
    fake_tools();
    let manifest = Manifest::parse(&manifest_with_twin(
        "podman",
        "image: lawtwin/kafka\nversion: 0.1.0\nconformance: answers\nports: [9092]\nadmin: {url: 'http://127.0.0.1:1'}",
    ))
    .unwrap();
    let directory = tempfile::tempdir().unwrap();
    let options = UpOptions { sync: false, wait: Duration::ZERO };
    let error = ops::up(
        &manifest,
        directory.path(),
        "local",
        &Recorder::new(|_| ok("")),
        &FakeClouds::default(),
        &options,
        &mut |_| {},
    )
    .await
    .unwrap_err();
    assert!(matches!(error, OpsError::Twin { .. }), "{error}");
    assert!(error.to_string().contains("does not answer"), "{error}");
}

/// ref:REQ-conformance-matches-report
#[tokio::test]
async fn a_level_read_from_the_image_label_is_recorded_and_checked() {
    fake_tools();
    let text = manifest_with_twin(
        "podman",
        "image: lawtwin/kafka\nversion: 0.1.0\nconformance: {image_label: io.lawtwin.conformance}\nports: [19092]",
    );
    let manifest = Manifest::parse(&text).unwrap();
    let labelled = |level: &'static str| {
        Recorder::new(move |args| {
            if args.len() > 1 && args[0] == "image" && args[1] == "inspect" {
                ok(&format!(r#"{{"io.lawtwin.conformance": "{level}"}}"#))
            } else {
                ok("")
            }
        })
    };
    let directory = tempfile::tempdir().unwrap();
    let options = UpOptions { sync: false, wait: Duration::ZERO };
    let report = ops::up(
        &manifest,
        directory.path(),
        "local",
        &labelled("answers"),
        &FakeClouds::default(),
        &options,
        &mut |_| {},
    )
    .await
    .unwrap();
    assert_eq!(report.attestation.dependencies[0].stand_in.as_ref().unwrap().conformance, "answers");
    let declared = Manifest::parse(&text.replace("{image_label:", "{level: exact, image_label:")).unwrap();
    let error = ops::up(
        &declared,
        directory.path(),
        "local",
        &labelled("answers"),
        &FakeClouds::default(),
        &options,
        &mut |_| {},
    )
    .await
    .unwrap_err();
    assert!(error.to_string().contains("declares conformance \"exact\", but image label"), "{error}");
}
