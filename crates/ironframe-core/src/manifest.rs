//! The manifest, `ironframe.yaml`: the dependencies an application reads from its configuration,
//! and for each environment whether each one is the real dependency or a twin. A manifest is read
//! in two passes, the JSON Schema for its shape and then the rules across fields, and every problem
//! of a pass is reported at once with the path of the field at fault. ref:DEC-manifest-shape

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::path::{Path, PathBuf};

/// The one manifest version this release reads. ref:DEC-manifest-shape
pub const MANIFEST_VERSION: u32 = 1;

/// The file name Ironframe looks for when no manifest is named. ref:DEC-manifest-shape
pub const DEFAULT_MANIFEST: &str = "ironframe.yaml";

/// The manifest's JSON Schema, embedded so `ironframe schema` can print it and the first pass can
/// check against it. ref:DEC-manifest-shape
pub const SCHEMA: &str = include_str!("../../../schema/ironframe-v1.schema.json");

/// The image of the configuration service a podman environment runs when it asks for one and names
/// no other. ref:DEC-config-service
pub const DEFAULT_CONFIG_SERVICE_IMAGE: &str = "localhost/ironframe-config-service:0.1.0";

/// The port the configuration service listens on when the manifest names none. ref:DEC-config-service
pub const DEFAULT_CONFIG_SERVICE_PORT: u16 = 8700;

/// The placeholders a settings template may use, so a typo is caught when the manifest is read
/// rather than when an application reads an empty setting. ref:DEC-manifest-shape
pub const PLACEHOLDERS: [&str; 6] = ["endpoint", "host", "port", "credentials", "kind", "name"];

/// The schemes a credentials reference may use. Ironframe passes a reference on and never reads
/// the secret behind it. ref:DEC-credentials-by-reference
pub const CREDENTIAL_SCHEMES: [&str; 6] =
    ["env", "file", "aws-secretsmanager", "gcp-secretmanager", "azure-keyvault", "vault"];

/// A whole manifest: its version, the project it wires, the dependencies the application reads,
/// and the environments. ref:DEC-manifest-shape
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    /// The manifest version, [`MANIFEST_VERSION`].
    pub version: u32,
    /// The project's name, which prefixes every container, compose project and cloud resource.
    pub project: String,
    /// The dependencies the application has, each with the settings it reads them through.
    pub dependencies: BTreeMap<String, DependencyDecl>,
    /// The environments, each binding every declared dependency.
    pub environments: BTreeMap<String, Environment>,
}

/// A dependency as the application sees it: the settings it reads, as templates over the endpoint
/// an environment binds. Declared once, so every environment hands the application the same keys.
/// ref:DEC-manifest-shape
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DependencyDecl {
    /// What the dependency is, for a reader of the manifest.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Setting name to template, such as `KAFKA_BOOTSTRAP_SERVERS: ${endpoint}`.
    pub settings: BTreeMap<String, String>,
}

/// One environment: where it runs, what each dependency is in it, where its settings are synced,
/// and whether it runs a configuration service. ref:DEC-manifest-shape
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Environment {
    /// Where the environment's containers run.
    pub runtime: Runtime,
    /// The inputs a cloud runtime needs, such as a region; absent for podman.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cloud: Option<Cloud>,
    /// Each declared dependency, bound to the real thing or a twin.
    pub dependencies: BTreeMap<String, Binding>,
    /// Where the environment's settings are written besides the configuration service.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub sync: Vec<SyncTarget>,
    /// A configuration service to run beside the dependencies, on podman.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub config_service: Option<ConfigService>,
}

/// Where an environment's containers run: podman on this machine, or one of the three clouds
/// through OpenTofu. ref:DEC-opentofu ref:DEC-podman-compose
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, PartialOrd, Ord)]
#[serde(rename_all = "lowercase")]
pub enum Runtime {
    /// Podman and compose on this machine.
    Podman,
    /// AWS ECS on Fargate.
    Aws,
    /// GCP Cloud Run.
    Gcp,
    /// Azure Container Apps.
    Azure,
}

