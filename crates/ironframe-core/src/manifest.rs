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

    /// The module directory under `modules/` that runs a twin on this runtime, for a twin serving
    /// `protocol`; none for podman. Cloud Run serves only HTTP, so a TCP twin on GCP runs on a
    /// Compute Engine instance. ref:DEC-cloud-run-http-only ref:DEC-gce-for-tcp-twins
    pub fn module(self, protocol: Protocol) -> Option<&'static str> {
        match (self, protocol) {
            (Runtime::Podman, _) => None,
            (Runtime::Aws, _) => Some("aws-ecs-fargate"),
            (Runtime::Gcp, Protocol::Http) => Some("gcp-cloud-run"),
            (Runtime::Gcp, Protocol::Tcp) => Some("gcp-compute-engine"),
            (Runtime::Azure, _) => Some("azure-container-apps"),
        }
    }

    /// The inputs the provider takes rather than the modules.
    pub fn provider_inputs(self) -> &'static [&'static str] {
        match self {
            Runtime::Podman => &[],
            Runtime::Aws => &["region"],
            Runtime::Gcp => &["project", "region"],
            Runtime::Azure => &["subscription_id"],
        }
    }

    /// The inputs any of the runtime's modules take, beside the name, image, ports and environment
    /// Ironframe passes itself.
    pub fn module_inputs(self) -> Vec<&'static str> {
        let mut all: Vec<&'static str> = Vec::new();
        for protocol in [Protocol::Tcp, Protocol::Http] {
            if let Some(module) = self.module(protocol) {
                for input in inputs_of_module(module) {
                    if !all.contains(input) {
                        all.push(input);
                    }
                }
            }
        }
        all
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

/// The inputs one module under `modules/` takes from `cloud`, beside the name, image, ports and
/// environment Ironframe passes itself. ref:DEC-opentofu
pub fn inputs_of_module(module: &str) -> &'static [&'static str] {
    match module {
        "aws-ecs-fargate" => {
            &["vpc_id", "subnet_ids", "cpu", "memory", "assign_public_ip", "allowed_cidr_blocks", "internal"]
        }
        "gcp-cloud-run" => &["project", "region", "cpu", "memory", "public"],
        "gcp-compute-engine" => {
            &["project", "region", "zone", "machine_type", "network", "subnetwork", "allowed_cidr_blocks", "public"]
        }
        "azure-container-apps" => {
            &["location", "resource_group_name", "cpu", "memory", "infrastructure_subnet_id", "transport", "external"]
        }
        _ => &[],
    }
}

/// What a twin serves on its first port, which decides where a cloud can run it: Cloud Run serves
/// only HTTP. ref:DEC-gce-for-tcp-twins
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Protocol {
    /// HTTP, such as an API server twin.
    #[default]
    Http,
    /// A protocol of its own over TCP, such as Kafka's.
    Tcp,
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
#[allow(clippy::large_enum_variant)] // a manifest holds a handful of bindings; boxing buys nothing
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
/// its release declares, the ports it serves, and how it is set up when it starts: its seed, the
/// contract it serves, a state to force and the faults to raise, through its control plane.
/// Ironframe runs it and records it; what the twin does with its configuration is its own
/// business. ref:DEC-manifest-shape ref:DEC-three-planes ref:DEC-twin-control-plane
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
    /// The conformance level the twin's release declares, or where to read it, recorded in the
    /// attestation.
    pub conformance: Conformance,
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
    /// The seed of the twin's random choices, handed over as `seed` in `TWIN_CONFIG` and checked
    /// through the control plane once the twin answers.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seed: Option<u64>,
    /// The contract a twin that serves several should serve, handed over as `contract` in
    /// `TWIN_CONFIG`, such as `petstore` for the HTTP twin.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contract: Option<String>,
    /// A state to force once the twin answers: a JSON file relative to the manifest, or the state
    /// itself.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<serde_json::Value>,
    /// Faults to raise once the twin answers, in order.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub faults: Vec<Fault>,
    /// Where the twin's control plane is reached.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub admin: Option<Admin>,
    /// What the twin serves on its first port, which decides where a cloud runs it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub protocol: Option<Protocol>,
    /// An environment variable the twin reads the address it should tell clients from; Ironframe
    /// sets it to the endpoint's `host:port`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub advertise_variable: Option<String>,
    /// The conformance report named by `conformance.report`, read when the manifest was loaded.
    #[serde(skip)]
    pub report: Option<ConformanceReport>,
}

