//! The `ironframe` command. Every verb is a call into `ironframe-core`; this file only reads the
//! command line, prints, and turns a failure into an exit status. ref:DEC-wiring-in-ironframe

use clap::{Parser, Subcommand, ValueEnum};
use ironframe_core::calm::model::{Architecture, DECORATOR_SCHEMAS, Decorators, ENVIRONMENT_TYPE};
use ironframe_core::calm::run as calm_run;
use ironframe_core::calm::{Resolution, default_decorators, export as calm_export, load_and_resolve};
use ironframe_core::manifest::{DEFAULT_MANIFEST, Manifest, SCHEMA};
use ironframe_core::ops::{self, RealClouds, UpOptions};
use ironframe_core::process::SystemRunner;
use ironframe_core::settings::render_dotenv;
use ironframe_core::sync::SyncOutcome;
use ironframe_core::twin::{ControlPlane, TwinError, parse_fault, pretty};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

/// The command line: a manifest, or a CALM architecture and its decorators, and a verb.
#[derive(Parser)]
#[command(
    name = "ironframe",
    version,
    about = "Wire applications to their dependencies, real or twin, per environment"
)]
struct Cli {
    /// The manifest to read.
    #[arg(short = 'f', long = "manifest", global = true, default_value = DEFAULT_MANIFEST)]
    manifest: PathBuf,
    /// A CALM 1.2 architecture to read instead of the manifest; its decorators wire it.
    #[arg(short = 'a', long = "architecture", global = true)]
    architecture: Option<PathBuf>,
    /// The architecture's decorators; `<name>.decorators.json` beside it when absent.
    #[arg(long = "decorators", global = true)]
    decorators: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}

