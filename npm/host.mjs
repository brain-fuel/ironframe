// The host: performs the effects the core asks for and reports each result as
// {ok: value} or {error: text}, the text in the words Ironframe's Rust gave.
// Every outside dependency is an option, so tests replace any of them.
// ref:DEC-host-protocol
import * as nodeFs from "node:fs/promises";
import { spawn as nodeSpawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { lookup as dnsLookup } from "node:dns/promises";
import { connect as netConnect, createServer as netServer } from "node:net";
import {once} from "node:events";
import { dirname, basename } from "node:path";
import { errorText, rootCause } from "./errors.mjs";

const ok = (value) => ({ ok: value });
const failure = (error) => {
  const result = { error: errorText(error) };
  if (error && error.code === "ENOENT") result.notFound = true;
  return result;
};

/** UTF-8 text, kept exactly: a byte-order mark stays, as Rust keeps it. */
const strict = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
const lossy = new TextDecoder("utf-8", { ignoreBOM: true });

/** The path a write goes through first, as Rust's path.with_extension(ext + ".tmp"). */
export function temporaryPath(path) {
  const name = basename(path);
  const dot = name.lastIndexOf(".");
  const hasExtension = dot > 0;
  return hasExtension ? `${path}.tmp` : `${path}..tmp`;
}

/** Joins a PATH entry and a name as Rust's Path::join does, without normalising. */
function join(directory, name) {
  if (directory === "") return name;
  return directory.endsWith("/") ? directory + name : `${directory}/${name}`;
}

/**
 * Creates a host. Options replace its dependencies: fs (node:fs/promises
 * shape), process ({env, cwd(), pid, stdin, stdout, stderr}), spawn, net
 * ({lookup, connect}), fetch, clock ({now(), monotonic(), sleep(ms), uuid()})
 * and clouds ({aws, gcp, azure}, each an object of calls).
 */
export function createHost(options = {}) {
  const fs = options.fs ?? nodeFs;
  const proc = options.process ?? process;
  const spawn = options.spawn ?? nodeSpawn;
  const net = options.net ?? { lookup: dnsLookup, connect: netConnect };
  const fetchImpl = options.fetch ?? globalThis.fetch;
  const clock = options.clock ?? defaultClock;
  const clouds = options.clouds ?? defaultClouds();
  const services = new Map();
  const commands = new Set();
  const signal = options.signal;

  async function freeEndpoint(endpoint) {
    if (!endpoint) return;
    const address = new URL(endpoint.includes('://') ? endpoint : 'tcp://' + endpoint);
    const port = Number(address.port || (address.protocol === 'https:' ? 443 : 80));
    const server = (options.createServer ?? netServer)();
    try {
      await new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(port, address.hostname.replace(/^\[|\]$/g, ''), resolve);
      });
    } finally {
      if (server.listening) await new Promise(resolve => server.close(resolve));
    }
  }

  function stopped(child) {
    return child.exitCode !== null || child.signalCode !== null;
  }

  function stopOwned(record) {
    record.stopping ??= stopGroup(record);
    return record.stopping;
  }

  async function stopGroup(record) {
    const {child, finished, grouped} = record;
    if (!child.pid) return;
    const group = grouped && process.platform !== 'win32';
    const alive = () => {
      if (!group) return !stopped(child);
      try {process.kill(-child.pid, 0); return true;}
      catch (error) {
        if (error.code === 'ESRCH') return false;
        if (error.code === 'EPERM') return true;
        throw error;
      }
    };
    if (!alive()) return;
    const send = name => {
      try {
        if (group) process.kill(-child.pid, name);
        else child.kill(name);
      } catch (error) {if (!['ESRCH', 'EPERM'].includes(error.code)) throw error;}
    };
    send('SIGTERM');
    const waitUntil = async deadline => {
      while (alive() && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 20));
      return !alive();
    };
    if (!(await waitUntil(Date.now() + 5000))) {
      send('SIGKILL');
      if (!(await waitUntil(Date.now() + 5000))) throw new Error('Owned process group did not stop');
    }
    if (!stopped(child)) await finished;
  }

  async function isFile(path) {
    try {
      return (await fs.stat(path)).isFile();
    } catch {
      return false;
    }
  }

  async function readText(path) {
    const bytes = await fs.readFile(path);
    try {
      return ok(strict.decode(bytes));
    } catch {
      return { error: "stream did not contain valid UTF-8" };
    }
  }

  const effects = {
    async readFile({ path }) {
      return readText(path);
    },

    async writeAtomically({ path, text }) {
      try {
        if (strict.decode(await fs.readFile(path)) === text) return ok(false);
      } catch {
        // Missing, unreadable or not UTF-8: write it.
      }
      await fs.mkdir(dirname(path), { recursive: true });
      const temporary = temporaryPath(path);
      await fs.writeFile(temporary, text);
      await fs.rename(temporary, path);
      return ok(true);
    },

    async writeFile({ path, text }) {
      await fs.writeFile(path, text);
      return ok(null);
    },

    async removeFile({ path }) {
      await fs.unlink(path);
      return ok(null);
    },

    async removeTree({ path }) {
      await fs.rm(path, { recursive: true });
      return ok(null);
    },

    async createDir({ path }) {
      await fs.mkdir(path, { recursive: true });
      return ok(null);
    },

    async canonicalize({ path }) {
      return ok(await fs.realpath(path));
    },

    async cwd() {
      return ok(proc.cwd());
    },

    async env({ name }) {
      const value = proc.env[name];
      return ok(value === undefined ? null : value);
    },

    async readStdin() {
      const chunks = [];
      for await (const chunk of proc.stdin) chunks.push(typeof chunk === "string" ? Buffer.from(chunk) : chunk);
      try {
        return ok(strict.decode(Buffer.concat(chunks)));
      } catch {
        return { error: "stream did not contain valid UTF-8" };
      }
    },

    async tempDir() {
      // Rust's std::env::temp_dir: TMPDIR as it is, else /tmp.
      const value = proc.env.TMPDIR;
      return ok(value === undefined ? "/tmp" : value);
    },

    async processId() {
      return ok(proc.pid);
    },

    async locate({ variable, names, fallbacks }) {
      const set = proc.env[variable];
      if (set !== undefined && set !== "") return ok(set);
      const entries = (proc.env.PATH ?? "").split(":");
      for (const name of names)
        for (const directory of entries) {
          const candidate = join(directory, name);
          if (await isFile(candidate)) return ok(candidate);
        }
      for (const fallback of fallbacks) if (await isFile(fallback)) return ok(fallback);
      return ok(null);
    },

    async run(fields) {
      return runProcess(fields);
    },

    async startService({command, cwd, env, log, endpoint}) {
      signal?.throwIfAborted();
      if (process.platform === 'win32') throw new Error('Owned process groups are not supported on Windows');
      await freeEndpoint(endpoint);
      await fs.mkdir(dirname(log), {recursive: true});
      const output = await fs.open(log, 'w');
      let child;
      try {
        child = spawn(command[0], command.slice(1), {cwd, env: {...proc.env, ...env}, detached: process.platform !== 'win32', stdio: ['ignore', output.fd, output.fd]});
        const finished = new Promise(resolve => child.once('exit', resolve));
        await once(child, 'spawn');
        const id = clock.uuid();
        services.set(id, {child, finished, grouped: true});
        return ok({id, pid: child.pid, log});
      } finally {await output.close();}
    },

    async serviceStatus({id}) {
      const service = services.get(id);
      if (!service) throw new Error('Unknown owned service handle');
      return ok({running: !stopped(service.child), code: service.child.exitCode});
    },

    async stopService({id}) {
      const service = services.get(id);
      if (!service) throw new Error('Unknown owned service handle');
      await stopOwned(service);
      services.delete(id);
      return ok(null);
    },

    async http({ method, url, headers, body, timeoutMs }) {
      try {
        const response = await fetchImpl(url, {
          method,
          headers,
          body: body ?? undefined,
          redirect: "follow",
          signal: AbortSignal.timeout(timeoutMs),
        });
        return ok({ status: response.status, body: await response.text() });
      } catch (error) {
        return { error: httpReason(error) };
      }
    },

    async tcpProbe({ host, port, timeoutMs }) {
      return ok(await tcpReachable(net, host, port, timeoutMs));
    },

    async sleep({ ms }) {
      await clock.sleep(ms);
      return ok(null);
    },

    async now() {
      return ok(clock.now());
    },

    async monotonic() {
      return ok(clock.monotonic());
    },

    async uuid() {
      return ok(clock.uuid());
    },

    async print({ stream, text }) {
      await write(stream === "stderr" ? proc.stderr : proc.stdout, text);
      return ok(null);
    },

    async progress({ text }) {
      await write(proc.stderr, `ironframe: ${text}\n`);
      return ok(null);
    },
  };

  function runProcess({ program, args, stream, cwd, env, inheritStdin, ownedGroup }) {
    return new Promise((resolve) => {
      if (ownedGroup && process.platform === 'win32') {resolve(failure(new Error('Owned process groups are not supported on Windows'))); return;}
      const stdio = [inheritStdin ? "inherit" : "ignore", stream ? "inherit" : "pipe", stream ? "inherit" : "pipe"];
      let child;
      try {
        child = spawn(program, args, {
          cwd: cwd ?? undefined,
          env: env ? { ...proc.env, ...env } : proc.env,
          stdio,
          ...(ownedGroup ? {detached: process.platform !== 'win32'} : {}),
          ...(signal ? {signal} : {}),
        });
      } catch (error) {
        resolve(failure(error));
        return;
      }
      const stdout = [];
      const stderr = [];
      const record = ownedGroup ? {child, grouped: true, finished: new Promise(resolve => child.once('exit', resolve))} : null;
      if (record) {
        commands.add(record);
        child.once('exit', () => {stopOwned(record).catch(() => {});});
      }
      child.stdout?.on("data", (chunk) => stdout.push(chunk));
      child.stderr?.on("data", (chunk) => stderr.push(chunk));
      let settled = false;
      child.on("error", (error) => {
        if (settled) return;
        settled = true;
        resolve(failure(error));
      });
      child.on("close", async (code) => {
        if (record) {
          try {await stopOwned(record);}
          catch (error) {if (!settled) {settled = true; resolve(failure(error));} return;}
          finally {commands.delete(record);}
        }
        if (settled) return;
        settled = true;
        resolve(
          ok({
            success: code === 0,
            code: code ?? null,
            stdout: stream ? "" : lossy.decode(Buffer.concat(stdout)),
            stderr: stream ? "" : lossy.decode(Buffer.concat(stderr)),
          }),
        );
      });
    });
  }

  /** Performs one effect; never throws. */
  async function perform(effect) {
    const name = effect && effect.effect;
    try {
      const local = Object.hasOwn(effects, name) ? effects[name] : undefined;
      if (local) return await local(effect);
      const dot = typeof name === "string" ? name.indexOf(".") : -1;
      const cloud = dot > 0 && Object.hasOwn(clouds, name.slice(0, dot)) ? clouds[name.slice(0, dot)] : undefined;
      const call = cloud && Object.hasOwn(cloud, name.slice(dot + 1)) ? cloud[name.slice(dot + 1)] : undefined;
      if (call) {
        const { effect: _, ...fields } = effect;
        return await call(fields);
      }
      return { error: `the host does not know the effect ${JSON.stringify(name)}` };
    } catch (error) {
      return failure(error);
    }
  }

  async function close() {
    const results = await Promise.allSettled([...services.values(), ...commands].map(stopOwned));
    services.clear();
    commands.clear();
    const errors = results.filter(result => result.status === 'rejected').map(result => result.reason);
    if (errors.length) throw new AggregateError(errors, 'Owned process cleanup failed');
  }
  return { perform, close, signal };
}

