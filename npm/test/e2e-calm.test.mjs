// End to end, the CALM chain with podman, LawTwin's images, the real products
// and LawSpec 0.29.2: the calm-shop architecture is validated and exported
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
// The example's pinned LawSpec consumes completed-run attestations;
// IRONFRAME_LAWSPEC_PACKAGE may name a local npm archive when checking the
// integration against an unpublished LawSpec build, which must too. IRONFRAME_E2E_ARTIFACTS retains the evidence and
// exports without retaining installed dependencies. ref:REQ-calm-end-to-end
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, existsSync, copyFileSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { connect } from "node:net";
import { arch, tmpdir } from "node:os";
import { join, resolve, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { createIronframe } from "../api.mjs";

const repo = fileURLToPath(new URL("../../", import.meta.url));
const bin = join(repo, "npm/bin/ironframe.mjs");
const artifacts = process.env.IRONFRAME_E2E_ARTIFACTS && resolve(process.env.IRONFRAME_E2E_ARTIFACTS);
/** Keeps reviewable outputs when an artifact directory is requested. */
function retain(name, value) {
  if (!artifacts) return;
  mkdirSync(artifacts, { recursive: true });
  writeFileSync(join(artifacts, name), typeof value === "string" ? value : JSON.stringify(value, null, 2) + "\n");
}
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
  return createHash("sha256").update(readFileSync(join(dir, "app/spec/shop.lawspec"))).digest("hex");
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
  const architecture = join(dir, "architecture");
  const digest = (value) => `sha256:${createHash("sha256").update(value).digest("hex")}`;
  assert.equal(attestation.architecture.digest, digest(readFileSync(join(architecture, "shop.calm.json"))));
  assert.equal(attestation.architecture.decorators_digest, digest(readFileSync(join(architecture, "shop.decorators.json"))));
  const topology = JSON.parse(readFileSync(join(architecture, ".ironframe", environment, "topology.json"), "utf8"));
  assert.equal(attestation.architecture.topology_digest, digest(JSON.stringify(topology)), "the attestation names the exported topology");
  assert.equal(attestation.application.node, "adoptions-service");
  for (const [ability, kind] of expectedKinds(environment)) {
    const record = attestation.dependencies.find((d) => d.name === ability);
    assert.equal(record.kind, kind, `${ability} in ${environment}`);
    assert.equal(record.implementation.kind, kind === "real" ? "real-provider" : "fixture");
    assert.ok(record.completed.reached);
    assert.equal(record.completed.history_digest !== undefined, kind === "stand-in");
  }
  retain(`${environment}-laws-attestation.json`, attestation);
  /** Checks execution linkage separately from the native property result. */
  function checkEvidence(obligations) {
    const native = obligations.filter((o) => o.stage === "law" && Array.isArray(o.against) && o.against.length > 0);
    assert.equal(native.length, 4, "every native law has completed-run evidence");
    for (const obligation of native) {
      assert.equal(obligation.status, "property-tested");
      assert.equal(obligation.plannedAgainst, undefined);
      assert.equal(obligation.environmentRun.id, attestation.run.id);
      assert.equal(obligation.environmentRun.execution.status, "completed");
      assert.equal(obligation.environmentRun.execution.exitCode, 0);
      assert.equal(obligation.environmentOutcome, "passed");
      for (const dependency of obligation.against) {
        const [, kind] = expectedKinds(environment).find(([ability]) => dependency.dependency === ability);
        const record = attestation.dependencies.find((d) => d.name === dependency.dependency);
        assert.equal(dependency.kind, kind);
        assert.equal(dependency.ranAgainst.provider, record.implementation.kind);
        if (kind === "stand-in") {
          assert.equal(dependency.ranAgainst.historyDigest, record.completed.history_digest);
          assert.equal(dependency.ranAgainst.historyFrom, "completed");
        }
      }
    }
  }
  const evidence = exec("npx", ["--no-install", "lawspec", "evidence", "--attestation", path, "--json"], join(dir, "app"));
  assert.equal(evidence.status, 0);
  retain(`${environment}-evidence.json`, evidence.stdout);
  checkEvidence(JSON.parse(evidence.stdout));
  // Without the completed file, the cache still holds the running snapshot
  // captured by the child. Keep that wiring planned, with no completion claim.
  const linked = exec("npx", ["--no-install", "lawspec", "evidence", "--json"], join(dir, "app"));
  assert.equal(linked.status, 0);
  retain(`${environment}-linked-evidence.json`, linked.stdout);
  const planned = JSON.parse(linked.stdout).filter((o) => o.stage === "law" && o.plannedAgainst?.length);
  assert.equal(planned.length, 4, "all native laws retain their running snapshot");
  for (const obligation of planned) {
    assert.equal(obligation.status, "property-tested");
    assert.equal(obligation.against, undefined);
    assert.equal(obligation.environmentOutcome, undefined);
    assert.equal(obligation.plannedEnvironmentRun.id, attestation.run.id);
    assert.equal(obligation.plannedEnvironmentRun.execution.status, "running");
  }
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
    digests.push(twins.map((twin) => {
      const history = succeeds(dir, ["twin", twin, "-e", environment, "history"]);
      retain(`${environment}-${twin}-replay-${round}.json`, history);
      return history;
    }));
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

/** The whole CALM chain, environment by environment. ref:REQ-calm-end-to-end */
async function theChainRunsInEveryBinding() {
  const dir = mkdtempSync(join(tmpdir(), "ironframe-e2e-calm-"));
  copyTree(join(repo, "examples/calm-shop"), dir);
  const laws = lawsDigest(dir);
  // A separate repository prefix selects locally built fixtures while keeping
  // their declared release and stands-in-for contract identities intact.
  const twinPrefix = process.env.IRONFRAME_TWIN_IMAGE_PREFIX;
  const appImage = process.env.IRONFRAME_APP_IMAGE;
  const httpPort = process.env.IRONFRAME_E2E_HTTP_PORT ? Number(process.env.IRONFRAME_E2E_HTTP_PORT) : null;
  if (httpPort) assert.ok(Number.isInteger(httpPort) && httpPort > 0 && httpPort <= 65535);
  {
    const file = join(dir, "architecture/shop.decorators.json");
    const document = JSON.parse(readFileSync(file, "utf8"));
    for (const decorator of document.decorators) {
      if (decorator.data.project) decorator.data.project += '-' + basename(dir).toLowerCase();
      const twin = decorator.data.twin;
      if (twin && twinPrefix) twin.image = `${twinPrefix}/${twin.image.split("/").at(-1)}`;
      if (httpPort) for (const binding of [decorator.data.real, twin]) {
        if (binding?.endpoint?.includes('localhost:8080')) binding.endpoint = binding.endpoint.replace('localhost:8080', 'localhost:' + httpPort);
      }
      const managed = decorator.data.application?.managed?.image;
      if (managed && appImage) managed.image = appImage;
    }
    writeFileSync(file, JSON.stringify(document, null, 2) + "\n");
  }
  try {
    // Validation and every export work without deploying anything.
    const validated = succeeds(dir, ["validate"]);
    for (const environment of ["twin", "real", "mixed", "staging"]) assert.ok(validated.includes(`environment ${environment}: resolved`));
    if (calmOnPath()) {
      assert.match(succeeds(dir, ["validate", "--calm-cli"]), /calm validate: passed/);
      const diagram = succeeds(dir, ["export", "diagram", "-e", "mixed", "--format", "calm-template"]);
      retain("calm-tool-diagram.md", diagram);
      assert.ok(diagram.includes("```mermaid") && diagram.includes("real apache/kafka 4.1.0"));
    }
    const root = succeeds(dir, ["export", "tofu", "-e", "staging"]);
    retain("staging.tf.json", root);
    assert.deepEqual((await problems(dir, "staging", { tofu: root })).tofu, []);
    const changedRoot = JSON.parse(root);
    const deployment = changedRoot.module.twin_adoptions_log;
    assert.equal(deployment.image, twinPrefix ? `${twinPrefix}/kafka:0.1.0` : "docker.io/lawtwin/kafka:0.1.0");
    assert.deepEqual(deployment.ports, [9092]);
    assert.equal(JSON.parse(deployment.environment.TWIN_CONFIG).seed, 42);
    assert.deepEqual(changedRoot.output.endpoints.value, { "adoptions-log": "${module.twin_adoptions_log.endpoint}" });
    assert.deepEqual(Object.keys(changedRoot.module), ["twin_adoptions_log"]);
    delete changedRoot.module.twin_adoptions_log;
    assert.ok((await problems(dir, "staging", { tofu: JSON.stringify(changedRoot) })).tofu.length > 0);
    for (const environment of ["twin", "real", "mixed"]) {
      const diagram = succeeds(dir, ["export", "diagram", "-e", environment]);
      retain(`${environment}-diagram.mmd`, diagram);
      assert.deepEqual((await problems(dir, environment, { mermaid: diagram })).mermaid, []);
      const missingEdges = diagram.split("\n").filter((line) => !line.includes(" -->|")).join("\n");
      assert.ok((await problems(dir, environment, { mermaid: missingEdges })).mermaid.length > 0);
      for (const app of ["adoptions-service", "adoptions-audit"]) {
        const settings = JSON.stringify(exportedSettings(dir, environment, app));
        retain(`${environment}-${app}-settings.json`, settings);
        assert.deepEqual((await problems(dir, environment, { app, settings })).settings, []);
        const missingSetting = JSON.parse(settings);
        delete missingSetting.KAFKA_BOOTSTRAP_SERVERS;
        assert.ok((await problems(dir, environment, { app, settings: JSON.stringify(missingSetting) })).settings.length > 0);
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
    if (process.env.IRONFRAME_LAWSPEC_PACKAGE) {
      const archive = resolve(process.env.IRONFRAME_LAWSPEC_PACKAGE);
      assert.equal(exec("npm", ["install", "--no-save", "--package-lock=false", "--no-audit", "--no-fund", archive], join(dir, "app")).status, 0);
    } else {
      assert.equal(exec("npm", ["ci", "--no-audit", "--no-fund"], join(dir, "app")).status, 0);
    }
    retain("lawspec-build.json", readFileSync(join(dir, "app/node_modules/lawspec/build.json"), "utf8"));
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
        retain(`${environment}-managed-attestation.json`, auditAttestation);
        assert.equal(auditAttestation.execution.status, "completed");
        assert.equal(auditAttestation.execution.exit_code, 0);
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
        const external = JSON.parse(readFileSync(resolve(dir, "architecture", file), "utf8"));
        assert.equal(external.execution.status, "completed");
        assert.equal(external.execution.exit_code, 0);
        retain(`${environment}-external-attestation.json`, external);

        // Faults, resets and deterministic replay through the twins' control planes.
        if (environment === "twin") {
          faultAndRecover(dir, environment, "pet-registry", ["server-error", "status=503"]);
          faultAndRecover(dir, environment, "adoptions-log", ["broker-unavailable"]);
          deterministicReplay(dir, environment, ["adoptions-log", "pet-registry"]);
          // A reset empties the twin's log, so the audit has nothing to read until the service publishes again.
          succeeds(dir, ["twin", "adoptions-log", "-e", environment, "reset"]);
          const emptyAudit = ironframe(dir, ["app", "adoptions-audit", "-e", environment]);
          assert.notEqual(emptyAudit.status, 0);
          const failed = JSON.parse(readFileSync(attestationPath(emptyAudit), "utf8"));
          assert.equal(failed.execution.status, "completed");
          assert.notEqual(failed.execution.exit_code, 0);
          retain("twin-empty-audit-attestation.json", failed);
          assert.equal(shop(dir, ["rex", "ada"]).status, 0);
          assert.equal(ironframe(dir, ["app", "adoptions-audit", "-e", environment]).status, 0);
        }
        if (environment === "mixed") {
          faultAndRecover(dir, environment, "pet-registry", ["server-error", "status=503"]);
          deterministicReplay(dir, environment, ["pet-registry"]);
          assert.notEqual(ironframe(dir, ["twin", "adoptions-log", "-e", environment, "reset"]).status, 0, "a real dependency has no control plane");
        }
      } finally {
        assert.equal(ironframe(dir, ["down", environment]).status, 0, `teardown ${environment}`);
      }
    }
  } finally {
    if (artifacts) {
      for (const name of ["architecture", "app/.lawspec", "app/spec", "app/.env"]) {
        const from = join(dir, name);
        if (existsSync(from)) cpSync(from, join(artifacts, "run", name), { recursive: true });
      }
      retain("laws-sha256.txt", `${lawsDigest(dir)}\n`);
    }
    rmSync(dir, { recursive: true, force: true });
  }
}

test("the same application runs against real, twin and mixed bindings", { skip, timeout: 3_600_000 }, theChainRunsInEveryBinding);