/// The verbs.
#[derive(Subcommand)]
enum Command {
    /// Check the manifest, or the architecture, its decorators and every environment they declare,
    /// and report every problem.
    Validate {
        /// Also check the architecture with the CALM CLI (`calm validate`), found on PATH or in
        /// IRONFRAME_CALM.
        #[arg(long)]
        calm_cli: bool,
    },
    /// Resolve an environment of a CALM architecture and print the resolved topology, or refuse it.
    Resolve {
        /// The architecture; the same as --architecture.
        architecture: Option<PathBuf>,
        /// The environment.
        #[arg(short = 'e', long = "env")]
        environment: String,
        /// Write the topology here as well as printing it.
        #[arg(short, long)]
        output: Option<PathBuf>,
    },
    /// Export what an environment's resolved topology generates, without deploying anything.
    Export {
        /// What to export.
        #[arg(value_enum)]
        what: ExportKind,
        /// The environment.
        #[arg(short = 'e', long = "env")]
        environment: String,
        /// The format: mermaid, dot, calm or calm-template for a diagram; env or json for settings.
        #[arg(long)]
        format: Option<String>,
        /// The application whose settings to export; every application's, as JSON, when absent.
        #[arg(long)]
        app: Option<String>,
        /// Where to write it; standard output when absent (a directory for tofu).
        #[arg(short, long)]
        output: Option<PathBuf>,
    },
    /// Run a command as an application of a CALM environment, its settings in its environment, and
    /// attest the run when it begins and when it completes.
    Run {
        /// The environment.
        #[arg(short = 'e', long = "env")]
        environment: String,
        /// The application node.
        #[arg(long)]
        app: String,
        /// The directory to run it in.
        #[arg(long)]
        dir: Option<PathBuf>,
        /// Where to write the attestation as well as the environment's working directory.
        #[arg(long)]
        attestation: Option<PathBuf>,
        /// The command and its arguments, after --.
        #[arg(last = true, required = true)]
        command: Vec<String>,
    },
    /// Run a managed application of a CALM environment as its binding says, and attest the run.
    App {
        /// The application node.
        node: String,
        /// The environment.
        #[arg(short = 'e', long = "env")]
        environment: String,
        /// Where to write the attestation as well as the environment's working directory.
        #[arg(long)]
        attestation: Option<PathBuf>,
        /// Arguments after the application's own, after --.
        #[arg(last = true)]
        args: Vec<String>,
    },
    /// Print a JSON Schema: the manifest's or the attestation's.
    Schema {
        /// Which schema.
        #[arg(value_enum, default_value = "manifest")]
        which: SchemaKind,
    },
    /// Print the settings an environment hands its application.
    Settings {
        /// The environment.
        environment: String,
        /// The output format.
        #[arg(long, value_enum, default_value = "env")]
        format: SettingsFormat,
        /// With an architecture, only this application's settings.
        #[arg(long)]
        app: Option<String>,
    },
    /// Print the compose file of a podman environment.
    Compose {
        /// The environment.
        environment: String,
    },
    /// Bring an environment up: start or deploy its containers, sync its settings, attest the run.
    Up {
        /// The environment.
        environment: String,
        /// Skip the environment's sync targets.
        #[arg(long)]
        no_sync: bool,
        /// Seconds to wait for each started container to answer.
        #[arg(long, default_value_t = 90)]
        wait: u64,
    },
    /// Take an environment down.
    Down {
        /// The environment.
        environment: String,
    },
    /// Show each dependency's state and whether its endpoint answers.
    Status {
        /// The environment.
        environment: String,
        /// Print JSON.
        #[arg(long)]
        json: bool,
    },
    /// Run `tofu plan` for a cloud environment.
    Plan {
        /// The environment.
        environment: String,
    },
    /// Write the environment's settings to its sync targets.
    Sync {
        /// The environment.
        environment: String,
    },
    /// Write the environment attestation now; with --app, the running attestation of an
    /// application run by other tooling, and with --complete, that run's completed attestation.
    Attest {
        /// The environment.
        environment: String,
        /// Where to write it; the environment's working directory when absent.
        #[arg(short, long)]
        output: Option<PathBuf>,
        /// With an architecture: begin a run of this application node.
        #[arg(long)]
        app: Option<String>,
        /// With an architecture: complete the run whose running attestation is this file.
        #[arg(long)]
        complete: Option<PathBuf>,
        /// The exit code the completed run ended with.
        #[arg(long, default_value_t = 0)]
        exit_code: i32,
    },
    /// Drive the twin standing in for a dependency through its control plane, as `lawtwin` does.
    Twin {
        /// The dependency the twin stands in for.
        dependency: String,
        /// The environment.
        #[arg(short = 'e', long = "env", default_value = "local")]
        environment: String,
        /// What to do.
        #[command(subcommand)]
        action: TwinAction,
    },
}

/// What `ironframe twin` asks of a twin's control plane.
#[derive(Subcommand)]
enum TwinAction {
    /// Show the twin's state.
    Inspect {
        /// Every record as well.
        #[arg(long)]
        records: bool,
    },
    /// Force a state from a JSON file, or `-` for standard input; exit 2 when a law refuses it.
    Force {
        /// The state file.
        state: String,
    },
    /// Raise a declared fault with name=value parameters, or `fault clear [<name>]`.
    Fault {
        /// The fault, or `clear`.
        name: String,
        /// The parameters, name=value; after `clear`, the fault to clear.
        params: Vec<String>,
    },
    /// List the declared faults and the active ones.
    Faults,
    /// Print the history, as JSON lines unless --array.
    History {
        /// Only entries after this position.
        #[arg(long)]
        since: Option<u64>,
        /// At most this many entries.
        #[arg(long)]
        limit: Option<u64>,
        /// One JSON array.
        #[arg(long)]
        array: bool,
    },
    /// Move the twin clock forward, such as 5s.
    Advance {
        /// The duration: 250ms, 5s, 2m or 1h.
        duration: String,
    },
    /// Show the seed, or start again from an empty state with a new one.
    Seed {
        /// The new seed.
        seed: Option<u64>,
    },
    /// Start again from an empty state with the same seed.
    Reset,
    /// Check the contract's laws over the state and history; exit 1 if one does not hold.
    Laws,
    /// Replay a history through a fresh model, the twin's own or a file's (`-` for standard
    /// input); exit 1 on a divergence or a broken law.
    Replay {
        /// The history, as JSON lines or a JSON array.
        file: Option<String>,
    },
}

