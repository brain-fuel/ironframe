// A tiny application that knows nothing of Ironframe.
// It reads KAFKA_BOOTSTRAP_SERVERS from its environment, or else from a .env file in its working directory.
// It asks each broker over the Kafka wire protocol for its supported API versions.
// It then asks for the metadata of the app's topic, which a broker that creates topics on first use creates.
// Whether the broker is the real Kafka or a twin is decided by the manifest beside it, not by the app.
// Run it with `node app.mjs` in this directory after `ironframe up local`. It needs Node 22 or later.
// ref:REQ-example-reads-config

import { readFileSync } from "node:fs";
import { lookup } from "node:dns/promises";
import { isIP, Socket } from "node:net";
import { constants } from "node:os";

/** The setting the app reads. */
const SETTING = "KAFKA_BOOTSTRAP_SERVERS";

/** The topic the app asks the broker about. */
const TOPIC = "kafka-app";

/** The client id the app names in each request. */
const CLIENT = Buffer.from("kafka-app");

/** How long one read may wait, as a read timeout on the socket would. */
const READ_TIMEOUT_MS = 10_000;

/** Whitespace as Rust's `char::is_whitespace` defines it, so trimming matches the Rust app's. */
const WS = "\\t\\n\\v\\f\\r \\u0085\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000";
const trimStart = (s) => s.replace(new RegExp(`^[${WS}]+`), "");
const trim = (s) => s.replace(new RegExp(`^[${WS}]+|[${WS}]+$`, "g"), "");
const trimQuotes = (s) => s.replace(/^"+|"+$/g, "");

/** The bootstrap servers from the environment, else from `.env`, as a dotenv library would. */
function bootstrapServers() {
  if (process.env[SETTING] !== undefined) return process.env[SETTING];
  let text;
  try {
    text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(readFileSync(".env"));
  } catch {
    return undefined;
  }
  const lines = text.split("\n");
  if (lines.at(-1) === "") lines.pop();
  for (const raw of lines) {
    const line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
    if (trimStart(line).startsWith("#")) continue;
    const at = line.indexOf("=");
    if (at < 0) continue;
    if (trim(line.slice(0, at)) === SETTING) return trimQuotes(trim(line.slice(at + 1)));
  }
  return undefined;
}

const int16 = (n) => { const b = Buffer.alloc(2); b.writeInt16BE(n); return b; };
const int32 = (n) => { const b = Buffer.alloc(4); b.writeInt32BE(n); return b; };
const frame = (body) => Buffer.concat([int32(body.length), body]);

/** An ApiVersions request, version 0, framed with its length. */
function apiVersionsRequest(correlation) {
  return frame(Buffer.concat([int16(18), int16(0), int32(correlation), int16(CLIENT.length), CLIENT]));
}

/** A Metadata request, version 0, for one topic, framed with its length. */
function metadataRequest(correlation, topic) {
  const name = Buffer.from(topic);
  return frame(Buffer.concat([
    int16(3), int16(0), int32(correlation), int16(CLIENT.length), CLIENT, int32(1), int16(name.length), name,
  ]));
}

/** An error worded as Rust's `std::io::Error` words it, for the errors a socket commonly gives. */
const ERRNO_TEXT = {
  ECONNREFUSED: "Connection refused",
  ECONNRESET: "Connection reset by peer",
  ECONNABORTED: "Software caused connection abort",
  EPIPE: "Broken pipe",
  ETIMEDOUT: "Operation timed out",
  EHOSTUNREACH: "No route to host",
  ENETUNREACH: "Network is unreachable",
  EADDRNOTAVAIL: "Can't assign requested address",
  EAGAIN: "Resource temporarily unavailable",
};
if (process.platform === "linux") {
  ERRNO_TEXT.ETIMEDOUT = "Connection timed out";
  ERRNO_TEXT.EADDRNOTAVAIL = "Cannot assign requested address";
}
function ioError(error) {
  if (error && typeof error.code === "string" && error.code in ERRNO_TEXT && constants.errno[error.code] !== undefined) {
    return `${ERRNO_TEXT[error.code]} (os error ${constants.errno[error.code]})`;
  }
  if (error && (error.code === "ENOTFOUND" || error.code === "EAI_AGAIN" || error.code === "EAI_NONAME")) {
    const text = process.platform === "darwin" ? "nodename nor servname provided, or not known" : "Name or service not known";
    return `failed to lookup address information: ${text}`;
  }
  return error && error.message ? error.message : String(error);
}

/** A failure the probe reports as its reason. */
class Failure extends Error {}

/** The host and port of `host:port`, as Rust's `ToSocketAddrs` for a string reads them. */
function splitServer(server) {
  const v6 = /^\[([^\]]*)\]:(.*)$/.exec(server);
  let host;
  let port;
  if (v6 && isIP(v6[1].split("%")[0]) === 6) {
    [, host, port] = v6;
  } else {
    const at = server.lastIndexOf(":");
    if (at < 0) throw new Failure("cannot connect: invalid socket address");
    host = server.slice(0, at);
    port = server.slice(at + 1);
  }
  if (!/^\+?[0-9]+$/.test(port) || Number(port.replace(/^\+/, "")) > 65535) {
    throw new Failure("cannot connect: invalid port value");
  }
  return [host, Number(port.replace(/^\+/, ""))];
}

