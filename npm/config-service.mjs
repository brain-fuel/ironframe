#!/usr/bin/env node
// The configuration service: an HTTP server whose every answer is the core's
// "configService.handle" over the settings document, re-read on each request.
// IRONFRAME_SETTINGS names the document and IRONFRAME_LISTEN the address.
// Mirrors the Rust service it replaced. ref:DEC-config-service
import { createServer } from "node:http";
import { pathToFileURL } from "node:url";
import { errorText } from "./errors.mjs";
import { run } from "./protocol.mjs";

/** Splits host:port, [v6]:port included, or names why it is not an address. */
export function parseListen(listen) {
  const match = /^(?:\[([^\]]*)\]|([^:]*)):([^:]*)$/.exec(listen);
  if (!match) throw new Error("invalid socket address");
  const port = Number(match[3]);
  if (!/^\d+$/.test(match[3]) || port > 65535) throw new Error("invalid port value");
  return { host: match[1] ?? match[2], port };
}

/**
 * Starts the service; resolves to the listening server, or rejects with the
 * reason it cannot listen. core and host are the protocol's.
 */
export function startConfigService({ core, host, settings, listen }) {
  const { host: address, port } = parseListen(listen);
  const server = createServer(async (request, response) => {
    let answer;
    try {
      const result = await run(
        core,
        "configService.handle",
        { settingsPath: settings, method: request.method, path: request.url },
        host,
      );
      answer =
        "done" in result
          ? result.done
          : { status: 500, contentType: "application/json", body: JSON.stringify({ error: result.failed }) };
    } catch (error) {
      answer = { status: 500, contentType: "application/json", body: JSON.stringify({ error: String(error.message ?? error) }) };
    }
    const body = Buffer.from(answer.body ?? "", "utf8");
    response.writeHead(answer.status, { "content-type": answer.contentType, "content-length": body.length });
    response.end(body);
  });
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, address, () => {
      server.off("error", reject);
      resolve(server);
    });
  });
}

/** The service as a program: serve until SIGINT or SIGTERM. */
export async function main({ env = process.env, stderr = process.stderr, loadCore, createHost } = {}) {
  const settings = env.IRONFRAME_SETTINGS ?? "/etc/ironframe/settings.json";
  const listen = env.IRONFRAME_LISTEN ?? "0.0.0.0:8700";
  loadCore ??= (await import("./launcher.mjs")).loadCore;
  createHost ??= (await import("./host.mjs")).createHost;
  const core = await loadCore();
  let server;
  try {
    server = await startConfigService({ core, host: createHost(), settings, listen });
  } catch (error) {
    stderr.write(`ironframe-config-service: cannot listen on ${listen}: ${errorText(error)}\n`);
    return 2;
  }
  stderr.write(`ironframe-config-service: serving ${settings} on ${listen}\n`);
  await new Promise((resolve) => {
    const stop = () => {
      process.off("SIGINT", stop);
      process.off("SIGTERM", stop);
      server.close(resolve);
      server.closeIdleConnections();
    };
    process.on("SIGINT", stop);
    process.on("SIGTERM", stop);
  });
  return 0;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) process.exitCode = await main();