/// What `ironframe export` writes.
#[derive(Clone, Copy, ValueEnum)]
enum ExportKind {
    /// The resolved topology, as JSON.
    Topology,
    /// A diagram of the topology.
    Diagram,
    /// The settings applications read.
    Settings,
    /// The OpenTofu root of a cloud environment.
    Tofu,
    /// The compose file of a podman environment.
    Compose,
}

/// The schemas `ironframe schema` prints.
#[derive(Clone, Copy, ValueEnum)]
enum SchemaKind {
    /// ironframe.yaml.
    Manifest,
    /// The environment attestation.
    Attestation,
    /// The ironframe-contract decorator.
    Contract,
    /// The ironframe-binding decorator.
    Binding,
    /// The ironframe-environment decorator.
    Environment,
}

/// The formats `ironframe settings` prints.
#[derive(Clone, Copy, ValueEnum)]
enum SettingsFormat {
    /// A dotenv file.
    Env,
    /// A JSON object.
    Json,
}

fn manifest_dir(path: &Path) -> PathBuf {
    let parent = path.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or(Path::new("."));
    std::fs::canonicalize(parent).unwrap_or_else(|_| parent.to_path_buf())
}

fn outcome(outcome: &SyncOutcome) -> String {
    match outcome {
        SyncOutcome::Unchanged => "unchanged".into(),
        SyncOutcome::Updated(detail) => format!("updated ({detail})"),
    }
}

