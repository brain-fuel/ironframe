//! An environment resolved: each dependency's endpoint, the image to run for it if any, and the
//! settings the application reads, rendered from the manifest's templates. Everything downstream,
//! compose, OpenTofu, the configuration service, every sync target and the attestation, works from
//! this one resolution, so they cannot disagree about where a dependency is. ref:DEC-manifest-shape

use crate::manifest::{Binding, Manifest, ManifestError, Runtime, TWIN_CONFIG_VARIABLE};
use ironframe_attestation::StandIn;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Whether a dependency is bound to the real thing or a twin. ref:DEC-manifest-shape
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BindingKind {
    /// The real dependency.
    Real,
    /// A twin.
    Twin,
}

impl BindingKind {
    /// The manifest's word for the kind, which `${kind}` renders.
    pub fn as_str(self) -> &'static str {
        match self {
            BindingKind::Real => "real",
            BindingKind::Twin => "twin",
        }
    }
}

/// One dependency of a resolved environment. ref:DEC-manifest-shape
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedDependency {
    /// The dependency's name.
    pub name: String,
    /// Real or twin.
    pub kind: BindingKind,
    /// The endpoint the application is handed.
    pub endpoint: String,
    /// The fully qualified image to run, when the runtime runs one for this dependency.
    pub image: Option<String>,
    /// The container ports to publish or expose.
    pub ports: Vec<u16>,
    /// The container's environment, `TWIN_CONFIG` included for a twin.
    pub container_env: BTreeMap<String, String>,
    /// The stand-in's identity, for a twin.
    pub stand_in: Option<StandIn>,
    /// The credentials reference, passed on unread.
    pub credentials: Option<String>,
    /// The settings the application reads for this dependency.
    pub settings: BTreeMap<String, String>,
}

/// An environment with every dependency resolved. ref:DEC-manifest-shape
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedEnvironment {
    /// The project's name.
    pub project: String,
    /// The environment's name.
    pub environment: String,
    /// Where it runs.
    pub runtime: Runtime,
    /// Its dependencies, in name order.
    pub dependencies: Vec<ResolvedDependency>,
}

impl ResolvedEnvironment {
    /// Every setting of every dependency, which is what the application reads.
    pub fn settings(&self) -> BTreeMap<String, String> {
        self.dependencies.iter().flat_map(|d| d.settings.clone()).collect()
    }

    /// The name every container, compose project and cloud resource of the environment starts with.
    pub fn stack_name(&self) -> String {
        format!("ironframe-{}-{}", self.project, self.environment)
    }
}

/// Why an environment could not be resolved. ref:DEC-manifest-shape
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum ResolveError {
    /// The manifest has no such environment.
    #[error(transparent)]
    Manifest(#[from] ManifestError),
    /// A twin in a cloud environment has no endpoint until it is deployed.
    #[error(
        "the endpoint of {dependency:?} in environment {environment:?} is known once the twin is deployed; run `ironframe up {environment}` first, or pin it with twin.endpoint"
    )]
    NotDeployed {
        /// The environment.
        environment: String,
        /// The dependency.
        dependency: String,
    },
    /// A template needs a part of the endpoint it does not have, such as a port.
    #[error("setting {key} of {dependency:?} uses ${{{placeholder}}}, but endpoint {endpoint:?} has none")]
    MissingPart {
        /// The dependency.
        dependency: String,
        /// The setting.
        key: String,
        /// The placeholder.
        placeholder: String,
        /// The endpoint it was rendered from.
        endpoint: String,
    },
}

/// Resolves environment `name` of a checked manifest. `deployed` holds the endpoints a cloud
/// deployment reported, by dependency, and is empty for podman. A twin's endpoint is the one it
/// pins, else the deployed one, else on podman `localhost` and its first port, since published
/// ports keep their numbers. ref:DEC-manifest-shape ref:DEC-podman-compose
pub fn resolve(
    manifest: &Manifest,
    name: &str,
    deployed: &BTreeMap<String, String>,
) -> Result<ResolvedEnvironment, ResolveError> {
    let environment = manifest.environment(name)?;
    let mut dependencies = Vec::new();
    for (dependency, binding) in &environment.dependencies {
        let declaration = &manifest.dependencies[dependency];
        let resolved = match binding {
            Binding::Real(real) => ResolvedDependency {
                name: dependency.clone(),
                kind: BindingKind::Real,
                endpoint: real.endpoint.clone(),
                image: real.image.as_deref().map(qualify_image),
                ports: real.ports.clone(),
                container_env: real.env.clone(),
                stand_in: None,
                credentials: real.credentials.clone(),
                settings: BTreeMap::new(),
            },
            Binding::Twin(twin) => {
                let endpoint = match (&twin.endpoint, deployed.get(dependency)) {
                    (Some(pinned), _) => pinned.clone(),
                    (None, Some(reported)) => reported.clone(),
                    (None, None) if environment.runtime == Runtime::Podman => format!("localhost:{}", twin.ports[0]),
                    (None, None) => {
                        return Err(ResolveError::NotDeployed {
                            environment: name.to_string(),
                            dependency: dependency.clone(),
                        });
                    }
                };
                let mut container_env = twin.env.clone();
                let config = twin.config.clone().unwrap_or_else(|| serde_json::json!({}));
                container_env.insert(TWIN_CONFIG_VARIABLE.to_string(), config.to_string());
                ResolvedDependency {
                    name: dependency.clone(),
                    kind: BindingKind::Twin,
                    endpoint,
                    image: Some(qualify_image(&twin.image_ref())),
                    ports: twin.ports.clone(),
                    container_env,
                    stand_in: Some(StandIn {
                        product: twin.image.clone(),
                        version: twin.version.clone(),
                        conformance: twin.conformance.clone(),
                    }),
                    credentials: twin.credentials.clone(),
                    settings: BTreeMap::new(),
                }
            }
        };
        let mut resolved = resolved;
        for (key, template) in &declaration.settings {
            let value = render(template, &resolved).map_err(|placeholder| ResolveError::MissingPart {
                dependency: dependency.clone(),
                key: key.clone(),
                placeholder,
                endpoint: resolved.endpoint.clone(),
            })?;
            resolved.settings.insert(key.clone(), value);
        }
        dependencies.push(resolved);
    }
    Ok(ResolvedEnvironment {
        project: manifest.project.clone(),
        environment: name.to_string(),
        runtime: environment.runtime,
        dependencies,
    })
}

