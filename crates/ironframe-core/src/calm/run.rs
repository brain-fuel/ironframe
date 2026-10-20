//! Running an application against a resolved environment and attesting the run: Ironframe hands
//! the application its settings through its environment, as any deployment tool would, records the
//! wiring as the run begins, runs the command, and records the run again once it has completed, with
//! each twin's history as it then stood. The attestation names each dependency by the application
//! ability that reaches it, so LawSpec matches it to the laws that ran under that ability's
//! production handler, and carries the architecture, contract, implementation and run identities.
//! The same two steps serve an application deployed by other tooling: `begin` writes the running
//! attestation it reads, and `complete` records its outcome. ref:DEC-calm-run ref:DEC-calm-planned-vs-completed

use crate::attest::{RunRecord, tcp_reachable};
use crate::calm::export::application_settings;
use crate::calm::resolve::{BoundKind, ContractIdentity, Deployment, Resolution, ResolvedApplication};
use crate::ops::{OpsError, io, observe_twins, resolve_in, write_attestation};
use crate::podman::Podman;
use crate::process::SystemRunner;
use crate::settings::ResolvedEnvironment;
use crate::twin::Observation;
use crate::workdir::{WorkDir, write_atomically};
use ironframe_attestation::{
    ApplicationRef, ArchitectureRef, Attestation, Completed, ContractRef, DependencyRecord, Execution, ExecutionStatus,
    Implementation, Kind, Producer, Run,
};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;
use time::OffsetDateTime;

/// The variable a run's command finds its running attestation's path in. ref:DEC-calm-run
pub const ATTESTATION_VARIABLE: &str = "IRONFRAME_ATTESTATION";

/// The variable a run's command finds its run id in. ref:DEC-calm-run
pub const RUN_VARIABLE: &str = "IRONFRAME_RUN_ID";

fn contract_ref(identity: &ContractIdentity) -> ContractRef {
    ContractRef {
        package: identity.package.clone(),
        version: identity.version.clone(),
        abilities: identity.abilities.clone(),
    }
}

/// The application `node` of the resolution, or an error naming those there are.
pub fn application<'a>(resolution: &'a Resolution, node: &str) -> Result<&'a ResolvedApplication, OpsError> {
    resolution.topology.application(node).ok_or_else(|| {
        OpsError::Usage(format!(
            "the architecture has no application node {node:?}; it has {}",
            resolution.topology.applications.iter().map(|a| format!("{:?}", a.node)).collect::<Vec<_>>().join(", ")
        ))
    })
}

/// The settings application `node` reads in the resolved environment. ref:DEC-calm-exports
pub fn settings_of(resolution: &Resolution, node: &str) -> Result<BTreeMap<String, String>, OpsError> {
    application(resolution, node)?;
    let workdir = WorkDir::new(&resolution.dir, &resolution.topology.environment);
    let deployed = workdir.read_endpoints().map_err(io(&workdir.endpoints()))?;
    let mut all = application_settings(resolution, &deployed)?;
    Ok(all.remove(node).unwrap_or_default())
}

/// The commit of the git checkout holding `dir`, with `-dirty` when it has changes there.
fn commit_of(dir: &Path) -> Option<String> {
    let git = |args: &[&str]| {
        std::process::Command::new("git").arg("-C").arg(dir).args(args).output().ok().filter(|o| o.status.success())
    };
    let head = String::from_utf8_lossy(&git(&["rev-parse", "HEAD"])?.stdout).trim().to_string();
    let dirty = git(&["status", "--porcelain", "--", "."]).is_some_and(|o| !o.stdout.is_empty());
    Some(if dirty { format!("{head}-dirty") } else { head })
}