impl Runtime {
    /// Whether the runtime is a cloud, deployed through OpenTofu.
    pub fn is_cloud(self) -> bool {
        self != Runtime::Podman
    }

    /// The manifest's word for the runtime.
    pub fn as_str(self) -> &'static str {
        match self {
            Runtime::Podman => "podman",
            Runtime::Aws => "aws",
            Runtime::Gcp => "gcp",
            Runtime::Azure => "azure",
        }
    }

    /// The module directory under `modules/` that runs a twin on this runtime; none for podman.
    pub fn module(self) -> Option<&'static str> {
        match self {
            Runtime::Podman => None,
            Runtime::Aws => Some("aws-ecs-fargate"),
            Runtime::Gcp => Some("gcp-cloud-run"),
            Runtime::Azure => Some("azure-container-apps"),
        }
    }

    /// The inputs passed to the OpenTofu provider rather than to the modules.
    pub fn provider_inputs(self) -> &'static [&'static str] {
        match self {
            Runtime::Podman => &[],
            Runtime::Aws => &["region"],
            Runtime::Gcp => &["project", "region"],
            Runtime::Azure => &["subscription_id"],
        }
    }

    /// The inputs the runtime's module takes, beside the name, image, ports and environment
    /// Ironframe passes itself.
    pub fn module_inputs(self) -> &'static [&'static str] {
        match self {
            Runtime::Podman => &[],
            Runtime::Aws => {
                &["vpc_id", "subnet_ids", "cpu", "memory", "assign_public_ip", "allowed_cidr_blocks", "internal"]
            }
            Runtime::Gcp => &["project", "region", "cpu", "memory", "public"],
            Runtime::Azure => &[
                "location",
                "resource_group_name",
                "cpu",
                "memory",
                "infrastructure_subnet_id",
                "transport",
                "external",
            ],
        }
    }

    /// The inputs the runtime's module and provider cannot do without.
    pub fn required_inputs(self) -> &'static [&'static str] {
        match self {
            Runtime::Podman => &[],
            Runtime::Aws => &["region", "vpc_id", "subnet_ids"],
            Runtime::Gcp => &["project", "region"],
            Runtime::Azure => &["location", "resource_group_name"],
        }
    }
}