impl Twin {
    /// The image reference with the version as its tag.
    pub fn image_ref(&self) -> String {
        format!("{}:{}", self.image, self.version)
    }

    /// The protocol, HTTP when the manifest names none.
    pub fn protocol(&self) -> Protocol {
        self.protocol.unwrap_or_default()
    }

    /// The JSON handed to the twin in `TWIN_CONFIG`: `config`, with `seed` and `contract` added.
    /// ref:DEC-twin-control-plane
    pub fn twin_config(&self) -> serde_json::Value {
        let mut config = match &self.config {
            Some(serde_json::Value::Object(map)) => map.clone(),
            _ => serde_json::Map::new(),
        };
        if let Some(seed) = self.seed {
            config.insert("seed".into(), seed.into());
        }
        if let Some(contract) = &self.contract {
            config.insert("contract".into(), contract.clone().into());
        }
        serde_json::Value::Object(config)
    }

    /// The conformance level to record: the report's when one was read, else the declared one,
    /// else `unrated`. A level read from an image label replaces it when `up` reads the label.
    /// ref:DEC-conformance-from-report
    pub fn conformance_level(&self) -> String {
        if let Some(report) = &self.report {
            return report.level.clone();
        }
        self.conformance.declared().map(str::to_string).unwrap_or_else(|| UNRATED.to_string())
    }
}

/// The level recorded for a twin whose level nothing declares. ref:DEC-conformance-from-report
pub const UNRATED: &str = "unrated";

/// The control-plane port of a LawTwin twin inside its container, the default for
/// `admin.container_port`. ref:DEC-twin-control-plane
pub const DEFAULT_ADMIN_CONTAINER_PORT: u16 = 9644;

/// A twin's conformance level: the level its release declares, as a word, or where to read it, a
/// conformance report beside the manifest or a label of the image, with an optional declared level
/// that must agree. ref:DEC-conformance-from-report
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Conformance {
    /// The declared level, such as `answers`.
    Level(String),
    /// Where the level is read, and optionally the level declared.
    Sourced(ConformanceSource),
}

/// Where a twin's conformance level is read. ref:DEC-conformance-from-report
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConformanceSource {
    /// The level declared, which must match the report's or the label's.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub level: Option<String>,
    /// The twin release's conformance report, a JSON file relative to the manifest.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub report: Option<PathBuf>,
    /// An image label holding the level, read when `up` has the image.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_label: Option<String>,
}

impl Conformance {
    /// The level the manifest declares, if it declares one.
    pub fn declared(&self) -> Option<&str> {
        match self {
            Conformance::Level(level) => Some(level),
            Conformance::Sourced(source) => source.level.as_deref(),
        }
    }

    /// The report to read, if any.
    pub fn report(&self) -> Option<&Path> {
        match self {
            Conformance::Level(_) => None,
            Conformance::Sourced(source) => source.report.as_deref(),
        }
    }

    /// The image label to read, if any.
    pub fn image_label(&self) -> Option<&str> {
        match self {
            Conformance::Level(_) => None,
            Conformance::Sourced(source) => source.image_label.as_deref(),
        }
    }
}

/// What Ironframe reads from a conformance report: the level, by name and, when it has one, by
/// number, and what the report is about. Two shapes are read: a level that is an object with
/// `number` and `name`, as LawTwin's Kafka reports give it, and a level that is a word, as
/// `lawtwin conform http` writes it. ref:DEC-conformance-from-report
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ConformanceReport {
    /// The level's name, such as `answers` or `conformant`.
    pub level: String,
    /// The level's number, when the report gives one.
    pub number: Option<u64>,
    /// The twin release the report is for, when it says.
    pub release: Option<String>,
    /// The twin the report is for, when it says, such as `kafka`.
    pub twin: Option<String>,
    /// The contract package the report checked, when it says, such as `lawtwin.petstore`.
    pub contract: Option<String>,
}