async fn run(cli: Cli) -> Result<ExitCode, Box<dyn std::error::Error>> {
    if let Command::Schema { which } = &cli.command {
        print!(
            "{}",
            match which {
                SchemaKind::Manifest => SCHEMA,
                SchemaKind::Attestation => ironframe_attestation::SCHEMA_V1,
                SchemaKind::Contract => DECORATOR_SCHEMAS[0].1,
                SchemaKind::Binding => DECORATOR_SCHEMAS[1].1,
                SchemaKind::Environment => DECORATOR_SCHEMAS[2].1,
            }
        );
        return Ok(ExitCode::SUCCESS);
    }
    let mut cli = cli;
    if let Command::Resolve { architecture: Some(path), .. } = &cli.command
        && cli.architecture.is_none()
    {
        cli.architecture = Some(path.clone());
    }
    if let (Command::Validate { calm_cli }, Some(path)) = (&cli.command, &cli.architecture) {
        return validate_architecture(path, cli.decorators.as_deref(), *calm_cli);
    }
    let (manifest, dir, resolution) = match &cli.architecture {
        Some(path) => {
            let Some(environment) = environment_of(&cli.command) else {
                return Err("this verb reads a manifest; give it --manifest, not --architecture".into());
            };
            let resolution = load_and_resolve(path, cli.decorators.as_deref(), &environment)?;
            (resolution.manifest.clone(), resolution.dir.clone(), Some(resolution))
        }
        None => {
            if environment_of(&cli.command).is_some() && needs_architecture(&cli.command) {
                return Err("this verb resolves a CALM architecture; give it --architecture".into());
            }
            (Manifest::load(&cli.manifest)?, manifest_dir(&cli.manifest), None)
        }
    };
    let runner = SystemRunner;
    let calm = || resolution.as_ref().ok_or("this verb resolves a CALM architecture; give it --architecture");
    match cli.command {
        Command::Schema { .. } => unreachable!("handled above"),
        Command::Resolve { output, .. } => {
            let resolution = calm()?;
            let text = serde_json::to_string_pretty(&resolution.topology)? + "\n";
            if let Some(output) = output {
                std::fs::write(&output, &text)?;
            }
            print!("{text}");
        }
        Command::Export { what, environment, format, app, output } => {
            let resolution = calm()?;
            let text = export(
                resolution,
                &manifest,
                &dir,
                &environment,
                what,
                format.as_deref(),
                app.as_deref(),
                output.as_deref(),
            )?;
            match (output, what) {
                (Some(_), ExportKind::Tofu) => {}
                (Some(path), _) => std::fs::write(path, text)?,
                (None, _) => print!("{text}"),
            }
        }
        Command::Run { app, dir: run_dir, attestation, command, .. } => {
            let resolution = calm()?;
            let report = calm_run::run(resolution, &app, &command, run_dir.as_deref(), attestation.as_deref()).await?;
            eprintln!(
                "ironframe: run {} of {app} exited {}; attestation {}",
                report.attestation.run.id,
                report.exit_code,
                report.path.display()
            );
            return Ok(exit_code(report.exit_code));
        }
        Command::App { node, attestation, args, .. } => {
            let resolution = calm()?;
            let report = calm_run::run_managed(resolution, &node, &args, attestation.as_deref()).await?;
            eprintln!(
                "ironframe: run {} of {node} exited {}; attestation {}",
                report.attestation.run.id,
                report.exit_code,
                report.path.display()
            );
            return Ok(exit_code(report.exit_code));
        }
        Command::Attest { app: Some(app), output, .. } => {
            let resolution = calm()?;
            let running = calm_run::begin(resolution, &app, &[], None).await?;
            let path = calm_run::write_run(resolution, &running, output.as_deref())?;
            println!("run {} of {app} begun; attestation: {}", running.run.id, path.display());
        }
        Command::Attest { complete: Some(file), exit_code: code, output, .. } => {
            let resolution = calm()?;
            let running = ironframe_attestation::Attestation::from_json(&std::fs::read_to_string(&file)?)?;
            let completed = calm_run::complete(resolution, &running, code).await?;
            let path = calm_run::write_run(resolution, &completed, Some(output.as_deref().unwrap_or(&file)))?;
            println!("run {} completed with exit code {code}; attestation: {}", completed.run.id, path.display());
        }
        Command::Validate { .. } => {
            println!(
                "{}: valid; project {}, environments {}",
                cli.manifest.display(),
                manifest.project,
                manifest.environments.keys().cloned().collect::<Vec<_>>().join(", ")
            );
        }
        Command::Settings { environment, format, app: Some(app) } => {
            let settings = calm_run::settings_of(calm()?, &app)?;
            match format {
                SettingsFormat::Env => {
                    print!("{}", render_dotenv(&format!("Settings of {app} in environment {environment}"), &settings))
                }
                SettingsFormat::Json => println!("{}", serde_json::to_string_pretty(&settings)?),
            }
        }
        Command::Settings { environment, format, app: None } => {
            let resolved = ops::resolve_in(&manifest, &dir, &environment)?;
            match format {
                SettingsFormat::Env => print!(
                    "{}",
                    render_dotenv(
                        &format!("Settings of environment {environment} of {}", manifest.project),
                        &resolved.settings()
                    )
                ),
                SettingsFormat::Json => println!("{}", serde_json::to_string_pretty(&resolved.settings())?),
            }
        }
        Command::Compose { environment } => {
            let declared = manifest.environment(&environment)?;
            if declared.runtime.is_cloud() {
                return Err(format!(
                    "environment {environment:?} runs on {}; only a podman environment has a compose file",
                    declared.runtime
                )
                .into());
            }
            let resolved = ops::resolve_in(&manifest, &dir, &environment)?;
            let settings = ironframe_core::workdir::WorkDir::new(&dir, &environment).settings();
            print!(
                "{}",
                ironframe_core::compose::compose_file(
                    &resolved,
                    declared.config_service.as_ref().map(|s| (s, settings.as_path()))
                )
            );
        }
        Command::Up { environment, no_sync, wait } => {
            let options = UpOptions { sync: !no_sync, wait: Duration::from_secs(wait) };
            let mut progress = |step: &str| eprintln!("ironframe: {step}");
            let report = ops::up(&manifest, &dir, &environment, &runner, &RealClouds, &options, &mut progress).await?;
            if let Some(resolution) = &resolution {
                println!("topology: {}", calm_run::write_topology(resolution)?.display());
            }
            for dependency in &report.environment.dependencies {
                println!("{:<20} {:<5} {}", dependency.name, dependency.kind.as_str(), dependency.endpoint);
            }
            for (target, done) in &report.synced {
                println!("synced {target}: {}", outcome(done));
            }
            println!("attestation: {}", report.attestation_path.display());
            if !report.unreached.is_empty() {
                eprintln!(
                    "ironframe: no answer from {}; the attestation records them as not reached",
                    report.unreached.join(", ")
                );
                return Ok(ExitCode::from(1));
            }
        }
        Command::Down { environment } => {
            ops::down(&manifest, &dir, &environment, &runner)?;
            println!("environment {environment} is down");
        }
        Command::Status { environment, json } => {
            let states = ops::status(&manifest, &dir, &environment, &runner)?;
            if json {
                println!("{}", serde_json::to_string_pretty(&states)?);
            } else {
                println!("{:<20} {:<5} {:<14} {:<10} ENDPOINT", "DEPENDENCY", "KIND", "STATE", "REACHABLE");
                for state in &states {
                    println!(
                        "{:<20} {:<5} {:<14} {:<10} {}",
                        state.name,
                        state.kind,
                        state.state,
                        if state.reachable { "yes" } else { "no" },
                        state.endpoint.as_deref().unwrap_or("-")
                    );
                }
            }
        }
        Command::Plan { environment } => {
            let root = ops::plan(&manifest, &dir, &environment, &runner)?;
            println!("planned {}", root.display());
        }
        Command::Sync { environment } => {
            let resolved = ops::resolve_in(&manifest, &dir, &environment)?;
            let done = ops::sync_environment(&manifest, &dir, &resolved, &RealClouds).await?;
            if done.is_empty() {
                println!("environment {environment} has no sync targets");
            }
            for (target, result) in &done {
                println!("synced {target}: {}", outcome(result));
            }
        }
        Command::Attest { environment, output, .. } => {
            let (attestation, path) = ops::attest_now(&manifest, &dir, &environment, output.as_deref()).await?;
            for dependency in &attestation.dependencies {
                let stand_in = dependency.stand_in.as_ref().map_or_else(String::new, |s| {
                    let mut text = format!("{}:{} conformance {}", s.product, s.version, s.conformance);
                    if let Some(seed) = s.seed {
                        text.push_str(&format!(" seed {seed}"));
                    }
                    if let Some(digest) = &s.history_digest {
                        text.push_str(&format!(" history {digest}"));
                    }
                    text
                });
                println!(
                    "{:<20} {:<8} {:<8} {:<24} {stand_in}",
                    dependency.name,
                    match dependency.kind {
                        ironframe_attestation::Kind::Real => "real",
                        ironframe_attestation::Kind::StandIn => "stand-in",
                    },
                    if dependency.reached { "reached" } else { "unreached" },
                    dependency.endpoint
                );
            }
            println!("attestation: {}", path.display());
        }
        Command::Twin { dependency, environment, action } => {
            let control = ops::control_plane(&manifest, &dir, &environment, &dependency)?;
            return Ok(match twin(&control, action).await {
                Ok(()) => ExitCode::SUCCESS,
                Err((message, code)) => {
                    eprintln!("ironframe twin {dependency}: {message}");
                    ExitCode::from(code)
                }
            });
        }
    }
    Ok(ExitCode::SUCCESS)
}

