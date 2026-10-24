#!/usr/bin/env node
// The ironframe command: the core's "cli" method over the real host. Its
// result is the exit code; a failure the core reports exits 2.
// ref:DEC-haskell-wasm-core
import { loadCore } from "../launcher.mjs";
import { createHost } from "../host.mjs";
import { run } from "../protocol.mjs";

const controller = new AbortController();
const host = createHost({signal: controller.signal});
let interrupted = false;
const cancel = () => {interrupted = true; controller.abort(); void host.close().catch(error => process.stderr.write(`ironframe: cleanup failed: ${error.message}\n`));};
process.once('SIGINT', cancel);
process.once('SIGTERM', cancel);
try {
  const core = await loadCore();
  const result = await run(core, "cli", { argv: process.argv.slice(2), cwd: process.cwd() }, host);
  if ("done" in result) process.exitCode = result.done.exitCode;
  else {
    process.stderr.write(`ironframe: ${result.failed}\n`);
    process.exitCode = 2;
  }
} catch (error) {
  process.stderr.write(`ironframe: ${error instanceof Error ? error.message : error}\n`);
  process.exitCode = interrupted ? 130 : 2;
} finally {
  process.removeListener('SIGINT', cancel);
  process.removeListener('SIGTERM', cancel);
  await host.close();
  if (interrupted) process.exitCode = 130;
}
