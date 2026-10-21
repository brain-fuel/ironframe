// A tiny application that knows nothing of Ironframe.
// It reads PETSTORE_URL from its environment, or else from a .env file in its working directory.
// It adds a pet to the Petstore API there and reads it back.
// Whether the API is the real service or a twin is decided by the manifest beside it, not by the app.
// Run it with `node app.mjs` in this directory after `ironframe up local`. It needs Node 22 or later.
// ref:REQ-example-reads-config

import { readFileSync } from "node:fs";
import { lookup } from "node:dns/promises";
import { isIP, Socket } from "node:net";
import { constants } from "node:os";

/** The setting the app reads. */
const SETTING = "PETSTORE_URL";

/** How long one read may wait, as a read timeout on the socket would. */
const READ_TIMEOUT_MS = 10_000;

/** Whitespace as Rust's `char::is_whitespace` defines it, so trimming matches the Rust app's. */
const WS = "\\t\\n\\v\\f\\r \\u0085\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000";
const trimStart = (s) => s.replace(new RegExp(`^[${WS}]+`), "");
const trim = (s) => s.replace(new RegExp(`^[${WS}]+|[${WS}]+$`, "g"), "");
const trimQuotes = (s) => s.replace(/^"+|"+$/g, "");

/** The base URL from the environment, else from `.env`, as a dotenv library would. */
function baseUrl() {
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

/** An error worded as Rust's `std::io::Error` words it, for the errors a socket commonly gives. */
const ERRNO_TEXT = {
  ECONNREFUSED: "Connection refused",
  ECONNRESET: "Connection reset by peer",
  ECONNABORTED: "Software caused connection abort",
  EPIPE: "Broken pipe",
  ETIMEDOUT: process.platform === "linux" ? "Connection timed out" : "Operation timed out",
  EHOSTUNREACH: "No route to host",
  ENETUNREACH: "Network is unreachable",
  EADDRNOTAVAIL: process.platform === "linux" ? "Cannot assign requested address" : "Can't assign requested address",
  EAGAIN: "Resource temporarily unavailable",
};
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

/** A failure the app reports as its reason. */
class Failure extends Error {}

/** The host, port and path prefix of an `http://` URL. */
function splitUrl(url) {
  if (!url.startsWith("http://")) throw new Failure(`${url} is not an http:// URL`);
  const rest = url.slice("http://".length);
  const slash = rest.indexOf("/");
  const authority = slash < 0 ? rest : rest.slice(0, slash);
  const path = slash < 0 ? "" : rest.slice(slash + 1);
  let host = authority;
  let port = 80;
  const colon = authority.lastIndexOf(":");
  if (colon >= 0) {
    host = authority.slice(0, colon);
    const text = authority.slice(colon + 1);
    if (!/^\+?[0-9]+$/.test(text) || Number(text.replace(/^\+/, "")) > 65535) throw new Failure(`bad port in ${url}`);
    port = Number(text.replace(/^\+/, ""));
  }
  return [host, port, `/${path.replace(/\/+$/, "")}`.replace(/\/+$/, "")];
}

/** A connected socket, each resolved address tried in turn as Rust's `TcpStream::connect` does. */
async function connect(host, port) {
  let addresses;
  if (isIP(host)) {
    addresses = [{ address: host, family: isIP(host) }];
  } else {
    try {
      addresses = await lookup(host, { all: true, verbatim: true });
    } catch (error) {
      throw new Failure(`cannot connect: ${ioError(error)}`);
    }
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

/** Everything the socket sends until it closes, each wait bounded by the read timeout. */
function readToEnd(socket) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let timer;
    const arm = () => {
      clearTimeout(timer);
      timer = setTimeout(() => reject(new Failure(`no response: ${ioError({ code: "EAGAIN" })}`)), READ_TIMEOUT_MS);
    };
    arm();
    socket.on("data", (chunk) => { chunks.push(chunk); arm(); });
    socket.on("end", () => { clearTimeout(timer); resolve(Buffer.concat(chunks)); });
    socket.on("error", (error) => { clearTimeout(timer); reject(new Failure(`no response: ${ioError(error)}`)); });
  });
}