/// Runs one control-plane command and prints the twin's answer as `lawtwin` does.
async fn twin(control: &ControlPlane, action: TwinAction) -> Result<(), (String, u8)> {
    let fail = |e: TwinError| (e.to_string(), e.exit_code());
    let print = |body: String| println!("{}", pretty(&body));
    match action {
        TwinAction::Inspect { records } => control.inspect(records).await.map(print).map_err(fail),
        TwinAction::Force { state } => {
            let text = if state == "-" {
                let mut text = String::new();
                std::io::stdin().read_to_string(&mut text).map_err(|e| (e.to_string(), 1))?;
                text
            } else {
                std::fs::read_to_string(&state).map_err(|e| (format!("{state}: {e}"), 1))?
            };
            control.force(text).await.map(print).map_err(fail)
        }
        TwinAction::Fault { name, params } if name == "clear" => {
            control.clear(params.first().map(String::as_str)).await.map(print).map_err(fail)
        }
        TwinAction::Fault { name, params } => {
            let fault = parse_fault(&name, &params).map_err(fail)?;
            control.raise(&fault).await.map(print).map_err(fail)
        }
        TwinAction::Faults => control.faults().await.map(print).map_err(fail),
        TwinAction::History { since, limit, array } => {
            let body = control.history(since, limit, array).await.map_err(fail)?;
            if array {
                print(body);
            } else {
                print!("{body}");
            }
            Ok(())
        }
        TwinAction::Advance { duration } => control.advance(&duration).await.map(print).map_err(fail),
        TwinAction::Seed { seed: Some(seed) } => control.set_seed(seed).await.map(print).map_err(fail),
        TwinAction::Seed { seed: None } => {
            control.request("GET", "/v1/seed", None).await.and_then(|r| r.ok()).map(print).map_err(fail)
        }
        TwinAction::Reset => control.reset().await.map(print).map_err(fail),
        TwinAction::Replay { file } => {
            let body = match file.as_deref() {
                None => None,
                Some("-") => {
                    let mut text = String::new();
                    std::io::stdin().read_to_string(&mut text).map_err(|e| (e.to_string(), 1))?;
                    Some(text)
                }
                Some(path) => Some(std::fs::read_to_string(path).map_err(|e| (format!("{path}: {e}"), 1))?),
            };
            let body = control.replay(body).await.map_err(fail)?;
            print(body.clone());
            let value: serde_json::Value = serde_json::from_str(&body).unwrap_or_default();
            let diverged = value["divergences"].as_array().is_none_or(|d| !d.is_empty());
            let broken =
                ["state", "history"].iter().any(|k| value["violations"][k].as_array().is_none_or(|v| !v.is_empty()));
            if diverged || broken { Err(("the replay diverged or broke a law".into(), 1)) } else { Ok(()) }
        }
        TwinAction::Laws => {
            let body = control.request("GET", "/v1/laws", None).await.and_then(|r| r.ok()).map_err(fail)?;
            print(body.clone());
            let value: serde_json::Value = serde_json::from_str(&body).unwrap_or_default();
            if value["holds"].as_bool() == Some(true) { Ok(()) } else { Err(("a law does not hold".into(), 1)) }
        }
    }
}

