// Ironframe as a library: the core's methods over a host, the real one unless
// another is given. ref:DEC-haskell-wasm-core
import { loadCore } from "./launcher.mjs";
import { createHost } from "./host.mjs";
import { run as runProtocol } from "./protocol.mjs";

export { createHost } from "./host.mjs";
export { run, ProtocolError } from "./protocol.mjs";

/** An Ironframe: call(request) answers one raw request; run(method, params) runs a method to its end. */
export function createIronframe({ host = createHost(), core } = {}) {
  let loaded = core ? Promise.resolve(core) : undefined;
  const coreCall = () => (loaded ??= loadCore());
  return {
    async call(request) {
      return (await coreCall())(request);
    },
    async run(method, params = {}) {
      return runProtocol(await coreCall(), method, params, host);
    },
  };
}
