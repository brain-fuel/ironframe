//! Podman for local environments: finding it, checking its compose provider, making sure every
//! image is present before anything starts, and bringing the compose project up and down. An image
//! that cannot be found or pulled stops `up` before a single container runs, with the dependency,
//! the image and podman's reason. ref:DEC-podman-compose ref:REQ-missing-image-fails-clearly

use crate::compose::{LABEL_DEPENDENCY, LABEL_ENVIRONMENT, LABEL_KIND, LABEL_PROJECT};
use crate::process::{CommandRunner, last_line, locate};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::fmt;
use std::path::{Path, PathBuf};

/// Where podman is looked for after `IRONFRAME_PODMAN` and `PATH`: the macOS installer's location.
/// ref:DEC-podman-compose
pub const PODMAN_FALLBACKS: [&str; 1] = ["/opt/podman/bin/podman"];

/// An image `up` needs and could not get. ref:REQ-missing-image-fails-clearly
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MissingImage {
    /// What needs it: a dependency's name, or the configuration service.
    pub needed_by: String,
    /// The image reference.
    pub image: String,
    /// podman's reason the pull failed.
    pub reason: String,
}

/// Why a podman step failed. ref:DEC-podman-compose
#[derive(Debug, thiserror::Error)]
pub enum PodmanError {
    /// podman is not installed where Ironframe looks.
    #[error(
        "podman is required for a podman environment but was not found: set IRONFRAME_PODMAN, put podman on PATH, or install it from https://podman.io (the macOS installer puts it at /opt/podman/bin/podman)"
    )]
    NotInstalled,
    /// `podman compose` has no provider.
    #[error("`podman compose` does not work: {0}; install podman-compose or docker-compose, which podman compose runs")]
    ComposeUnavailable(String),
    /// Images are missing and could not be pulled.
    #[error("{}", MissingImages(.0))]
    ImagesUnavailable(Vec<MissingImage>),
    /// A podman command failed.
    #[error("`podman {command}` failed: {reason}")]
    Failed {
        /// The subcommand.
        command: String,
        /// Its reason.
        reason: String,
    },
    /// podman could not be started.
    #[error("cannot run podman at {0}: {1}")]
    Io(PathBuf, std::io::Error),
}

struct MissingImages<'a>(&'a [MissingImage]);

impl fmt::Display for MissingImages<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} image(s) the environment needs are not available, so nothing was started:", self.0.len())?;
        for missing in self.0 {
            write!(
                f,
                "\n  - {} needs {}: not present locally, and pulling it failed: {}",
                missing.needed_by, missing.image, missing.reason
            )?;
        }
        write!(f, "\nBuild or pull each image, or bind the dependency to something else in the manifest.")
    }
}

/// One container of an environment as podman reports it. ref:DEC-podman-compose
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContainerState {
    /// The dependency or service it serves, from its label.
    pub dependency: String,
    /// `real`, `twin` or `config-service`, from its label.
    pub kind: String,
    /// The container's name.
    pub name: String,
    /// The image it runs.
    pub image: String,
    /// podman's state word, such as `running` or `exited`.
    pub state: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct PsEntry {
    #[serde(default)]
    names: Vec<String>,
    #[serde(default)]
    image: String,
    #[serde(default)]
    state: String,
    #[serde(default)]
    labels: Option<BTreeMap<String, String>>,
}

/// podman, found and ready to run through a [`CommandRunner`]. ref:DEC-podman-compose
pub struct Podman<'a> {
    /// The podman binary.
    pub program: PathBuf,
    runner: &'a dyn CommandRunner,
}

impl<'a> Podman<'a> {
    /// Finds podman: `IRONFRAME_PODMAN`, then `PATH`, then [`PODMAN_FALLBACKS`].
    pub fn locate(runner: &'a dyn CommandRunner) -> Result<Self, PodmanError> {
        let program = locate("IRONFRAME_PODMAN", &["podman"], &PODMAN_FALLBACKS).ok_or(PodmanError::NotInstalled)?;
        Ok(Podman { program, runner })
    }

