//! GCP Parameter Manager: the settings become versions of one JSON-format parameter, created when
//! missing. A version's id is the digest of its content, so the same settings are the same version
//! and a repeated sync writes nothing. The real calls go through Google's official Rust client.
//! ref:DEC-config-sync

use super::{SyncError, SyncOutcome, settings_json};
use crate::manifest::{GcpParameterTarget, SyncTarget};
use async_trait::async_trait;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

/// What creating a parameter version did. ref:DEC-config-sync
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VersionCreated {
    /// A new version was written.
    Created,
    /// A version with that id was already there.
    AlreadyExists,
}

/// The Parameter Manager calls the sync makes. Names are full resource names, such as
/// `projects/p/locations/global/parameters/x`. ref:DEC-config-sync
#[async_trait]
pub trait ParameterManagerApi: Send + Sync {
    /// Whether the parameter exists.
    async fn parameter_exists(&self, name: &str) -> Result<bool, String>;
    /// Creates a JSON-format parameter `id` under `parent`.
    async fn create_parameter(&self, parent: &str, id: &str) -> Result<(), String>;
    /// Creates version `id` of the parameter `parameter` holding `data`.
    async fn create_version(&self, parameter: &str, id: &str, data: Vec<u8>) -> Result<VersionCreated, String>;
}

/// The version id of some content: `sha256-` and the first 32 hex digits of its digest.
/// ref:DEC-config-sync
pub fn version_id(content: &[u8]) -> String {
    let digest = Sha256::digest(content);
    let hex: String = digest.iter().take(16).map(|b| format!("{b:02x}")).collect();
    format!("sha256-{hex}")
}

/// Syncs settings into the target's parameter. ref:DEC-config-sync
pub async fn sync(
    api: &dyn ParameterManagerApi,
    target: &GcpParameterTarget,
    environment: &str,
    settings: &BTreeMap<String, String>,
) -> Result<SyncOutcome, SyncError> {
    let fail = |reason: String| SyncError {
        target: super::describe(&SyncTarget::GcpParameterManager(target.clone()), environment),
        reason,
    };
    let parent = format!("projects/{}/locations/{}", target.project, target.location);
    let name = format!("{parent}/parameters/{}", target.parameter);
    if !api.parameter_exists(&name).await.map_err(fail)? {
        api.create_parameter(&parent, &target.parameter).await.map_err(fail)?;
    }
    let content = settings_json(settings);
    let id = version_id(&content);
    match api.create_version(&name, &id, content).await.map_err(fail)? {
        VersionCreated::Created => Ok(SyncOutcome::Updated(format!("version {id}"))),
        VersionCreated::AlreadyExists => Ok(SyncOutcome::Unchanged),
    }
}

/// [`ParameterManagerApi`] over Google's official client, with Application Default Credentials.
/// ref:DEC-config-sync
#[cfg(feature = "gcp")]
pub struct SdkParameterManager {
    client: google_cloud_parametermanager_v1::client::ParameterManager,
}

#[cfg(feature = "gcp")]
impl SdkParameterManager {
    /// A client with Application Default Credentials, as `gcloud auth application-default login`
    /// sets them up.
    pub async fn new() -> Result<Self, String> {
        let client = google_cloud_parametermanager_v1::client::ParameterManager::builder()
            .build()
            .await
            .map_err(|e| e.to_string())?;
        Ok(SdkParameterManager { client })
    }
}

#[cfg(feature = "gcp")]
fn code(error: &google_cloud_parametermanager_v1::Error) -> Option<google_cloud_gax::error::rpc::Code> {
    error.status().map(|s| s.code)
}

#[cfg(feature = "gcp")]
#[async_trait]
impl ParameterManagerApi for SdkParameterManager {
    async fn parameter_exists(&self, name: &str) -> Result<bool, String> {
        match self.client.get_parameter().set_name(name).send().await {
            Ok(_) => Ok(true),
            Err(error) if code(&error) == Some(google_cloud_gax::error::rpc::Code::NotFound) => Ok(false),
            Err(error) => Err(error.to_string()),
        }
    }

    async fn create_parameter(&self, parent: &str, id: &str) -> Result<(), String> {
        use google_cloud_parametermanager_v1::model::{Parameter, ParameterFormat};
        self.client
            .create_parameter()
            .set_parent(parent)
            .set_parameter_id(id)
            .set_parameter(Parameter::new().set_format(ParameterFormat::Json))
            .send()
            .await
            .map(|_| ())
            .map_err(|e| e.to_string())
    }

    async fn create_version(&self, parameter: &str, id: &str, data: Vec<u8>) -> Result<VersionCreated, String> {
        use google_cloud_parametermanager_v1::model::{ParameterVersion, ParameterVersionPayload};
        let version = ParameterVersion::new().set_payload(ParameterVersionPayload::new().set_data(data));
        match self
            .client
            .create_parameter_version()
            .set_parent(parameter)
            .set_parameter_version_id(id)
            .set_parameter_version(version)
            .send()
            .await
        {
            Ok(_) => Ok(VersionCreated::Created),
            Err(error) if code(&error) == Some(google_cloud_gax::error::rpc::Code::AlreadyExists) => {
                Ok(VersionCreated::AlreadyExists)
            }
            Err(error) => Err(error.to_string()),
        }
    }
}
