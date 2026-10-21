// End to end, the CALM chain with podman, LawTwin's images, the real products
// and LawSpec 0.26: the calm-shop architecture is validated and exported
// without deploying anything; then in each of the twin, real and mixed
// environments Ironframe brings the dependencies up, the shop's unchanged
// LawSpec laws run against them under `ironframe run`, the audit runs as a
// managed application over the shared Kafka, the service runs as an external
// application reading its synced .env, and LawSpec reads the completed
// attestation. In the environments with twins, faults, resets and
// deterministic replay are driven through the twins' control planes.
// Unresolved and incompatible bindings are refused by name. It needs podman
// with a compose provider, Go, npm, and the images lawtwin/kafka:0.1.0,
// lawtwin/http:0.1.0, apache/kafka:4.1.0 and lawtwin/petstore3-native:latest,
// so it runs only with IRONFRAME_E2E=1, as `make e2e-calm` sets it.
//
// The LawSpec assertions match the LawSpec release the example pins
// (examples/calm-shop/app/package.json: 0.26.0), which reports a law's wiring
// as plannedAgainst and plannedEnvironmentRun. LawSpec's main branch consumes
// completed-run attestations and reports against and environmentOutcome
// instead; when the example's pin moves to that release, the two marked
// assertions below change with it. ref:REQ-calm-end-to-end
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { connect } from "node:net";
import { arch, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createIronframe } from "../api.mjs";

const repo = fileURLToPath(new URL("../../", import.meta.url));
const bin = join(repo, "npm/bin/ironframe.mjs");
const skip = process.env.IRONFRAME_E2E === "1" ? false : "set IRONFRAME_E2E=1 (make e2e-calm) to run against podman";

/** Copies a directory's files, skipping generated and installed ones. */
function copyTree(from, to) {
  mkdirSync(to, { recursive: true });
  for (const name of readdirSync(from)) {
    if ([".ironframe", ".lawspec", "node_modules", "lawspec", ".env", "shop-bin", "shop-linux"].includes(name) || name.startsWith("lawspec_"))
      continue;
    if (statSync(join(from, name)).isDirectory()) copyTree(join(from, name), join(to, name));
    else copyFileSync(join(from, name), join(to, name));
  }
}

function exec(program, args, cwd, env = {}) {
  const output = spawnSync(program, args, { cwd, encoding: "utf8", env: { ...process.env, ...env } });
  process.stderr.write(`$ ${program} ${args.join(" ")}\n${output.stdout ?? ""}${output.stderr ?? ""}`);
  return output;
}

function ironframe(dir, args) {
  return exec(process.execPath, [bin, "-a", "shop.calm.json", ...args], join(dir, "architecture"));
}

function succeeds(dir, args) {
  const output = ironframe(dir, args);
  assert.equal(output.status, 0, `ironframe ${args.join(" ")} failed`);
  return output.stdout;
}

/** The path ironframe printed after "; attestation " on standard error. */
function attestationPath(output) {
  const line = output.stderr.split("\n").reverse().find((l) => l.includes("; attestation "));
  assert.ok(line, "ironframe names the attestation");
  return line.slice(line.lastIndexOf("; attestation ") + "; attestation ".length).trim();
}

/** A digest of the shop's laws, which no binding may change. */
function lawsDigest(dir) {
  const bytes = readFileSync(join(dir, "app/spec/shop.lawspec"));
  let h = 0n;
  for (const b of bytes) h = (h * 31n + BigInt(b)) & 0xffffffffffffffffn;
  return h.toString(16);
}

function exportedSettings(dir, environment, app) {
  return JSON.parse(succeeds(dir, ["export", "settings", "-e", environment, "--app", app, "--format", "json"]));
}

function expectedKinds(environment) {
  const [log, registry] = environment === "twin" ? ["stand-in", "stand-in"] : environment === "real" ? ["real", "real"] : ["real", "stand-in"];
  return [
    ["shop.adoptions::ability::Adoptions", log],
    ["shop.adoptions::ability::Pets", registry],
  ];
}