/// The environment a verb works on, if it works on one.
fn environment_of(command: &Command) -> Option<String> {
    match command {
        Command::Schema { .. } | Command::Validate { .. } => None,
        Command::Resolve { environment, .. }
        | Command::Export { environment, .. }
        | Command::Run { environment, .. }
        | Command::App { environment, .. }
        | Command::Settings { environment, .. }
        | Command::Compose { environment }
        | Command::Up { environment, .. }
        | Command::Down { environment }
        | Command::Status { environment, .. }
        | Command::Plan { environment }
        | Command::Sync { environment }
        | Command::Attest { environment, .. }
        | Command::Twin { environment, .. } => Some(environment.clone()),
    }
}

/// Whether a verb only has meaning for a CALM architecture.
fn needs_architecture(command: &Command) -> bool {
    matches!(
        command,
        Command::Resolve { .. }
            | Command::Export { .. }
            | Command::Run { .. }
            | Command::App { .. }
            | Command::Settings { app: Some(_), .. }
            | Command::Attest { app: Some(_), .. }
            | Command::Attest { complete: Some(_), .. }
    )
}

/// An exit code as the process's own.
fn exit_code(code: i32) -> ExitCode {
    ExitCode::from(u8::try_from(code).unwrap_or(1))
}

/// Checks an architecture and its decorators, resolves every environment they declare, and, when
/// asked, checks the architecture with the CALM CLI too. ref:DEC-calm-architecture
fn validate_architecture(
    path: &Path,
    decorators: Option<&Path>,
    calm_cli: bool,
) -> Result<ExitCode, Box<dyn std::error::Error>> {
    let architecture = Architecture::load(path)?;
    let decorators_path = decorators.map_or_else(|| default_decorators(path), Path::to_path_buf);
    let decorations = Decorators::load(&decorators_path)?;
    let mut environments: Vec<String> = decorations
        .of_type(ENVIRONMENT_TYPE)
        .filter_map(|d| d.data["environment"].as_str().map(str::to_string))
        .collect();
    environments.sort();
    environments.dedup();
    let mut failed = false;
    if environments.is_empty() {
        eprintln!("ironframe: {} declares no environment", decorators_path.display());
        failed = true;
    }
    for environment in &environments {
        match load_and_resolve(path, Some(&decorators_path), environment) {
            Ok(resolution) => {
                let topology = &resolution.topology;
                let kinds: Vec<String> =
                    topology.dependencies.iter().map(|d| format!("{} {}", d.node, d.kind.as_str())).collect();
                println!("environment {environment}: resolved; {}", kinds.join(", "));
            }
            Err(error) => {
                eprintln!("ironframe: environment {environment}: {error}");
                failed = true;
            }
        }
    }
    println!(
        "{}: CALM {} architecture, {} nodes, {} relationships, {} decorators",
        path.display(),
        ironframe_core::calm::model::CALM_RELEASE,
        architecture.nodes.len(),
        architecture.relationships.len(),
        decorations.items.len()
    );
    if calm_cli {
        let Some(calm) = ironframe_core::process::locate("IRONFRAME_CALM", &["calm"], &[]) else {
            return Err("the CALM CLI is not installed; npm install -g @finos/calm-cli, or set IRONFRAME_CALM".into());
        };
        let status = std::process::Command::new(&calm)
            .args(["validate", "--architecture"])
            .arg(path)
            .args(["--format", "pretty"])
            .status()?;
        println!("calm validate: {}", if status.success() { "passed" } else { "failed" });
        failed |= !status.success();
    }
    Ok(if failed { ExitCode::from(1) } else { ExitCode::SUCCESS })
}

