// The host's effects against the real file system, processes and sockets.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, readdir, realpath, writeFile, chmod, rm } from "node:fs/promises";
import { createServer as createTcpServer } from "node:net";
import { createServer as createHttpServer } from "node:http";
import { EventEmitter } from "node:events";
import { constants, tmpdir } from "node:os";
import { join } from "node:path";
import { createHost, temporaryPath, tcpReachable } from "../host.mjs";
import { osErrorText, errorText } from "../errors.mjs";

const darwin = process.platform === "darwin";
const enoent = `No such file or directory (os error ${constants.errno.ENOENT})`;

async function scratch() {
  return realpath(await mkdtemp(join(tmpdir(), "ironframe-host-")));
}

function collector() {
  const chunks = [];
  return { chunks, write: (text, done) => (chunks.push(String(text)), done && done(), true) };
}

test("error texts read as Rust's io::Error Display", () => {
  assert.equal(osErrorText("ENOENT"), enoent);
  assert.equal(osErrorText("ECONNREFUSED"), `Connection refused (os error ${constants.errno.ECONNREFUSED})`);
  if (darwin) assert.equal(osErrorText("ECONNREFUSED"), "Connection refused (os error 61)");
  assert.equal(errorText(Object.assign(new Error("x"), { code: "EACCES" })), `Permission denied (os error ${constants.errno.EACCES})`);
  assert.match(errorText(Object.assign(new Error("x"), { code: "ENOTFOUND" })), /^failed to lookup address information: /);
  assert.equal(errorText(new Error("plain")), "plain");
});

test("readFile gives the exact text, or the reason with notFound", async () => {
  const dir = await scratch();
  const host = createHost();
  await writeFile(join(dir, "a.txt"), "﻿héllo\n");
  assert.deepEqual(await host.perform({ effect: "readFile", path: join(dir, "a.txt") }), { ok: "﻿héllo\n" });
  assert.deepEqual(await host.perform({ effect: "readFile", path: join(dir, "missing") }), { error: enoent, notFound: true });
  await writeFile(join(dir, "bad"), Buffer.from([0xff, 0xfe, 0x00]));
  assert.deepEqual(await host.perform({ effect: "readFile", path: join(dir, "bad") }), { error: "stream did not contain valid UTF-8" });
  const directory = await host.perform({ effect: "readFile", path: dir });
  assert.equal(directory.error, `Is a directory (os error ${constants.errno.EISDIR})`);
  assert.equal(directory.notFound, undefined);
});

test("writeAtomically creates the directory, writes through a temporary file and skips equal content", async () => {
  const dir = await scratch();
  const host = createHost();
  const path = join(dir, "deep", "er", "settings.json");
  assert.deepEqual(await host.perform({ effect: "writeAtomically", path, text: "{}\n" }), { ok: true });
  assert.equal(await readFile(path, "utf8"), "{}\n");
  assert.deepEqual(await host.perform({ effect: "writeAtomically", path, text: "{}\n" }), { ok: false });
  assert.deepEqual(await host.perform({ effect: "writeAtomically", path, text: "{\"a\":1}\n" }), { ok: true });
  assert.deepEqual(await readdir(join(dir, "deep", "er")), ["settings.json"]);
  assert.equal(temporaryPath("/x/settings.json"), "/x/settings.json.tmp");
  assert.equal(temporaryPath("/x/Makefile"), "/x/Makefile..tmp");
  assert.equal(temporaryPath("/x/.env"), "/x/.env..tmp");
});

