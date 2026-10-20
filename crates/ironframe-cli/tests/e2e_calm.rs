//! End to end, the CALM chain with podman, LawTwin's images, the real products and LawSpec 0.26:
//! the calm-shop architecture is validated (by Ironframe, and by the CALM CLI when it is installed)
//! and exported without deploying anything; then in each of the twin, real and mixed environments
//! Ironframe brings the dependencies up, the shop's unchanged LawSpec laws run against them under
//! `ironframe run`, the audit runs as a managed application over the shared Kafka, the service runs
//! as an external application reading its synced .env, and LawSpec reads the completed attestation
//! and reports which obligations ran against real providers and which against fixtures. In the
//! environments with twins, faults, resets and deterministic replay are driven through the twins'
//! control planes. Unresolved and incompatible bindings are refused by name. It needs podman with a
//! compose provider, Go, npm, and the images `lawtwin/kafka:0.1.0`, `lawtwin/http:0.1.0`,
//! `apache/kafka:4.1.0` and `lawtwin/petstore3-native:latest`, so it is ignored by `cargo test`
//! and run by `make e2e-calm`. ref:REQ-calm-end-to-end

use ironframe_attestation::{Attestation, ExecutionStatus, Kind};
use serde_json::Value;
use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

/// The repository's root.
fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").canonicalize().unwrap()
}

/// Copies a directory's files, skipping generated and installed ones.
fn copy_tree(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let name = entry.file_name().to_string_lossy().into_owned();
        if [".ironframe", ".lawspec", "node_modules", "lawspec", ".env", "shop-bin", "shop-linux"]
            .contains(&name.as_str())
            || name.starts_with("lawspec_")
        {
            continue;
        }
        if entry.file_type().unwrap().is_dir() {
            copy_tree(&entry.path(), &to.join(&name));
        } else {
            std::fs::copy(entry.path(), to.join(&name)).unwrap();
        }
    }
}

/// A copy of the calm-shop example in a fresh directory, so a run leaves nothing in the repository.
fn copy_example() -> tempfile::TempDir {
    let directory = tempfile::tempdir().unwrap();
    copy_tree(&root().join("examples/calm-shop"), directory.path());
    directory
}

/// Runs a program, echoing what it printed.
fn exec(program: &str, args: &[&str], dir: &Path, env: &[(&str, &str)]) -> Output {
    let output = Command::new(program).args(args).current_dir(dir).envs(env.iter().copied()).output().unwrap();
    eprintln!(
        "$ {program} {}\n{}{}",
        args.join(" "),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    output
}

/// Runs ironframe on the example's architecture.
fn ironframe(dir: &Path, args: &[&str]) -> Output {
    let mut all = vec!["-a", "shop.calm.json"];
    all.extend_from_slice(args);
    exec(env!("CARGO_BIN_EXE_ironframe"), &all, &dir.join("architecture"), &[])
}

/// Runs ironframe and asserts it succeeded, returning what it printed.
fn succeeds(dir: &Path, args: &[&str]) -> String {
    let output = ironframe(dir, args);
    assert!(output.status.success(), "ironframe {} failed", args.join(" "));
    String::from_utf8(output.stdout).unwrap()
}

/// The path ironframe printed after `attestation ` on standard error.
fn attestation_path(output: &Output) -> PathBuf {
    let text = String::from_utf8_lossy(&output.stderr);
    let line = text.lines().rev().find(|l| l.contains("; attestation ")).expect("ironframe names the attestation");
    PathBuf::from(line.rsplit_once("; attestation ").unwrap().1.trim())
}

/// Takes an environment down when dropped, so a failed assertion leaves no container running.
struct Up<'a>(&'a Path, &'a str);

impl Drop for Up<'_> {
    fn drop(&mut self) {
        ironframe(self.0, &["down", self.1]);
    }
}

/// The digest of the shop's laws, which no binding may change.
fn laws_digest(dir: &Path) -> String {
    let text = std::fs::read(dir.join("app/spec/shop.lawspec")).unwrap();
    format!("{:x}", text.iter().fold(0u64, |h, b| h.wrapping_mul(31).wrapping_add(u64::from(*b))))
}

/// The application settings ironframe exports for an application, as a map.
fn exported_settings(dir: &Path, environment: &str, app: &str) -> BTreeMap<String, String> {
    serde_json::from_str(&succeeds(dir, &["export", "settings", "-e", environment, "--app", app, "--format", "json"]))
        .unwrap()
}