/** A connected socket, each resolved address tried in turn as Rust's `TcpStream::connect` does. */
async function connect(host, port) {
  let addresses;
  try {
    addresses = await lookup(host, { all: true, verbatim: true });
  } catch (error) {
    throw new Failure(`cannot connect: ${ioError(error)}`);
  }
  let last = new Error("could not resolve to any addresses");
  for (const { address, family } of addresses) {
    try {
      return await new Promise((resolve, reject) => {
        const socket = new Socket();
        socket.once("error", (error) => { socket.destroy(); reject(error); });
        socket.connect({ host: address, port, family, autoSelectFamily: false }, () => {
          socket.removeAllListeners("error");
          resolve(socket);
        });
      });
    } catch (error) {
      last = error;
    }
  }
  throw new Failure(`cannot connect: ${ioError(last)}`);
}

/** Reads exact byte counts from a socket, each wait bounded by the read timeout. */
class Reader {
  constructor(socket) {
    this.socket = socket;
    this.buffered = Buffer.alloc(0);
    this.ended = false;
    this.error = null;
    this.wake = null;
    socket.on("data", (chunk) => { this.buffered = Buffer.concat([this.buffered, chunk]); this.notify(); });
    socket.on("end", () => { this.ended = true; this.notify(); });
    socket.on("error", (error) => { this.error = error; this.notify(); });
  }
  notify() {
    const wake = this.wake;
    this.wake = null;
    if (wake) wake();
  }
  async exact(n, context) {
    while (this.buffered.length < n) {
      if (this.error) throw new Failure(`${context}: ${ioError(this.error)}`);
      if (this.ended) throw new Failure(`${context}: failed to fill whole buffer`);
      const timedOut = await new Promise((resolve) => {
        const timer = setTimeout(() => { this.wake = null; resolve(true); }, READ_TIMEOUT_MS);
        this.wake = () => { clearTimeout(timer); resolve(false); };
      });
      if (timedOut) throw new Failure(`${context}: ${ioError({ code: "EAGAIN" })}`);
    }
    const head = this.buffered.subarray(0, n);
    this.buffered = this.buffered.subarray(n);
    return head;
  }
}

/** Sends a framed request and reads the framed response. */
async function roundTrip(socket, reader, request) {
  await new Promise((resolve, reject) => {
    socket.write(request, (error) => (error ? reject(new Failure(`cannot send: ${ioError(error)}`)) : resolve()));
  });
  const size = (await reader.exact(4, "no response")).readInt32BE();
  return Buffer.from(await reader.exact(Math.max(size, 0), "short response"));
}

/** A reader over a response's fields, failing on a short response. */
class Fields {
  constructor(bytes) { this.bytes = bytes; }
  take(n) {
    if (this.bytes.length < n) throw new Failure("response too short");
    const head = this.bytes.subarray(0, n);
    this.bytes = this.bytes.subarray(n);
    return head;
  }
  int16() { return this.take(2).readInt16BE(); }
  int32() { return this.take(4).readInt32BE(); }
  string() { return this.take(Math.max(this.int16(), 0)).toString("utf8"); }
}

/** Reads a Metadata version 0 response: the number of brokers, and the topic's error code and partitions. */
function readMetadata(response) {
  const fields = new Fields(response);
  if (fields.int32() !== 2) throw new Failure("metadata answered another request");
  const brokers = Math.max(fields.int32(), 0);
  for (let i = 0; i < brokers; i++) {
    fields.int32();
    fields.string();
    fields.int32();
  }
  if (fields.int32() < 1) throw new Failure("metadata named no topic");
  const error = fields.int16();
  fields.string();
  const partitions = Math.max(fields.int32(), 0);
  return [brokers, error, partitions];
}

/** Asks one broker for its API versions and for the app's topic: how many APIs, how many partitions. */
async function probe(server) {
  const [host, port] = splitServer(server);
  const socket = await connect(host, port);
  try {
    const reader = new Reader(socket);
    const response = await roundTrip(socket, reader, apiVersionsRequest(1));
    if (response.length < 10) throw new Failure("response too short");
    const correlation = response.readInt32BE(0);
    const error = response.readInt16BE(4);
    const count = response.readInt32BE(6);
    if (correlation !== 1) throw new Failure(`response for request ${correlation}, expected 1`);
    if (error !== 0) throw new Failure(`broker answered with error code ${error}`);
    const [, topicError, partitions] = readMetadata(await roundTrip(socket, reader, metadataRequest(2, TOPIC)));
    if (topicError !== 0) throw new Failure(`metadata for topic ${TOPIC} answered with error code ${topicError}`);
    return [Math.max(count, 0), partitions];
  } finally {
    socket.destroy();
  }
}

async function main() {
  const servers = bootstrapServers();
  if (servers === undefined) {
    process.stderr.write(`kafka-app: set ${SETTING}, or write it to .env\n`);
    return 2;
  }
  let failed = false;
  for (const server of servers.split(",").map(trim).filter((s) => s !== "")) {
    try {
      const [count, partitions] = await probe(server);
      process.stdout.write(`kafka-app: ${server} supports ${count} APIs; topic ${TOPIC} has ${partitions} partition(s)\n`);
    } catch (error) {
      if (!(error instanceof Failure)) throw error;
      process.stderr.write(`kafka-app: ${server}: ${error.message}\n`);
      failed = true;
    }
  }
  return failed ? 1 : 0;
}

process.exitCode = await main();