fn render(template: &str, dependency: &ResolvedDependency) -> Result<String, String> {
    let (host, port) = split_endpoint(&dependency.endpoint);
    let mut out = String::new();
    let mut rest = template;
    while let Some(start) = rest.find("${") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 2..];
        let end = after.find('}').expect("templates were checked when the manifest was read");
        let name = &after[..end];
        let value = match name {
            "endpoint" => dependency.endpoint.clone(),
            "host" => host.clone(),
            "port" => port.map(|p| p.to_string()).ok_or_else(|| name.to_string())?,
            "credentials" => dependency.credentials.clone().ok_or_else(|| name.to_string())?,
            "kind" => dependency.kind.as_str().to_string(),
            "name" => dependency.name.clone(),
            other => return Err(other.to_string()),
        };
        out.push_str(&value);
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

/// The host and port of an endpoint, `host:port` or a URL; a URL without a port takes its scheme's.
/// ref:DEC-manifest-shape
pub fn split_endpoint(endpoint: &str) -> (String, Option<u16>) {
    let (scheme, rest) = match endpoint.split_once("://") {
        Some((scheme, rest)) => (Some(scheme), rest),
        None => (None, endpoint),
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or(rest);
    let authority = authority.rsplit('@').next().unwrap_or(authority);
    match authority.rsplit_once(':') {
        Some((host, port)) if port.parse::<u16>().is_ok() => (host.to_string(), port.parse().ok()),
        _ => {
            let default = match scheme {
                Some("https") => Some(443),
                Some("http") => Some(80),
                _ => None,
            };
            (authority.to_string(), default)
        }
    }
}

/// An image reference with its registry spelled out. A short name is a Docker Hub name, as Docker
/// reads it, so podman never has to ask which registry is meant. ref:DEC-podman-compose
pub fn qualify_image(image: &str) -> String {
    let first = image.split('/').next().unwrap_or(image);
    let has_registry = image.contains('/') && (first.contains('.') || first.contains(':') || first == "localhost");
    if has_registry {
        image.to_string()
    } else if image.contains('/') {
        format!("docker.io/{image}")
    } else {
        format!("docker.io/library/{image}")
    }
}

/// The settings of every environment of a project, the document the configuration service serves.
/// ref:DEC-config-service
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct SettingsDocument {
    /// The project's name.
    pub project: String,
    /// Environment name to its settings.
    pub environments: BTreeMap<String, BTreeMap<String, String>>,
}

impl SettingsDocument {
    /// Puts one resolved environment's settings into the document, replacing what it had.
    pub fn insert(&mut self, environment: &ResolvedEnvironment) {
        self.project = environment.project.clone();
        self.environments.insert(environment.environment.clone(), environment.settings());
    }
}

/// Settings as a dotenv file: a header comment, then `KEY=value` lines in name order, quoting a
/// value only when it holds something a dotenv reader would take apart. ref:DEC-config-sync
pub fn render_dotenv(header: &str, settings: &BTreeMap<String, String>) -> String {
    let mut out = String::new();
    for line in header.lines() {
        out.push_str("# ");
        out.push_str(line);
        out.push('\n');
    }
    for (key, value) in settings {
        out.push_str(key);
        out.push('=');
        if value.chars().all(|c| c.is_ascii_alphanumeric() || "_./:,@+-".contains(c)) {
            out.push_str(value);
        } else {
            out.push('"');
            for c in value.chars() {
                match c {
                    '"' => out.push_str("\\\""),
                    '\\' => out.push_str("\\\\"),
                    '\n' => out.push_str("\\n"),
                    '$' => out.push_str("\\$"),
                    c => out.push(c),
                }
            }
            out.push('"');
        }
        out.push('\n');
    }
    out
}

/// Reads a dotenv file as [`render_dotenv`] writes it: comments and blank lines skipped, quoted
/// values unescaped. ref:DEC-config-sync
pub fn parse_dotenv(text: &str) -> BTreeMap<String, String> {
    let mut settings = BTreeMap::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, raw)) = line.split_once('=') else { continue };
        let value = if raw.len() >= 2 && raw.starts_with('"') && raw.ends_with('"') {
            let mut value = String::new();
            let mut chars = raw[1..raw.len() - 1].chars();
            while let Some(c) = chars.next() {
                if c == '\\' {
                    match chars.next() {
                        Some('n') => value.push('\n'),
                        Some(other) => value.push(other),
                        None => value.push('\\'),
                    }
                } else {
                    value.push(c);
                }
            }
            value
        } else {
            raw.to_string()
        };
        settings.insert(key.trim().to_string(), value);
    }
    settings
}