/// What each ability is bound to in each environment: stand-in or real.
fn expected_kinds(environment: &str) -> [(&'static str, Kind); 2] {
    let (log, registry) = match environment {
        "twin" => (Kind::StandIn, Kind::StandIn),
        "real" => (Kind::Real, Kind::Real),
        _ => (Kind::Real, Kind::StandIn),
    };
    [("shop.adoptions::ability::Adoptions", log), ("shop.adoptions::ability::Pets", registry)]
}

/// Runs the shop's laws under `ironframe run` and checks the completed attestation and what
/// LawSpec makes of it.
fn run_laws(dir: &Path, environment: &str) -> Attestation {
    let output = ironframe(
        dir,
        &[
            "run",
            "-e",
            environment,
            "--app",
            "adoptions-service",
            "--dir",
            "../app",
            "--",
            "sh",
            "-c",
            "npx --no-install lawspec test --attestation \"$IRONFRAME_ATTESTATION\" --seed 7 --fresh",
        ],
    );
    assert!(output.status.success(), "the shop's laws failed in environment {environment}");
    let path = attestation_path(&output);
    let attestation = Attestation::from_json(&std::fs::read_to_string(&path).unwrap()).unwrap();
    let execution = attestation.execution.as_ref().unwrap();
    assert_eq!(execution.status, ExecutionStatus::Completed);
    assert_eq!(execution.exit_code, Some(0));
    let architecture = attestation.architecture.as_ref().unwrap();
    assert!(architecture.digest.starts_with("sha256:") && architecture.topology_digest.is_some());
    assert_eq!(attestation.application.as_ref().unwrap().node, "adoptions-service");
    for (ability, kind) in expected_kinds(environment) {
        let record = attestation.dependencies.iter().find(|d| d.name == ability).unwrap();
        assert_eq!(record.kind, kind, "{ability} in {environment}");
        let implementation = record.implementation.as_ref().unwrap();
        assert_eq!(implementation.kind, if kind == Kind::Real { "real-provider" } else { "fixture" });
        let completed = record.completed.as_ref().unwrap();
        assert!(completed.reached);
        assert_eq!(completed.history_digest.is_some(), kind == Kind::StandIn);
    }
    // LawSpec 0.26 reads the completed attestation: the laws stay property tested against the
    // inputs they ran with, and each names the run and what each ability was bound to.
    let evidence = exec(
        "npx",
        &["--no-install", "lawspec", "evidence", "--attestation", path.to_str().unwrap(), "--json"],
        &dir.join("app"),
        &[],
    );
    assert!(evidence.status.success());
    let obligations: Vec<Value> = serde_json::from_slice(&evidence.stdout).unwrap();
    let native: Vec<&Value> = obligations
        .iter()
        .filter(|o| o["stage"] == "law" && o["plannedAgainst"].as_array().is_some_and(|a| !a.is_empty()))
        .collect();
    assert_eq!(native.len(), 4, "every law relies on a native handler");
    for obligation in native {
        assert_eq!(obligation["status"], "property-tested");
        assert_eq!(obligation["plannedEnvironmentRun"]["id"], attestation.run.id.as_str());
        for dependency in obligation["plannedAgainst"].as_array().unwrap() {
            let (_, kind) = expected_kinds(environment)
                .into_iter()
                .find(|(ability, _)| dependency["dependency"] == *ability)
                .unwrap();
            assert_eq!(dependency["kind"], if kind == Kind::Real { "real" } else { "stand-in" });
        }
    }
    // Without the file, LawSpec links each law to the run it last passed in.
    let linked = exec("npx", &["--no-install", "lawspec", "evidence", "--json"], &dir.join("app"), &[]);
    let obligations: Vec<Value> = serde_json::from_slice(&linked.stdout).unwrap();
    assert!(
        obligations
            .iter()
            .filter(|o| o["stage"] == "law" && o["against"].is_array())
            .all(|o| { o["environmentRun"]["id"] == attestation.run.id.as_str() })
    );
    attestation
}

/// Waits until an HTTP API answers a request for a pet with any status line.
fn wait_for_http(base: &str) {
    let (host, port) = ironframe_core::settings::split_endpoint(base);
    let path = format!("{}/pet/1", base.splitn(4, '/').nth(3).map(|p| format!("/{p}")).unwrap_or_default());
    for _ in 0..120 {
        if let Ok(mut stream) = TcpStream::connect((host.as_str(), port.unwrap_or(80))) {
            let _ = write!(stream, "GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n");
            let mut response = String::new();
            let _ = stream.read_to_string(&mut response);
            if response.starts_with("HTTP/1.1 200") || response.starts_with("HTTP/1.1 404") {
                return;
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
    panic!("{base} never answered");
}

/// The shop's own executable, run as an external deployment would: it reads the synced .env.
fn shop(dir: &Path, args: &[&str], env: &[(&str, &str)]) -> Output {
    exec(dir.join("app/shop-bin").to_str().unwrap(), args, &dir.join("app"), env)
}

/// Checks the twin's histories replay deterministically and that a reset with the same seed and the
/// same requests gives the same history byte for byte.
fn deterministic_replay(dir: &Path, environment: &str, twins: &[&str]) {
    let mut digests: Vec<Vec<String>> = Vec::new();
    for _ in 0..2 {
        for twin in twins {
            succeeds(dir, &["twin", twin, "-e", environment, "reset"]);
        }
        assert!(shop(dir, &["rex", "ada"], &[("SHOP_PET_ID_BASE", "1000")]).status.success());
        digests.push(twins.iter().map(|twin| succeeds(dir, &["twin", twin, "-e", environment, "history"])).collect());
        for twin in twins {
            succeeds(dir, &["twin", twin, "-e", environment, "replay"]);
        }
    }
    assert_eq!(digests[0], digests[1], "the same seed and requests give the same history");
    assert!(digests[0].iter().all(|h| !h.trim().is_empty()));
}

/// Raises a fault the shop must notice, sees it fail, clears it, and sees it pass again.
fn fault_and_recover(dir: &Path, environment: &str, twin: &str, fault: &[&str]) {
    let mut raise = vec!["twin", twin, "-e", environment, "fault"];
    raise.extend_from_slice(fault);
    succeeds(dir, &raise);
    assert!(!shop(dir, &["rex", "ada"], &[]).status.success(), "the shop should fail under {fault:?}");
    succeeds(dir, &["twin", twin, "-e", environment, "fault", "clear"]);
    assert!(shop(dir, &["rex", "ada"], &[]).status.success(), "the shop should recover once {fault:?} is cleared");
}

/// The whole chain, environment by environment. ref:REQ-calm-end-to-end
#[test]
#[ignore = "needs podman, Go, npm, LawTwin's images and the real products; run with make e2e-calm"]
fn the_same_application_runs_against_real_twin_and_mixed_bindings() {
    let example = copy_example();
    let dir = example.path();
    let laws = laws_digest(dir);

    // Validation and every export work without deploying anything.
    let validated = succeeds(dir, &["validate"]);
    for environment in ["twin", "real", "mixed", "staging"] {
        assert!(validated.contains(&format!("environment {environment}: resolved")));
    }
    if ironframe_core::process::locate("IRONFRAME_CALM", &["calm"], &[]).is_some() {
        assert!(succeeds(dir, &["validate", "--calm-cli"]).contains("calm validate: passed"));
        let diagram = succeeds(dir, &["export", "diagram", "-e", "mixed", "--format", "calm-template"]);
        assert!(diagram.contains("```mermaid") && diagram.contains("real apache/kafka 4.1.0"));
    }
    let resolution =
        ironframe_core::calm::load_and_resolve(&dir.join("architecture/shop.calm.json"), None, "staging").unwrap();
    let root_text = succeeds(dir, &["export", "tofu", "-e", "staging"]);
    let root: Value = serde_json::from_str(&root_text).unwrap();
    assert!(ironframe_core::calm::export::tofu_problems(&resolution.topology, &root).is_empty());
    for environment in ["twin", "real", "mixed"] {
        let resolution =
            ironframe_core::calm::load_and_resolve(&dir.join("architecture/shop.calm.json"), None, environment)
                .unwrap();
        let diagram = succeeds(dir, &["export", "diagram", "-e", environment]);
        assert_eq!(
            ironframe_core::calm::export::mermaid_problems(&resolution.topology, &diagram),
            Vec::<String>::new()
        );
        for app in ["adoptions-service", "adoptions-audit"] {
            let settings = exported_settings(dir, environment, app);
            assert!(ironframe_core::calm::export::settings_problems(&resolution.topology, app, &settings).is_empty());
        }
    }

    // Unresolved and incompatible bindings are refused by name.
    let decorators_path = dir.join("architecture/shop.decorators.json");
    let original = std::fs::read_to_string(&decorators_path).unwrap();
    let mut changed: Value = serde_json::from_str(&original).unwrap();
    for decorator in changed["decorators"].as_array_mut().unwrap() {
        if decorator["unique-id"] == "adoptions-log-twin" {
            decorator["data"]["twin"]["stands-in-for"]["version"] = Value::from("0.9.0");
        }
        if decorator["unique-id"] == "pet-registry-twin" {
            decorator["applies-to"] = Value::from(vec!["pet-registri"]);
        }
    }
    std::fs::write(&decorators_path, serde_json::to_string_pretty(&changed).unwrap()).unwrap();
    let refused = ironframe(dir, &["resolve", "--env", "twin"]);
    assert!(!refused.status.success());
    let message = String::from_utf8_lossy(&refused.stderr);
    for needle in ["adoptions-log-twin", "0.9.0", "incompatible", "pet-registri", "pet-registry", "unresolved"] {
        assert!(message.contains(needle), "the refusal names {needle}");
    }
    std::fs::write(&decorators_path, &original).unwrap();

    // The shop's generated code and executable.
    assert!(exec("npm", &["ci", "--no-audit", "--no-fund"], &dir.join("app"), &[]).status.success());
    assert!(exec("npx", &["--no-install", "lawspec", "generate"], &dir.join("app"), &[]).status.success());
    assert!(exec("go", &["build", "-o", "shop-bin", "./cmd/shop"], &dir.join("app"), &[]).status.success());
    // The static Linux executable the managed image holds, for podman's own architecture.
    let arch = if cfg!(target_arch = "aarch64") { "arm64" } else { "amd64" };
    let linux = [("GOOS", "linux"), ("GOARCH", arch), ("CGO_ENABLED", "0")];
    assert!(exec("go", &["build", "-o", "shop-linux", "./cmd/shop"], &dir.join("app"), &linux).status.success());

    for environment in ["twin", "real", "mixed"] {
        let output = ironframe(dir, &["up", environment, "--wait", "180"]);
        let _up = Up(dir, environment);
        assert!(output.status.success(), "ironframe up {environment} failed");

        // The Petstore answers once its server has deployed, which may be after its port opens.
        let url = &exported_settings(dir, environment, "adoptions-service")["PETSTORE_URL"];
        wait_for_http(url);

        // The injected settings are the topology's: the synced .env holds what export says.
        let dotenv = ironframe_core::settings::parse_dotenv(&std::fs::read_to_string(dir.join("app/.env")).unwrap());
        for (key, value) in exported_settings(dir, environment, "adoptions-service") {
            assert_eq!(dotenv.get(&key), Some(&value), "{key} in {environment}");
        }

        // The unchanged laws, run under ironframe and read by LawSpec.
        run_laws(dir, environment);
        assert_eq!(laws_digest(dir), laws, "no binding changes the laws");

        // The audit, a managed application, reads what the service published on the shared log.
        let audit = ironframe(dir, &["app", "adoptions-audit", "-e", environment]);
        assert!(audit.status.success(), "the audit failed in {environment}");
        let audit_attestation =
            Attestation::from_json(&std::fs::read_to_string(attestation_path(&audit)).unwrap()).unwrap();
        assert_eq!(audit_attestation.dependencies.len(), 1);
        assert_eq!(audit_attestation.dependencies[0].node.as_deref(), Some("adoptions-log"));
        if environment == "real" {
            // Here the audit is a managed image, built from its Containerfile when podman lacks it.
            let implementation = &audit_attestation.application.as_ref().unwrap().implementation;
            assert!(implementation.image_digest.as_deref().is_some_and(|d| d.starts_with("sha256:")));
        }

        // The service as an external deployment: it reads the .env itself, and Ironframe records
        // the run it did not start.
        let begun = succeeds(dir, &["attest", environment, "--app", "adoptions-service"]);
        let file = begun.trim().rsplit_once("attestation: ").unwrap().1.to_string();
        assert!(shop(dir, &["rex", "ada"], &[]).status.success());
        succeeds(dir, &["attest", environment, "--complete", &file, "--exit-code", "0"]);
        let external = Attestation::from_json(&std::fs::read_to_string(&file).unwrap()).unwrap();
        assert_eq!(external.execution.unwrap().status, ExecutionStatus::Completed);

        // Faults, resets and deterministic replay through the twins' control planes.
        match environment {
            "twin" => {
                fault_and_recover(dir, environment, "pet-registry", &["server-error", "status=503"]);
                fault_and_recover(dir, environment, "adoptions-log", &["broker-unavailable"]);
                deterministic_replay(dir, environment, &["adoptions-log", "pet-registry"]);
                // A reset empties the twin's log, so the audit has nothing to read until the
                // service publishes again.
                succeeds(dir, &["twin", "adoptions-log", "-e", environment, "reset"]);
                assert!(!ironframe(dir, &["app", "adoptions-audit", "-e", environment]).status.success());
                assert!(shop(dir, &["rex", "ada"], &[]).status.success());
                assert!(ironframe(dir, &["app", "adoptions-audit", "-e", environment]).status.success());
            }
            "mixed" => {
                fault_and_recover(dir, environment, "pet-registry", &["server-error", "status=503"]);
                deterministic_replay(dir, environment, &["pet-registry"]);
                let real = ironframe(dir, &["twin", "adoptions-log", "-e", environment, "reset"]);
                assert!(!real.status.success(), "a real dependency has no control plane");
            }
            _ => {}
        }
    }
}