impl fmt::Display for Runtime {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// A cloud environment's inputs: where the OpenTofu modules come from, and the values passed to
/// the provider and to every module, such as `region` or `subnet_ids`. ref:DEC-opentofu
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct Cloud {
    /// The module source to use instead of the released modules, a local path or a git source.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub modules: Option<String>,
    /// Every other key, passed to each module as an input of the same name.
    #[serde(flatten)]
    pub inputs: BTreeMap<String, serde_json::Value>,
}

/// What a dependency is in one environment. ref:DEC-manifest-shape
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Binding {
    /// The real dependency.
    Real(Real),
    /// A twin standing in for it.
    Twin(Twin),
}

/// The real dependency: where it is and the reference to its credentials. On podman it may also be
/// run from its own image, as a broker image is run for a local environment. ref:DEC-manifest-shape
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Real {
    /// Where the application reaches it, `host:port` or a URL.
    pub endpoint: String,
    /// A reference to its credentials, such as `env:KAFKA_PASSWORD`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credentials: Option<String>,
    /// An image of the real product to run on podman, with its tag.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,
    /// The container ports to publish when `image` is run.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub ports: Vec<u16>,
    /// Environment variables for the container when `image` is run.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub env: BTreeMap<String, String>,
}

/// A twin: the stand-in's image and version, the configuration handed to it, the conformance level
/// its release declares, and the ports it serves. Ironframe runs it and records it; what the twin
/// does with its configuration is its own business. ref:DEC-manifest-shape ref:DEC-three-planes
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Twin {
    /// The image name without a tag, such as `lawtwin/kafka`.
    pub image: String,
    /// The image tag, which is the twin's version.
    pub version: String,
    /// Configuration handed to the twin as JSON in `TWIN_CONFIG`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub config: Option<serde_json::Value>,
    /// The conformance level the twin's release declares, recorded in the attestation.
    pub conformance: String,
    /// The container ports the twin serves; the first is the endpoint's.
    pub ports: Vec<u16>,
    /// Further environment variables for the container.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub env: BTreeMap<String, String>,
    /// The endpoint to hand the application, when it is not the one Ironframe works out.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub endpoint: Option<String>,
    /// A reference to credentials the application should present to the twin.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credentials: Option<String>,
}

impl Twin {
    /// The image reference with the version as its tag.
    pub fn image_ref(&self) -> String {
        format!("{}:{}", self.image, self.version)
    }
}

/// A place an environment's settings are written to, beside the configuration service.
/// ref:DEC-config-sync
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SyncTarget {
    /// A dotenv file for applications run on this machine.
    EnvFile(EnvFileTarget),
    /// A hosted configuration profile in AWS AppConfig.
    AwsAppconfig(AwsAppConfigTarget),
    /// A parameter in GCP Parameter Manager.
    GcpParameterManager(GcpParameterTarget),
    /// Key-values in Azure App Configuration.
    AzureAppConfiguration(AzureAppConfigurationTarget),
}

/// A dotenv file, relative to the manifest's directory. ref:DEC-config-sync
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EnvFileTarget {
    /// Where to write it.
    pub path: PathBuf,
}

/// An AWS AppConfig hosted configuration profile, created when missing and deployed with each
/// change. ref:DEC-config-sync
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AwsAppConfigTarget {
    /// The AWS region.
    pub region: String,
    /// The AppConfig application's name.
    pub application: String,
    /// The AppConfig environment's name; the Ironframe environment's when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub environment: Option<String>,
    /// The configuration profile's name.
    pub profile: String,
    /// The deployment strategy; `AppConfig.AllAtOnce` when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deployment_strategy: Option<String>,
}

/// A GCP Parameter Manager parameter of JSON format, one version per distinct content.
/// ref:DEC-config-sync
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GcpParameterTarget {
    /// The GCP project.
    pub project: String,
    /// The location; `global` when absent.
    #[serde(default = "default_gcp_location")]
    pub location: String,
    /// The parameter's id.
    pub parameter: String,
}

fn default_gcp_location() -> String {
    "global".to_string()
}

/// An Azure App Configuration store: one key-value per setting, under a prefix and a label.
/// ref:DEC-config-sync
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AzureAppConfigurationTarget {
    /// The store's endpoint, `https://<name>.azconfig.io`.
    pub endpoint: String,
    /// The label; the Ironframe environment's name when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    /// A prefix for every key, such as `kafka-app:`.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub prefix: String,
    /// The environment variable holding the store's connection string.
    #[serde(default = "default_azure_connection_env")]
    pub connection_string_env: String,
}

fn default_azure_connection_env() -> String {
    "AZURE_APPCONFIG_CONNECTION_STRING".to_string()
}

/// The configuration service of a podman environment: its image and its port. ref:DEC-config-service
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConfigService {
    /// The image to run; [`DEFAULT_CONFIG_SERVICE_IMAGE`] when absent.
    #[serde(default = "default_config_service_image")]
    pub image: String,
    /// The port to publish; [`DEFAULT_CONFIG_SERVICE_PORT`] when absent.
    #[serde(default = "default_config_service_port")]
    pub port: u16,
}

fn default_config_service_image() -> String {
    DEFAULT_CONFIG_SERVICE_IMAGE.to_string()
}

fn default_config_service_port() -> u16 {
    DEFAULT_CONFIG_SERVICE_PORT
}

/// One thing wrong with a manifest: the dotted path of the field, empty for the whole document,
/// and what is wrong with it. ref:DEC-manifest-shape
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Problem {
    /// The field, such as `environments.local.dependencies.kafka.twin.version`.
    pub at: String,
    /// What is wrong.
    pub message: String,
}

impl fmt::Display for Problem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.at.is_empty() { write!(f, "{}", self.message) } else { write!(f, "{}: {}", self.at, self.message) }
    }
}