/** Writes text and waits until the stream has taken it, so output keeps its order. */
function write(stream, text) {
  return new Promise((resolve) => {
    if (text === "") resolve();
    else stream.write(text, () => resolve());
  });
}

/** The root cause of a failed request, as reqwest's error chain ends. */
export function httpReason(error) {
  if (error && (error.name === "TimeoutError" || error.name === "AbortError")) return "operation timed out";
  const cause = rootCause(error);
  if (cause && typeof cause.code === "string" && cause.code !== "ERR_INVALID_URL") return errorText(cause);
  if (cause && cause.code === "ERR_INVALID_URL") return "relative URL without a base";
  return errorText(cause ?? error);
}

/**
 * Rust's tcp_reachable: every address of the host is tried in turn; one
 * counts when it connects within the timeout and then, within 300 ms, sends a
 * byte or stays silent. A close or reset in that moment does not count.
 */
export async function tcpReachable(net, host, port, timeoutMs) {
  let addresses;
  try {
    addresses = await net.lookup(host, { all: true, order: "verbatim" });
  } catch {
    return false;
  }
  for (const { address, family } of addresses)
    if (await probeAddress(net, address, family, port, timeoutMs)) return true;
  return false;
}

function probeAddress(net, address, family, port, timeoutMs) {
  // Rust's connect_timeout refuses a zero timeout.
  if (!(timeoutMs > 0)) return Promise.resolve(false);
  return new Promise((resolve) => {
    let done = false;
    let timer;
    const socket = net.connect({ host: address, port, family });
    const finish = (reached) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      socket.destroy();
      resolve(reached);
    };
    timer = setTimeout(() => finish(false), timeoutMs);
    socket.once("connect", () => {
      clearTimeout(timer);
      timer = setTimeout(() => finish(true), 300);
      socket.once("data", () => finish(true));
      socket.once("end", () => finish(false));
    });
    socket.once("error", () => finish(false));
    socket.once("close", () => finish(false));
  });
}

