//! Captures the command's golden corpus: for each case, the files it starts from, the commands it
//! runs with fake podman and OpenTofu scripts, and each command's exact standard output, standard
//! error and exit status, then the files left behind. Written to corpus/cli.json. Run with
//! `cargo test -p ironframe-cli --test corpus_cli -- --ignored`. ref:DEC-haskell-wasm-core

use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").canonicalize().unwrap()
}

/// The fake podman: logs its arguments and answers as an empty podman with a compose provider.
const FAKE_PODMAN: &str = r#"#!/bin/sh
echo "podman $*" >> "$IRONFRAME_FAKE_LOG"
case "$1 $2" in
  "image inspect") echo null ;;
  "ps "*|"ps -a") echo "[]" ;;
esac
exit 0
"#;

/// The fake OpenTofu: logs its arguments and reports one endpoint.
const FAKE_TOFU: &str = r#"#!/bin/sh
echo "tofu $*" >> "$IRONFRAME_FAKE_LOG"
case "$2" in
  output) echo '{"adoptions-log": "adoptions.elb.example:9092", "kafka": "kafka.elb.example:9092"}' ;;
esac
exit 0
"#;

/// The fake podman whose compose provider is missing.
const BROKEN_PODMAN: &str = r#"#!/bin/sh
echo "podman $*" >> "$IRONFRAME_FAKE_LOG"
if [ "$1" = compose ]; then echo "Error: looking up compose provider failed" >&2; exit 125; fi
exit 0
"#;

fn normalise(text: &str, root: &Path) -> String {
    let canonical = root.canonicalize().unwrap();
    let text = text.replace(&canonical.display().to_string(), "/work").replace(&root.display().to_string(), "/work");
    let text = replace_uuids(&text);
    replace_times(&text)
}

fn replace_uuids(text: &str) -> String {
    let c: Vec<char> = text.chars().collect();
    let shape = [8, 4, 4, 4, 12];
    let mut out = String::new();
    let mut i = 0;
    while i < c.len() {
        let mut j = i;
        let mut ok = i == 0 || !c[i - 1].is_ascii_alphanumeric();
        for (k, n) in shape.iter().enumerate() {
            if !ok {
                break;
            }
            for _ in 0..*n {
                if j < c.len() && c[j].is_ascii_hexdigit() && !c[j].is_ascii_uppercase() {
                    j += 1;
                } else {
                    ok = false;
                    break;
                }
            }
            if ok && k < 4 {
                if j < c.len() && c[j] == '-' {
                    j += 1;
                } else {
                    ok = false;
                }
            }
        }
        if ok {
            out.push_str("<uuid>");
            i = j;
        } else {
            out.push(c[i]);
            i += 1;
        }
    }
    out
}

fn replace_times(text: &str) -> String {
    let c: Vec<char> = text.chars().collect();
    let digit = |i: usize| i < c.len() && c[i].is_ascii_digit();
    let at = |i: usize, ch: char| i < c.len() && c[i] == ch;
    let mut out = String::new();
    let mut i = 0;
    while i < c.len() {
        let date = (0..4).all(|k| digit(i + k))
            && at(i + 4, '-')
            && digit(i + 5)
            && digit(i + 6)
            && at(i + 7, '-')
            && digit(i + 8)
            && digit(i + 9)
            && at(i + 10, 'T')
            && digit(i + 11)
            && digit(i + 12)
            && at(i + 13, ':')
            && digit(i + 14)
            && digit(i + 15)
            && at(i + 16, ':')
            && digit(i + 17)
            && digit(i + 18);
        if date {
            let mut j = i + 19;
            if at(j, '.') {
                j += 1;
                while digit(j) {
                    j += 1;
                }
            }
            if at(j, 'Z') {
                j += 1;
            } else if (at(j, '+') || at(j, '-')) && digit(j + 1) && digit(j + 2) && at(j + 3, ':') {
                j += 6;
            }
            out.push_str("<time>");
            i = j;
            continue;
        }
        out.push(c[i]);
        i += 1;
    }
    out
}

/// Every file under `dir`, by relative path.
fn files(dir: &Path) -> BTreeMap<String, String> {
    let mut found = BTreeMap::new();
    fn walk(root: &Path, at: &Path, found: &mut BTreeMap<String, String>) {
        let Ok(entries) = std::fs::read_dir(at) else { return };
        for entry in entries {
            let path = entry.unwrap().path();
            if path.is_dir() {
                walk(root, &path, found);
            } else {
                let relative = path.strip_prefix(root).unwrap().display().to_string();
                found.insert(relative, std::fs::read_to_string(&path).unwrap_or_else(|_| "<binary>".into()));
            }
        }
    }
    walk(dir, dir, &mut found);
    found
}

