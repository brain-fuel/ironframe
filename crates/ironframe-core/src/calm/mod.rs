//! CALM architectures as Ironframe's source of wiring: a CALM 1.2 architecture names the service
//! nodes and the edges between them, and Ironframe's decorators, attached by element unique-id,
//! give each node and edge its LawSpec contract identity and each node its binding per environment.
//! Resolving an environment gives one topology, from which the diagrams, the connection settings,
//! the OpenTofu root and the attestation are all generated. ref:DEC-calm-architecture

pub mod export;
pub mod model;
pub mod resolve;
pub mod run;

pub use model::{Architecture, CalmError, CalmProblem, Decorators};
pub use resolve::{Resolution, ResolvedTopology, resolve};

use std::path::{Path, PathBuf};

/// The decorators file Ironframe looks for beside an architecture `<name>.json` when none is
/// named: `<name>.decorators.json`, with a trailing `.calm` of the stem dropped first.
/// ref:DEC-calm-decorators
pub fn default_decorators(architecture: &Path) -> PathBuf {
    let stem = architecture.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let stem = stem.strip_suffix(".calm").unwrap_or(&stem).to_string();
    architecture.with_file_name(format!("{stem}.decorators.json"))
}

/// Reads an architecture and its decorators and resolves `environment`. Relative paths in the
/// bindings are read against the decorators' directory. ref:DEC-calm-resolution
pub fn load_and_resolve(
    architecture: &Path,
    decorators: Option<&Path>,
    environment: &str,
) -> Result<Resolution, CalmError> {
    let model = Architecture::load(architecture)?;
    let decorators_path = decorators.map_or_else(|| default_decorators(architecture), Path::to_path_buf);
    let decorations = Decorators::load(&decorators_path)?;
    let dir = decorators_path.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or(Path::new("."));
    let dir = std::fs::canonicalize(dir).unwrap_or_else(|_| dir.to_path_buf());
    resolve(&model, &decorations, environment, &dir).map_err(|mut error| {
        error.origin = Some(decorators_path.clone());
        error
    })
}