const defaultClock = {
  now() {
    const ms = performance.timeOrigin + performance.now();
    const seconds = Math.floor(ms / 1000);
    const nanos = Math.min(999_999_999, Math.floor((ms - seconds * 1000) * 1e6));
    return { seconds, nanos };
  },
  monotonic() {
    return Math.floor(performance.now());
  },
  sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  },
  uuid() {
    return randomUUID();
  },
};

/** The calls each cloud adapter answers. */
export const cloudCalls = {
  aws: ["findApplication", "createApplication", "findEnvironment", "createEnvironment", "findProfile",
    "createProfile", "latestVersion", "createVersion", "deploy"],
  gcp: ["parameterExists", "createParameter", "createVersion"],
  azure: ["get", "put"],
};

/** The clouds over their official SDKs, each loaded on first use. */
function defaultClouds() {
  const lazy = (cloud, load) => {
    let adapter;
    return Object.fromEntries(
      cloudCalls[cloud].map((call) => [call, async (fields) => (adapter ??= await load())[call](fields)]),
    );
  };
  return {
    aws: lazy("aws", async () => (await import("./clouds/aws.mjs")).createAws()),
    gcp: lazy("gcp", async () => (await import("./clouds/gcp.mjs")).createGcp()),
    azure: lazy("azure", async () => (await import("./clouds/azure.mjs")).createAzure()),
  };
}
