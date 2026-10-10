//! End to end, with podman and LawTwin's real images: `ironframe up local` starts the Kafka twin
//! and the Petstore twin of the two examples, each example application runs against its twin with
//! the settings Ironframe synced, `ironframe attest` records each stand-in with its conformance
//! level, seed and history digest, `ironframe twin` drives a twin's control plane, and
//! `ironframe down` removes everything. It needs podman with a compose provider and the images
//! `lawtwin/kafka:0.1.0`, `lawtwin/http:0.1.0` and `localhost/ironframe-config-service:0.1.0`, so it
//! is ignored by `cargo test` and run by `make e2e`. ref:REQ-end-to-end-with-twins

use ironframe_attestation::{Attestation, Kind};
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

/// The repository's root.
fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").canonicalize().unwrap()
}

/// The directory cargo builds into, found from this test's own executable.
fn target_dir() -> PathBuf {
    std::env::current_exe().unwrap().parent().unwrap().parent().unwrap().to_path_buf()
}

/// A copy of an example's manifest and conformance reports in a fresh directory, so a run leaves
/// nothing behind in the repository.
fn copy_example(name: &str) -> tempfile::TempDir {
    let directory = tempfile::tempdir().unwrap();
    let from = root().join("examples").join(name);
    std::fs::copy(from.join("ironframe.yaml"), directory.path().join("ironframe.yaml")).unwrap();
    std::fs::create_dir(directory.path().join("conformance")).unwrap();
    for entry in std::fs::read_dir(from.join("conformance")).unwrap() {
        let entry = entry.unwrap();
        std::fs::copy(entry.path(), directory.path().join("conformance").join(entry.file_name())).unwrap();
    }
    directory
}

fn ironframe(directory: &Path, args: &[&str]) -> Output {
    let output = Command::new(env!("CARGO_BIN_EXE_ironframe")).args(args).current_dir(directory).output().unwrap();
    eprintln!(
        "$ ironframe {}\n{}{}",
        args.join(" "),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    output
}

fn succeeds(directory: &Path, args: &[&str]) -> String {
    let output = ironframe(directory, args);
    assert!(output.status.success(), "ironframe {} failed", args.join(" "));
    String::from_utf8(output.stdout).unwrap()
}

fn run_app(name: &str, directory: &Path) -> String {
    let output = Command::new(target_dir().join(name)).current_dir(directory).output().unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
    eprintln!("$ {name}\n{stdout}{}", String::from_utf8_lossy(&output.stderr));
    assert!(output.status.success(), "{name} failed against its twin");
    stdout
}

/// Takes an environment down when dropped, so a failed assertion leaves no container running.
struct Up<'a>(&'a Path);

impl Drop for Up<'_> {
    fn drop(&mut self) {
        ironframe(self.0, &["down", "local"]);
    }
}

fn http_get(address: &str, path: &str) -> String {
    let mut stream = TcpStream::connect(address).unwrap();
    write!(stream, "GET {path} HTTP/1.1\r\nHost: {address}\r\nConnection: close\r\n\r\n").unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).unwrap();
    response.split_once("\r\n\r\n").map(|(_, body)| body.to_string()).unwrap_or_default()
}

fn attestation(directory: &Path) -> Attestation {
    let text = std::fs::read_to_string(directory.join(".ironframe/local/attestation.json")).unwrap();
    Attestation::from_json(&text).unwrap()
}

