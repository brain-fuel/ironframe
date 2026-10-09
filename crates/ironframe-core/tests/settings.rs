//! Resolving an environment decides every endpoint once, and the settings the application reads
//! are rendered from it, so compose, OpenTofu, the configuration service, the sync targets and the
//! attestation agree. ref:DEC-manifest-shape

mod common;

use ironframe_core::settings::{
    BindingKind, ResolveError, parse_dotenv, qualify_image, render_dotenv, resolve, split_endpoint,
};
use std::collections::BTreeMap;

/// ref:REQ-settings-resolution
#[test]
fn a_local_twin_is_reached_at_localhost_on_its_first_port() {
    let local = resolve(&common::manifest(), "local", &BTreeMap::new()).unwrap();
    let kafka = &local.dependencies[0];
    assert_eq!((kafka.name.as_str(), kafka.kind), ("kafka", BindingKind::Twin));
    assert_eq!(kafka.endpoint, "localhost:9092");
    assert_eq!(kafka.image.as_deref(), Some("docker.io/lawtwin/kafka:0.1.0"));
    assert_eq!(kafka.settings["KAFKA_BOOTSTRAP_SERVERS"], "localhost:9092");
    assert_eq!(kafka.settings["KAFKA_KIND"], "twin");
    let stand_in = kafka.stand_in.as_ref().unwrap();
    assert_eq!(
        (stand_in.product.as_str(), stand_in.version.as_str(), stand_in.conformance.as_str()),
        ("lawtwin/kafka", "0.1.0", "unrated")
    );
}

/// ref:REQ-settings-resolution
#[test]
fn a_twin_receives_its_config_as_json_in_twin_config() {
    let local = resolve(&common::manifest(), "local", &BTreeMap::new()).unwrap();
    let env = &local.dependencies[0].container_env;
    assert_eq!(env["TWIN_CONFIG"], r#"{"seed":42}"#);
    assert_eq!(env["LOG_LEVEL"], "debug");
    assert_eq!(local.dependencies[1].container_env["TWIN_CONFIG"], "{}");
}

/// ref:REQ-settings-resolution
#[test]
fn a_pinned_endpoint_wins_and_its_parts_fill_the_templates() {
    let local = resolve(&common::manifest(), "local", &BTreeMap::new()).unwrap();
    let payments = &local.settings();
    assert_eq!(payments["PAYMENTS_URL"], "http://localhost:8080/v1");
    assert_eq!(payments["PAYMENTS_HOST"], "localhost");
    assert_eq!(payments["PAYMENTS_PORT"], "8080");
    assert_eq!(payments["PAYMENTS_CREDENTIALS"], "env:PAYMENTS_TOKEN");
}

/// ref:REQ-settings-resolution
#[test]
fn a_cloud_twin_has_no_endpoint_until_it_is_deployed() {
    let error = resolve(&common::manifest(), "staging", &BTreeMap::new()).unwrap_err();
    assert_eq!(error, ResolveError::NotDeployed { environment: "staging".into(), dependency: "kafka".into() });
    assert!(error.to_string().contains("ironframe up staging"));
    let deployed = BTreeMap::from([("kafka".to_string(), "kafka-nlb.elb.amazonaws.com:9092".to_string())]);
    let staging = resolve(&common::manifest(), "staging", &deployed).unwrap();
    let settings = staging.settings();
    assert_eq!(settings["KAFKA_BOOTSTRAP_SERVERS"], "kafka-nlb.elb.amazonaws.com:9092");
    assert_eq!(settings["PAYMENTS_PORT"], "443");
    assert_eq!(settings["KAFKA_KIND"], "twin");
    assert_eq!(staging.dependencies[1].image, None);
}

/// ref:REQ-settings-resolution
#[test]
fn endpoints_split_into_host_and_port_with_scheme_defaults() {
    assert_eq!(split_endpoint("localhost:9092"), ("localhost".into(), Some(9092)));
    assert_eq!(split_endpoint("https://user@api.example.com/v1?x=1"), ("api.example.com".into(), Some(443)));
    assert_eq!(split_endpoint("http://api.example.com"), ("api.example.com".into(), Some(80)));
    assert_eq!(split_endpoint("broker"), ("broker".into(), None));
}

/// ref:REQ-settings-resolution
#[test]
fn short_image_names_are_docker_hub_names() {
    assert_eq!(qualify_image("apache/kafka:4.1.0"), "docker.io/apache/kafka:4.1.0");
    assert_eq!(qualify_image("redis:7"), "docker.io/library/redis:7");
    assert_eq!(qualify_image("ghcr.io/brain-fuel/x:1"), "ghcr.io/brain-fuel/x:1");
    assert_eq!(qualify_image("localhost/ironframe-config-service:0.1.0"), "localhost/ironframe-config-service:0.1.0");
    assert_eq!(qualify_image("registry:5000/team/x:1"), "registry:5000/team/x:1");
}

/// ref:REQ-settings-resolution
#[test]
fn dotenv_output_reads_back_to_the_same_settings() {
    let settings = BTreeMap::from([
        ("PLAIN".to_string(), "localhost:9092,localhost:9093".to_string()),
        ("SPACED".to_string(), "a value with # and \"quotes\"".to_string()),
        ("DOLLAR".to_string(), "$HOME\\path".to_string()),
        ("EMPTY".to_string(), String::new()),
    ]);
    let text = render_dotenv("header line one\nline two", &settings);
    assert!(text.starts_with("# header line one\n# line two\n"));
    assert!(text.contains("PLAIN=localhost:9092,localhost:9093\n"));
    assert_eq!(parse_dotenv(&text), settings);
}