/// Why a manifest could not be used: the file, and every problem found in it. ref:DEC-manifest-shape
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestError {
    /// The manifest's file, when it was read from one.
    pub origin: Option<PathBuf>,
    /// Every problem, in the order found.
    pub problems: Vec<Problem>,
}

impl fmt::Display for ManifestError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let origin = self.origin.as_ref().map_or_else(|| "manifest".to_string(), |p| p.display().to_string());
        match self.problems.as_slice() {
            [one] => write!(f, "{origin}: {one}"),
            many => {
                write!(f, "{origin}: {} problems", many.len())?;
                for problem in many {
                    write!(f, "\n  - {problem}")?;
                }
                Ok(())
            }
        }
    }
}

impl std::error::Error for ManifestError {}

fn problem(at: impl Into<String>, message: impl Into<String>) -> Problem {
    Problem { at: at.into(), message: message.into() }
}

impl Manifest {
    /// Reads and checks the manifest at `path`. ref:DEC-manifest-shape
    pub fn load(path: &Path) -> Result<Manifest, ManifestError> {
        let text = std::fs::read_to_string(path).map_err(|error| ManifestError {
            origin: Some(path.to_path_buf()),
            problems: vec![problem("", format!("cannot read the manifest: {error}"))],
        })?;
        Manifest::parse(&text).map_err(|mut error| {
            error.origin = Some(path.to_path_buf());
            error
        })
    }

    /// Reads and checks a manifest from YAML text: its shape against the JSON Schema, then the
    /// rules across fields. Each pass reports every problem it finds. ref:DEC-manifest-shape
    pub fn parse(text: &str) -> Result<Manifest, ManifestError> {
        let fail = |problems| ManifestError { origin: None, problems };
        let value: serde_json::Value =
            serde_yaml::from_str(text).map_err(|error| fail(vec![problem("", format!("not valid YAML: {error}"))]))?;
        let shape = schema_problems(&value);
        if !shape.is_empty() {
            return Err(fail(shape));
        }
        let manifest: Manifest =
            serde_json::from_value(value).map_err(|error| fail(vec![problem("", error.to_string())]))?;
        let rules = manifest.problems();
        if rules.is_empty() { Ok(manifest) } else { Err(fail(rules)) }
    }

    /// The environment named `name`, or an error naming the ones there are.
    pub fn environment(&self, name: &str) -> Result<&Environment, ManifestError> {
        self.environments.get(name).ok_or_else(|| ManifestError {
            origin: None,
            problems: vec![problem(
                "",
                format!(
                    "no environment named {name:?}; the manifest has {}",
                    self.environments.keys().map(|k| format!("{k:?}")).collect::<Vec<_>>().join(", ")
                ),
            )],
        })
    }

