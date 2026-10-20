//! The environment attestation, version 1: a small JSON document that records, for one run in one
//! environment, which endpoint each dependency reached and whether that endpoint was the real
//! dependency or a stand-in with a declared conformance level. Any tool may write it and any tool
//! may read it, so nothing in it names Ironframe, LawSpec or LawTwin; the schema is
//! schema/attestation-v1.schema.json and the page docs/reference/attestation.md.
//! ref:DEC-attestation-format

use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use time::OffsetDateTime;

/// The value of `format` in every attestation, so a reader can tell the document apart from any
/// other JSON it is handed before trusting a single field. ref:DEC-attestation-format
pub const FORMAT: &str = "environment-attestation";

/// The one version this crate writes and reads. Fields added later keep the version, since readers
/// ignore what they do not know; a change that would mislead an older reader raises it.
/// ref:DEC-attestation-format
pub const VERSION: u32 = 1;

/// One run's attestation: the environment, the run, the tool that wrote it, and a record per
/// dependency. ref:DEC-attestation-format
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Attestation {
    /// Always [`FORMAT`], so the document identifies itself.
    pub format: String,
    /// The format version, [`VERSION`] for every document this crate writes.
    pub version: u32,
    /// The environment the run used, as the writer names it, such as `local` or `staging`.
    pub environment: String,
    /// When the run started and which run it was.
    pub run: Run,
    /// The tool that wrote the document; informative only, since a reader must not depend on who
    /// wrote it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub producer: Option<Producer>,
    /// One record per dependency, named uniquely.
    pub dependencies: Vec<DependencyRecord>,
    /// The architecture the wiring was resolved from, when it was resolved from one: each
    /// document's digest, the resolved topology's and the elements the run involved.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub architecture: Option<ArchitectureRef>,
    /// The application the run exercised, when the writer knows it: its node, contract and
    /// implementation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub application: Option<ApplicationRef>,
    /// What the document records: wiring alone, a run under way, or a run that completed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub execution: Option<Execution>,
}

/// The architecture a run's wiring was resolved from, by identity. ref:DEC-attestation-architecture
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArchitectureRef {
    /// The architecture document, by file name or URL.
    pub document: String,
    /// `sha256:` digest of the architecture document.
    pub digest: String,
    /// The architecture's own unique-id, when it gives one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unique_id: Option<String>,
    /// The decorators document, by file name or URL.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub decorators: Option<String>,
    /// `sha256:` digest of the decorators document.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub decorators_digest: Option<String>,
    /// `sha256:` digest of the resolved topology: the planned wiring.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub topology_digest: Option<String>,
    /// The unique-ids of the architecture elements the run involved: the application node, its
    /// relationships and the dependency nodes they reach.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub elements: Vec<String>,
}

/// A contract identity: a package, its version or version requirement, and abilities by their
/// resolved identity. ref:DEC-attestation-architecture
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContractRef {
    /// The package.
    pub package: String,
    /// An exact version, or a requirement.
    pub version: String,
    /// The abilities, such as `unit::ability::Name`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub abilities: Vec<String>,
}

/// What implemented an application or a dependency in the run. ref:DEC-attestation-architecture
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct Implementation {
    /// `real-provider`, `fixture` or `application`.
    pub kind: String,
    /// The product, such as an image name or a module path.
    pub product: String,
    /// Its version.
    pub version: String,
    /// The commit it was built from, when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
    /// The digest of the image it ran from, when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_digest: Option<String>,
}

/// The application a run exercised. ref:DEC-attestation-architecture
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApplicationRef {
    /// The architecture node it is.
    pub node: String,
    /// The contract it implements.
    pub contract: ContractRef,
    /// What implemented it.
    pub implementation: Implementation,
}

/// What an attestation records: the wiring alone, a run under way, or a completed run.
/// ref:DEC-calm-planned-vs-completed
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ExecutionStatus {
    /// The environment was wired and its endpoints probed; nothing ran.
    Wired,
    /// The run had started when the document was written.
    Running,
    /// The run completed; its outcome is recorded.
    Completed,
}

/// The run's execution: its status and, once completed, its outcome. ref:DEC-calm-planned-vs-completed
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Execution {
    /// Wired, running or completed.
    pub status: ExecutionStatus,
    /// The command the run executed, as words.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub command: Vec<String>,
    /// The command's exit code; present exactly when the run completed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    /// When the run completed.
    #[serde(default, skip_serializing_if = "Option::is_none", with = "time::serde::rfc3339::option")]
    pub finished_at: Option<OffsetDateTime>,
    /// The environment run it happened in, such as the run `up` started.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub environment_run: Option<String>,
}

/// The run an attestation belongs to: an id chosen by the writer and the times it started and was
/// recorded, in RFC 3339. ref:DEC-attestation-format
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Run {
    /// An identifier unique to the run, such as a UUID; readers compare it, never parse it.
    pub id: String,
    /// When the run began.
    #[serde(with = "time::serde::rfc3339")]
    pub started_at: OffsetDateTime,
    /// When the document was written, at or after `started_at`.
    #[serde(with = "time::serde::rfc3339")]
    pub recorded_at: OffsetDateTime,
}

