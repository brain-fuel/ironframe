//! The attestation survives a write and a read unchanged, agrees with its published schema, and
//! refuses the documents that would mislead a reader. ref:DEC-attestation-format

use ironframe_attestation::{
    ApplicationRef, ArchitectureRef, Attestation, AttestationError, Completed, ContractRef, DependencyRecord,
    Execution, ExecutionStatus, Implementation, Kind, Producer, Run, SCHEMA_V1, StandIn,
};
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

/// ref:REQ-attestation-stand-in-run
#[test]
fn a_stand_in_s_seed_and_history_digest_round_trip_and_satisfy_the_schema() {
    let mut attestation = sample();
    let stand_in = attestation.dependencies[0].stand_in.as_mut().unwrap();
    stand_in.seed = Some(42);
    stand_in.history_digest = Some(format!("sha256:{}", "ab".repeat(32)));
    stand_in.history_entries = Some(7);
    let text = attestation.to_json().unwrap();
    assert_eq!(Attestation::from_json(&text).unwrap(), attestation);
    assert!(schema_accepts(&text), "{text}");
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(value["dependencies"][0]["stand_in"]["seed"], 42);
    assert_eq!(value["dependencies"][0]["stand_in"]["history_entries"], 7);
}

/// ref:REQ-attestation-stand-in-run
#[test]
fn a_history_digest_of_another_form_is_refused_by_reader_and_schema() {
    let mut attestation = sample();
    attestation.dependencies[0].stand_in.as_mut().unwrap().history_digest = Some("md5:abc".into());
    assert_eq!(attestation.to_json(), Err(AttestationError::BadHistoryDigest("kafka".into())));
    let mut value: serde_json::Value = serde_json::from_str(&sample().to_json().unwrap()).unwrap();
    value["dependencies"][0]["stand_in"]["history_digest"] = "sha256:XYZ".into();
    assert!(!schema_accepts(&value.to_string()));
    assert_eq!(Attestation::from_json(&value.to_string()), Err(AttestationError::BadHistoryDigest("kafka".into())));
}

/// A completed run of an application resolved from an architecture: every identity filled in.
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
    first.completed = Some(Completed {
        reached: true,
        history_digest: Some(format!("sha256:{}", "d".repeat(64))),
        history_entries: Some(12),
    });
    attestation.execution = Some(Execution {
        status: ExecutionStatus::Completed,
        command: vec!["lawspec".into(), "test".into()],
        exit_code: Some(0),
        finished_at: Some(datetime!(2026-10-09 12:00:05 UTC)),
        environment_run: Some("up-run".into()),
    });
    attestation
}

/// The fields a CALM run adds round-trip and agree with the schema, and a version 1 reader that
/// does not know them still reads the document. ref:DEC-attestation-architecture
#[test]
fn a_completed_run_round_trips_and_older_readers_ignore_its_additions() {
    let attestation = completed_run();
    let text = attestation.to_json().unwrap();
    assert!(schema_accepts(&text));
    assert_eq!(Attestation::from_json(&text).unwrap(), attestation);
    let mut value: serde_json::Value = serde_json::from_str(&text).unwrap();
    for key in ["architecture", "application", "execution"] {
        value.as_object_mut().unwrap().remove(key);
    }
    for dependency in value["dependencies"].as_array_mut().unwrap() {
        for key in ["node", "edge", "contract", "implementation", "completed"] {
            dependency.as_object_mut().unwrap().remove(key);
        }
    }
    let plain = Attestation::from_json(&value.to_string()).unwrap();
    assert_eq!(plain.dependencies, sample().dependencies);
}

/// A completed run carries its outcome, and only a completed run carries what was observed after
/// it. ref:DEC-calm-planned-vs-completed
#[test]
fn execution_outcome_agrees_with_its_status() {
    let mut no_exit = completed_run();
    no_exit.execution.as_mut().unwrap().exit_code = None;
    assert!(matches!(no_exit.validate(), Err(AttestationError::Execution(_))));

    let mut running_with_outcome = completed_run();
    let execution = running_with_outcome.execution.as_mut().unwrap();
    execution.status = ExecutionStatus::Running;
    execution.exit_code = None;
    execution.finished_at = None;
    assert!(matches!(running_with_outcome.validate(), Err(AttestationError::Execution(_))));

    let mut early = completed_run();
    early.execution.as_mut().unwrap().finished_at = Some(datetime!(2026-10-09 11:00:00 UTC));
    assert!(matches!(early.validate(), Err(AttestationError::Execution(_))));

    let mut bad_digest = completed_run();
    bad_digest.dependencies[0].completed.as_mut().unwrap().history_digest = Some("sha256:XYZ".into());
    assert!(matches!(bad_digest.validate(), Err(AttestationError::BadHistoryDigest(_))));
}