const core = createIronframe();

/** The topology checks of the exports, made by the core. */
async function problems(dir, environment, extra) {
  const result = await core.run("calm.problems", {
    architecture: join(dir, "architecture/shop.calm.json"),
    environment,
    ...extra,
  });
  assert.ok("done" in result, result.failed);
  return result.done;
}

function runLaws(dir, environment) {
  const output = ironframe(dir, [
    "run", "-e", environment, "--app", "adoptions-service", "--dir", "../app", "--",
    "sh", "-c", 'npx --no-install lawspec test --attestation "$IRONFRAME_ATTESTATION" --seed 7 --fresh',
  ]);
  assert.equal(output.status, 0, `the shop's laws failed in environment ${environment}`);
  const path = attestationPath(output);
  const attestation = JSON.parse(readFileSync(path, "utf8"));
  assert.equal(attestation.execution.status, "completed");
  assert.equal(attestation.execution.exit_code, 0);
  assert.ok(attestation.architecture.digest.startsWith("sha256:") && attestation.architecture.topology_digest);
  assert.equal(attestation.application.node, "adoptions-service");
  for (const [ability, kind] of expectedKinds(environment)) {
    const record = attestation.dependencies.find((d) => d.name === ability);
    assert.equal(record.kind, kind, `${ability} in ${environment}`);
    assert.equal(record.implementation.kind, kind === "real" ? "real-provider" : "fixture");
    assert.ok(record.completed.reached);
    assert.equal(record.completed.history_digest !== undefined, kind === "stand-in");
  }
  // LawSpec 0.26 reads the completed attestation. With the pin moved to a
  // release that consumes completed runs, plannedAgainst becomes against and
  // plannedEnvironmentRun becomes environmentRun with environmentOutcome.
  const evidence = exec("npx", ["--no-install", "lawspec", "evidence", "--attestation", path, "--json"], join(dir, "app"));
  assert.equal(evidence.status, 0);
  const obligations = JSON.parse(evidence.stdout);
  const native = obligations.filter((o) => o.stage === "law" && Array.isArray(o.plannedAgainst) && o.plannedAgainst.length > 0);
  assert.equal(native.length, 4, "every law relies on a native handler");
  for (const obligation of native) {
    assert.equal(obligation.status, "property-tested");
    assert.equal(obligation.plannedEnvironmentRun.id, attestation.run.id);
    for (const dependency of obligation.plannedAgainst) {
      const [, kind] = expectedKinds(environment).find(([ability]) => dependency.dependency === ability);
      assert.equal(dependency.kind, kind === "real" ? "real" : "stand-in");
    }
  }
  // Without the file, LawSpec links each law to the run it last passed in.
  const linked = JSON.parse(exec("npx", ["--no-install", "lawspec", "evidence", "--json"], join(dir, "app")).stdout);
  assert.ok(linked.filter((o) => o.stage === "law" && Array.isArray(o.against)).every((o) => o.environmentRun.id === attestation.run.id));
  return attestation;
}

/** Waits until an HTTP API answers a request for a pet with any status line. */
async function waitForHttp(base) {
  const url = new URL(base);
  const port = Number(url.port || 80);
  const path = `${url.pathname.replace(/\/$/, "")}/pet/1`;
  for (let i = 0; i < 120; i++) {
    const status = await new Promise((resolve) => {
      const socket = connect(port, url.hostname, () =>
        socket.write(`GET ${path} HTTP/1.1\r\nHost: ${url.hostname}\r\nConnection: close\r\n\r\n`),
      );
      let response = "";
      socket.setEncoding("utf8");
      socket.on("data", (c) => (response += c));
      socket.on("end", () => resolve(response.slice(0, 12)));
      socket.on("error", () => resolve(""));
    });
    if (status === "HTTP/1.1 200" || status === "HTTP/1.1 404") return;
    await new Promise((r) => setTimeout(r, 500));
  }
  assert.fail(`${base} never answered`);
}

function shop(dir, args, env = {}) {
  return exec(join(dir, "app/shop-bin"), args, join(dir, "app"), env);
}

