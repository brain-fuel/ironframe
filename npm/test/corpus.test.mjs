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

// Checks every case of one corpus file through the WASM core. The cases are
// the recorded behaviour of every requirement the Rust tests checked.
// ref:REQ-manifest-validation ref:REQ-settings-resolution
// ref:REQ-compose-generation ref:REQ-cloud-root-module
// ref:REQ-config-sync-idempotent ref:REQ-conformance-matches-report
// ref:REQ-twin-start-setup ref:REQ-attestation-round-trip
// ref:REQ-attestation-stand-in-run ref:REQ-missing-image-fails-clearly
// ref:REQ-config-service-serves-settings
function checkFile(file) {
  // The core reads each case from the file's own text: JSON.parse would put
  // integer-like keys first and change what a case says.
  const corpusText = readFileSync(new URL(file, corpus), "utf8");
  const cases = JSON.parse(corpusText);
  test(file, { skip: missing }, async (t) => {
    for (const [index, item] of cases.entries()) {
      await t.test(item.name ?? `${item.method} #${index}`, async () => {
        let result;
        try {
          result = await run(core, "corpus.check", { corpusText, index, fixtures: given }, host);
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

for (const file of files) checkFile(file);
