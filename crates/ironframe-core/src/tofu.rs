//! A cloud environment's OpenTofu root: generated as JSON from the manifest, one module instance
//! per twin from `modules/`, the provider configured from the environment's cloud inputs, and one
//! output mapping each twin to its endpoint, which `up` reads back into the settings. Real
//! dependencies are hosted already and are not deployed. ref:DEC-opentofu

use crate::manifest::{Binding, Cloud, Environment, Manifest, Runtime, TWIN_CONFIG_VARIABLE};
use crate::process::{CommandRunner, last_line, locate};
use crate::settings::qualify_image;
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// The released modules, used when an environment names no `cloud.modules`. ref:DEC-opentofu
pub const RELEASED_MODULES: &str = "git::https://github.com/brain-fuel/ironframe.git//modules?ref=v0.1.0";

/// The name of the root module's output that maps each twin to its endpoint. ref:DEC-opentofu
pub const ENDPOINTS_OUTPUT: &str = "endpoints";

/// Why an OpenTofu step failed. ref:DEC-opentofu
#[derive(Debug, thiserror::Error)]
pub enum TofuError {
    /// Neither OpenTofu nor Terraform is installed.
    #[error(
        "a cloud environment needs OpenTofu: set IRONFRAME_TOFU, or install it (`brew install opentofu`, or https://opentofu.org/docs/intro/install/); terraform on PATH also works"
    )]
    NotInstalled,
    /// The environment runs on podman.
    #[error(
        "environment {0:?} runs on podman; `plan` is for cloud environments, and `ironframe up {0}` runs it locally"
    )]
    NotCloud(String),
    /// A command failed.
    #[error("`{tool} {command}` failed: {reason}")]
    Failed {
        /// The binary.
        tool: String,
        /// The subcommand.
        command: String,
        /// Its reason.
        reason: String,
    },
    /// The endpoints output was not what the root declares.
    #[error("cannot read the endpoints output: {0}")]
    Output(String),
    /// The binary could not be started.
    #[error("cannot run {0}: {1}")]
    Io(PathBuf, std::io::Error),
}

/// The source of `module` under `base`: a local path made absolute against the manifest's
/// directory, since the root lives elsewhere, or a remote source with the module's directory put
/// before its query. ref:DEC-opentofu
pub fn module_source(base: &str, module: &str, manifest_dir: &Path) -> String {
    let remote = base.contains("::") || base.contains("://") || base.starts_with("github.com/");
    if !remote {
        let path = Path::new(base);
        let absolute = if path.is_absolute() { path.to_path_buf() } else { manifest_dir.join(path) };
        return absolute.join(module).to_string_lossy().into_owned();
    }
    match base.split_once('?') {
        Some((source, query)) => format!("{}/{module}?{query}", source.trim_end_matches('/')),
        None => format!("{}/{module}", base.trim_end_matches('/')),
    }
}

/// The resource name a twin is deployed under: project, environment and dependency joined with
/// hyphens, as every cloud accepts them; the modules shorten it where a cloud limits length.
/// ref:DEC-opentofu
pub fn deployment_name(project: &str, environment: &str, dependency: &str) -> String {
    format!("{project}-{environment}-{dependency}").replace('_', "-")
}

fn provider(runtime: Runtime, cloud: &Cloud) -> (&'static str, Value) {
    let mut config = Map::new();
    for input in runtime.provider_inputs() {
        if let Some(value) = cloud.inputs.get(*input) {
            config.insert((*input).to_string(), value.clone());
        }
    }
    let name = match runtime {
        Runtime::Aws => "aws",
        Runtime::Gcp => "google",
        Runtime::Azure => {
            config.insert("features".into(), json!({}));
            "azurerm"
        }
        Runtime::Podman => unreachable!("a podman environment has no OpenTofu root"),
    };
    (name, Value::Object(config))
}

fn required_provider(runtime: Runtime) -> (&'static str, Value) {
    match runtime {
        Runtime::Aws => ("aws", json!({"source": "hashicorp/aws", "version": ">= 6.0, < 7.0"})),
        Runtime::Gcp => ("google", json!({"source": "hashicorp/google", "version": ">= 6.0, < 8.0"})),
        Runtime::Azure => ("azurerm", json!({"source": "hashicorp/azurerm", "version": ">= 4.0, < 5.0"})),
        Runtime::Podman => unreachable!("a podman environment has no OpenTofu root"),
    }
}