function deterministicReplay(dir, environment, twins) {
  const digests = [];
  for (let round = 0; round < 2; round++) {
    for (const twin of twins) succeeds(dir, ["twin", twin, "-e", environment, "reset"]);
    assert.equal(shop(dir, ["rex", "ada"], { SHOP_PET_ID_BASE: "1000" }).status, 0);
    digests.push(twins.map((twin) => succeeds(dir, ["twin", twin, "-e", environment, "history"])));
    for (const twin of twins) succeeds(dir, ["twin", twin, "-e", environment, "replay"]);
  }
  assert.deepEqual(digests[0], digests[1], "the same seed and requests give the same history");
  assert.ok(digests[0].every((h) => h.trim() !== ""));
}

function faultAndRecover(dir, environment, twin, fault) {
  succeeds(dir, ["twin", twin, "-e", environment, "fault", ...fault]);
  assert.notEqual(shop(dir, ["rex", "ada"]).status, 0, `the shop should fail under ${fault}`);
  succeeds(dir, ["twin", twin, "-e", environment, "fault", "clear"]);
  assert.equal(shop(dir, ["rex", "ada"]).status, 0, `the shop should recover once ${fault} is cleared`);
}

function calmOnPath() {
  if (process.env.IRONFRAME_CALM) return true;
  return spawnSync("sh", ["-c", "command -v calm"], { encoding: "utf8" }).status === 0;
}