impl ConformanceReport {
    /// Reads a report from its JSON. ref:DEC-conformance-from-report
    pub fn parse(text: &str) -> Result<ConformanceReport, String> {
        let value: serde_json::Value = serde_json::from_str(text).map_err(|e| format!("not JSON: {e}"))?;
        let (level, number) = match &value["level"] {
            serde_json::Value::String(name) => (name.clone(), None),
            serde_json::Value::Object(level) => {
                let name = level.get("name").and_then(|n| n.as_str()).ok_or("level has no name")?;
                (name.to_string(), level.get("number").and_then(serde_json::Value::as_u64))
            }
            _ => return Err("the report has no level".into()),
        };
        if level.trim().is_empty() {
            return Err("the report's level is empty".into());
        }
        let text_of = |v: &serde_json::Value| v.as_str().map(str::to_string);
        Ok(ConformanceReport {
            level,
            number,
            release: text_of(&value["release"]),
            twin: text_of(&value["twin"]),
            contract: text_of(&value["contract"]).or_else(|| text_of(&value["contract"]["package"])),
        })
    }

    /// Whether a declared level names this report's level: its name, ignoring case, its number,
    /// or both as `<number>-<name>`. ref:DEC-conformance-from-report
    pub fn matches(&self, declared: &str) -> bool {
        let declared = declared.trim().to_ascii_lowercase();
        let name = self.level.to_ascii_lowercase();
        declared == name || self.number.is_some_and(|n| declared == n.to_string() || declared == format!("{n}-{name}"))
    }

    /// How the report names its level, for a message.
    pub fn describe(&self) -> String {
        match self.number {
            Some(number) => format!("level {number} ({})", self.level),
            None => format!("level {}", self.level),
        }
    }
}

/// A fault to raise when the twin starts: a fault its maker declares, by name, and its parameters.
/// ref:DEC-twin-control-plane
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Fault {
    /// The fault's name, such as `latency`.
    pub name: String,
    /// Its parameters, by name; each a string or an integer.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub params: BTreeMap<String, serde_json::Value>,
}

/// Where a twin's control plane is reached: on podman a port published on this machine, in a cloud
/// a URL the operator gives. ref:DEC-twin-control-plane
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Admin {
    /// The port published on this machine; `container_port` when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
    /// The control plane's port inside the container.
    #[serde(default = "default_admin_container_port")]
    pub container_port: u16,
    /// The control plane's URL, which wins over the port.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
}

fn default_admin_container_port() -> u16 {
    DEFAULT_ADMIN_CONTAINER_PORT
}

impl Admin {
    /// The port published on this machine.
    pub fn host_port(&self) -> u16 {
        self.port.unwrap_or(self.container_port)
    }

    /// The control plane's URL in an environment on `runtime`, if it has one there.
    pub fn url_on(&self, runtime: Runtime) -> Option<String> {
        match (&self.url, runtime) {
            (Some(url), _) => Some(url.trim_end_matches('/').to_string()),
            (None, Runtime::Podman) => Some(format!("http://127.0.0.1:{}", self.host_port())),
            (None, _) => None,
        }
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
        let mut manifest = Manifest::parse(&text).map_err(|mut error| {
            error.origin = Some(path.to_path_buf());
            error
        })?;
        let directory = path.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or(Path::new("."));
        let problems = manifest.read_reports(directory);
        if problems.is_empty() {
            Ok(manifest)
        } else {
            Err(ManifestError { origin: Some(path.to_path_buf()), problems })
        }
    }