/// The attestation of application `node` as the run begins: the wiring of each ability it
/// consumes, each twin's seed and history as observed now, and every identity. Written, it is what
/// the run's command reads. ref:DEC-calm-run
pub async fn begin(
    resolution: &Resolution,
    node: &str,
    command: &[String],
    app_dir: Option<&Path>,
) -> Result<Attestation, OpsError> {
    let app = application(resolution, node)?;
    let topology = &resolution.topology;
    let name = &topology.environment;
    let environment = resolve_in(&resolution.manifest, &resolution.dir, name)?;
    let workdir = WorkDir::new(&resolution.dir, name);
    let records = workdir.read_twins().map_err(io(&workdir.twins()))?;
    let observed = observe_twins(&environment, &workdir, &records).await?;
    let environment_run: Option<RunRecord> =
        std::fs::read_to_string(workdir.run()).ok().and_then(|t| serde_json::from_str(&t).ok());
    let run = RunRecord::start();
    let mut attestation =
        Attestation::new(name, Run { id: run.id.clone(), started_at: run.started_at, recorded_at: run.started_at });
    attestation.producer = Some(Producer { name: "ironframe".into(), version: env!("CARGO_PKG_VERSION").into() });
    let podman = Podman::locate(&SystemRunner).ok();
    let mut elements = vec![app.node.clone()];
    for edge in topology.edges_of(node) {
        let Some(dependency) = topology.dependency(&edge.destination) else { continue };
        let Some(wired) = environment.dependencies.iter().find(|d| d.name == edge.destination) else { continue };
        elements.push(edge.relationship.clone());
        if !elements.contains(&dependency.node) {
            elements.push(dependency.node.clone());
        }
        let reached = tcp_reachable(&wired.endpoint, Duration::from_secs(2));
        let image_digest = wired.image.as_ref().and_then(|image| podman.as_ref().and_then(|p| p.image_digest(image)));
        let implementation = match (&dependency.twin, &dependency.provider) {
            (Some(twin), _) => Implementation {
                kind: "fixture".into(),
                product: twin.image.clone(),
                version: twin.version.clone(),
                commit: None,
                image_digest,
            },
            (None, provider) => Implementation {
                // A real provider: the one the binding names, else its image, else its endpoint.
                kind: "real-provider".into(),
                product: provider
                    .as_ref()
                    .map(|p| p.name.clone())
                    .or_else(|| wired.image.clone())
                    .unwrap_or_else(|| wired.endpoint.clone()),
                version: provider.as_ref().map(|p| p.version.clone()).unwrap_or_else(|| "unknown".into()),
                commit: None,
                image_digest,
            },
        };
        for ability in &edge.consumes {
            let stand_in = wired.stand_in.clone().map(|mut stand_in| {
                let record = records.get(&wired.name);
                if let Some(level) = record.and_then(|r| r.conformance.clone()) {
                    stand_in.conformance = level;
                }
                let observation: Option<&Observation> = observed.get(&wired.name);
                stand_in.seed = observation.and_then(|o| o.seed).or(record.and_then(|r| r.seed)).or(stand_in.seed);
                stand_in.history_digest = observation.and_then(|o| o.history_digest.clone());
                stand_in.history_entries = observation.and_then(|o| o.history_entries);
                stand_in.stands_in_for = dependency.twin.as_ref().map(|t| contract_ref(&t.stands_in_for));
                stand_in
            });
            attestation.dependencies.push(DependencyRecord {
                name: ability.clone(),
                endpoint: wired.endpoint.clone(),
                reached,
                kind: if dependency.kind == BoundKind::Twin { Kind::StandIn } else { Kind::Real },
                stand_in,
                node: Some(dependency.node.clone()),
                edge: Some(edge.relationship.clone()),
                contract: Some(contract_ref(&dependency.contract)),
                implementation: Some(implementation.clone()),
                completed: None,
            });
        }
    }
    attestation.architecture = Some(ArchitectureRef {
        document: topology.architecture.document.clone(),
        digest: topology.architecture.digest.clone(),
        unique_id: topology.architecture.unique_id.clone(),
        decorators: Some(topology.architecture.decorators.clone()),
        decorators_digest: Some(topology.architecture.decorators_digest.clone()),
        topology_digest: Some(topology.digest()),
        elements,
    });
    let dir = app_dir.map(Path::to_path_buf).unwrap_or_else(|| resolution.dir.clone());
    attestation.application = Some(ApplicationRef {
        node: app.node.clone(),
        contract: contract_ref(&app.contract),
        implementation: Implementation {
            kind: "application".into(),
            product: app.contract.package.clone(),
            version: app.version.clone(),
            commit: app.commit.clone().or_else(|| commit_of(&dir)),
            image_digest: match &app.deployment {
                Deployment::Image { image, .. } => podman.as_ref().and_then(|p| p.image_digest(image)),
                _ => None,
            },
        },
    });
    attestation.execution = Some(Execution {
        status: ExecutionStatus::Running,
        command: command.to_vec(),
        exit_code: None,
        finished_at: None,
        environment_run: environment_run.map(|r| r.id),
    });
    attestation.validate()?;
    Ok(attestation)
}

