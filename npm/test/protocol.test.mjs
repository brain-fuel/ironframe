// The protocol loop against a fake core that replays its effect results.
import { test } from "node:test";
import assert from "node:assert/strict";
import { run, ProtocolError, isMissingMethod } from "../protocol.mjs";

/** A core that reads two files, then answers with their texts, as the real core replays. */
function fakeCore(requests) {
  return async (request) => {
    requests.push(structuredClone(request));
    if (request.method !== "concat") return { error: "no such method" };
    const [first, second] = request.effects;
    if (!first) return { effect: { effect: "readFile", path: request.params.a }, index: 0 };
    if (first.error) return { failed: `cannot read ${request.params.a}: ${first.error}` };
    if (!second) return { effect: { effect: "readFile", path: request.params.b }, index: 1 };
    return { done: first.ok + second.ok };
  };
}

const files = { "/a": "one ", "/b": "two" };
const host = {
  performed: [],
  async perform(effect) {
    this.performed.push(effect);
    return effect.path in files ? { ok: files[effect.path] } : { error: "No such file or directory (os error 2)", notFound: true };
  },
};

test("runs until done, feeding each result back with the earlier ones", async () => {
  const requests = [];
  host.performed = [];
  assert.deepEqual(await run(fakeCore(requests), "concat", { a: "/a", b: "/b" }, host), { done: "one two" });
  assert.deepEqual(requests.map((r) => r.effects), [[], [{ ok: "one " }], [{ ok: "one " }, { ok: "two" }]]);
  assert.deepEqual(host.performed, [{ effect: "readFile", path: "/a" }, { effect: "readFile", path: "/b" }]);
});

test("a failure is the method's result, not an exception", async () => {
  assert.deepEqual(await run(fakeCore([]), "concat", { a: "/missing", b: "/b" }, host), {
    failed: "cannot read /missing: No such file or directory (os error 2)",
  });
});

test("protocol errors and out-of-step effects throw", async () => {
  await assert.rejects(run(fakeCore([]), "nope", {}, host), (error) => error instanceof ProtocolError && isMissingMethod(error));
  const skipping = async () => ({ effect: { effect: "cwd" }, index: 3 });
  await assert.rejects(run(skipping, "m", {}, host), /asked for effect 3 after 0 results/);
  await assert.rejects(run(async () => ({ what: 1 }), "m", {}, host), /unexpected response/);
});
