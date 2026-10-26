// End to end, with podman and LawTwin's real images: `ironframe up local`
// starts the Kafka twin and the Petstore twin of the two examples, each
// example application runs against its twin with the settings Ironframe
// synced, `ironframe attest` records each stand-in with its conformance level,
// seed and history digest, `ironframe twin` drives a twin's control plane, and
// `ironframe down` removes everything. It needs podman with a compose
// provider and the images lawtwin/kafka:0.3.0, lawtwin/http:0.3.0 and
// localhost/ironframe-config-service:0.3.0 (make config-service-image), so it
// runs only with IRONFRAME_E2E=1, as `make e2e` sets it.
// ref:REQ-end-to-end-with-twins
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFileSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { connect } from "node:net";
import { tmpdir } from "node:os";
import { join, basename } from "node:path";
import { fileURLToPath } from "node:url";

const repo = fileURLToPath(new URL("../../", import.meta.url));
const bin = join(repo, "npm/bin/ironframe.mjs");
const skip = process.env.IRONFRAME_E2E === "1" ? false : "set IRONFRAME_E2E=1 (make e2e) to run against podman";

/** A copy of an example's manifest and conformance reports in a fresh directory. */
function copyExample(name) {
  const directory = mkdtempSync(join(tmpdir(), `ironframe-e2e-${name}-`));
  const from = join(repo, "examples", name);
  const manifest = readFileSync(join(from, "ironframe.yaml"), "utf8")
    .replace(/^project: (.+)$/m, (_, project) => 'project: ' + project + '-' + basename(directory).slice(-6).toLowerCase());
  const httpPort = process.env.IRONFRAME_E2E_HTTP_PORT ?? '8080';
  writeFileSync(join(directory, "ironframe.yaml"), manifest.replaceAll('localhost:8080', 'localhost:' + httpPort));
  mkdirSync(join(directory, "conformance"));
  for (const entry of readdirSync(join(from, "conformance")))
    copyFileSync(join(from, "conformance", entry), join(directory, "conformance", entry));
  return directory;
}

/** Runs the command, echoing what it printed. */
function ironframe(directory, args) {
  const output = spawnSync(process.execPath, [bin, ...args], { cwd: directory, encoding: "utf8" });
  process.stderr.write(`$ ironframe ${args.join(" ")}\n${output.stdout}${output.stderr}`);
  return output;
}

function succeeds(directory, args) {
  const output = ironframe(directory, args);
  assert.equal(output.status, 0, `ironframe ${args.join(" ")} failed`);
  return output.stdout;
}

/** Runs an example application in a directory, where it reads the synced .env. */
function runApp(name, directory) {
  const output = spawnSync(process.execPath, [join(repo, "examples", name, "app.mjs")], { cwd: directory, encoding: "utf8" });
  process.stderr.write(`$ ${name}\n${output.stdout}${output.stderr}`);
  assert.equal(output.status, 0, `${name} failed against its twin`);
  return output.stdout;
}

/** A plain HTTP GET, as the Rust test made it, returning the body. */
function httpGet(host, port, path) {
  return new Promise((resolve, reject) => {
    const socket = connect(port, host, () => {
      socket.write(`GET ${path} HTTP/1.1\r\nHost: ${host}:${port}\r\nConnection: close\r\n\r\n`);
    });
    let response = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => (response += chunk));
    socket.on("end", () => resolve(response.split("\r\n\r\n").slice(1).join("\r\n\r\n")));
    socket.on("error", reject);
  });
}

function attestation(directory) {
  return JSON.parse(readFileSync(join(directory, ".ironframe/local/attestation.json"), "utf8"));
}

function sha256(text) {
  return `sha256:${createHash("sha256").update(text).digest("hex")}`;
}

/**
 * Brings both examples up against LawTwin's images, runs each app, drives a
 * twin and attests. ref:REQ-end-to-end-with-twins ref:REQ-example-reads-config
 */