/// One export of a resolved environment, as text; the OpenTofu root is written to its directory.
/// ref:DEC-calm-exports
#[allow(clippy::too_many_arguments)]
fn export(
    resolution: &Resolution,
    manifest: &Manifest,
    dir: &Path,
    environment: &str,
    what: ExportKind,
    format: Option<&str>,
    app: Option<&str>,
    output: Option<&Path>,
) -> Result<String, Box<dyn std::error::Error>> {
    let topology = &resolution.topology;
    Ok(match what {
        ExportKind::Topology => serde_json::to_string_pretty(topology)? + "\n",
        ExportKind::Diagram => match format.unwrap_or("mermaid") {
            "mermaid" => calm_export::mermaid(topology),
            "dot" => calm_export::dot(topology),
            "calm" | "calm-template" => {
                let annotated = calm_export::annotated_architecture(&resolution.architecture.document, topology);
                let text = serde_json::to_string_pretty(&annotated)? + "\n";
                if format == Some("calm") { text } else { calm_template(&text)? }
            }
            other => return Err(format!("no diagram format {other:?}; use mermaid, dot, calm or calm-template").into()),
        },
        ExportKind::Settings => {
            let workdir = ironframe_core::workdir::WorkDir::new(dir, environment);
            let deployed = workdir.read_endpoints()?;
            let all = calm_export::application_settings(resolution, &deployed)?;
            match (app, format.unwrap_or(if app.is_some() { "env" } else { "json" })) {
                (Some(app), "env") => render_dotenv(
                    &format!("Settings of {app} in environment {environment} of {}", topology.project),
                    all.get(app).ok_or_else(|| format!("no application node {app:?}"))?,
                ),
                (Some(app), "json") => {
                    serde_json::to_string_pretty(all.get(app).ok_or_else(|| format!("no application node {app:?}"))?)?
                        + "\n"
                }
                (None, "json") => serde_json::to_string_pretty(&all)? + "\n",
                (None, _) => return Err("dotenv settings are one application's; give --app".into()),
                (_, other) => return Err(format!("no settings format {other:?}; use env or json").into()),
            }
        }
        ExportKind::Tofu => {
            let root = ironframe_core::tofu::root_module(manifest, environment, dir)?;
            let text = serde_json::to_string_pretty(&root)? + "\n";
            if let Some(output) = output {
                std::fs::create_dir_all(output)?;
                std::fs::write(output.join("main.tf.json"), &text)?;
                eprintln!("ironframe: wrote {}", output.join("main.tf.json").display());
            }
            text
        }
        ExportKind::Compose => {
            let resolved = ops::resolve_in(manifest, dir, environment)?;
            let declared = manifest.environment(environment)?;
            let settings = ironframe_core::workdir::WorkDir::new(dir, environment).settings();
            ironframe_core::compose::compose_file(
                &resolved,
                declared.config_service.as_ref().map(|s| (s, settings.as_path())),
            )
        }
    })
}