/// The attestation of a run that has completed with `exit_code`: the running attestation with its
/// outcome, and each dependency as observed now, its twin's history digest then. The wiring fields
/// stay as the run began, so a reader that keyed its results by them finds the same wiring.
/// ref:DEC-calm-planned-vs-completed
pub async fn complete(resolution: &Resolution, running: &Attestation, exit_code: i32) -> Result<Attestation, OpsError> {
    let name = &resolution.topology.environment;
    if running.environment != *name {
        return Err(OpsError::Usage(format!(
            "the attestation is of environment {:?}, not {name:?}",
            running.environment
        )));
    }
    if running.execution.as_ref().map(|e| e.status) != Some(ExecutionStatus::Running) {
        return Err(OpsError::Usage("only a running attestation can be completed".into()));
    }
    let environment: ResolvedEnvironment = resolve_in(&resolution.manifest, &resolution.dir, name)?;
    let workdir = WorkDir::new(&resolution.dir, name);
    let records = workdir.read_twins().map_err(io(&workdir.twins()))?;
    let observed = observe_twins(&environment, &workdir, &records).await?;
    let now = OffsetDateTime::now_utc().max(running.run.started_at);
    let mut done = running.clone();
    done.run.recorded_at = now;
    for record in &mut done.dependencies {
        let node = record.node.clone().unwrap_or_else(|| record.name.clone());
        let observation = observed.get(&node);
        record.completed = Some(Completed {
            reached: tcp_reachable(&record.endpoint, Duration::from_secs(2)),
            history_digest: observation.and_then(|o| o.history_digest.clone()),
            history_entries: observation.and_then(|o| o.history_entries),
        });
    }
    if let Some(execution) = &mut done.execution {
        execution.status = ExecutionStatus::Completed;
        execution.exit_code = Some(exit_code);
        execution.finished_at = Some(now);
    }
    done.validate()?;
    Ok(done)
}

/// Where a run's attestation is kept in the environment's working directory.
pub fn run_attestation_path(resolution: &Resolution, run: &str) -> PathBuf {
    WorkDir::new(&resolution.dir, &resolution.topology.environment).root.join("runs").join(format!("{run}.json"))
}

/// Writes an attestation to the run's path in the working directory and to `also`, if given.
pub fn write_run(resolution: &Resolution, attestation: &Attestation, also: Option<&Path>) -> Result<PathBuf, OpsError> {
    let path = run_attestation_path(resolution, &attestation.run.id);
    write_attestation(&path, attestation)?;
    if let Some(also) = also {
        write_attestation(also, attestation)?;
    }
    Ok(also.map(Path::to_path_buf).unwrap_or(path))
}

/// What a run produced: its command's exit code and its completed attestation, and where that was
/// written. ref:DEC-calm-run
#[derive(Debug, Clone)]
pub struct RunReport {
    /// The command's exit code.
    pub exit_code: i32,
    /// The completed attestation.
    pub attestation: Attestation,
    /// Where it was written.
    pub path: PathBuf,
}