/// ref:REQ-end-to-end-with-twins
#[test]
#[ignore = "needs podman and LawTwin's images; run with `make e2e`"]
fn up_runs_the_apps_against_real_twins_and_attest_lists_each_stand_in_with_its_level() {
    let status = Command::new(std::env::var("CARGO").unwrap_or_else(|_| "cargo".into()))
        .args(["build", "-q", "-p", "kafka-app", "-p", "petstore-app"])
        .current_dir(root())
        .status()
        .unwrap();
    assert!(status.success(), "the example applications build");

    let kafka = copy_example("kafka-app");
    let petstore = copy_example("petstore-app");
    let kafka_dir = kafka.path();
    let petstore_dir = petstore.path();

    succeeds(kafka_dir, &["validate"]);
    let _kafka_up = Up(kafka_dir);
    succeeds(kafka_dir, &["up", "local"]);
    let _petstore_up = Up(petstore_dir);
    succeeds(petstore_dir, &["up", "local"]);

    // The settings reached the applications through env files and the configuration service.
    assert!(
        std::fs::read_to_string(kafka_dir.join(".env")).unwrap().contains("KAFKA_BOOTSTRAP_SERVERS=localhost:9092")
    );
    assert!(std::fs::read_to_string(petstore_dir.join(".env")).unwrap().contains("PETSTORE_URL=http://localhost:8080"));
    assert!(
        http_get("127.0.0.1:8700", "/v1/environments/local").contains(r#""KAFKA_BOOTSTRAP_SERVERS":"localhost:9092""#)
    );

    // The twins were set up at start: the seed, and the Petstore's latency fault.
    let seed = succeeds(kafka_dir, &["twin", "kafka", "seed"]);
    assert!(seed.contains("42"), "{seed}");
    let faults = succeeds(petstore_dir, &["twin", "petstore", "inspect"]);
    assert!(faults.contains("\"latency\""), "{faults}");

    // Each application runs against its twin, reading its settings as it always does.
    assert!(run_app("kafka-app", kafka_dir).contains("topic kafka-app has 1 partition(s)"));
    assert!(run_app("petstore-app", petstore_dir).contains("added pet"));

    // A state the contract forbids is refused with exit 2, as lawtwin refuses it.
    let forced = {
        let state = petstore_dir.join("bad-state.json");
        std::fs::write(&state, r#"{"resources": {"Pet": [{"id": 1, "photoUrls": []}]}}"#).unwrap();
        ironframe(petstore_dir, &["twin", "petstore", "force", state.to_str().unwrap()])
    };
    assert!(!forced.status.success());
    let advanced = succeeds(kafka_dir, &["twin", "kafka", "advance", "5s"]);
    assert!(advanced.contains("nowMs"), "{advanced}");

    // The attestation lists each stand-in with its level, seed and the digest of what the app did.
    let listing = succeeds(kafka_dir, &["attest", "local"]);
    assert!(listing.contains("conformance answers"), "{listing}");
    succeeds(petstore_dir, &["attest", "local"]);
    for (directory, dependency, product, level) in
        [(kafka_dir, "kafka", "lawtwin/kafka", "answers"), (petstore_dir, "petstore", "lawtwin/http", "conformant")]
    {
        let attested = attestation(directory);
        let record = attested.dependencies.iter().find(|d| d.name == dependency).unwrap();
        assert_eq!(record.kind, Kind::StandIn);
        assert!(record.reached, "{dependency} was reached");
        let stand_in = record.stand_in.as_ref().unwrap();
        assert_eq!((stand_in.product.as_str(), stand_in.version.as_str()), (product, "0.1.0"));
        assert_eq!(stand_in.conformance, level);
        assert_eq!(stand_in.seed, Some(42));
        assert!(stand_in.history_entries.unwrap() >= 2, "{dependency}'s history holds what the app did");
        let history =
            std::fs::read_to_string(directory.join(format!(".ironframe/local/history/{dependency}.jsonl"))).unwrap();
        assert_eq!(stand_in.history_digest.as_deref(), Some(ironframe_core::twin::history_digest(&history).as_str()));
    }
    let history = std::fs::read_to_string(kafka_dir.join(".ironframe/local/history/kafka.jsonl")).unwrap();
    assert!(history.contains(r#""op":"createTopicsRequest","name":"kafka-app""#), "{history}");

    drop(_petstore_up);
    drop(_kafka_up);
    let left = Command::new(
        ironframe_core::process::locate("IRONFRAME_PODMAN", &["podman"], &["/opt/podman/bin/podman"]).unwrap(),
    )
    .args(["ps", "-a", "--filter", "label=io.ironframe.environment=local", "--format", "{{.Names}}"])
    .output()
    .unwrap();
    let names = String::from_utf8_lossy(&left.stdout);
    assert!(!names.contains("ironframe-kafka-app-local") && !names.contains("ironframe-petstore-app-local"), "{names}");
}
