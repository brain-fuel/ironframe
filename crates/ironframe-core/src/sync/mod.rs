//! Syncing an environment's settings into the places applications already read configuration
//! from: a dotenv file, AWS AppConfig, GCP Parameter Manager and Azure App Configuration. Each
//! cloud is reached through a small trait of the calls the sync makes, so the sync's decisions,
//! what to create, when to write a version and when to leave things alone, are tested against
//! recorded calls, and the trait's real implementation is a thin layer over the cloud's SDK or REST
//! API. ref:DEC-config-sync

pub mod aws;
pub mod azure;
pub mod gcp;

use crate::manifest::{EnvFileTarget, SyncTarget};
use crate::settings::render_dotenv;
use crate::workdir::write_atomically;
use std::collections::BTreeMap;
use std::path::Path;

/// What a sync did to its target. ref:DEC-config-sync
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SyncOutcome {
    /// The target already held these settings, and nothing was written.
    Unchanged,
    /// The target was written; the detail says what was made, such as a version number.
    Updated(String),
}

/// Why a sync failed: the target, and the reason. ref:DEC-config-sync
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("sync to {target} failed: {reason}")]
pub struct SyncError {
    /// The target, as [`describe`] names it.
    pub target: String,
    /// The reason.
    pub reason: String,
}

/// A one-line name for a target, for messages. ref:DEC-config-sync
pub fn describe(target: &SyncTarget, environment: &str) -> String {
    match target {
        SyncTarget::EnvFile(t) => format!("env file {}", t.path.display()),
        SyncTarget::AwsAppconfig(t) => format!(
            "AWS AppConfig {}/{}/{} in {}",
            t.application,
            t.environment.as_deref().unwrap_or(environment),
            t.profile,
            t.region
        ),
        SyncTarget::GcpParameterManager(t) => {
            format!("GCP Parameter Manager projects/{}/locations/{}/parameters/{}", t.project, t.location, t.parameter)
        }
        SyncTarget::AzureAppConfiguration(t) => {
            format!("Azure App Configuration {} label {}", t.endpoint, t.label.as_deref().unwrap_or(environment))
        }
    }
}

/// The settings as the JSON document AppConfig and Parameter Manager hold: one object, keys in
/// name order, so the same settings are always the same bytes. ref:DEC-config-sync
pub fn settings_json(settings: &BTreeMap<String, String>) -> Vec<u8> {
    let mut bytes = serde_json::to_vec_pretty(settings).expect("settings serialise");
    bytes.push(b'\n');
    bytes
}

/// Writes the settings to a dotenv file, relative to the manifest's directory, leaving it alone
/// when it already holds them. ref:DEC-config-sync
pub fn sync_env_file(
    target: &EnvFileTarget,
    manifest_dir: &Path,
    project: &str,
    environment: &str,
    settings: &BTreeMap<String, String>,
) -> Result<SyncOutcome, SyncError> {
    let path = manifest_dir.join(&target.path);
    let header = format!(
        "Settings of environment {environment} of {project}, written by ironframe from the manifest or architecture.\nEdits are overwritten; change those instead."
    );
    let text = render_dotenv(&header, settings);
    match write_atomically(&path, &text) {
        Ok(true) => Ok(SyncOutcome::Updated(path.display().to_string())),
        Ok(false) => Ok(SyncOutcome::Unchanged),
        Err(error) => Err(SyncError { target: format!("env file {}", path.display()), reason: error.to_string() }),
    }
}
