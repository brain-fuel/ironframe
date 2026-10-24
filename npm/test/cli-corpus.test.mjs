// Replays corpus/cli.json through the real command, as the
// Rust capture harness recorded it before the port: each case copies its
// examples into a fresh directory with fake podman and OpenTofu scripts, runs
// its steps, and compares standard output, standard error and exit status of
// each, then the files that changed, with the directory written as /work and
// ids and times as <uuid> and <time>. Skipped while the core has no "cli".
// IRONFRAME_CORPUS_COMMAND replays against another build instead, such as
// the Rust one at target/debug/ironframe.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmod, cp, mkdir, mkdtemp, readdir, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { existsSync, readFileSync } from "node:fs";
import { availableParallelism, tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { loadCore } from "../launcher.mjs";

const repo = fileURLToPath(new URL("../../", import.meta.url));
const bin = fileURLToPath(new URL("../bin/ironframe.mjs", import.meta.url));
const cases = JSON.parse(readFileSync(join(repo, "corpus/cli.json"), "utf8"));
const other = process.env.IRONFRAME_CORPUS_COMMAND;

async function skipReason() {
  if (other) return false;
  if (!existsSync(new URL("../core.wasm", import.meta.url))) return "no core.wasm; run tools/wasm.sh";
  const core = await loadCore();
  const answer = await core({ method: "cli", params: { argv: ["--version"], cwd: "/" }, effects: [] });
  return answer.error === "no such method" ? "the core has no cli yet" : false;
}

const FAKE_PODMAN = `#!/bin/sh
echo "podman $*" >> "$IRONFRAME_FAKE_LOG"
case "$1 $2" in
  "image inspect") echo null ;;
  "ps "*|"ps -a") echo "[]" ;;
esac
exit 0
`;

const FAKE_TOFU = `#!/bin/sh
echo "tofu $*" >> "$IRONFRAME_FAKE_LOG"
case "$2" in
  output) echo '{"adoptions-log": "adoptions.elb.example:9092", "kafka": "kafka.elb.example:9092"}' ;;
esac
exit 0
`;

const BROKEN_PODMAN = `#!/bin/sh
echo "podman $*" >> "$IRONFRAME_FAKE_LOG"
if [ "$1" = compose ]; then echo "Error: looking up compose provider failed" >&2; exit 125; fi
exit 0
`;

/** Lower-case hex in the 8-4-4-4-12 shape, not inside a word, becomes <uuid>. */
export function replaceUuids(text) {
  const c = Array.from(text);
  const hex = (ch) => /^[0-9a-f]$/.test(ch ?? "");
  const alnum = (ch) => /^[0-9A-Za-z]$/.test(ch ?? "");
  let out = "";
  let i = 0;
  while (i < c.length) {
    let j = i;
    let ok = i === 0 || !alnum(c[i - 1]);
    [8, 4, 4, 4, 12].forEach((n, k) => {
      if (!ok) return;
      for (let m = 0; m < n; m++) {
        if (hex(c[j])) j++;
        else {
          ok = false;
          return;
        }
      }
      if (k < 4) {
        if (c[j] === "-") j++;
        else ok = false;
      }
    });
    if (ok) {
      out += "<uuid>";
      i = j;
    } else out += c[i++];
  }
  return out;
}

/** An RFC 3339 time, its fraction and offset included, becomes <time>. */
export function replaceTimes(text) {
  const c = Array.from(text);
  const digit = (i) => /^[0-9]$/.test(c[i] ?? "");
  const at = (i, ch) => c[i] === ch;
  let out = "";
  let i = 0;
  while (i < c.length) {
    const date =
      [0, 1, 2, 3].every((k) => digit(i + k)) && at(i + 4, "-") && digit(i + 5) && digit(i + 6) &&
      at(i + 7, "-") && digit(i + 8) && digit(i + 9) && at(i + 10, "T") && digit(i + 11) && digit(i + 12) &&
      at(i + 13, ":") && digit(i + 14) && digit(i + 15) && at(i + 16, ":") && digit(i + 17) && digit(i + 18);
    if (date) {
      let j = i + 19;
      if (at(j, ".")) {
        j++;
        while (digit(j)) j++;
      }
      if (at(j, "Z")) j++;
      else if ((at(j, "+") || at(j, "-")) && digit(j + 1) && digit(j + 2) && at(j + 3, ":")) j += 6;
      out += "<time>";
      i = j;
      continue;
    }
    out += c[i++];
  }
  return out;
}

function normalise(text, root) {
  return replaceTimes(replaceUuids(text.split(root).join("/work").replaceAll("ironframe 0.2.0", "ironframe 0.1.0").replaceAll('"name": "ironframe",\n    "version": "0.2.0"', '"name": "ironframe",\n    "version": "0.1.0"')));
}

const utf8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });

/** Every file under a directory by relative path, its text or <binary>. */
async function files(root) {
  const found = {};
  async function walk(at) {
    let entries;
    try {
      entries = await readdir(at, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const path = join(at, entry.name);
      if (entry.isDirectory()) await walk(path);
      else {
        let text;
        try {
          text = utf8.decode(await readFile(path));
        } catch {
          text = "<binary>";
        }
        found[path.slice(root.length + 1)] = text;
      }
    }
  }
  await walk(root);
  return found;
}

/** Copies an example as the recorder did: no hidden entries, src or Cargo.toml, nor the Node port of the app that came later. */
async function copyExample(from, to) {
  await cp(from, to, {
    recursive: true,
    filter: (source) => {
      if (source === from) return true;
      const name = source.slice(source.lastIndexOf("/") + 1);
      return !(name.startsWith(".") || name === "src" || name === "Cargo.toml" || name === "app.mjs");
    },
  });
}

function execute(args, cwd, env) {
  const [program, prefix] = other ? [other, []] : [process.execPath, [bin]];
  return new Promise((resolve, reject) => {
    const child = spawn(program, [...prefix, ...args], { cwd, env, stdio: ["ignore", "pipe", "pipe"] });
    const stdout = [];
    const stderr = [];
    child.stdout.on("data", (chunk) => stdout.push(chunk));
    child.stderr.on("data", (chunk) => stderr.push(chunk));
    child.on("error", reject);
    child.on("close", (code) =>
      resolve({ stdout: Buffer.concat(stdout).toString("utf8"), stderr: Buffer.concat(stderr).toString("utf8"), code }),
    );
  });
}

async function replay(item) {
  const root = await realpath(await mkdtemp(join(tmpdir(), "ironframe-cli-")));
  try {
    for (const example of item.input.examples) {
      const [from, to] =
        example === "calm-shop" ? ["examples/calm-shop/architecture", "calm-shop/architecture"] : [`examples/${example}`, example];
      await copyExample(join(repo, from), join(root, to));
    }
    const tools = join(root, ".tools");
    await mkdir(tools, { recursive: true });
    for (const [name, script] of [["podman", FAKE_PODMAN], ["tofu", FAKE_TOFU], ["broken-podman", BROKEN_PODMAN]]) {
      await writeFile(join(tools, name), script);
      await chmod(join(tools, name), 0o755);
    }
    const before = await files(root);
    const steps = [];
    for (const step of item.input.steps) {
      const env = { ...process.env };
      delete env.IRONFRAME_CALM;
      delete env.FORCE_COLOR;
      Object.assign(env, {
        PATH: "/usr/bin:/bin",
        IRONFRAME_PODMAN: join(tools, "podman"),
        IRONFRAME_TOFU: join(tools, "tofu"),
        IRONFRAME_FAKE_LOG: join(tools, "log"),
        NO_COLOR: "1",
      });
      for (const [key, value] of Object.entries(step.env)) env[key] = value.split("$ROOT").join(root);
      const output = await execute(step.args, join(root, step.cwd), env);
      steps.push({ stdout: normalise(output.stdout, root), stderr: normalise(output.stderr, root), code: output.code });
    }
    const after = await files(root);
    const changed = {};
    for (const path of Object.keys(after).sort())
      if (before[path] !== after[path]) changed[normalise(path, root)] = normalise(after[path], root);
    return { steps, files: changed };
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

const skip = await skipReason();

test("corpus/cli.json", { skip, concurrency: availableParallelism() }, async (t) => {
  await Promise.all(
    cases.map((item) =>
      t.test(item.name, async () => {
        const actual = await replay(item);
        item.expected.steps.forEach((expected, index) => {
          const step = actual.steps[index];
          const where = `${item.name} step ${index + 1}: ironframe ${item.input.steps[index].args.join(" ")}`;
          const arguments_ = item.input.steps[index].args;
          const schema = arguments_.includes('schema') && ({attestation: 'attestation-v1.schema.json', contract: 'calm/ironframe-contract.decorator.schema.json', binding: 'calm/ironframe-binding.decorator.schema.json'})[arguments_.at(-1)];
          const stdout = schema ? readFileSync(join(repo, 'schema', schema), 'utf8') : expected.stdout;
          assert.equal(step.stdout, stdout, `${where}: standard output`);
          assert.equal(step.stderr, expected.stderr, `${where}: standard error`);
          assert.equal(step.code, expected.code, `${where}: exit status`);
        });
        assert.deepEqual(actual.files, item.expected.files, `${item.name}: changed files`);
      }),
    ),
  );
});