/// The tool and version that wrote an attestation, for a person reading it.
/// ref:DEC-attestation-format
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Producer {
    /// The tool's name.
    pub name: String,
    /// The tool's version.
    pub version: String,
}

/// What one dependency resolved to in the run. ref:DEC-attestation-format
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyRecord {
    /// The dependency's name, unique within the attestation.
    pub name: String,
    /// The endpoint the run was wired to, as the application was told it, such as `localhost:9092`.
    pub endpoint: String,
    /// Whether the writer reached the endpoint when it recorded the run.
    pub reached: bool,
    /// The real dependency or a stand-in for it.
    pub kind: Kind,
    /// The stand-in's product, version and declared conformance level; present exactly when `kind`
    /// is `stand-in`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stand_in: Option<StandIn>,
    /// The architecture node the dependency is, when the wiring came from an architecture.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub node: Option<String>,
    /// The relationship the application reached it through.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edge: Option<String>,
    /// The contract the dependency's binding had to satisfy.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contract: Option<ContractRef>,
    /// What implemented the dependency: the real provider or a fixture, with its identity.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub implementation: Option<Implementation>,
    /// What was observed of the dependency when the run completed; present only on a completed run.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed: Option<Completed>,
}

/// A dependency as observed once the run completed: whether it still answered and, for a stand-in,
/// the digest of its history then. The stand-in's own fields record it as the run began, so the
/// wiring a reader keys its results by is the same in the running and the completed document.
/// ref:DEC-calm-planned-vs-completed ref:DEC-history-digest
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct Completed {
    /// Whether the endpoint answered when the run completed.
    pub reached: bool,
    /// `sha256:` digest of the stand-in's history when the run completed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub history_digest: Option<String>,
    /// How many entries that history held.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub history_entries: Option<u64>,
}

/// Whether an endpoint served the real dependency or a stand-in, which is what evidence needs to
/// tell an obligation checked against production behaviour from one checked against a model of it.
/// ref:DEC-attestation-format
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Kind {
    /// The dependency itself, hosted or run from its own image.
    #[serde(rename = "real")]
    Real,
    /// Something standing in for the dependency.
    #[serde(rename = "stand-in")]
    StandIn,
}

/// The stand-in a dependency resolved to. The conformance level is the one its maker declares for
/// that release; the attestation records it and does not judge it. The seed and the history digest
/// are optional: a writer that can read them from the stand-in records them, so evidence can cite
/// exactly which deterministic run of which stand-in the application talked to.
/// ref:DEC-attestation-format ref:DEC-history-digest
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct StandIn {
    /// The stand-in's product name, such as an image name.
    pub product: String,
    /// The stand-in's version.
    pub version: String,
    /// The conformance level declared for that version.
    pub conformance: String,
    /// The seed of the stand-in's random choices in this run, when it has one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seed: Option<u64>,
    /// `sha256:<64 lowercase hex digits>` of the stand-in's history of the run, as its maker's tool
    /// exports it, at the time the document was recorded.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub history_digest: Option<String>,
    /// How many entries that history held.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub history_entries: Option<u64>,
    /// The contract identity the stand-in stands in for, when its binding says.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stands_in_for: Option<ContractRef>,
}

/// Whether `digest` is `sha256:` followed by 64 lowercase hexadecimal digits, the one digest form
/// version 1 knows. ref:DEC-history-digest
pub fn is_history_digest(digest: &str) -> bool {
    digest
        .strip_prefix("sha256:")
        .is_some_and(|hex| hex.len() == 64 && hex.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)))
}

/// Why a document is not a valid attestation, each naming the field at fault.
/// ref:DEC-attestation-format
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum AttestationError {
    /// The text is not JSON of the attestation's shape.
    #[error("not an environment attestation: {0}")]
    Malformed(String),
    /// `format` names some other document.
    #[error("format is {0:?}, expected {FORMAT:?}")]
    WrongFormat(String),
    /// `version` is one this reader does not know.
    #[error("attestation version {0} is not supported; this reader knows version {VERSION}")]
    UnsupportedVersion(u32),
    /// A required text field is empty.
    #[error("{0} must not be empty")]
    Empty(String),
    /// Two dependency records share a name.
    #[error("dependency {0:?} is recorded twice")]
    DuplicateDependency(String),
    /// `stand_in` is missing on a stand-in, or present on a real dependency.
    #[error("dependency {0:?}: stand_in must be present exactly when kind is \"stand-in\"")]
    StandInMismatch(String),
    /// The run was recorded before it started.
    #[error("run.recorded_at is before run.started_at")]
    RecordedBeforeStart,
    /// A history digest is not `sha256:` and 64 lowercase hexadecimal digits.
    #[error("dependency {0:?}: stand_in.history_digest must be sha256: followed by 64 lowercase hex digits")]
    BadHistoryDigest(String),
    /// The execution's outcome disagrees with its status.
    #[error("execution: {0}")]
    Execution(String),
}

