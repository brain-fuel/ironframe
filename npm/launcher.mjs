// Loads the WASM core and calls it. The core is pure: one JSON request in, one
// JSON response out, through its one export, ironframe_call. Mirrors LawSpec's
// npm/launcher.mjs. ref:DEC-haskell-wasm-core
import { readFile } from "node:fs/promises";
let compiled;

// GHC's JSFFI reactor reads these WASI arguments during initialization. Bound
// the heap below wasm32's address ceiling and compact the oldest generation
// in place instead of reserving a second copy near that ceiling.
const coreArguments = ["ironframe", "+RTS", "-M3584m", "-c", "-RTS"];

// Instantiate the core with WASI preview1 imports and serialize calls: the
// core handles one request at a time.
async function instantiateCore(module, wasiImports, initialize) {
  const exports = {};
  const jsffi = (await import("./core_jsffi.js")).default;
  const instance = await WebAssembly.instantiate(module, {
    wasi_snapshot_preview1: wasiImports,
    ghc_wasm_jsffi: jsffi(exports),
  });
  Object.assign(exports, instance.exports);
  initialize(instance);
  let pending = Promise.resolve();
  return (request) => {
    const result = pending.then(async () =>
      JSON.parse(await instance.exports.ironframe_call(JSON.stringify(request))),
    );
    pending = result.then(() => {}, () => {});
    return result;
  };
}

// node:wasi warns that it is experimental; the command's standard error is
// part of its contract, so that one warning is left out.
async function quietly(load) {
  const emit = process.emitWarning;
  process.emitWarning = function (warning, ...rest) {
    if (/WASI is an experimental feature/.test(String(warning?.message ?? warning))) return;
    return emit.call(this, warning, ...rest);
  };
  try {
    return await load();
  } finally {
    process.emitWarning = emit;
  }
}

/** Loads the core; returns call(request) → Promise<response>. */
export async function loadCore() {
  const { WASI } = await quietly(() => import("node:wasi"));
  if (Number(process.versions.node.split(".")[0]) < 22)
    throw new Error("Ironframe requires Node 22+");
  compiled ??= readFile(new URL("./core.wasm", import.meta.url)).then(WebAssembly.compile);
  // The core reaches no files itself: every effect goes through the host.
  const wasi = new WASI({ version: "preview1", args: coreArguments, env: {}, preopens: {} });
  return instantiateCore(await compiled, wasi.wasiImport, (instance) => wasi.initialize(instance));
}