/// The root module of cloud environment `name`, as OpenTofu's JSON syntax. ref:DEC-opentofu
pub fn root_module(manifest: &Manifest, name: &str, manifest_dir: &Path) -> Result<Value, TofuError> {
    let environment: &Environment = manifest.environment(name).map_err(|e| TofuError::Output(e.to_string()))?;
    let runtime = environment.runtime;
    let module = runtime.module().ok_or_else(|| TofuError::NotCloud(name.to_string()))?;
    let cloud = environment.cloud.clone().unwrap_or_default();
    let base = cloud.modules.clone().unwrap_or_else(|| RELEASED_MODULES.to_string());
    let source = module_source(&base, module, manifest_dir);
    let mut modules = Map::new();
    let mut endpoints = Map::new();
    for (dependency, binding) in &environment.dependencies {
        let Binding::Twin(twin) = binding else { continue };
        let mut env: BTreeMap<String, String> = twin.env.clone();
        let config = twin.config.clone().unwrap_or_else(|| json!({}));
        env.insert(TWIN_CONFIG_VARIABLE.to_string(), config.to_string());
        let mut inputs = Map::new();
        inputs.insert("source".into(), json!(source));
        inputs.insert("name".into(), json!(deployment_name(&manifest.project, name, dependency)));
        inputs.insert("image".into(), json!(qualify_image(&twin.image_ref())));
        inputs.insert("ports".into(), json!(twin.ports));
        inputs.insert("environment".into(), json!(env));
        for input in runtime.module_inputs() {
            if let Some(value) = cloud.inputs.get(*input) {
                inputs.insert((*input).to_string(), value.clone());
            }
        }
        let key = format!("twin_{}", dependency.replace('-', "_"));
        endpoints.insert(dependency.clone(), json!(format!("${{module.{key}.endpoint}}")));
        modules.insert(key, Value::Object(inputs));
    }
    let (provider_name, provider_config) = provider(runtime, &cloud);
    let (required_name, required) = required_provider(runtime);
    let mut root = json!({
        "//": format!("Generated by ironframe for environment {name} of {}; edits are overwritten.", manifest.project),
        "terraform": {
            "required_version": ">= 1.6.0",
            "required_providers": { required_name: required }
        },
        "provider": { provider_name: [provider_config] },
        "output": {
            ENDPOINTS_OUTPUT: {
                "description": "Each twin's endpoint, by dependency.",
                "value": Value::Object(endpoints)
            }
        }
    });
    if !modules.is_empty() {
        root["module"] = Value::Object(modules);
    }
    Ok(root)
}

/// OpenTofu, or Terraform, found and ready to run in one root directory. ref:DEC-opentofu
pub struct Tofu<'a> {
    /// The binary.
    pub program: PathBuf,
    /// The root module's directory.
    pub root: PathBuf,
    runner: &'a dyn CommandRunner,
}

impl<'a> Tofu<'a> {
    /// Finds `IRONFRAME_TOFU`, then `tofu`, then `terraform` on `PATH`.
    pub fn locate(root: PathBuf, runner: &'a dyn CommandRunner) -> Result<Self, TofuError> {
        let program = locate("IRONFRAME_TOFU", &["tofu", "terraform"], &["/opt/homebrew/bin/tofu"])
            .ok_or(TofuError::NotInstalled)?;
        Ok(Tofu { program, root, runner })
    }

    /// The binary at a known path.
    pub fn at(program: PathBuf, root: PathBuf, runner: &'a dyn CommandRunner) -> Self {
        Tofu { program, root, runner }
    }

    fn run(&self, args: &[&str], stream: bool) -> Result<crate::process::CommandOutput, TofuError> {
        let mut all = vec![format!("-chdir={}", self.root.display())];
        all.extend(args.iter().map(|a| a.to_string()));
        let output =
            self.runner.run(&self.program, &all, stream).map_err(|e| TofuError::Io(self.program.clone(), e))?;
        if output.success {
            Ok(output)
        } else {
            Err(TofuError::Failed {
                tool: self.program.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
                command: args.join(" "),
                reason: if stream { "see the output above".into() } else { last_line(&output.stderr) },
            })
        }
    }

    /// `init`, fetching the modules and providers.
    pub fn init(&self) -> Result<(), TofuError> {
        self.run(&["init", "-input=false"], true).map(|_| ())
    }

    /// `plan`.
    pub fn plan(&self) -> Result<(), TofuError> {
        self.run(&["plan", "-input=false"], true).map(|_| ())
    }

    /// `apply`, without asking.
    pub fn apply(&self) -> Result<(), TofuError> {
        self.run(&["apply", "-input=false", "-auto-approve"], true).map(|_| ())
    }

    /// `destroy`, without asking.
    pub fn destroy(&self) -> Result<(), TofuError> {
        self.run(&["destroy", "-input=false", "-auto-approve"], true).map(|_| ())
    }

    /// The endpoint of each deployed twin, from the root's endpoints output.
    pub fn endpoints(&self) -> Result<BTreeMap<String, String>, TofuError> {
        let output = self.run(&["output", "-json", ENDPOINTS_OUTPUT], false)?;
        serde_json::from_str(&output.stdout).map_err(|e| TofuError::Output(e.to_string()))
    }
}