/** One HTTP/1.1 exchange: the request line and body, and the status and body of the answer. */
async function exchange(url, method, path, body) {
  const [host, port, prefix] = splitUrl(url);
  const socket = await connect(host, port);
  try {
    socket.on("error", () => {});
    const content = body ?? "";
    const request =
      `${method} ${prefix}${path} HTTP/1.1\r\nHost: ${host}:${port}\r\nAccept: application/json\r\n` +
      `Content-Type: application/json\r\nContent-Length: ${Buffer.byteLength(content)}\r\nConnection: close\r\n\r\n${content}`;
    const answer = readToEnd(socket);
    answer.catch(() => {});
    await new Promise((resolve, reject) => {
      socket.write(request, (error) => (error ? reject(new Failure(`cannot send: ${ioError(error)}`)) : resolve()));
    });
    let text;
    try {
      text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(await answer);
    } catch (error) {
      if (error instanceof Failure) throw error;
      throw new Failure("no response: stream did not contain valid UTF-8");
    }
    return parseResponse(text);
  } finally {
    socket.destroy();
  }
}

/** The status and body of an HTTP/1.1 response read to its end. */
function parseResponse(response) {
  const end = response.indexOf("\r\n\r\n");
  if (end < 0) throw new Failure("the response has no end of headers");
  const head = response.slice(0, end);
  const words = head.split(new RegExp(`[${WS}]+`)).filter((w) => w !== "");
  const status = words[1];
  if (status === undefined || !/^\+?[0-9]+$/.test(status) || Number(status.replace(/^\+/, "")) > 65535) {
    throw new Failure("the response has no status");
  }
  return [Number(status.replace(/^\+/, "")), response.slice(end + 4)];
}

/** The value of a top-level JSON field, as text: a number, or a string without its quotes. */
function field(json, name) {
  const found = json.indexOf(`"${name}"`);
  if (found < 0) return undefined;
  const rest = trimStart(json.slice(found + name.length + 2));
  if (!rest.startsWith(":")) return undefined;
  const value = trimStart(rest.slice(1));
  if (value.startsWith('"')) return value.slice(1).split('"')[0];
  return /^[0-9]*/.exec(value)[0];
}

/** A string as Rust's `{:?}` prints an `Option<&str>`. */
function debugOption(value) {
  if (value === undefined) return "None";
  let out = "";
  for (const c of value) {
    const code = c.codePointAt(0);
    if (c === "\0") out += "\\0";
    else if (c === "\t") out += "\\t";
    else if (c === "\r") out += "\\r";
    else if (c === "\n") out += "\\n";
    else if (c === "\\") out += "\\\\";
    else if (c === '"') out += '\\"';
    else if (code < 0x20 || (code >= 0x7f && code <= 0x9f)) out += `\\u{${code.toString(16)}}`;
    else out += c;
  }
  return `Some("${out}")`;
}

async function run(url) {
  const [status, created] = await exchange(url, "POST", "/pet", '{"name":"Rex","photoUrls":[],"status":"available"}');
  if (status !== 200) throw new Failure(`adding a pet answered ${status}: ${created}`);
  const id = field(created, "id");
  if (id === undefined || id === "") throw new Failure("the created pet has no id");
  const [readStatus, read] = await exchange(url, "GET", `/pet/${id}`, undefined);
  if (readStatus !== 200) throw new Failure(`reading pet ${id} back answered ${readStatus}: ${read}`);
  const name = field(read, "name");
  if (name !== "Rex") throw new Failure(`pet ${id} read back with name ${debugOption(name)}, not "Rex"`);
  return id;
}

async function main() {
  const url = baseUrl();
  if (url === undefined) {
    process.stderr.write(`petstore-app: set ${SETTING}, or write it to .env\n`);
    return 2;
  }
  try {
    const id = await run(url);
    process.stdout.write(`petstore-app: ${url} added pet ${id} and read it back\n`);
    return 0;
  } catch (error) {
    if (!(error instanceof Failure)) throw error;
    process.stderr.write(`petstore-app: ${url}: ${error.message}\n`);
    return 1;
  }
}

process.exitCode = await main();