test("writeFile, removeFile, createDir and canonicalize", async () => {
  const dir = await scratch();
  const host = createHost();
  assert.deepEqual(await host.perform({ effect: "writeFile", path: join(dir, "no", "f"), text: "x" }), { error: enoent, notFound: true });
  assert.deepEqual(await host.perform({ effect: "createDir", path: join(dir, "a", "b") }), { ok: null });
  assert.deepEqual(await host.perform({ effect: "createDir", path: join(dir, "a", "b") }), { ok: null });
  assert.deepEqual(await host.perform({ effect: "writeFile", path: join(dir, "a", "b", "f"), text: "x" }), { ok: null });
  assert.deepEqual(await host.perform({ effect: "canonicalize", path: join(dir, "a", "..", "a", "b", "f") }), { ok: join(dir, "a", "b", "f") });
  assert.deepEqual(await host.perform({ effect: "removeFile", path: join(dir, "a", "b", "f") }), { ok: null });
  assert.deepEqual(await host.perform({ effect: "removeFile", path: join(dir, "a", "b", "f") }), { error: enoent, notFound: true });
  assert.deepEqual(await host.perform({ effect: "canonicalize", path: join(dir, "nope") }), { error: enoent, notFound: true });
});

test("cwd, env, tempDir and processId", async () => {
  const proc = { cwd: () => "/somewhere", env: { SET: "v", EMPTY: "", TMPDIR: "/var/t/" }, pid: 42 };
  const host = createHost({ process: proc });
  assert.deepEqual(await host.perform({ effect: "cwd" }), { ok: "/somewhere" });
  assert.deepEqual(await host.perform({ effect: "env", name: "SET" }), { ok: "v" });
  assert.deepEqual(await host.perform({ effect: "env", name: "EMPTY" }), { ok: "" });
  assert.deepEqual(await host.perform({ effect: "env", name: "UNSET" }), { ok: null });
  assert.deepEqual(await host.perform({ effect: "tempDir" }), { ok: "/var/t/" });
  assert.deepEqual(await createHost({ process: { env: {} } }).perform({ effect: "tempDir" }), { ok: "/tmp" });
  assert.deepEqual(await host.perform({ effect: "processId" }), { ok: 42 });
});

test("readStdin reads all of standard input", async () => {
  const stdin = (async function* () {
    yield Buffer.from("one\n");
    yield Buffer.from("two");
  })();
  assert.deepEqual(await createHost({ process: { env: {}, stdin } }).perform({ effect: "readStdin" }), { ok: "one\ntwo" });
});

test("locate: the variable, then PATH, then the fallbacks", async () => {
  const dir = await scratch();
  await mkdir(join(dir, "bin1"));
  await mkdir(join(dir, "bin2"));
  await mkdir(join(dir, "bin1", "tool"));
  await writeFile(join(dir, "bin2", "tool"), "");
  await writeFile(join(dir, "fallback"), "");
  const locate = (env, names, fallbacks) =>
    createHost({ process: { env } }).perform({ effect: "locate", variable: "TOOL", names, fallbacks });
  const path = `${dir}/bin1:${dir}/bin2`;
  assert.deepEqual(await locate({ TOOL: "/given", PATH: path }, ["tool"], []), { ok: "/given" });
  assert.deepEqual(await locate({ TOOL: "", PATH: path }, ["tool"], []), { ok: `${dir}/bin2/tool` });
  assert.deepEqual(await locate({ PATH: path }, ["nope", "tool"], []), { ok: `${dir}/bin2/tool` });
  assert.deepEqual(await locate({ PATH: path }, ["nope"], [join(dir, "missing"), join(dir, "fallback")]), { ok: join(dir, "fallback") });
  assert.deepEqual(await locate({ PATH: path }, ["nope"], [join(dir, "bin1")]), { ok: null });
});

test("run captures output and status with standard input closed", async () => {
  const host = createHost();
  const result = await host.perform({ effect: "run", program: "sh", args: ["-c", "cat; echo out; echo err >&2; exit 3"], stream: false });
  assert.deepEqual(result, { ok: { success: false, code: 3, stdout: "out\n", stderr: "err\n" } });
  const fine = await host.perform({ effect: "run", program: "sh", args: ["-c", "printf ok"], stream: false });
  assert.deepEqual(fine, { ok: { success: true, code: 0, stdout: "ok", stderr: "" } });
});

