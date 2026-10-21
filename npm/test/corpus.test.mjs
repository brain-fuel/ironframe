// The recorded corpus, checked by the core itself: each case of every
// corpus/*.json but cli.json goes to "corpus.check", whose answer says whether
// the core reproduces it. Skipped while the core lacks that method.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { loadCore } from "../launcher.mjs";
import { createHost } from "../host.mjs";
import { run, isMissingMethod } from "../protocol.mjs";

const corpus = new URL("../../corpus/", import.meta.url);
const files = readdirSync(corpus).filter((name) => name.endsWith(".json") && name !== "cli.json").sort();
const core = existsSync(new URL("../core.wasm", import.meta.url)) ? await loadCore() : undefined;
const probe = core && (await core({ method: "corpus.check", params: { case: {} }, effects: [] }));
const missing = !core ? "no core.wasm; run tools/wasm.sh" : probe.error === "no such method" ? "the core has no corpus.check yet" : false;
const host = createHost();

/** The example files cases name rather than copy, keyed by their repository path. */
function fixtures() {
  const dir = "examples/calm-shop/architecture";
  const found = {};
  const read = (relative) => {
    found[`${dir}/${relative}`] = readFileSync(new URL(`../../${dir}/${relative}`, import.meta.url), "utf8");
  };
  for (const name of readdirSync(new URL(`../../${dir}/`, import.meta.url))) if (name.endsWith(".json")) read(name);
  for (const name of readdirSync(new URL(`../../${dir}/conformance/`, import.meta.url))) read(`conformance/${name}`);
  return found;
}
const given = fixtures();

for (const file of files) {
  const cases = JSON.parse(readFileSync(new URL(file, corpus), "utf8"));
  test(file, { skip: missing }, async (t) => {
    for (const [index, item] of cases.entries()) {
      await t.test(item.name ?? `${item.method} #${index}`, async () => {
        let result;
        try {
          result = await run(core, "corpus.check", { case: item, fixtures: given }, host);
        } catch (error) {
          if (isMissingMethod(error)) return t.skip("no corpus.check");
          throw error;
        }
        assert.ok("done" in result, `corpus.check failed: ${result.failed}`);
        assert.equal(result.done.pass, true, result.done.diff ?? JSON.stringify(result.done));
      });
    }
  });
}
