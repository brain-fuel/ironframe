//! The working directory of an environment, `.ironframe/<environment>/` beside the manifest, where
//! Ironframe keeps what it generates and what a run leaves behind: the compose file, the OpenTofu
//! root, the settings document, the deployed endpoints, the run and the attestation. It is ignored
//! by git; the manifest is the only source. ref:DEC-manifest-shape

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// The paths of one environment's working directory. ref:DEC-manifest-shape
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkDir {
    /// `.ironframe/<environment>`.
    pub root: PathBuf,
}

impl WorkDir {
    /// The working directory of `environment` for the manifest in `manifest_dir`.
    pub fn new(manifest_dir: &Path, environment: &str) -> Self {
        WorkDir { root: manifest_dir.join(".ironframe").join(environment) }
    }

    /// The compose file.
    pub fn compose(&self) -> PathBuf {
        self.root.join("compose.yaml")
    }

    /// The OpenTofu root's directory.
    pub fn tofu(&self) -> PathBuf {
        self.root.join("tofu")
    }

    /// The settings document the configuration service serves.
    pub fn settings(&self) -> PathBuf {
        self.root.join("settings.json")
    }

    /// The endpoints a cloud deployment reported.
    pub fn endpoints(&self) -> PathBuf {
        self.root.join("endpoints.json")
    }

    /// The run `up` started.
    pub fn run(&self) -> PathBuf {
        self.root.join("run.json")
    }

    /// The latest attestation.
    pub fn attestation(&self) -> PathBuf {
        self.root.join("attestation.json")
    }

    /// The endpoints a cloud deployment reported, or none before one.
    pub fn read_endpoints(&self) -> std::io::Result<BTreeMap<String, String>> {
        match std::fs::read_to_string(self.endpoints()) {
            Ok(text) => serde_json::from_str(&text).map_err(std::io::Error::other),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(BTreeMap::new()),
            Err(error) => Err(error),
        }
    }
}

/// Writes `contents` to `path` through a temporary file beside it, creating the directory, so a
/// reader never sees half a file. Returns whether the contents changed. ref:DEC-config-sync
pub fn write_atomically(path: &Path, contents: &str) -> std::io::Result<bool> {
    if std::fs::read_to_string(path).is_ok_and(|old| old == contents) {
        return Ok(false);
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let temporary = path.with_extension(format!(
        "{}.tmp",
        path.extension().map(|e| e.to_string_lossy().into_owned()).unwrap_or_default()
    ));
    std::fs::write(&temporary, contents)?;
    std::fs::rename(&temporary, path)?;
    Ok(true)
}