test("the same application runs against real, twin and mixed bindings", { skip, timeout: 3_600_000 }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "ironframe-e2e-calm-"));
  copyTree(join(repo, "examples/calm-shop"), dir);
  const laws = lawsDigest(dir);
  try {
    // Validation and every export work without deploying anything.
    const validated = succeeds(dir, ["validate"]);
    for (const environment of ["twin", "real", "mixed", "staging"]) assert.ok(validated.includes(`environment ${environment}: resolved`));
    if (calmOnPath()) {
      assert.match(succeeds(dir, ["validate", "--calm-cli"]), /calm validate: passed/);
      const diagram = succeeds(dir, ["export", "diagram", "-e", "mixed", "--format", "calm-template"]);
      assert.ok(diagram.includes("```mermaid") && diagram.includes("real apache/kafka 4.1.0"));
    }
    const root = succeeds(dir, ["export", "tofu", "-e", "staging"]);
    assert.deepEqual((await problems(dir, "staging", { tofu: root })).tofu, []);
    for (const environment of ["twin", "real", "mixed"]) {
      const diagram = succeeds(dir, ["export", "diagram", "-e", environment]);
      assert.deepEqual((await problems(dir, environment, { mermaid: diagram })).mermaid, []);
      for (const app of ["adoptions-service", "adoptions-audit"]) {
        const settings = JSON.stringify(exportedSettings(dir, environment, app));
        assert.deepEqual((await problems(dir, environment, { app, settings })).settings, []);
      }
    }

    // Unresolved and incompatible bindings are refused by name.
    const decoratorsPath = join(dir, "architecture/shop.decorators.json");
    const original = readFileSync(decoratorsPath, "utf8");
    const changed = JSON.parse(original);
    for (const decorator of changed.decorators) {
      if (decorator["unique-id"] === "adoptions-log-twin") decorator.data.twin["stands-in-for"].version = "0.9.0";
      if (decorator["unique-id"] === "pet-registry-twin") decorator["applies-to"] = ["pet-registri"];
    }
    writeFileSync(decoratorsPath, JSON.stringify(changed, null, 2));
    const refused = ironframe(dir, ["resolve", "--env", "twin"]);
    assert.notEqual(refused.status, 0);
    for (const needle of ["adoptions-log-twin", "0.9.0", "incompatible", "pet-registri", "pet-registry", "unresolved"])
      assert.ok(refused.stderr.includes(needle), `the refusal names ${needle}`);
    writeFileSync(decoratorsPath, original);

    // The shop's generated code and executable.
    assert.equal(exec("npm", ["ci", "--no-audit", "--no-fund"], join(dir, "app")).status, 0);
    assert.equal(exec("npx", ["--no-install", "lawspec", "generate"], join(dir, "app")).status, 0);
    assert.equal(exec("go", ["build", "-o", "shop-bin", "./cmd/shop"], join(dir, "app")).status, 0);
    // The static Linux executable the managed image holds, for podman's own architecture.
    const goarch = arch() === "arm64" ? "arm64" : "amd64";
    assert.equal(exec("go", ["build", "-o", "shop-linux", "./cmd/shop"], join(dir, "app"), { GOOS: "linux", GOARCH: goarch, CGO_ENABLED: "0" }).status, 0);

    for (const environment of ["twin", "real", "mixed"]) {
      const output = ironframe(dir, ["up", environment, "--wait", "180"]);
      try {
        assert.equal(output.status, 0, `ironframe up ${environment} failed`);

        // The Petstore answers once its server has deployed, which may be after its port opens.
        await waitForHttp(exportedSettings(dir, environment, "adoptions-service").PETSTORE_URL);

        // The injected settings are the topology's: the synced .env holds what export says.
        const dotenv = readFileSync(join(dir, "app/.env"), "utf8");
        for (const [key, value] of Object.entries(exportedSettings(dir, environment, "adoptions-service")))
          assert.ok(dotenv.includes(`${key}=${value}\n`), `${key} in ${environment}`);

        // The unchanged laws, run under ironframe and read by LawSpec.
        runLaws(dir, environment);
        assert.equal(lawsDigest(dir), laws, "no binding changes the laws");

        // The audit, a managed application, reads what the service published on the shared log.
        const audit = ironframe(dir, ["app", "adoptions-audit", "-e", environment]);
        assert.equal(audit.status, 0, `the audit failed in ${environment}`);
        const auditAttestation = JSON.parse(readFileSync(attestationPath(audit), "utf8"));
        assert.equal(auditAttestation.dependencies.length, 1);
        assert.equal(auditAttestation.dependencies[0].node, "adoptions-log");
        if (environment === "real") {
          // Here the audit is a managed image, built from its Containerfile when podman lacks it.
          assert.ok(auditAttestation.application.implementation.image_digest?.startsWith("sha256:"));
        }

        // The service as an external deployment: it reads the .env itself, and Ironframe records the run it did not start.
        const begun = succeeds(dir, ["attest", environment, "--app", "adoptions-service"]);
        const file = begun.trim().slice(begun.trim().lastIndexOf("attestation: ") + "attestation: ".length);
        assert.equal(shop(dir, ["rex", "ada"]).status, 0);
        succeeds(dir, ["attest", environment, "--complete", file, "--exit-code", "0"]);
        assert.equal(JSON.parse(readFileSync(resolve(dir, "architecture", file), "utf8")).execution.status, "completed");

        // Faults, resets and deterministic replay through the twins' control planes.
        if (environment === "twin") {
          faultAndRecover(dir, environment, "pet-registry", ["server-error", "status=503"]);
          faultAndRecover(dir, environment, "adoptions-log", ["broker-unavailable"]);
          deterministicReplay(dir, environment, ["adoptions-log", "pet-registry"]);
          // A reset empties the twin's log, so the audit has nothing to read until the service publishes again.
          succeeds(dir, ["twin", "adoptions-log", "-e", environment, "reset"]);
          assert.notEqual(ironframe(dir, ["app", "adoptions-audit", "-e", environment]).status, 0);
          assert.equal(shop(dir, ["rex", "ada"]).status, 0);
          assert.equal(ironframe(dir, ["app", "adoptions-audit", "-e", environment]).status, 0);
        }
        if (environment === "mixed") {
          faultAndRecover(dir, environment, "pet-registry", ["server-error", "status=503"]);
          deterministicReplay(dir, environment, ["pet-registry"]);
          assert.notEqual(ironframe(dir, ["twin", "adoptions-log", "-e", environment, "reset"]).status, 0, "a real dependency has no control plane");
        }
      } finally {
        ironframe(dir, ["down", environment]);
      }
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