impl Attestation {
    /// A version 1 attestation of the given environment and run, with no dependencies yet.
    pub fn new(environment: impl Into<String>, run: Run) -> Self {
        Attestation {
            format: FORMAT.to_string(),
            version: VERSION,
            environment: environment.into(),
            run,
            producer: None,
            dependencies: Vec::new(),
            architecture: None,
            application: None,
            execution: None,
        }
    }

    /// Checks the rules the schema cannot state: unique names, `stand_in` agreeing with `kind`,
    /// and the run's times in order. Every writer calls it before writing and every reader after
    /// reading, so a document that passes once passes everywhere. ref:DEC-attestation-format
    pub fn validate(&self) -> Result<(), AttestationError> {
        if self.format != FORMAT {
            return Err(AttestationError::WrongFormat(self.format.clone()));
        }
        if self.version != VERSION {
            return Err(AttestationError::UnsupportedVersion(self.version));
        }
        if self.environment.is_empty() {
            return Err(AttestationError::Empty("environment".into()));
        }
        if self.run.id.is_empty() {
            return Err(AttestationError::Empty("run.id".into()));
        }
        if self.run.recorded_at < self.run.started_at {
            return Err(AttestationError::RecordedBeforeStart);
        }
        let mut seen = BTreeSet::new();
        for dependency in &self.dependencies {
            if dependency.name.is_empty() {
                return Err(AttestationError::Empty("dependencies[].name".into()));
            }
            if !seen.insert(dependency.name.as_str()) {
                return Err(AttestationError::DuplicateDependency(dependency.name.clone()));
            }
            if dependency.endpoint.is_empty() {
                return Err(AttestationError::Empty(format!("dependency {:?} endpoint", dependency.name)));
            }
            if (dependency.kind == Kind::StandIn) != dependency.stand_in.is_some() {
                return Err(AttestationError::StandInMismatch(dependency.name.clone()));
            }
            if let Some(digest) = dependency.stand_in.as_ref().and_then(|s| s.history_digest.as_deref())
                && !is_history_digest(digest)
            {
                return Err(AttestationError::BadHistoryDigest(dependency.name.clone()));
            }
            let completed = self.execution.as_ref().is_some_and(|e| e.status == ExecutionStatus::Completed);
            if let Some(after) = &dependency.completed {
                if !completed {
                    return Err(AttestationError::Execution(format!(
                        "dependency {:?} records what was observed after the run, but the run has not completed",
                        dependency.name
                    )));
                }
                if after.history_digest.as_deref().is_some_and(|d| !is_history_digest(d)) {
                    return Err(AttestationError::BadHistoryDigest(dependency.name.clone()));
                }
            }
        }
        if let Some(execution) = &self.execution {
            let completed = execution.status == ExecutionStatus::Completed;
            if completed != execution.exit_code.is_some() || completed != execution.finished_at.is_some() {
                return Err(AttestationError::Execution(
                    "exit_code and finished_at are present exactly when the run completed".into(),
                ));
            }
            if execution.finished_at.is_some_and(|f| f < self.run.started_at) {
                return Err(AttestationError::Execution("finished_at is before run.started_at".into()));
            }
        }
        Ok(())
    }

    /// Reads and validates an attestation from JSON text. Unknown fields are ignored, so a later
    /// writer may add fields without breaking this reader. ref:DEC-attestation-format
    pub fn from_json(text: &str) -> Result<Self, AttestationError> {
        let value: serde_json::Value =
            serde_json::from_str(text).map_err(|error| AttestationError::Malformed(error.to_string()))?;
        if let Some(format) = value.get("format").and_then(|f| f.as_str())
            && format != FORMAT
        {
            return Err(AttestationError::WrongFormat(format.to_string()));
        }
        if let Some(version) = value.get("version").and_then(|v| v.as_u64())
            && version != u64::from(VERSION)
        {
            return Err(AttestationError::UnsupportedVersion(u32::try_from(version).unwrap_or(u32::MAX)));
        }
        let attestation: Attestation =
            serde_json::from_value(value).map_err(|error| AttestationError::Malformed(error.to_string()))?;
        attestation.validate()?;
        Ok(attestation)
    }

    /// Validates the attestation and writes it as indented JSON with a trailing newline.
    /// ref:DEC-attestation-format
    pub fn to_json(&self) -> Result<String, AttestationError> {
        self.validate()?;
        let mut text =
            serde_json::to_string_pretty(self).map_err(|error| AttestationError::Malformed(error.to_string()))?;
        text.push('\n');
        Ok(text)
    }
}

/// The JSON Schema of version 1, embedded so a tool can hand it out or check a document against it
/// without the repository. ref:DEC-attestation-format
pub const SCHEMA_V1: &str = include_str!("../../../schema/attestation-v1.schema.json");