/// Runs `command` in `dir` as application `node`: the application's settings and the running
/// attestation's path in its environment, the attestation written before it starts and completed
/// after it exits. ref:DEC-calm-run
pub async fn run(
    resolution: &Resolution,
    node: &str,
    command: &[String],
    dir: Option<&Path>,
    output: Option<&Path>,
) -> Result<RunReport, OpsError> {
    let Some((program, args)) = command.split_first() else {
        return Err(OpsError::Usage("give the command to run after --".into()));
    };
    let settings = settings_of(resolution, node)?;
    let running = begin(resolution, node, command, dir).await?;
    let path = write_run(resolution, &running, output)?;
    let mut child = std::process::Command::new(program);
    child.args(args).envs(&settings).env(ATTESTATION_VARIABLE, &path).env(RUN_VARIABLE, &running.run.id);
    if let Some(dir) = dir {
        child.current_dir(dir);
    }
    let status = child.status().map_err(|e| OpsError::Io(PathBuf::from(program), e))?;
    let exit_code = status.code().unwrap_or(1);
    let completed = complete(resolution, &running, exit_code).await?;
    let path = write_run(resolution, &completed, output)?;
    Ok(RunReport { exit_code, attestation: completed, path })
}

/// Runs managed application `node` as its binding says, with `extra` arguments: its process in its
/// directory, or its image with podman on the host's network, built first from its context when
/// podman does not have it. ref:DEC-calm-deployment
pub async fn run_managed(
    resolution: &Resolution,
    node: &str,
    extra: &[String],
    output: Option<&Path>,
) -> Result<RunReport, OpsError> {
    let app = application(resolution, node)?;
    match &app.deployment {
        Deployment::External => Err(OpsError::Usage(format!(
            "application {node:?} is deployed by its own tooling in environment {:?}; run it there with `ironframe settings`, or use `ironframe run`",
            resolution.topology.environment
        ))),
        Deployment::Process { command, dir } => {
            let dir = dir.as_ref().map(|d| resolution.dir.join(d));
            let mut words = command.clone();
            words.extend(extra.iter().cloned());
            run(resolution, node, &words, dir.as_deref(), output).await
        }
        Deployment::Image { image, args, build_context, containerfile } => {
            let runner = SystemRunner;
            let podman = Podman::locate(&runner)?;
            let image = crate::settings::qualify_image(image);
            if !podman.has_image(&image) {
                let Some(context) = build_context else {
                    return Err(OpsError::Usage(format!(
                        "podman has no image {image} and the binding names no build context"
                    )));
                };
                let context = resolution.dir.join(context);
                podman.build(&context, containerfile.as_ref().map(|f| context.join(f)).as_deref(), &image)?;
            }
            let settings = settings_of(resolution, node)?;
            let mut words = vec![
                podman.program.to_string_lossy().into_owned(),
                "run".into(),
                "--rm".into(),
                "--network".into(),
                "host".into(),
            ];
            for (key, value) in &settings {
                words.push("-e".into());
                words.push(format!("{key}={value}"));
            }
            words.push(image);
            words.extend(args.iter().cloned());
            words.extend(extra.iter().cloned());
            run(resolution, node, &words, None, output).await
        }
    }
}

/// Writes the resolved topology of the environment into its working directory, as the planned
/// wiring every later run of it refers to by digest. ref:DEC-calm-planned-vs-completed
pub fn write_topology(resolution: &Resolution) -> Result<PathBuf, OpsError> {
    let workdir = WorkDir::new(&resolution.dir, &resolution.topology.environment);
    let path = workdir.root.join("topology.json");
    let text = serde_json::to_string_pretty(&resolution.topology).expect("a topology serialises") + "\n";
    write_atomically(&path, &text).map_err(io(&path))?;
    Ok(path)
}