    /// Reads the conformance report of every twin that names one, relative to `directory`, and
    /// checks it against the twin: the declared level must be the report's, and a report that says
    /// which release or twin it is for must be for this one. Returns every problem found.
    /// ref:DEC-conformance-from-report ref:REQ-conformance-matches-report
    pub fn read_reports(&mut self, directory: &Path) -> Vec<Problem> {
        let mut found = Vec::new();
        for (name, environment) in &mut self.environments {
            for (dependency, binding) in &mut environment.dependencies {
                let Binding::Twin(twin) = binding else { continue };
                let Some(relative) = twin.conformance.report() else { continue };
                let at = format!("environments.{name}.dependencies.{dependency}.twin.conformance.report");
                let path = directory.join(relative);
                let report = match std::fs::read_to_string(&path) {
                    Ok(text) => ConformanceReport::parse(&text),
                    Err(error) => Err(format!("cannot read it: {error}")),
                };
                let report = match report {
                    Ok(report) => report,
                    Err(reason) => {
                        found.push(problem(&at, format!("{}: {reason}", relative.display())));
                        continue;
                    }
                };
                found.extend(report_problems(&at, twin, &report));
                twin.report = Some(report);
            }
        }
        found
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
                            if !all.contains(&module_input) {
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
                    twin_problems(&at, twin, runtime, found);
                    credentials_problems(&at, twin.credentials.as_deref(), uses_credentials, found);
                    let mut ports = twin.ports.clone();
                    if runtime == Runtime::Podman
                        && let Some(admin) = &twin.admin
                        && admin.url.is_none()
                    {
                        ports.push(admin.host_port());
                    }
                    (ports, true)
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

/// How a twin disagrees with its conformance report. ref:REQ-conformance-matches-report
pub fn report_problems(at: &str, twin: &Twin, report: &ConformanceReport) -> Vec<Problem> {
    let mut found = Vec::new();
    if let Some(declared) = twin.conformance.declared()
        && !report.matches(declared)
    {
        found.push(problem(
            at,
            format!("the twin declares conformance {declared:?}, but its report gives {}", report.describe()),
        ));
    }
    if let Some(release) = &report.release
        && release != &twin.version
    {
        found.push(problem(
            at,
            format!("the report is for release {release}, but the twin is version {}", twin.version),
        ));
    }
    if let Some(name) = &report.twin {
        let image = twin.image.rsplit('/').next().unwrap_or(&twin.image);
        if image != name {
            found.push(problem(at, format!("the report is for the {name} twin, but the image is {}", twin.image)));
        }
    }
    if let (Some(contract), Some(package)) = (&twin.contract, &report.contract)
        && package != contract
        && !package.ends_with(&format!(".{contract}"))
    {
        found.push(problem(at, format!("the report checked contract {package}, but the twin serves {contract}")));
    }
    found
}

fn twin_problems(at: &str, twin: &Twin, runtime: Runtime, found: &mut Vec<Problem>) {
    match &twin.conformance {
        Conformance::Level(level) if level.trim().is_empty() => {
            found.push(problem(format!("{at}.conformance"), "declare the release's conformance level"))
        }
        Conformance::Level(_) => {}
        Conformance::Sourced(source) => {
            if source.level.is_none() && source.report.is_none() && source.image_label.is_none() {
                found.push(problem(
                    format!("{at}.conformance"),
                    "give the level, the report to read it from, or the image label that holds it",
                ));
            }
            if source.level.as_deref().is_some_and(|l| l.trim().is_empty()) {
                found.push(problem(format!("{at}.conformance.level"), "the level must not be empty"));
            }
            if source.image_label.as_deref().is_some_and(|l| l.trim().is_empty()) {
                found.push(problem(format!("{at}.conformance.image_label"), "the label must not be empty"));
            }
        }
    }
    if twin.ports.is_empty() {
        found.push(problem(format!("{at}.ports"), "a twin serves at least one port"));
    }
    if runtime == Runtime::Gcp && twin.protocol() == Protocol::Http && twin.ports.len() > 1 {
        found.push(problem(
            format!("{at}.ports"),
            "Cloud Run serves one port per service; a twin serving more is `protocol: tcp`, run on Compute Engine",
        ));
    }
    if let Some(config) = &twin.config {
        if !config.is_object() {
            found.push(problem(format!("{at}.config"), "the twin's config is a mapping"));
        }
        for (key, given) in
            [("seed", twin.seed.map(serde_json::Value::from)), ("contract", twin.contract.clone().map(Into::into))]
        {
            if let (Some(given), Some(in_config)) = (given, config.get(key))
                && &given != in_config
            {
                found.push(problem(
                    format!("{at}.config.{key}"),
                    format!("config.{key} is {in_config} but the twin's {key} is {given}; give it once"),
                ));
            }
        }
    }
    if twin.env.contains_key(TWIN_CONFIG_VARIABLE) {
        found.push(problem(
            format!("{at}.env.{TWIN_CONFIG_VARIABLE}"),
            "TWIN_CONFIG is written from `config`; set the configuration there",
        ));
    }
    if twin.contract.as_deref().is_some_and(|c| c.trim().is_empty()) {
        found.push(problem(format!("{at}.contract"), "the contract must not be empty"));
    }
    let admin_url = twin.admin.as_ref().and_then(|a| a.url_on(runtime));
    if let Some(admin) = &twin.admin {
        if admin.container_port == 0 || admin.port == Some(0) {
            found.push(problem(format!("{at}.admin"), "a port is between 1 and 65535"));
        }
        if runtime.is_cloud() && admin.url.is_none() {
            found.push(problem(
                format!("{at}.admin.url"),
                "a cloud twin's control plane is not published; give the URL it is reached at",
            ));
        }
        if let Some(url) = &admin.url
            && !(url.starts_with("http://") || url.starts_with("https://"))
        {
            found.push(problem(format!("{at}.admin.url"), "the control plane's URL is http:// or https://"));
        }
        if runtime == Runtime::Podman && admin.url.is_none() && twin.ports.contains(&admin.container_port) {
            found.push(problem(
                format!("{at}.ports"),
                format!("port {} is the control plane's; it is published through `admin`", admin.container_port),
            ));
        }
    }
    let needs_admin = |what: &str, found: &mut Vec<Problem>| {
        if admin_url.is_none() {
            found.push(problem(
                format!("{at}.{what}"),
                "applied through the twin's control plane, so the twin needs `admin`",
            ));
        }
    };
    if twin.state.is_some() {
        needs_admin("state", found);
    }
    if let Some(state) = &twin.state
        && !(state.is_object() || state.as_str().is_some_and(|p| !p.trim().is_empty()))
    {
        found.push(problem(format!("{at}.state"), "a state is a mapping, or the path of a JSON file"));
    }
    if !twin.faults.is_empty() {
        needs_admin("faults", found);
    }
    for (index, fault) in twin.faults.iter().enumerate() {
        if fault.name.trim().is_empty() {
            found.push(problem(format!("{at}.faults[{index}].name"), "the fault's name must not be empty"));
        }
        for (name, value) in &fault.params {
            if !(value.is_string() || value.is_i64() || value.is_u64()) {
                found.push(problem(
                    format!("{at}.faults[{index}].params.{name}"),
                    "a fault's parameter is a string or a whole number",
                ));
            }
        }
    }
    if let Some(variable) = &twin.advertise_variable {
        if !is_setting_key(variable) {
            found.push(problem(format!("{at}.advertise_variable"), "an environment variable name"));
        }
        if twin.env.contains_key(variable) {
            found.push(problem(
                format!("{at}.env.{variable}"),
                "this variable is set from the endpoint through `advertise_variable`",
            ));
        }
        let supported = runtime == Runtime::Podman || (runtime == Runtime::Gcp && twin.protocol() == Protocol::Tcp);
        if !supported {
            found.push(problem(
                format!("{at}.advertise_variable"),
                format!(
                    "the address a twin advertises is set on podman and on GCP Compute Engine (`protocol: tcp`); on {runtime} pin it in `config` or `env`"
                ),
            ));
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