/// One case: the example directories it starts from, and its steps, each run in a directory
/// relative to the case's root with arguments and extra environment.
struct Case {
    name: &'static str,
    examples: &'static [&'static str],
    steps: Vec<(&'static str, Vec<&'static str>, Vec<(&'static str, &'static str)>)>,
}

fn copy(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') || name == "src" || name == "Cargo.toml" {
            continue;
        }
        if entry.file_type().unwrap().is_dir() {
            copy(&entry.path(), &to.join(&name));
        } else {
            std::fs::copy(entry.path(), to.join(&name)).unwrap();
        }
    }
}

fn run_case(case: &Case) -> Value {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().canonicalize().unwrap();
    for example in case.examples {
        let (from, to) = match *example {
            "calm-shop" => ("examples/calm-shop/architecture", "calm-shop/architecture"),
            other => (Box::leak(format!("examples/{other}").into_boxed_str()) as &str, *example),
        };
        copy(&repo().join(from), &root.join(to));
    }
    let tools = root.join(".tools");
    std::fs::create_dir_all(&tools).unwrap();
    for (name, script) in [("podman", FAKE_PODMAN), ("tofu", FAKE_TOFU), ("broken-podman", BROKEN_PODMAN)] {
        let path = tools.join(name);
        std::fs::write(&path, script).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let log = root.join(".tools/log");
    let before = files(&root);
    let mut steps = Vec::new();
    for (cwd, args, env) in &case.steps {
        let mut command = Command::new(env!("CARGO_BIN_EXE_ironframe"));
        command
            .args(args)
            .current_dir(root.join(cwd))
            .env_remove("IRONFRAME_CALM")
            .env("PATH", "/usr/bin:/bin")
            .env("IRONFRAME_PODMAN", tools.join("podman"))
            .env("IRONFRAME_TOFU", tools.join("tofu"))
            .env("IRONFRAME_FAKE_LOG", &log)
            .env("NO_COLOR", "1");
        for (key, value) in env {
            let value = value.replace("$ROOT", &root.display().to_string());
            command.env(key, value);
        }
        let output = command.output().unwrap();
        steps.push(json!({
            "cwd": cwd,
            "args": args,
            "env": env.iter().map(|(k, v)| (k.to_string(), json!(v))).collect::<serde_json::Map<_, _>>(),
            "stdout": normalise(&String::from_utf8_lossy(&output.stdout), &root),
            "stderr": normalise(&String::from_utf8_lossy(&output.stderr), &root),
            "code": output.status.code(),
        }));
    }
    let after = files(&root);
    let changed: BTreeMap<String, String> = after
        .into_iter()
        .filter(|(path, text)| before.get(path) != Some(text))
        .map(|(path, text)| (normalise(&path, &root), normalise(&text, &root)))
        .collect();
    json!({"name": format!("cli/{}", case.name), "method": "cli", "input": {"examples": case.examples, "steps": steps.iter().map(|s| json!({"cwd": s["cwd"], "args": s["args"], "env": s["env"]})).collect::<Vec<_>>()},
        "expected": {"steps": steps.iter().map(|s| json!({"stdout": s["stdout"], "stderr": s["stderr"], "code": s["code"]})).collect::<Vec<_>>(), "files": changed}})
}

fn cases() -> Vec<Case> {
    let k = "kafka-app";
    let p = "petstore-app";
    let a = "calm-shop/architecture";
    let one = |name: &'static str, examples: &'static [&'static str], cwd: &'static str, args: Vec<&'static str>| Case {
        name,
        examples,
        steps: vec![(cwd, args, vec![])],
    };
    let ka: &'static [&'static str] = &["kafka-app"];
    let pa: &'static [&'static str] = &["petstore-app"];
    let ca: &'static [&'static str] = &["calm-shop"];
    let arch = |rest: &[&'static str]| {
        let mut all = vec!["-a", "shop.calm.json"];
        all.extend_from_slice(rest);
        all
    };
    vec![
        one("validate-kafka", ka, k, vec!["validate"]),
        one("validate-petstore", pa, p, vec!["validate"]),
        one("validate-named", ka, ".", vec!["-f", "kafka-app/ironframe.yaml", "validate"]),
        one("validate-missing", ka, k, vec!["-f", "nope.yaml", "validate"]),
        one("settings-env", ka, k, vec!["settings", "local"]),
        one("settings-json", ka, k, vec!["settings", "local", "--format", "json"]),
        one("settings-production", ka, k, vec!["settings", "production"]),
        one("settings-undeployed", ka, k, vec!["settings", "staging"]),
        one("settings-unknown", ka, k, vec!["settings", "nope"]),
        one("settings-petstore", pa, p, vec!["settings", "local"]),
        one("compose-local", ka, k, vec!["compose", "local"]),
        one("compose-broker", ka, k, vec!["compose", "local-broker"]),
        one("compose-cloud", ka, k, vec!["compose", "staging"]),
        one("compose-petstore", pa, p, vec!["compose", "local"]),
        one("schema-manifest", ka, k, vec!["schema"]),
        one("schema-attestation", ka, k, vec!["schema", "attestation"]),
        one("schema-contract", ka, k, vec!["schema", "contract"]),
        one("schema-binding", ka, k, vec!["schema", "binding"]),
        one("schema-environment", ka, k, vec!["schema", "environment"]),
        one("resolve-needs-architecture", ka, k, vec!["resolve", "-e", "local"]),
        one("export-needs-architecture", ka, k, vec!["export", "topology", "-e", "local"]),
        one("status-local", ka, k, vec!["status", "local"]),
        one("status-json", ka, k, vec!["status", "local", "--json"]),
        one("status-cloud", ka, k, vec!["status", "staging"]),
        one("status-production", ka, k, vec!["status", "production", "--json"]),
        one("plan-cloud", ka, k, vec!["plan", "staging"]),
        one("plan-gcp", ka, k, vec!["plan", "staging-gcp"]),
        one("plan-podman", ka, k, vec!["plan", "local"]),
        one("down-local", ka, k, vec!["down", "local"]),
        one("down-cloud", ka, k, vec!["down", "staging"]),
        one("sync-local", ka, k, vec!["sync", "local"]),
        one("sync-petstore", pa, p, vec!["sync", "local"]),
        one("attest-local", ka, k, vec!["attest", "local"]),
        one("attest-output", pa, p, vec!["attest", "local", "-o", "evidence/attestation.json"]),
        one("twin-unreachable", ka, k, vec!["twin", "kafka", "seed"]),
        one("twin-unknown", ka, k, vec!["twin", "nope", "seed"]),
        one("twin-real", ka, k, vec!["twin", "kafka", "-e", "production", "seed"]),
        one("twin-no-admin", ka, k, vec!["twin", "kafka", "-e", "staging-gcp", "seed"]),
        Case { name: "up-no-compose", examples: ka, steps: vec![(k, vec!["up", "local"], vec![("IRONFRAME_PODMAN", "$ROOT/.tools/broken-podman")])] },
        Case { name: "up-no-podman", examples: ka, steps: vec![(k, vec!["up", "local"], vec![("IRONFRAME_PODMAN", "$ROOT/.tools/none")])] },
        one("up-twin-unanswered", ka, k, vec!["up", "local", "--wait", "0", "--no-sync"]),
        one("up-broker", ka, k, vec!["up", "local-broker", "--wait", "0"]),
        one("up-cloud", ka, k, vec!["up", "staging-gcp", "--wait", "0", "--no-sync"]),
        one("calm-validate", ca, a, arch(&["validate"])),
        one("calm-validate-cli", ca, a, arch(&["validate", "--calm-cli"])),
        one("calm-validate-missing", ca, a, vec!["-a", "nope.json", "validate"]),
        one("calm-validate-decorators", ca, a, vec!["-a", "shop.calm.json", "--decorators", "nope.json", "validate"]),
        one("calm-resolve-twin", ca, a, arch(&["resolve", "--env", "twin"])),
        one("calm-resolve-real", ca, a, arch(&["resolve", "--env", "real"])),
        one("calm-resolve-mixed", ca, a, arch(&["resolve", "-e", "mixed"])),
        one("calm-resolve-staging", ca, a, arch(&["resolve", "-e", "staging"])),
        one("calm-resolve-positional", ca, a, vec!["resolve", "shop.calm.json", "--env", "twin"]),
        one("calm-resolve-output", ca, a, arch(&["resolve", "-e", "twin", "-o", "topology.json"])),
        one("calm-resolve-unknown", ca, a, arch(&["resolve", "-e", "production"])),
        one("calm-resolve-relative", ca, "calm-shop", vec!["-a", "architecture/shop.calm.json", "resolve", "-e", "mixed"]),
        one("calm-export-topology", ca, a, arch(&["export", "topology", "-e", "mixed"])),
        one("calm-export-mermaid", ca, a, arch(&["export", "diagram", "-e", "mixed"])),
        one("calm-export-dot", ca, a, arch(&["export", "diagram", "-e", "twin", "--format", "dot"])),
        one("calm-export-calm", ca, a, arch(&["export", "diagram", "-e", "real", "--format", "calm"])),
        one("calm-export-calm-template", ca, a, arch(&["export", "diagram", "-e", "real", "--format", "calm-template"])),
        one("calm-export-diagram-unknown", ca, a, arch(&["export", "diagram", "-e", "real", "--format", "svg"])),
        one("calm-export-settings", ca, a, arch(&["export", "settings", "-e", "twin"])),
        one("calm-export-settings-app", ca, a, arch(&["export", "settings", "-e", "twin", "--app", "adoptions-service"])),
        one("calm-export-settings-app-json", ca, a, arch(&["export", "settings", "-e", "real", "--app", "adoptions-audit", "--format", "json"])),
        one("calm-export-settings-env-all", ca, a, arch(&["export", "settings", "-e", "twin", "--format", "env"])),
        one("calm-export-settings-nope", ca, a, arch(&["export", "settings", "-e", "twin", "--app", "nope"])),
        one("calm-export-settings-format", ca, a, arch(&["export", "settings", "-e", "twin", "--app", "adoptions-audit", "--format", "yaml"])),
        one("calm-export-settings-staging", ca, a, arch(&["export", "settings", "-e", "staging"])),
        one("calm-export-tofu", ca, a, arch(&["export", "tofu", "-e", "staging"])),
        one("calm-export-tofu-output", ca, a, arch(&["export", "tofu", "-e", "staging", "-o", "tofu-root"])),
        one("calm-export-tofu-podman", ca, a, arch(&["export", "tofu", "-e", "twin"])),
        one("calm-export-compose", ca, a, arch(&["export", "compose", "-e", "real"])),
        one("calm-export-compose-output", ca, a, arch(&["export", "compose", "-e", "twin", "-o", "compose.yaml"])),
        one("calm-settings-app", ca, a, arch(&["settings", "twin", "--app", "adoptions-service"])),
        one("calm-settings-app-json", ca, a, arch(&["settings", "mixed", "--app", "adoptions-service", "--format", "json"])),
        one("calm-settings-all", ca, a, arch(&["settings", "twin"])),
        one("calm-settings-app-manifest", ka, k, vec!["settings", "local", "--app", "x"]),
        one("calm-compose", ca, a, arch(&["compose", "mixed"])),
        one("calm-schema", ca, a, arch(&["schema", "binding"])),
        one("calm-validate-manifest-verb", ca, a, arch(&["status", "twin"])),
        one("calm-run", ca, a, arch(&["run", "-e", "twin", "--app", "adoptions-service", "--", "sh", "-c", "echo $KAFKA_BOOTSTRAP_SERVERS $PETSTORE_URL; test -f \"$IRONFRAME_ATTESTATION\" && echo has-attestation; exit 3"])),
        one("calm-run-dir", ca, a, arch(&["run", "-e", "mixed", "--app", "adoptions-audit", "--dir", ".", "--attestation", "run.json", "--", "sh", "-c", "pwd; echo $KAFKA_BOOTSTRAP_SERVERS"])),
        one("calm-run-missing-program", ca, a, arch(&["run", "-e", "twin", "--app", "adoptions-service", "--", "no-such-program-xyz"])),
        one("calm-run-unknown-app", ca, a, arch(&["run", "-e", "twin", "--app", "nope", "--", "true"])),
        one("calm-app-external", ca, a, arch(&["app", "adoptions-service", "-e", "twin"])),
        one("calm-app-process-missing-dir", ca, a, arch(&["app", "adoptions-audit", "-e", "twin"])),
        one("calm-app-image", ca, a, arch(&["app", "adoptions-audit", "-e", "real", "--", "--verbose"])),
        Case {
            name: "calm-attest-begin-complete",
            examples: ca,
            steps: vec![
                (a, arch(&["attest", "twin", "--app", "adoptions-service", "-o", "begun.json"]), vec![]),
                (a, arch(&["attest", "twin", "--complete", "begun.json", "--exit-code", "4"]), vec![]),
                (a, arch(&["attest", "twin", "--complete", "begun.json"]), vec![]),
                (a, arch(&["attest", "mixed", "--complete", "begun.json", "-o", "other.json"]), vec![]),
            ],
        },
        one("calm-attest-wired", ca, a, arch(&["attest", "twin"])),
        one("calm-attest-complete-missing", ca, a, arch(&["attest", "twin", "--complete", "none.json"])),
        one("calm-up-twin", ca, a, arch(&["up", "twin", "--wait", "0"])),
        one("calm-up-real", ca, a, arch(&["up", "real", "--wait", "0"])),
        one("calm-down", ca, a, arch(&["down", "mixed"])),
        one("calm-twin-real", ca, a, arch(&["twin", "adoptions-log", "-e", "mixed", "reset"])),
        one("calm-twin-unreachable", ca, a, arch(&["twin", "pet-registry", "-e", "mixed", "reset"])),
        one("calm-plan-staging", ca, a, arch(&["plan", "staging"])),
    ]
}

#[test]
#[ignore = "writes corpus/cli.json; run with --ignored"]
fn capture() {
    let all: Vec<Value> = cases().iter().map(run_case).collect();
    let text = serde_json::to_string_pretty(&Value::Array(all)).unwrap() + "\n";
    std::fs::write(repo().join("corpus/cli.json"), text).unwrap();
}