    /// Every rule across fields the manifest breaks; the shape is the schema's to check.
    /// ref:DEC-manifest-shape
    pub fn problems(&self) -> Vec<Problem> {
        let mut found = Vec::new();
        if self.version != MANIFEST_VERSION {
            found
                .push(problem("version", format!("version {} is not supported; use {MANIFEST_VERSION}", self.version)));
        }
        if !is_name(&self.project) {
            found.push(problem("project", NAME_RULE));
        }
        let mut owners: BTreeMap<&str, &str> = BTreeMap::new();
        for (dependency, declaration) in &self.dependencies {
            let at = format!("dependencies.{dependency}");
            if !is_name(dependency) {
                found.push(problem(&at, NAME_RULE));
            }
            if declaration.settings.is_empty() {
                found.push(problem(format!("{at}.settings"), "declare at least one setting the application reads"));
            }
            for (key, template) in &declaration.settings {
                if !is_setting_key(key) {
                    found.push(problem(
                        format!("{at}.settings.{key}"),
                        "a setting name is an environment variable name: letters, digits and _, not starting with a digit",
                    ));
                }
                if let Some(other) = owners.insert(key, dependency) {
                    found.push(problem(
                        format!("{at}.settings.{key}"),
                        format!("setting {key} is also declared by dependency {other:?}"),
                    ));
                }
                match placeholders(template) {
                    Ok(names) => {
                        for name in names {
                            if !PLACEHOLDERS.contains(&name.as_str()) {
                                found.push(problem(
                                    format!("{at}.settings.{key}"),
                                    format!("unknown placeholder ${{{name}}}; use one of {}", placeholder_list()),
                                ));
                            }
                        }
                    }
                    Err(message) => found.push(problem(format!("{at}.settings.{key}"), message)),
                }
            }
        }
        if self.environments.is_empty() {
            found.push(problem("environments", "declare at least one environment"));
        }
        for (name, environment) in &self.environments {
            self.environment_problems(name, environment, &mut found);
        }
        found
    }