/// Renders an annotated architecture with the CALM CLI's block-architecture widget, through
/// `calm docify` with a one-line template, since only docify registers CALM's widgets; the CLI is
/// found on PATH or in IRONFRAME_CALM. ref:DEC-calm-exports
fn calm_template(annotated: &str) -> Result<String, Box<dyn std::error::Error>> {
    let Some(calm) = ironframe_core::process::locate("IRONFRAME_CALM", &["calm"], &[]) else {
        return Err("the CALM CLI is not installed; npm install -g @finos/calm-cli, or set IRONFRAME_CALM".into());
    };
    let scratch = std::env::temp_dir().join(format!("ironframe-calm-{}", std::process::id()));
    std::fs::create_dir_all(&scratch)?;
    let architecture = scratch.join("architecture.json");
    let template = scratch.join("diagram.md");
    let output = scratch.join("out.md");
    std::fs::write(&architecture, annotated)?;
    std::fs::write(&template, calm_export::CALM_DIAGRAM_TEMPLATE)?;
    let result = std::process::Command::new(&calm)
        .arg("docify")
        .arg("--architecture")
        .arg(&architecture)
        .arg("--template")
        .arg(&template)
        .arg("--output")
        .arg(&output)
        .output()?;
    if !result.status.success() {
        return Err(format!("calm docify failed: {}", String::from_utf8_lossy(&result.stderr).trim()).into());
    }
    let text = std::fs::read_to_string(&output)?;
    let _ = std::fs::remove_dir_all(&scratch);
    Ok(text)
}

#[tokio::main]
async fn main() -> ExitCode {
    match run(Cli::parse()).await {
        Ok(code) => code,
        Err(error) => {
            eprintln!("ironframe: {error}");
            ExitCode::from(2)
        }
    }
}