    /// podman at a known path.
    pub fn at(program: PathBuf, runner: &'a dyn CommandRunner) -> Self {
        Podman { program, runner }
    }

    fn run(&self, args: &[&str], stream: bool) -> Result<crate::process::CommandOutput, PodmanError> {
        let args: Vec<String> = args.iter().map(|a| a.to_string()).collect();
        self.runner.run(&self.program, &args, stream).map_err(|e| PodmanError::Io(self.program.clone(), e))
    }

    fn run_checked(&self, args: &[&str], stream: bool) -> Result<crate::process::CommandOutput, PodmanError> {
        let output = self.run(args, stream)?;
        if output.success {
            Ok(output)
        } else {
            Err(PodmanError::Failed {
                command: args.join(" "),
                reason: if stream { "see the output above".into() } else { last_line(&output.stderr) },
            })
        }
    }

    /// Checks that `podman compose` has a provider to run.
    pub fn check_compose(&self) -> Result<(), PodmanError> {
        let output = self.run(&["compose", "version"], false)?;
        if output.success { Ok(()) } else { Err(PodmanError::ComposeUnavailable(last_line(&output.stderr))) }
    }

    /// Makes sure every image is present, pulling those that are not, and reports every one that
    /// stays missing. `images` pairs what needs an image with the image. Nothing is started here,
    /// so a missing image leaves the machine as it was. ref:REQ-missing-image-fails-clearly
    pub fn ensure_images(&self, images: &[(String, String)]) -> Result<(), PodmanError> {
        let mut missing = Vec::new();
        for (needed_by, image) in images {
            if self.run(&["image", "exists", image], false)?.success {
                continue;
            }
            let pulled = self.run(&["pull", "--quiet", image], false)?;
            if !pulled.success {
                missing.push(MissingImage {
                    needed_by: needed_by.clone(),
                    image: image.clone(),
                    reason: last_line(&pulled.stderr),
                });
            }
        }
        if missing.is_empty() { Ok(()) } else { Err(PodmanError::ImagesUnavailable(missing)) }
    }

    /// Brings the compose project up in the background.
    pub fn compose_up(&self, file: &Path, project: &str) -> Result<(), PodmanError> {
        let file = file.to_string_lossy();
        self.run_checked(&["compose", "-f", &file, "-p", project, "up", "-d"], true).map(|_| ())
    }

    /// Stops and removes the compose project's containers.
    pub fn compose_down(&self, file: &Path, project: &str) -> Result<(), PodmanError> {
        let file = file.to_string_lossy();
        self.run_checked(&["compose", "-f", &file, "-p", project, "down"], true).map(|_| ())
    }

    /// The containers of one environment, found by their labels.
    pub fn containers(&self, project: &str, environment: &str) -> Result<Vec<ContainerState>, PodmanError> {
        let project_filter = format!("label={LABEL_PROJECT}={project}");
        let environment_filter = format!("label={LABEL_ENVIRONMENT}={environment}");
        let output = self.run_checked(
            &["ps", "-a", "--filter", &project_filter, "--filter", &environment_filter, "--format", "json"],
            false,
        )?;
        parse_ps(&output.stdout)
    }
}

/// Reads `podman ps --format json` into container states. ref:DEC-podman-compose
pub fn parse_ps(text: &str) -> Result<Vec<ContainerState>, PodmanError> {
    if text.trim().is_empty() {
        return Ok(Vec::new());
    }
    let entries: Vec<PsEntry> = serde_json::from_str(text)
        .map_err(|e| PodmanError::Failed { command: "ps --format json".into(), reason: e.to_string() })?;
    Ok(entries
        .into_iter()
        .map(|entry| {
            let labels = entry.labels.unwrap_or_default();
            ContainerState {
                dependency: labels.get(LABEL_DEPENDENCY).cloned().unwrap_or_default(),
                kind: labels.get(LABEL_KIND).cloned().unwrap_or_default(),
                name: entry.names.first().cloned().unwrap_or_default(),
                image: entry.image,
                state: entry.state,
            }
        })
        .collect())
}