    fn environment_problems(&self, name: &str, environment: &Environment, found: &mut Vec<Problem>) {
        let at = format!("environments.{name}");
        if !is_name(name) {
            found.push(problem(&at, NAME_RULE));
        }
        for missing in self.dependencies.keys().filter(|d| !environment.dependencies.contains_key(*d)) {
            found.push(problem(
                format!("{at}.dependencies"),
                format!("dependency {missing:?} is declared but not bound; bind it to `real` or `twin`"),
            ));
        }
        let runtime = environment.runtime;
        match (&environment.cloud, runtime.is_cloud()) {
            (Some(_), false) => found.push(problem(format!("{at}.cloud"), "only a cloud runtime takes `cloud` inputs")),
            (None, true) => found.push(problem(
                format!("{at}.cloud"),
                format!("runtime {runtime} needs `cloud` with {}", runtime.required_inputs().join(", ")),
            )),
            (Some(cloud), true) => {
                for input in runtime.required_inputs() {
                    if !cloud.inputs.contains_key(*input) {
                        found.push(problem(format!("{at}.cloud.{input}"), format!("runtime {runtime} needs {input}")));
                    }
                }
                for input in cloud.inputs.keys() {
                    let known = runtime.provider_inputs().contains(&input.as_str())
                        || runtime.module_inputs().contains(&input.as_str());
                    if !known {
                        let mut all: Vec<&str> = runtime.provider_inputs().to_vec();
                        for module_input in runtime.module_inputs() {
                            if !all.contains(module_input) {
                                all.push(module_input);
                            }
                        }
                        found.push(problem(
                            format!("{at}.cloud.{input}"),
                            format!("runtime {runtime} takes no input {input:?}; it takes modules, {}", all.join(", ")),
                        ));
                    }
                }
            }
            (None, false) => {}
        }
        if environment.config_service.is_some() && runtime.is_cloud() {
            found.push(problem(
                format!("{at}.config_service"),
                "the configuration service runs on podman; a cloud environment's settings reach its applications through `sync`",
            ));
        }
        let mut published: BTreeMap<u16, String> = BTreeMap::new();
        if let Some(service) = &environment.config_service {
            published.insert(service.port, "the configuration service".to_string());
            if service.port == 0 {
                found.push(problem(format!("{at}.config_service.port"), "a port is between 1 and 65535"));
            }
        }
        for (dependency, binding) in &environment.dependencies {
            let at = format!("{at}.dependencies.{dependency}");
            let Some(declaration) = self.dependencies.get(dependency) else {
                found.push(problem(
                    &at,
                    format!("dependency {dependency:?} is not declared under the top-level `dependencies`"),
                ));
                continue;
            };
            let uses_credentials = declaration.settings.values().any(|t| t.contains("${credentials}"));
            let (ports, runs_image) = match binding {
                Binding::Real(real) => {
                    let at = format!("{at}.real");
                    if real.endpoint.trim().is_empty() {
                        found.push(problem(format!("{at}.endpoint"), "the endpoint must not be empty"));
                    }
                    credentials_problems(&at, real.credentials.as_deref(), uses_credentials, found);
                    match &real.image {
                        Some(image) => {
                            if runtime.is_cloud() {
                                found.push(problem(
                                    format!("{at}.image"),
                                    "a real dependency runs from an image only on podman; in a cloud it is hosted and named by its endpoint",
                                ));
                            }
                            if image.trim().is_empty() {
                                found.push(problem(format!("{at}.image"), "the image must not be empty"));
                            }
                            if real.ports.is_empty() {
                                found.push(problem(
                                    format!("{at}.ports"),
                                    "an image run locally needs the ports to publish",
                                ));
                            }
                        }
                        None => {
                            if !real.ports.is_empty() || !real.env.is_empty() {
                                found.push(problem(&at, "`ports` and `env` apply only with `image`"));
                            }
                        }
                    }
                    (real.ports.clone(), real.image.is_some())
                }
                Binding::Twin(twin) => {
                    let at = format!("{at}.twin");
                    if twin.image.trim().is_empty() {
                        found.push(problem(format!("{at}.image"), "the image must not be empty"));
                    } else if has_tag(&twin.image) {
                        found.push(problem(
                            format!("{at}.image"),
                            "name the image without a tag or digest; the twin's `version` is its tag",
                        ));
                    }
                    if twin.version.trim().is_empty() {
                        found.push(problem(format!("{at}.version"), "the version must not be empty"));
                    }
                    if twin.conformance.trim().is_empty() {
                        found.push(problem(format!("{at}.conformance"), "declare the release's conformance level"));
                    }
                    if twin.ports.is_empty() {
                        found.push(problem(format!("{at}.ports"), "a twin serves at least one port"));
                    }
                    if runtime == Runtime::Gcp && twin.ports.len() > 1 {
                        found.push(problem(format!("{at}.ports"), "Cloud Run serves one port per service"));
                    }
                    if let Some(config) = &twin.config
                        && !config.is_object()
                    {
                        found.push(problem(format!("{at}.config"), "the twin's config is a mapping"));
                    }
                    if twin.env.contains_key(TWIN_CONFIG_VARIABLE) {
                        found.push(problem(
                            format!("{at}.env.{TWIN_CONFIG_VARIABLE}"),
                            "TWIN_CONFIG is written from `config`; set the configuration there",
                        ));
                    }
                    credentials_problems(&at, twin.credentials.as_deref(), uses_credentials, found);
                    (twin.ports.clone(), true)
                }
            };
            for port in &ports {
                if *port == 0 {
                    found.push(problem(format!("{at}.ports"), "a port is between 1 and 65535"));
                } else if runtime == Runtime::Podman
                    && runs_image
                    && let Some(other) = published.insert(*port, format!("dependency {dependency:?}"))
                {
                    found.push(problem(
                        format!("{at}.ports"),
                        format!("port {port} is already published by {other} in this environment"),
                    ));
                }
            }
        }
        for (index, target) in environment.sync.iter().enumerate() {
            let at = format!("{at}.sync[{index}]");
            let required: Vec<(&str, &str)> = match target {
                SyncTarget::EnvFile(t) => vec![("env_file.path", t.path.to_str().unwrap_or(""))],
                SyncTarget::AwsAppconfig(t) => vec![
                    ("aws_appconfig.region", &t.region),
                    ("aws_appconfig.application", &t.application),
                    ("aws_appconfig.profile", &t.profile),
                ],
                SyncTarget::GcpParameterManager(t) => vec![
                    ("gcp_parameter_manager.project", &t.project),
                    ("gcp_parameter_manager.location", &t.location),
                    ("gcp_parameter_manager.parameter", &t.parameter),
                ],
                SyncTarget::AzureAppConfiguration(t) => vec![
                    ("azure_app_configuration.endpoint", &t.endpoint),
                    ("azure_app_configuration.connection_string_env", &t.connection_string_env),
                ],
            };
            for (field, value) in required {
                if value.trim().is_empty() {
                    found.push(problem(format!("{at}.{field}"), "must not be empty"));
                }
            }
            if let SyncTarget::AzureAppConfiguration(t) = target
                && !t.endpoint.starts_with("https://")
            {
                found
                    .push(problem(format!("{at}.azure_app_configuration.endpoint"), "the endpoint is an https:// URL"));
            }
        }
    }
}