async function upRunsTheAppsAgainstTwins() {
  const kafka = copyExample("kafka-app");
  const petstore = copyExample("petstore-app");
  try {
    succeeds(kafka, ["validate"]);
    succeeds(kafka, ["up", "local"]);
    succeeds(petstore, ["up", "local"]);

    // The settings reached the applications through env files and the configuration service.
    assert.match(readFileSync(join(kafka, ".env"), "utf8"), /KAFKA_BOOTSTRAP_SERVERS=localhost:9092/);
    assert.ok(readFileSync(join(petstore, ".env"), "utf8").includes('PETSTORE_URL=http://localhost:' + (process.env.IRONFRAME_E2E_HTTP_PORT ?? '8080')));
    assert.match(await httpGet("127.0.0.1", 8700, "/v1/environments/local"), /"KAFKA_BOOTSTRAP_SERVERS":"localhost:9092"/);

    // The twins were set up at start: the seed, and the Petstore's latency fault.
    assert.match(succeeds(kafka, ["twin", "kafka", "seed"]), /42/);
    assert.match(succeeds(petstore, ["twin", "petstore", "inspect"]), /"latency"/);

    // Each application runs against its twin, reading its settings as it always does.
    assert.match(runApp("kafka-app", kafka), /topic kafka-app has 1 partition\(s\)/);
    assert.match(runApp("petstore-app", petstore), /added pet/);

    // A state the contract forbids is refused, as lawtwin refuses it.
    const state = join(petstore, "bad-state.json");
    writeFileSync(state, '{"resources": {"Pet": [{"id": 1, "photoUrls": []}]}}');
    assert.notEqual(ironframe(petstore, ["twin", "petstore", "force", state]).status, 0);
    assert.match(succeeds(kafka, ["twin", "kafka", "advance", "5s"]), /nowMs/);

    // The attestation lists each stand-in with its level, seed and the digest of what the app did.
    assert.match(succeeds(kafka, ["attest", "local"]), /conformance answers/);
    succeeds(petstore, ["attest", "local"]);
    for (const [directory, dependency, product, level] of [
      [kafka, "kafka", "lawtwin/kafka", "answers"],
      [petstore, "petstore", "lawtwin/http", "conformant"],
    ]) {
      const record = attestation(directory).dependencies.find((d) => d.name === dependency);
      assert.equal(record.kind, "stand-in");
      assert.ok(record.reached, `${dependency} was reached`);
      assert.deepEqual([record.stand_in.product, record.stand_in.version], [product, "0.3.0"]);
      assert.equal(record.stand_in.conformance, level);
      assert.equal(record.stand_in.seed, 42);
      assert.ok(record.stand_in.history_entries >= 2, `${dependency}'s history holds what the app did`);
      const history = readFileSync(join(directory, `.ironframe/local/history/${dependency}.jsonl`), "utf8");
      assert.equal(record.stand_in.history_digest, sha256(history));
    }
    const history = readFileSync(join(kafka, ".ironframe/local/history/kafka.jsonl"), "utf8");
    assert.match(history, /"op":"createTopicsRequest","name":"kafka-app"/);
  } finally {
    ironframe(petstore, ["down", "local"]);
    ironframe(kafka, ["down", "local"]);
    const podman = process.env.IRONFRAME_PODMAN || "podman";
    const left = spawnSync(podman, ["ps", "-a", "--filter", "label=io.ironframe.environment=local", "--format", "{{.Names}}"], { encoding: "utf8" });
    for (const directory of [kafka, petstore]) {
      const project = readFileSync(join(directory, 'ironframe.yaml'), 'utf8').match(/^project: (.+)$/m)[1];
      assert.ok(!left.stdout.includes('ironframe-' + project + '-local'), left.stdout);
    }
    rmSync(kafka, { recursive: true, force: true });
    rmSync(petstore, { recursive: true, force: true });
  }
}

test("up runs the apps against real twins and attest lists each stand-in with its level", { skip }, upRunsTheAppsAgainstTwins);
