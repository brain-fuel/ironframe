//! Each sync target receives the environment's settings, creates what is missing, and writes
//! nothing when it already holds them, so a repeated `up` or `sync` is a no-op. The clouds are
//! recorded fakes behind the same traits the SDK and REST clients implement. ref:DEC-config-sync

mod common;

use common::{FakeAppConfig, FakeAppConfiguration, FakeParameterManager};
use ironframe_core::manifest::{AwsAppConfigTarget, AzureAppConfigurationTarget, EnvFileTarget, GcpParameterTarget};
use ironframe_core::settings::parse_dotenv;
use ironframe_core::sync::azure::{ConnectionString, sign};
use ironframe_core::sync::gcp::version_id;
use ironframe_core::sync::{SyncOutcome, aws, azure, gcp, settings_json, sync_env_file};
use std::collections::BTreeMap;

fn settings(bootstrap: &str) -> BTreeMap<String, String> {
    BTreeMap::from([
        ("KAFKA_BOOTSTRAP_SERVERS".to_string(), bootstrap.to_string()),
        ("PAYMENTS_URL".to_string(), "https://payments.example.com".to_string()),
    ])
}

fn aws_target() -> AwsAppConfigTarget {
    AwsAppConfigTarget {
        region: "eu-west-1".into(),
        application: "shop".into(),
        environment: None,
        profile: "connections".into(),
        deployment_strategy: None,
    }
}

/// ref:REQ-config-sync-idempotent
#[tokio::test]
async fn appconfig_is_created_versioned_and_deployed_on_the_first_sync() {
    let api = FakeAppConfig::default();
    let outcome = aws::sync(&api, &aws_target(), "staging", &settings("k:9092")).await.unwrap();
    assert_eq!(outcome, SyncOutcome::Updated("version 1, deployment 1".into()));
    assert_eq!(
        api.calls(),
        [
            "create_application shop",
            "create_environment app-shop staging",
            "create_profile app-shop connections",
            "create_version app-shop profile-connections",
            "deploy app-shop env-staging profile-connections 1 AppConfig.AllAtOnce",
        ]
    );
    let stored: BTreeMap<String, String> = serde_json::from_slice(&api.versions.lock().unwrap()[0]).unwrap();
    assert_eq!(stored, settings("k:9092"));
}

/// ref:REQ-config-sync-idempotent
#[tokio::test]
async fn appconfig_is_left_alone_when_it_already_holds_the_settings() {
    let api = FakeAppConfig::default();
    aws::sync(&api, &aws_target(), "staging", &settings("k:9092")).await.unwrap();
    let before = api.calls().len();
    let again = aws::sync(&api, &aws_target(), "staging", &settings("k:9092")).await.unwrap();
    assert_eq!(again, SyncOutcome::Unchanged);
    assert_eq!(api.calls().len(), before);
    let changed = aws::sync(&api, &aws_target(), "staging", &settings("k2:9092")).await.unwrap();
    assert_eq!(changed, SyncOutcome::Updated("version 2, deployment 1".into()));
    assert_eq!(
        api.calls()[before..],
        [
            "create_version app-shop profile-connections",
            "deploy app-shop env-staging profile-connections 2 AppConfig.AllAtOnce"
        ]
    );
}

/// ref:REQ-config-sync-idempotent
#[tokio::test]
async fn appconfig_uses_the_named_environment_and_strategy() {
    let api = FakeAppConfig::default();
    let target = AwsAppConfigTarget {
        environment: Some("Staging-EU".into()),
        deployment_strategy: Some("AppConfig.Linear50PercentEvery30Seconds".into()),
        ..aws_target()
    };
    aws::sync(&api, &target, "staging", &settings("k:9092")).await.unwrap();
    assert!(api.calls().contains(&"create_environment app-shop Staging-EU".to_string()));
    assert!(api.calls().last().unwrap().ends_with("AppConfig.Linear50PercentEvery30Seconds"));
}

fn gcp_target() -> GcpParameterTarget {
    GcpParameterTarget { project: "shop-prod".into(), location: "global".into(), parameter: "shop-staging".into() }
}

