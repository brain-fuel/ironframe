// The host side of the core's protocol: call, perform the effect the core
// names, append its result and call again, until the core finishes. The core
// replays the results deterministically, so the requests only grow.
// ref:DEC-host-protocol

/** A response the core could not make sense of, or a method it lacks. */
export class ProtocolError extends Error {
  constructor(message) {
    super(message);
    this.name = "ProtocolError";
  }
}

/** Runs a method to its end: {done: value} or {failed: message}. */
export async function run(core, method, params, host) {
  const effects = [];
  for (;;) {
    const response = await core({ method, params, effects });
    if ("done" in response) return { done: response.done };
    if ("failed" in response) return { failed: response.failed };
    if ("effect" in response) {
      if (response.index !== effects.length)
        throw new ProtocolError(`the core asked for effect ${response.index} after ${effects.length} results`);
      effects.push(await host.perform(response.effect));
      continue;
    }
    if ("error" in response) throw new ProtocolError(`${method}: ${response.error}`);
    throw new ProtocolError(`${method}: unexpected response ${JSON.stringify(response)}`);
  }
}

/** Whether an error is the core's answer to an unknown method. */
export function isMissingMethod(error) {
  return error instanceof ProtocolError && /: no such method( "[^"]*")?$/.test(error.message);
}