/// The environment variable a twin's `config` reaches it through, as JSON. ref:DEC-three-planes
pub const TWIN_CONFIG_VARIABLE: &str = "TWIN_CONFIG";

const NAME_RULE: &str = "a name is lowercase letters, digits, - and _, starting with a letter, at most 40 characters";

fn credentials_problems(at: &str, credentials: Option<&str>, used: bool, found: &mut Vec<Problem>) {
    match credentials {
        Some(reference) => {
            let scheme = reference.split_once(':').map(|(s, rest)| (s, rest.is_empty()));
            match scheme {
                Some((scheme, false)) if CREDENTIAL_SCHEMES.contains(&scheme) => {}
                _ => found.push(problem(
                    format!("{at}.credentials"),
                    format!(
                        "a credentials reference is <scheme>:<location> with scheme one of {}; Ironframe never holds the secret itself",
                        CREDENTIAL_SCHEMES.join(", ")
                    ),
                )),
            }
        }
        None if used => found.push(problem(
            format!("{at}.credentials"),
            "the dependency's settings use ${credentials}, so this binding must name a credentials reference",
        )),
        None => {}
    }
}

/// Whether `name` is a valid project, environment or dependency name: it becomes part of container,
/// compose and cloud resource names, which accept little else. ref:DEC-manifest-shape
pub fn is_name(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_lowercase())
        && name.len() <= 40
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_')
}

fn is_setting_key(key: &str) -> bool {
    let mut chars = key.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

fn has_tag(image: &str) -> bool {
    image.contains('@') || image.rsplit('/').next().is_some_and(|last| last.contains(':'))
}

fn placeholder_list() -> String {
    PLACEHOLDERS.iter().map(|p| format!("${{{p}}}")).collect::<Vec<_>>().join(", ")
}

/// The placeholder names a template uses, in order, or why the template is malformed.
/// ref:DEC-manifest-shape
pub fn placeholders(template: &str) -> Result<Vec<String>, String> {
    let mut names = Vec::new();
    let mut rest = template;
    while let Some(start) = rest.find("${") {
        let after = &rest[start + 2..];
        let end = after.find('}').ok_or_else(|| format!("unclosed placeholder in {template:?}"))?;
        names.push(after[..end].to_string());
        rest = &after[end + 1..];
    }
    Ok(names)
}

fn schema_problems(value: &serde_json::Value) -> Vec<Problem> {
    let schema: serde_json::Value = serde_json::from_str(SCHEMA).expect("the embedded manifest schema is JSON");
    let validator = jsonschema::validator_for(&schema).expect("the embedded manifest schema compiles");
    let mut seen = BTreeSet::new();
    validator
        .iter_errors(value)
        .map(|error| {
            let at = error
                .instance_path
                .to_string()
                .trim_start_matches('/')
                .split('/')
                .filter(|s| !s.is_empty())
                .map(|s| s.replace("~1", "/").replace("~0", "~"))
                .collect::<Vec<_>>()
                .join(".");
            problem(at, error.to_string())
        })
        .filter(|p| seen.insert(p.to_string()))
        .collect()
}
