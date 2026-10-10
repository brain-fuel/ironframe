//! The `ironframe` command. Every verb is a call into `ironframe-core`; this file only reads the
//! command line, prints, and turns a failure into an exit status. ref:DEC-wiring-in-ironframe

use clap::{Parser, Subcommand, ValueEnum};
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

/// The command line: a manifest and a verb.
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
    #[command(subcommand)]
    command: Command,
}

/// The verbs.
#[derive(Subcommand)]
enum Command {
    /// Check the manifest and report every problem.
    Validate,
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
    /// Write the environment attestation now.
    Attest {
        /// The environment.
        environment: String,
        /// Where to write it; the environment's working directory when absent.
        #[arg(short, long)]
        output: Option<PathBuf>,
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
}

/// The schemas `ironframe schema` prints.
#[derive(Clone, Copy, ValueEnum)]
enum SchemaKind {
    /// ironframe.yaml.
    Manifest,
    /// The environment attestation.
    Attestation,
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
            }
        );
        return Ok(ExitCode::SUCCESS);
    }
    let manifest = Manifest::load(&cli.manifest)?;
    let dir = manifest_dir(&cli.manifest);
    let runner = SystemRunner;
    match cli.command {
        Command::Schema { .. } => unreachable!("handled above"),
        Command::Validate => {
            println!(
                "{}: valid; project {}, environments {}",
                cli.manifest.display(),
                manifest.project,
                manifest.environments.keys().cloned().collect::<Vec<_>>().join(", ")
            );
        }
        Command::Settings { environment, format } => {
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
        Command::Attest { environment, output } => {
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
        TwinAction::Reset => {
            control.request("DELETE", "/v1/reset", None).await.and_then(|r| r.ok()).map(print).map_err(fail)
        }
        TwinAction::Laws => {
            let body = control.request("GET", "/v1/laws", None).await.and_then(|r| r.ok()).map_err(fail)?;
            print(body.clone());
            let value: serde_json::Value = serde_json::from_str(&body).unwrap_or_default();
            if value["holds"].as_bool() == Some(true) { Ok(()) } else { Err(("a law does not hold".into(), 1)) }
        }
    }
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