/// ref:REQ-config-sync-idempotent
#[tokio::test]
async fn parameter_manager_gets_one_version_per_distinct_content() {
    let api = FakeParameterManager::default();
    let first = gcp::sync(&api, &gcp_target(), "staging", &settings("k:9092")).await.unwrap();
    let id = version_id(&settings_json(&settings("k:9092")));
    assert_eq!(first, SyncOutcome::Updated(format!("version {id}")));
    assert!(id.starts_with("sha256-") && id.len() == 39);
    let name = "projects/shop-prod/locations/global/parameters/shop-staging";
    assert_eq!(
        *api.calls.lock().unwrap(),
        [
            "create_parameter projects/shop-prod/locations/global shop-staging".to_string(),
            format!("create_version {name} {id}")
        ]
    );
    assert_eq!(gcp::sync(&api, &gcp_target(), "staging", &settings("k:9092")).await.unwrap(), SyncOutcome::Unchanged);
    assert!(matches!(
        gcp::sync(&api, &gcp_target(), "staging", &settings("k2:9092")).await.unwrap(),
        SyncOutcome::Updated(_)
    ));
    assert_eq!(api.parameters.lock().unwrap()[name].len(), 2);
}

fn azure_target() -> AzureAppConfigurationTarget {
    AzureAppConfigurationTarget {
        endpoint: "https://shop.azconfig.io".into(),
        label: None,
        prefix: "shop:".into(),
        connection_string_env: "AZURE_APPCONFIG_CONNECTION_STRING".into(),
    }
}

/// ref:REQ-config-sync-idempotent
#[tokio::test]
async fn app_configuration_writes_only_the_keys_that_changed() {
    let api = FakeAppConfiguration::default();
    let first = azure::sync(&api, &azure_target(), "staging", &settings("k:9092")).await.unwrap();
    assert_eq!(first, SyncOutcome::Updated("shop:KAFKA_BOOTSTRAP_SERVERS, shop:PAYMENTS_URL".into()));
    assert_eq!(
        azure::sync(&api, &azure_target(), "staging", &settings("k:9092")).await.unwrap(),
        SyncOutcome::Unchanged
    );
    azure::sync(&api, &azure_target(), "staging", &settings("k2:9092")).await.unwrap();
    assert_eq!(
        *api.puts.lock().unwrap(),
        [
            "shop:KAFKA_BOOTSTRAP_SERVERS@staging=k:9092",
            "shop:PAYMENTS_URL@staging=https://payments.example.com",
            "shop:KAFKA_BOOTSTRAP_SERVERS@staging=k2:9092",
        ]
    );
}

/// ref:REQ-config-sync-idempotent
#[test]
fn app_configuration_requests_are_signed_as_the_service_documents() {
    // A made-up test key (base64 of "0123456789abcdef0123456789abcdef"), assembled from parts so
    // that it never appears in the repository as a credential-shaped literal.
    let secret = ["MDEyMzQ1Njc4OWFi", "Y2RlZjAxMjM0NTY3", "ODlhYmNkZWY="].concat();
    let credential =
        ConnectionString::parse(&format!("Endpoint=https://shop.azconfig.io;Id=key-1;Secret={secret}")).unwrap();
    assert_eq!(credential.id, "key-1");
    let headers = sign(
        "PUT",
        "shop.azconfig.io",
        "/kv/shop:KAFKA?label=staging&api-version=2023-11-01",
        br#"{"value":"localhost:9092"}"#,
        "Fri, 09 Oct 2026 12:00:00 GMT",
        &credential,
    )
    .unwrap();
    let headers: BTreeMap<_, _> = headers.into_iter().collect();
    assert_eq!(headers["x-ms-content-sha256"], "TZC95FBXR++ubw3F+yF0o6iWFfCbnJyp12lFiCzGi5c=");
    assert_eq!(
        headers["Authorization"],
        "HMAC-SHA256 Credential=key-1&SignedHeaders=x-ms-date;host;x-ms-content-sha256&Signature=3QabqpqkWPpz9W/ZBSh79mI85EP7VADfloGyLm3vl1I="
    );
    assert!(ConnectionString::parse("Endpoint=https://x;Id=a").unwrap_err().contains("secret"));
}

/// ref:REQ-config-sync-idempotent
#[test]
fn an_env_file_is_written_once_and_then_left_alone() {
    let directory = tempfile::tempdir().unwrap();
    let target = EnvFileTarget { path: "config/.env.local".into() };
    let first = sync_env_file(&target, directory.path(), "shop", "local", &settings("localhost:9092")).unwrap();
    assert!(matches!(first, SyncOutcome::Updated(_)));
    let text = std::fs::read_to_string(directory.path().join("config/.env.local")).unwrap();
    assert!(text.starts_with("# Settings of environment local of shop"));
    assert_eq!(parse_dotenv(&text), settings("localhost:9092"));
    assert_eq!(
        sync_env_file(&target, directory.path(), "shop", "local", &settings("localhost:9092")).unwrap(),
        SyncOutcome::Unchanged
    );
}
