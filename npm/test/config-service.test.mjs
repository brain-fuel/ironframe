// The configuration service's server over a fake core.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:net";
import { main, parseListen, startConfigService } from "../config-service.mjs";
import { osErrorText } from "../errors.mjs";

/** A core that reads the settings path through the host, then answers by path. */
function fakeCore(requests) {
  return async ({ method, params, effects }) => {
    requests.push({ method, params });
    if (method !== "configService.handle") return { error: "no such method" };
    if (effects.length === 0) return { effect: { effect: "readFile", path: params.settingsPath }, index: 0 };
    if (params.path === "/healthz") return { done: { status: 200, contentType: "text/plain; charset=utf-8", body: "ok\n" } };
    if (params.path === "/boom") return { failed: "the core failed" };
    return { done: { status: 404, contentType: "application/json", body: JSON.stringify({ error: `no ${params.path}`, read: effects[0].ok }) } };
  };
}

const host = { perform: async (effect) => ({ ok: `settings at ${effect.path}` }) };

test("parsing the listen address", () => {
  assert.deepEqual(parseListen("0.0.0.0:8700"), { host: "0.0.0.0", port: 8700 });
  assert.deepEqual(parseListen("[::1]:80"), { host: "::1", port: 80 });
  assert.throws(() => parseListen("8700"), /invalid socket address/);
  assert.throws(() => parseListen("x:port"), /invalid port value/);
});

test("each request is the core's configService.handle", async (t) => {
  const requests = [];
  const server = await startConfigService({ core: fakeCore(requests), host, settings: "/etc/s.json", listen: "127.0.0.1:0" });
  t.after(() => server.close());
  const base = `http://127.0.0.1:${server.address().port}`;
  const health = await fetch(`${base}/healthz`);
  assert.equal(health.status, 200);
  assert.equal(health.headers.get("content-type"), "text/plain; charset=utf-8");
  assert.equal(await health.text(), "ok\n");
  const missing = await fetch(`${base}/v1/environments/nope?x=1`);
  assert.equal(missing.status, 404);
  assert.deepEqual(await missing.json(), { error: "no /v1/environments/nope?x=1", read: "settings at /etc/s.json" });
  const failed = await fetch(`${base}/boom`, { method: "POST" });
  assert.equal(failed.status, 500);
  assert.deepEqual(await failed.json(), { error: "the core failed" });
  assert.deepEqual(requests[0], { method: "configService.handle", params: { settingsPath: "/etc/s.json", method: "GET", path: "/healthz" } });
  assert.equal(requests.at(-1).params.method, "POST");
});

test("main logs where it serves, and exits 2 when it cannot listen", async (t) => {
  const taken = createServer();
  await new Promise((resolve) => taken.listen(0, "127.0.0.1", resolve));
  t.after(() => taken.close());
  const listen = `127.0.0.1:${taken.address().port}`;
  const lines = [];
  const stderr = { write: (text) => lines.push(text) };
  const code = await main({
    env: { IRONFRAME_SETTINGS: "/s.json", IRONFRAME_LISTEN: listen },
    stderr,
    loadCore: async () => fakeCore([]),
    createHost: () => host,
  });
  assert.equal(code, 2);
  assert.deepEqual(lines, [`ironframe-config-service: cannot listen on ${listen}: ${osErrorText("EADDRINUSE")}\n`]);

  lines.length = 0;
  const serving = main({ env: { IRONFRAME_LISTEN: "127.0.0.1:0" }, stderr, loadCore: async () => fakeCore([]), createHost: () => host });
  while (lines.length === 0) await new Promise((resolve) => setTimeout(resolve, 5));
  assert.deepEqual(lines, ["ironframe-config-service: serving /etc/ironframe/settings.json on 127.0.0.1:0\n"]);
  process.emit("SIGTERM");
  assert.equal(await serving, 0);
});
