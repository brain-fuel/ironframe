//! The commands as library functions: `up`, `down`, `status`, `plan`, `sync` and `attest`, for
//! podman and cloud environments. Each takes the manifest, its directory and the tools to run, so
//! the order of steps, above all that every image is checked before anything starts, is tested with
//! recorded tools. ref:DEC-podman-compose ref:DEC-opentofu ref:REQ-missing-image-fails-clearly

use crate::attest::{RunRecord, attest, tcp_reachable, wait_reachable};
use crate::compose::{CONFIG_SERVICE, compose_file};
use crate::manifest::{Manifest, ManifestError, SyncTarget};
use crate::podman::{ContainerState, Podman, PodmanError};
use crate::process::CommandRunner;
use crate::settings::{ResolveError, ResolvedEnvironment, SettingsDocument, resolve};
use crate::sync::aws::AppConfigApi;
use crate::sync::azure::AppConfigurationApi;
use crate::sync::gcp::ParameterManagerApi;
use crate::sync::{SyncError, SyncOutcome, describe, sync_env_file};
use crate::tofu::{Tofu, TofuError, root_module};
use crate::twin::{ControlPlane, Observation, TwinError, TwinRecord};
use crate::workdir::{WorkDir, write_atomically};
use async_trait::async_trait;
use ironframe_attestation::{Attestation, AttestationError};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Why a command failed. ref:DEC-podman-compose
#[derive(Debug, thiserror::Error)]
pub enum OpsError {
    /// The manifest is wrong.
    #[error(transparent)]
    Manifest(#[from] ManifestError),
    /// The environment could not be resolved.
    #[error(transparent)]
    Resolve(#[from] ResolveError),
    /// podman failed.
    #[error(transparent)]
    Podman(#[from] PodmanError),
    /// OpenTofu failed.
    #[error(transparent)]
    Tofu(#[from] TofuError),
    /// A sync failed.
    #[error(transparent)]
    Sync(#[from] SyncError),
    /// The attestation is invalid.
    #[error(transparent)]
    Attestation(#[from] AttestationError),
    /// A twin's control plane failed or refused.
    #[error("twin {dependency:?}: {error}")]
    Twin {
        /// The dependency the twin stands in for.
        dependency: String,
        /// What went wrong.
        error: TwinError,
    },
    /// A twin's conformance level disagrees with its image's label, or the label is missing.
    #[error("twin {0:?}: {1}")]
    Conformance(String, String),
    /// The command names something the environment does not have.
    #[error("{0}")]
    Usage(String),
    /// A file could not be written or read.
    #[error("{0}: {1}")]
    Io(PathBuf, std::io::Error),
}

pub(crate) fn io(path: &Path) -> impl FnOnce(std::io::Error) -> OpsError + '_ {
    move |error| OpsError::Io(path.to_path_buf(), error)
}

/// How `up` behaves. ref:DEC-podman-compose
#[derive(Debug, Clone)]
pub struct UpOptions {
    /// Whether to run the environment's sync targets.
    pub sync: bool,
    /// How long to wait for each started container to answer.
    pub wait: Duration,
}

impl Default for UpOptions {
    fn default() -> Self {
        UpOptions { sync: true, wait: Duration::from_secs(90) }
    }
}

/// What `up` did. ref:DEC-podman-compose
#[derive(Debug)]
pub struct UpReport {
    /// The environment as resolved.
    pub environment: ResolvedEnvironment,
    /// The attestation written.
    pub attestation: Attestation,
    /// Where it was written.
    pub attestation_path: PathBuf,
    /// Each sync target and what was done to it.
    pub synced: Vec<(String, SyncOutcome)>,
    /// The dependencies whose endpoint did not answer.
    pub unreached: Vec<String>,
}

/// The cloud clients a sync uses. The real ones are built from each cloud's usual credentials;
/// tests pass recorded ones. ref:DEC-config-sync
#[async_trait]
pub trait Clouds: Send + Sync {
    /// An AppConfig client for `region`.
    async fn aws(&self, region: &str) -> Result<Box<dyn AppConfigApi>, String>;
    /// A Parameter Manager client.
    async fn gcp(&self) -> Result<Box<dyn ParameterManagerApi>, String>;
    /// An App Configuration client for the store at `endpoint`, whose connection string is in the
    /// environment variable `connection_string_env`.
    async fn azure(&self, endpoint: &str, connection_string_env: &str) -> Result<Box<dyn AppConfigurationApi>, String>;
}

/// The clients over the clouds' SDKs and REST APIs, as far as this build's features include them.
/// ref:DEC-config-sync
pub struct RealClouds;

#[async_trait]
impl Clouds for RealClouds {
    async fn aws(&self, region: &str) -> Result<Box<dyn AppConfigApi>, String> {
        #[cfg(feature = "aws")]
        {
            Ok(Box::new(crate::sync::aws::SdkAppConfig::new(region).await))
        }
        #[cfg(not(feature = "aws"))]
        {
            let _ = region;
            Err("this build of ironframe has no AWS support (feature `aws`)".into())
        }
    }

    async fn gcp(&self) -> Result<Box<dyn ParameterManagerApi>, String> {
        #[cfg(feature = "gcp")]
        {
            Ok(Box::new(crate::sync::gcp::SdkParameterManager::new().await?))
        }
        #[cfg(not(feature = "gcp"))]
        {
            Err("this build of ironframe has no GCP support (feature `gcp`)".into())
        }
    }

    async fn azure(&self, endpoint: &str, connection_string_env: &str) -> Result<Box<dyn AppConfigurationApi>, String> {
        #[cfg(feature = "azure")]
        {
            let text = std::env::var(connection_string_env)
                .map_err(|_| format!("set {connection_string_env} to the store's connection string"))?;
            let credential = crate::sync::azure::ConnectionString::parse(&text)?;
            Ok(Box::new(crate::sync::azure::RestAppConfiguration::new(endpoint, credential)?))
        }
        #[cfg(not(feature = "azure"))]
        {
            let _ = (endpoint, connection_string_env);
            Err("this build of ironframe has no Azure support (feature `azure`)".into())
        }
    }
}

/// Runs every sync target of the environment, in order, stopping at the first failure.
/// ref:DEC-config-sync
pub async fn sync_environment(
    manifest: &Manifest,
    manifest_dir: &Path,
    environment: &ResolvedEnvironment,
    clouds: &dyn Clouds,
) -> Result<Vec<(String, SyncOutcome)>, OpsError> {
    let targets = &manifest.environment(&environment.environment)?.sync;
    let settings = environment.settings();
    let name = environment.environment.as_str();
    let mut done = Vec::new();
    for target in targets {
        let label = describe(target, name);
        let client_failed = |reason: String| SyncError { target: label.clone(), reason };
        let outcome = match target {
            SyncTarget::EnvFile(t) => sync_env_file(t, manifest_dir, &environment.project, name, &settings)?,
            SyncTarget::AwsAppconfig(t) => {
                let api = clouds.aws(&t.region).await.map_err(client_failed)?;
                crate::sync::aws::sync(api.as_ref(), t, name, &settings).await?
            }
            SyncTarget::GcpParameterManager(t) => {
                let api = clouds.gcp().await.map_err(client_failed)?;
                crate::sync::gcp::sync(api.as_ref(), t, name, &settings).await?
            }
            SyncTarget::AzureAppConfiguration(t) => {
                let api = clouds.azure(&t.endpoint, &t.connection_string_env).await.map_err(client_failed)?;
                crate::sync::azure::sync(api.as_ref(), t, name, &settings).await?
            }
        };
        done.push((label, outcome));
    }
    Ok(done)
}

/// Resolves environment `name`, with the endpoints of an earlier cloud deployment.
/// ref:DEC-manifest-shape
pub fn resolve_in(manifest: &Manifest, manifest_dir: &Path, name: &str) -> Result<ResolvedEnvironment, OpsError> {
    let workdir = WorkDir::new(manifest_dir, name);
    let deployed = workdir.read_endpoints().map_err(io(&workdir.endpoints()))?;
    Ok(resolve(manifest, name, &deployed)?)
}

fn write_settings(workdir: &WorkDir, environment: &ResolvedEnvironment) -> Result<PathBuf, OpsError> {
    let mut document = SettingsDocument::default();
    document.insert(environment);
    let path = workdir.settings();
    let text = serde_json::to_string_pretty(&document).expect("settings serialise") + "\n";
    write_atomically(&path, &text).map_err(io(&path))?;
    Ok(path)
}

pub(crate) fn write_attestation(path: &Path, attestation: &Attestation) -> Result<(), OpsError> {
    write_atomically(path, &attestation.to_json()?).map_err(io(path))?;
    Ok(())
}

/// Brings environment `name` up. On podman: every image is checked, and pulled if absent, before
/// anything starts; then the settings document and compose file are written and the project
/// started, each started container is waited for, the sync targets run, and the attestation is
/// written. In a cloud: the OpenTofu root is applied, the endpoints it reports are kept, and the
/// settings, sync and attestation follow. `progress` hears each step. ref:DEC-podman-compose
/// ref:DEC-opentofu ref:REQ-missing-image-fails-clearly
pub async fn up(
    manifest: &Manifest,
    manifest_dir: &Path,
    name: &str,
    runner: &dyn CommandRunner,
    clouds: &dyn Clouds,
    options: &UpOptions,
    progress: &mut (dyn FnMut(&str) + Send),
) -> Result<UpReport, OpsError> {
    let declared = manifest.environment(name)?;
    let workdir = WorkDir::new(manifest_dir, name);
    let run = RunRecord::start();
    let started_images: Vec<String>;
    let mut labelled: BTreeMap<String, String> = BTreeMap::new();
    let environment = if declared.runtime.is_cloud() {
        let tofu = prepare_tofu(manifest, manifest_dir, name, runner)?;
        progress("applying the OpenTofu root");
        tofu.init()?;
        tofu.apply()?;
        let endpoints = tofu.endpoints()?;
        let text = serde_json::to_string_pretty(&endpoints).expect("endpoints serialise") + "\n";
        write_atomically(&workdir.endpoints(), &text).map_err(io(&workdir.endpoints()))?;
        let environment = resolve(manifest, name, &endpoints)?;
        write_settings(&workdir, &environment)?;
        started_images = Vec::new();
        environment
    } else {
        let environment = resolve(manifest, name, &BTreeMap::new())?;
        let podman = Podman::locate(runner)?;
        podman.check_compose()?;
        let mut images: Vec<(String, String)> = environment
            .dependencies
            .iter()
            .filter_map(|d| d.image.clone().map(|image| (format!("dependency {:?}", d.name), image)))
            .collect();
        if let Some(service) = &declared.config_service {
            images.push((CONFIG_SERVICE.to_string(), crate::settings::qualify_image(&service.image)));
        }
        progress("checking images");
        podman.ensure_images(&images)?;
        labelled = labelled_levels(&podman, &environment)?;
        let settings = write_settings(&workdir, &environment)?;
        let compose = compose_file(&environment, declared.config_service.as_ref().map(|s| (s, settings.as_path())));
        write_atomically(&workdir.compose(), &compose).map_err(io(&workdir.compose()))?;
        progress("starting containers");
        podman.compose_up(&workdir.compose(), &environment.stack_name())?;
        started_images =
            environment.dependencies.iter().filter(|d| d.image.is_some()).map(|d| d.name.clone()).collect();
        environment
    };
    let run_text = serde_json::to_string_pretty(&run).expect("a run serialises") + "\n";
    write_atomically(&workdir.run(), &run_text).map_err(io(&workdir.run()))?;
    let mut records: BTreeMap<String, TwinRecord> = BTreeMap::new();
    for dependency in &environment.dependencies {
        let (Some(twin), Some(url)) = (&dependency.twin, &dependency.admin_url) else { continue };
        let fail = |error| OpsError::Twin { dependency: dependency.name.clone(), error };
        let control = ControlPlane::new(url.clone());
        progress(&format!("waiting for the control plane of {} at {url}", dependency.name));
        if !control.wait_healthy(options.wait).await {
            return Err(fail(TwinError::Unreachable {
                url: url.clone(),
                reason: format!("no answer at /healthz within {}s", options.wait.as_secs()),
            }));
        }
        if twin.seed.is_some() || twin.state.is_some() || !twin.faults.is_empty() {
            progress(&format!("setting up {}", dependency.name));
        }
        let mut record = control.set_up(twin, manifest_dir).await.map_err(fail)?;
        record.conformance = labelled.get(&dependency.name).cloned();
        records.insert(dependency.name.clone(), record);
    }
    for (name, level) in &labelled {
        records.entry(name.clone()).or_default().conformance = Some(level.clone());
    }
    let twins_text = serde_json::to_string_pretty(&records).expect("twin records serialise") + "\n";
    write_atomically(&workdir.twins(), &twins_text).map_err(io(&workdir.twins()))?;
    let mut unreached = Vec::new();
    let mut reached = BTreeMap::new();
    for dependency in &environment.dependencies {
        let answered = if started_images.contains(&dependency.name) {
            progress(&format!("waiting for {} at {}", dependency.name, dependency.endpoint));
            wait_reachable(&dependency.endpoint, options.wait)
        } else {
            tcp_reachable(&dependency.endpoint, Duration::from_secs(3))
        };
        if !answered {
            unreached.push(dependency.name.clone());
        }
        reached.insert(dependency.endpoint.clone(), answered);
    }
    let synced = if options.sync {
        progress("syncing settings");
        sync_environment(manifest, manifest_dir, &environment, clouds).await?
    } else {
        Vec::new()
    };
    let observed = observe_twins(&environment, &workdir, &records).await?;
    let attestation =
        attest(&environment, &run, &|endpoint| reached.get(endpoint).copied().unwrap_or(false), &observed, &records);
    write_attestation(&workdir.attestation(), &attestation)?;
    Ok(UpReport { environment, attestation, attestation_path: workdir.attestation(), synced, unreached })
}

fn prepare_tofu<'a>(
    manifest: &Manifest,
    manifest_dir: &Path,
    name: &str,
    runner: &'a dyn CommandRunner,
) -> Result<Tofu<'a>, OpsError> {
    let workdir = WorkDir::new(manifest_dir, name);
    let root = root_module(manifest, name, manifest_dir)?;
    let path = workdir.tofu().join("main.tf.json");
    let text = serde_json::to_string_pretty(&root).expect("the root serialises") + "\n";
    write_atomically(&path, &text).map_err(io(&path))?;
    Ok(Tofu::locate(workdir.tofu(), runner)?)
}

/// Writes the OpenTofu root of cloud environment `name` and runs `init` and `plan` on it.
/// ref:DEC-opentofu
pub fn plan(
    manifest: &Manifest,
    manifest_dir: &Path,
    name: &str,
    runner: &dyn CommandRunner,
) -> Result<PathBuf, OpsError> {
    if !manifest.environment(name)?.runtime.is_cloud() {
        return Err(TofuError::NotCloud(name.to_string()).into());
    }
    let tofu = prepare_tofu(manifest, manifest_dir, name, runner)?;
    tofu.init()?;
    tofu.plan()?;
    Ok(tofu.root)
}

/// Takes environment `name` down: the compose project on podman, the OpenTofu root in a cloud.
/// ref:DEC-podman-compose ref:DEC-opentofu
pub fn down(manifest: &Manifest, manifest_dir: &Path, name: &str, runner: &dyn CommandRunner) -> Result<(), OpsError> {
    let declared = manifest.environment(name)?;
    let workdir = WorkDir::new(manifest_dir, name);
    if declared.runtime.is_cloud() {
        let tofu = prepare_tofu(manifest, manifest_dir, name, runner)?;
        tofu.init()?;
        tofu.destroy()?;
        match std::fs::remove_file(workdir.endpoints()) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
                return Err(OpsError::Io(workdir.endpoints(), error));
            }
            _ => {}
        }
        return Ok(());
    }
    let environment = resolve(manifest, name, &BTreeMap::new())?;
    let podman = Podman::locate(runner)?;
    podman.check_compose()?;
    let settings = workdir.settings();
    let compose = compose_file(&environment, declared.config_service.as_ref().map(|s| (s, settings.as_path())));
    write_atomically(&workdir.compose(), &compose).map_err(io(&workdir.compose()))?;
    podman.compose_down(&workdir.compose(), &environment.stack_name())?;
    Ok(())
}

/// One dependency's state, as `status` reports it. ref:DEC-podman-compose
#[derive(Debug, Clone, serde::Serialize)]
pub struct DependencyStatus {
    /// The dependency.
    pub name: String,
    /// `real` or `twin`.
    pub kind: String,
    /// The endpoint the application is handed, if known yet.
    pub endpoint: Option<String>,
    /// The container's state on podman, `hosted` for a real dependency that runs elsewhere, or
    /// `not deployed` for a cloud twin before `up`.
    pub state: String,
    /// Whether the endpoint answered just now.
    pub reachable: bool,
}

/// The state of every dependency of environment `name`. ref:DEC-podman-compose
pub fn status(
    manifest: &Manifest,
    manifest_dir: &Path,
    name: &str,
    runner: &dyn CommandRunner,
) -> Result<Vec<DependencyStatus>, OpsError> {
    let declared = manifest.environment(name)?;
    let probe = |endpoint: &str| tcp_reachable(endpoint, Duration::from_secs(2));
    match resolve_in(manifest, manifest_dir, name) {
        Ok(environment) => {
            let containers: Vec<ContainerState> = if declared.runtime.is_cloud() {
                Vec::new()
            } else {
                Podman::locate(runner)?.containers(&environment.project, name)?
            };
            Ok(environment
                .dependencies
                .iter()
                .map(|d| {
                    let state = match containers.iter().find(|c| c.dependency == d.name) {
                        Some(container) => container.state.clone(),
                        None if d.image.is_some() && !declared.runtime.is_cloud() => "absent".into(),
                        None if declared.runtime.is_cloud() && d.kind == crate::settings::BindingKind::Twin => {
                            "deployed".into()
                        }
                        None => "hosted".into(),
                    };
                    DependencyStatus {
                        name: d.name.clone(),
                        kind: d.kind.as_str().into(),
                        endpoint: Some(d.endpoint.clone()),
                        state,
                        reachable: probe(&d.endpoint),
                    }
                })
                .collect())
        }
        Err(OpsError::Resolve(ResolveError::NotDeployed { .. })) => Ok(declared
            .dependencies
            .iter()
            .map(|(dependency, binding)| match binding {
                crate::manifest::Binding::Real(real) => DependencyStatus {
                    name: dependency.clone(),
                    kind: "real".into(),
                    endpoint: Some(real.endpoint.clone()),
                    state: "hosted".into(),
                    reachable: probe(&real.endpoint),
                },
                crate::manifest::Binding::Twin(_) => DependencyStatus {
                    name: dependency.clone(),
                    kind: "twin".into(),
                    endpoint: None,
                    state: "not deployed".into(),
                    reachable: false,
                },
            })
            .collect()),
        Err(error) => Err(error),
    }
}

/// Writes the attestation of environment `name` now: the run `up` started, or a new one when there
/// was none, with each endpoint probed and each twin's seed and history read from its control
/// plane, its history kept beside the attestation. Writes to `output`, or the working directory's
/// `attestation.json`. ref:DEC-attestation-format ref:DEC-history-digest
pub async fn attest_now(
    manifest: &Manifest,
    manifest_dir: &Path,
    name: &str,
    output: Option<&Path>,
) -> Result<(Attestation, PathBuf), OpsError> {
    let environment = resolve_in(manifest, manifest_dir, name)?;
    let workdir = WorkDir::new(manifest_dir, name);
    let run = match std::fs::read_to_string(workdir.run()) {
        Ok(text) => serde_json::from_str(&text).map_err(|e| OpsError::Io(workdir.run(), std::io::Error::other(e)))?,
        Err(_) => RunRecord::start(),
    };
    let records = workdir.read_twins().map_err(io(&workdir.twins()))?;
    let observed = observe_twins(&environment, &workdir, &records).await?;
    let attestation =
        attest(&environment, &run, &|endpoint| tcp_reachable(endpoint, Duration::from_secs(2)), &observed, &records);
    let path = output.map(Path::to_path_buf).unwrap_or_else(|| workdir.attestation());
    write_attestation(&path, &attestation)?;
    Ok((attestation, path))
}

/// The control-plane URL of each twin: the one `up` recorded, else the one the manifest gives.
pub(crate) fn admin_urls(environment: &ResolvedEnvironment, records: &BTreeMap<String, TwinRecord>) -> BTreeMap<String, String> {
    environment
        .dependencies
        .iter()
        .filter(|d| d.twin.is_some())
        .filter_map(|d| {
            let url = records.get(&d.name).and_then(|r| r.admin.clone()).or_else(|| d.admin_url.clone())?;
            Some((d.name.clone(), url))
        })
        .collect()
}

/// Reads each twin's seed and history from its control plane and keeps the history in the working
/// directory, where the attestation's digest can be checked against it. A twin whose control plane
/// does not answer is recorded without them. ref:DEC-history-digest
pub(crate) async fn observe_twins(
    environment: &ResolvedEnvironment,
    workdir: &WorkDir,
    records: &BTreeMap<String, TwinRecord>,
) -> Result<BTreeMap<String, Observation>, OpsError> {
    let mut observed = BTreeMap::new();
    for (dependency, url) in admin_urls(environment, records) {
        let Ok(observation) = ControlPlane::new(url).observe().await else { continue };
        if let Some(history) = &observation.history {
            let path = workdir.history(&dependency);
            write_atomically(&path, history).map_err(io(&path))?;
        }
        observed.insert(dependency, observation);
    }
    Ok(observed)
}

/// Reads the conformance level from the image label of each twin that names one, and checks it
/// against the declared level and the report. ref:DEC-conformance-from-report
fn labelled_levels(
    podman: &Podman<'_>,
    environment: &ResolvedEnvironment,
) -> Result<BTreeMap<String, String>, OpsError> {
    let mut levels = BTreeMap::new();
    for dependency in &environment.dependencies {
        let (Some(twin), Some(image)) = (&dependency.twin, &dependency.image) else { continue };
        let Some(label) = twin.conformance.image_label() else { continue };
        let labels = podman.image_labels(image)?;
        let fail = |message: String| OpsError::Conformance(dependency.name.clone(), message);
        let Some(level) = labels.get(label).filter(|l| !l.trim().is_empty()) else {
            return Err(fail(format!("image {image} has no label {label:?} to read the conformance level from")));
        };
        if let Some(declared) = twin.conformance.declared()
            && !declared.eq_ignore_ascii_case(level)
            && !twin.report.as_ref().is_some_and(|r| r.matches(declared) && r.matches(level))
        {
            return Err(fail(format!(
                "the twin declares conformance {declared:?}, but image label {label} says {level:?}"
            )));
        }
        if let Some(report) = &twin.report
            && !report.matches(level)
        {
            return Err(fail(format!(
                "image label {label} says {level:?}, but the report gives {}",
                report.describe()
            )));
        }
        levels.insert(dependency.name.clone(), twin.report.as_ref().map_or_else(|| level.clone(), |r| r.level.clone()));
    }
    Ok(levels)
}

/// The control plane of the twin standing in for `dependency` in environment `name`: the URL `up`
/// recorded, else the one the manifest gives. ref:DEC-twin-control-plane
pub fn control_plane(
    manifest: &Manifest,
    manifest_dir: &Path,
    name: &str,
    dependency: &str,
) -> Result<ControlPlane, OpsError> {
    let environment = resolve_in(manifest, manifest_dir, name)?;
    let Some(resolved) = environment.dependencies.iter().find(|d| d.name == dependency) else {
        return Err(OpsError::Usage(format!(
            "environment {name:?} has no dependency {dependency:?}; it has {}",
            environment.dependencies.iter().map(|d| format!("{:?}", d.name)).collect::<Vec<_>>().join(", ")
        )));
    };
    if resolved.twin.is_none() {
        return Err(OpsError::Usage(format!(
            "dependency {dependency:?} is the real thing in environment {name:?}, not a twin"
        )));
    }
    let workdir = WorkDir::new(manifest_dir, name);
    let records = workdir.read_twins().map_err(io(&workdir.twins()))?;
    admin_urls(&environment, &records).remove(dependency).map(ControlPlane::new).ok_or_else(|| {
        OpsError::Usage(format!(
            "the twin for {dependency:?} in environment {name:?} has no control plane; give it `admin` in the manifest"
        ))
    })
}