test("run adds environment, sets the directory and streams without capturing", async () => {
  const dir = await scratch();
  const host = createHost();
  const result = await host.perform({
    effect: "run",
    program: "sh",
    args: ["-c", "pwd; echo $IRONFRAME_TEST_VALUE; test -n \"$PATH\" && echo has-path"],
    stream: false,
    cwd: dir,
    env: { IRONFRAME_TEST_VALUE: "added" },
  });
  assert.deepEqual(result.ok, { success: true, code: 0, stdout: `${dir}\nadded\nhas-path\n`, stderr: "" });
  const streamed = await host.perform({ effect: "run", program: "sh", args: ["-c", "exit 4"], stream: true, inheritStdin: true, env: {} });
  assert.deepEqual(streamed, { ok: { success: false, code: 4, stdout: "", stderr: "" } });
});

test("run reports a program that cannot start in Rust's words", async () => {
  const host = createHost();
  assert.deepEqual(
    await host.perform({ effect: "run", program: "/no/such/program-xyz", args: [], stream: false }),
    { error: enoent, notFound: true },
  );
  assert.deepEqual(
    await host.perform({ effect: "run", program: "no-such-program-xyz", args: [], stream: true, inheritStdin: true, env: {} }),
    { error: enoent, notFound: true },
  );
  const dir = await scratch();
  await writeFile(join(dir, "plain"), "not a program");
  await chmod(join(dir, "plain"), 0o644);
  assert.deepEqual(
    await host.perform({ effect: "run", program: join(dir, "plain"), args: [], stream: false }),
    { error: `Permission denied (os error ${constants.errno.EACCES})` },
  );
});

function listen(server) {
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server.address().port)));
}

async function freePort() {
  const server = createTcpServer();
  const port = await listen(server);
  await new Promise((resolve) => server.close(resolve));
  return port;
}

test("tcpProbe: open and silent or speaking counts, closed or reset does not", async (t) => {
  const sockets = new Set();
  const holding = createTcpServer((socket) => sockets.add(socket));
  const speaking = createTcpServer((socket) => socket.write("x"));
  const closing = createTcpServer((socket) => socket.end());
  const resetting = createTcpServer((socket) => socket.resetAndDestroy());
  const ports = {
    holding: await listen(holding),
    speaking: await listen(speaking),
    closing: await listen(closing),
    resetting: await listen(resetting),
    refused: await freePort(),
  };
  t.after(() => {
    for (const socket of sockets) socket.destroy();
    for (const server of [holding, speaking, closing, resetting]) server.close();
  });
  const probe = (host, port, timeoutMs = 1000) =>
    createHost().perform({ effect: "tcpProbe", endpoint: `${host}:${port}`, host, port, timeoutMs });
  assert.deepEqual(await probe("127.0.0.1", ports.holding), { ok: true });
  assert.deepEqual(await probe("localhost", ports.holding), { ok: true });
  assert.deepEqual(await probe("127.0.0.1", ports.speaking), { ok: true });
  assert.deepEqual(await probe("127.0.0.1", ports.closing), { ok: false });
  assert.deepEqual(await probe("127.0.0.1", ports.resetting), { ok: false });
  assert.deepEqual(await probe("127.0.0.1", ports.refused), { ok: false });
  assert.deepEqual(await probe("no-such-host.invalid", ports.holding), { ok: false });
  assert.deepEqual(await probe("127.0.0.1", ports.holding, 0), { ok: false });
});

test("tcpProbe tries every address and times out an unanswered connect", async () => {
  const attempts = [];
  const net = {
    lookup: async () => [{ address: "10.0.0.1", family: 4 }, { address: "10.0.0.2", family: 4 }],
    connect: ({ host }) => {
      attempts.push(host);
      // A connection that never opens.
      return Object.assign(new EventEmitter(), { destroy() {} });
    },
  };
  const started = performance.now();
  assert.equal(await tcpReachable(net, "h", 1, 50), false);
  assert.deepEqual(attempts, ["10.0.0.1", "10.0.0.2"]);
  assert.ok(performance.now() - started >= 90);
});

