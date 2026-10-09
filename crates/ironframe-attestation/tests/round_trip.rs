//! The attestation survives a write and a read unchanged, agrees with its published schema, and
//! refuses the documents that would mislead a reader. ref:DEC-attestation-format

use ironframe_attestation::{Attestation, AttestationError, DependencyRecord, Kind, Producer, Run, SCHEMA_V1, StandIn};
use time::macros::datetime;

fn sample() -> Attestation {
    let mut attestation = Attestation::new(
        "local",
        Run {
            id: "0b7c4f5e-9a51-4d7e-8f53-0c3f4a2b6d10".into(),
            started_at: datetime!(2026-10-09 12:00:00 UTC),
            recorded_at: datetime!(2026-10-09 12:00:05 UTC),
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
            }),
        },
        DependencyRecord {
            name: "payments".into(),
            endpoint: "https://payments.example.com".into(),
            reached: false,
            kind: Kind::Real,
            stand_in: None,
        },
    ];
    attestation
}

fn schema_accepts(text: &str) -> bool {
    let schema: serde_json::Value = serde_json::from_str(SCHEMA_V1).unwrap();
    let instance: serde_json::Value = serde_json::from_str(text).unwrap();
    jsonschema::validator_for(&schema).unwrap().is_valid(&instance)
}

/// ref:REQ-attestation-round-trip
#[test]
fn an_attestation_reads_back_exactly_as_it_was_written() {
    let attestation = sample();
    let text = attestation.to_json().unwrap();
    assert_eq!(Attestation::from_json(&text).unwrap(), attestation);
}

/// ref:REQ-attestation-round-trip
#[test]
fn every_written_attestation_satisfies_the_published_schema() {
    let text = sample().to_json().unwrap();
    assert!(schema_accepts(&text), "{text}");
}

/// ref:REQ-attestation-round-trip
#[test]
fn the_written_form_uses_the_documented_field_names_and_kind_words() {
    let text = sample().to_json().unwrap();
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(value["format"], "environment-attestation");
    assert_eq!(value["version"], 1);
    assert_eq!(value["run"]["started_at"], "2026-10-09T12:00:00Z");
    assert_eq!(value["dependencies"][0]["kind"], "stand-in");
    assert_eq!(value["dependencies"][0]["stand_in"]["conformance"], "unrated");
    assert_eq!(value["dependencies"][1]["kind"], "real");
    assert!(value["dependencies"][1].get("stand_in").is_none());
}

/// ref:REQ-attestation-round-trip
#[test]
fn a_reader_ignores_fields_a_later_writer_adds() {
    let mut value: serde_json::Value = serde_json::from_str(&sample().to_json().unwrap()).unwrap();
    value["notes"] = "added later".into();
    value["dependencies"][0]["latency_ms"] = 3.into();
    let read = Attestation::from_json(&value.to_string()).unwrap();
    assert_eq!(read, sample());
    assert!(schema_accepts(&value.to_string()));
}

/// ref:REQ-attestation-round-trip
#[test]
fn a_stand_in_without_its_product_is_refused_by_reader_and_schema() {
    let mut value: serde_json::Value = serde_json::from_str(&sample().to_json().unwrap()).unwrap();
    value["dependencies"][0].as_object_mut().unwrap().remove("stand_in");
    assert_eq!(Attestation::from_json(&value.to_string()), Err(AttestationError::StandInMismatch("kafka".into())));
    assert!(!schema_accepts(&value.to_string()));
}

/// ref:REQ-attestation-round-trip
#[test]
fn another_format_or_version_is_refused_before_any_field_is_trusted() {
    let mut value: serde_json::Value = serde_json::from_str(&sample().to_json().unwrap()).unwrap();
    value["version"] = 2.into();
    assert_eq!(Attestation::from_json(&value.to_string()), Err(AttestationError::UnsupportedVersion(2)));
    value["format"] = "something-else".into();
    assert_eq!(Attestation::from_json(&value.to_string()), Err(AttestationError::WrongFormat("something-else".into())));
}

/// ref:REQ-attestation-round-trip
#[test]
fn a_dependency_recorded_twice_is_refused() {
    let mut attestation = sample();
    attestation.dependencies[1].name = "kafka".into();
    assert_eq!(attestation.to_json(), Err(AttestationError::DuplicateDependency("kafka".into())));
}
