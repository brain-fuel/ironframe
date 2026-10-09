//! The configuration service serves each environment's settings as JSON, as dotenv and one by one,
//! picks up a rewritten settings file without a restart, and answers a missing environment or
//! setting with a 404 that says what there is. ref:DEC-config-service

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use ironframe_config_service::{Source, router};
use ironframe_core::settings::{SettingsDocument, parse_dotenv};
use std::collections::BTreeMap;
use tower::ServiceExt;

fn document(bootstrap: &str) -> SettingsDocument {
    SettingsDocument {
        project: "kafka-app".into(),
        environments: BTreeMap::from([
            ("local".into(), BTreeMap::from([("KAFKA_BOOTSTRAP_SERVERS".into(), bootstrap.into())])),
            ("staging".into(), BTreeMap::from([("KAFKA_BOOTSTRAP_SERVERS".into(), "b-1.example:9092".into())])),
        ]),
    }
}

async fn get(source: Source, uri: &str) -> (StatusCode, String) {
    let response = router(source).oneshot(Request::get(uri).body(Body::empty()).unwrap()).await.unwrap();
    let status = response.status();
    let body = response.into_body().collect().await.unwrap().to_bytes();
    (status, String::from_utf8(body.to_vec()).unwrap())
}

/// ref:REQ-config-service-serves-settings
#[tokio::test]
async fn an_environment_is_served_as_a_json_object_of_its_settings() {
    let (status, body) = get(Source::Fixed(document("localhost:9092")), "/v1/environments/local").await;
    assert_eq!(status, StatusCode::OK);
    let value: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(value, serde_json::json!({"KAFKA_BOOTSTRAP_SERVERS": "localhost:9092"}));
}

/// ref:REQ-config-service-serves-settings
#[tokio::test]
async fn an_environment_is_served_as_dotenv_that_reads_back_to_the_same_settings() {
    let (status, body) = get(Source::Fixed(document("localhost:9092")), "/v1/environments/staging/env").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(parse_dotenv(&body), document("x").environments["staging"]);
}

/// ref:REQ-config-service-serves-settings
#[tokio::test]
async fn one_setting_is_served_as_its_bare_value() {
    let (status, body) =
        get(Source::Fixed(document("localhost:9092")), "/v1/environments/local/settings/KAFKA_BOOTSTRAP_SERVERS").await;
    assert_eq!((status, body.as_str()), (StatusCode::OK, "localhost:9092"));
}

/// ref:REQ-config-service-serves-settings
#[tokio::test]
async fn the_environment_list_names_the_project_and_its_environments() {
    let (status, body) = get(Source::Fixed(document("localhost:9092")), "/v1/environments").await;
    assert_eq!(status, StatusCode::OK);
    let value: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(value, serde_json::json!({"project": "kafka-app", "environments": ["local", "staging"]}));
    assert_eq!(get(Source::Fixed(document("x")), "/healthz").await, (StatusCode::OK, "ok\n".to_string()));
}

/// ref:REQ-config-service-serves-settings
#[tokio::test]
async fn a_missing_environment_or_setting_is_a_404_naming_what_exists() {
    let (status, body) = get(Source::Fixed(document("x")), "/v1/environments/production").await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(body.contains("local, staging"), "{body}");
    let (status, body) = get(Source::Fixed(document("x")), "/v1/environments/local/settings/NOPE").await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(body.contains("NOPE"), "{body}");
}

/// ref:REQ-config-service-serves-settings
#[tokio::test]
async fn a_rewritten_settings_file_is_served_without_a_restart() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("settings.json");
    std::fs::write(&path, serde_json::to_string(&document("localhost:9092")).unwrap()).unwrap();
    let source = Source::File(path.clone());
    let uri = "/v1/environments/local/settings/KAFKA_BOOTSTRAP_SERVERS";
    assert_eq!(get(source.clone(), uri).await.1, "localhost:9092");
    std::fs::write(&path, serde_json::to_string(&document("localhost:19092")).unwrap()).unwrap();
    assert_eq!(get(source, uri).await.1, "localhost:19092");
}

/// ref:REQ-config-service-serves-settings
#[tokio::test]
async fn an_unreadable_settings_file_is_a_503_not_a_crash() {
    let (status, body) = get(Source::File("/nonexistent/settings.json".into()), "/v1/environments/local").await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert!(body.contains("cannot read"), "{body}");
}
