//! Running the external tools Ironframe drives, podman and OpenTofu, through one trait, so the
//! decisions taken on their answers are tested with recorded answers and no tool installed.
//! ref:DEC-podman-compose ref:DEC-opentofu

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// What a finished command reported. ref:DEC-podman-compose
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CommandOutput {
    /// Whether it exited with status zero.
    pub success: bool,
    /// Its standard output, empty when it was streamed to the terminal.
    pub stdout: String,
    /// Its standard error, empty when it was streamed to the terminal.
    pub stderr: String,
}

/// Runs a program with arguments. `stream` sends the program's output to the terminal instead of
/// capturing it, for long commands a person watches, such as `tofu apply`. ref:DEC-podman-compose
pub trait CommandRunner {
    /// Runs `program` with `args`, capturing or streaming its output.
    fn run(&self, program: &Path, args: &[String], stream: bool) -> std::io::Result<CommandOutput>;
}

/// The runner that starts real processes. ref:DEC-podman-compose
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemRunner;

impl CommandRunner for SystemRunner {
    fn run(&self, program: &Path, args: &[String], stream: bool) -> std::io::Result<CommandOutput> {
        let mut command = Command::new(program);
        command.args(args).stdin(Stdio::null());
        if stream {
            let status = command.status()?;
            return Ok(CommandOutput { success: status.success(), ..CommandOutput::default() });
        }
        let output = command.output()?;
        Ok(CommandOutput {
            success: output.status.success(),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        })
    }
}

/// Finds a tool: the path in `override_variable` if set, else the first of `names` on `PATH`, else
/// the first of `fallbacks` that exists. ref:DEC-podman-compose
pub fn locate(override_variable: &str, names: &[&str], fallbacks: &[&str]) -> Option<PathBuf> {
    if let Some(path) = std::env::var_os(override_variable).filter(|p| !p.is_empty()) {
        return Some(PathBuf::from(path));
    }
    let path = std::env::var_os("PATH").unwrap_or_default();
    for name in names {
        for directory in std::env::split_paths(&path) {
            let candidate = directory.join(name);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    fallbacks.iter().map(PathBuf::from).find(|p| p.is_file())
}

/// The last non-empty line of a tool's error output, which is where podman and OpenTofu put the
/// reason. ref:DEC-podman-compose
pub fn last_line(text: &str) -> String {
    text.lines().rev().map(str::trim).find(|l| !l.is_empty()).unwrap_or("no output").to_string()
}