test("http sends the request and reports the answer or the root cause", async (t) => {
  let seen;
  const server = createHttpServer((request, response) => {
    let body = "";
    request.on("data", (chunk) => (body += chunk));
    request.on("end", () => {
      seen = { method: request.method, url: request.url, type: request.headers["content-type"], body };
      if (request.url === "/slow") setTimeout(() => response.end("late"), 500);
      else {
        response.writeHead(201);
        response.end("answered");
      }
    });
  });
  const port = await listen(server);
  t.after(() => server.close());
  const host = createHost();
  const answer = await host.perform({
    effect: "http",
    method: "POST",
    url: `http://127.0.0.1:${port}/v1/x`,
    headers: { "content-type": "application/json" },
    body: "{}",
    timeoutMs: 2000,
  });
  assert.deepEqual(answer, { ok: { status: 201, body: "answered" } });
  assert.deepEqual(seen, { method: "POST", url: "/v1/x", type: "application/json", body: "{}" });
  const refused = await host.perform({ effect: "http", method: "GET", url: `http://127.0.0.1:${await freePort()}/healthz`, headers: {}, timeoutMs: 2000 });
  assert.deepEqual(refused, { error: osErrorText("ECONNREFUSED") });
  const slow = await host.perform({ effect: "http", method: "GET", url: `http://127.0.0.1:${port}/slow`, headers: {}, timeoutMs: 100 });
  assert.deepEqual(slow, { error: "operation timed out" });
});

test("print writes as is, progress prefixes the command's name", async () => {
  const stdout = collector();
  const stderr = collector();
  const host = createHost({ process: { env: {}, stdout, stderr } });
  assert.deepEqual(await host.perform({ effect: "print", stream: "stdout", text: "a\n" }), { ok: null });
  await host.perform({ effect: "print", stream: "stderr", text: "b" });
  await host.perform({ effect: "progress", text: "starting kafka" });
  assert.deepEqual(stdout.chunks, ["a\n"]);
  assert.deepEqual(stderr.chunks, ["b", "ironframe: starting kafka\n"]);
});

test("time, sleep and identifiers", async () => {
  const host = createHost();
  const before = Date.now();
  const { ok: now } = await host.perform({ effect: "now" });
  assert.ok(Number.isInteger(now.seconds) && Number.isInteger(now.nanos));
  assert.ok(now.nanos >= 0 && now.nanos < 1e9);
  assert.ok(Math.abs(now.seconds * 1000 + now.nanos / 1e6 - before) < 1000);
  const first = (await host.perform({ effect: "monotonic" })).ok;
  assert.deepEqual(await host.perform({ effect: "sleep", ms: 30 }), { ok: null });
  const second = (await host.perform({ effect: "monotonic" })).ok;
  assert.ok(Number.isInteger(first) && second - first >= 25);
  assert.match((await host.perform({ effect: "uuid" })).ok, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});

test("cloud effects go to the cloud's adapter; unknown effects are errors", async () => {
  const calls = [];
  const host = createHost({
    clouds: { aws: { findApplication: async (fields) => (calls.push(fields), { ok: "app-1" }) } },
  });
  assert.deepEqual(await host.perform({ effect: "aws.findApplication", region: "eu-west-1", name: "shop" }), { ok: "app-1" });
  assert.deepEqual(calls, [{ region: "eu-west-1", name: "shop" }]);
  assert.match((await host.perform({ effect: "aws.toString" })).error, /does not know the effect/);
  assert.match((await host.perform({ effect: "gcp.parameterExists" })).error, /does not know the effect/);
  assert.match((await host.perform({ effect: "launchRockets" })).error, /does not know the effect/);
});

test("an effect that throws becomes an error result", async () => {
  const dir = await scratch();
  await rm(dir, { recursive: true });
  const host = createHost({ fs: { readFile: async () => { throw new TypeError("boom"); } } });
  assert.deepEqual(await host.perform({ effect: "readFile", path: "x" }), { error: "boom" });
});
