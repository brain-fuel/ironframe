---
id: ironframe.reference.host-protocol
kind: reference
title: Host protocol
---
# Host protocol

The core is pure. It answers one kind of call: a JSON request in, a JSON
response out. A host runs a method by calling the core, performing the effect
the core names, and calling again with one more result, until the core
finishes. The Node host is `npm/host.mjs`; the loop is `npm/protocol.mjs`.
ref:DEC-host-protocol ref:DEC-haskell-wasm-core

## The call

The WASM core exports one function, `ironframe_call`, through GHC's JavaScript
FFI. It takes the request as JSON text and returns the response as JSON text.
`npm/launcher.mjs` loads `npm/core.wasm` under `node:wasi` with no files, no
environment and no preopened directories, and serializes calls: the core
handles one request at a time. ref:ghc-wasm-jsffi ref:node-wasi

## Request

```json
{"method": "cli", "params": {"argv": ["validate"], "cwd": "/work"}, "effects": [{"ok": "/work"}]}
```

| Field | Meaning |
| --- | --- |
| `method` | The method to run. |
| `params` | Its parameters, a JSON value. |
| `effects` | The result of every effect performed so far, in order. Empty on the first call. |

## Response

| Response | Meaning |
| --- | --- |
| `{"done": value}` | The method finished with this result. |
| `{"failed": message}` | The method failed; the message says why. |
| `{"effect": effect, "index": n}` | Perform this effect next. `n` is the number of results the request carried; a host that holds another number is out of step. |
| `{"error": message}` | The request is not JSON, or there is no such method. |

The core runs the method from the start on every call, feeding it the results
in order, so the same method, parameters and results always give the same
response. The host only appends; it never edits a result it has sent.

## Results

Every effect's result is one of:

| Result | Meaning |
| --- | --- |
| `{"ok": value}` | The effect was performed; `value` is described with each effect below. |
| `{"error": text}` | It failed. The text is worded as Rust's `io::Error` words it, such as `No such file or directory (os error 2)`, mapped from Node's error code. |
| `{"error": text, "notFound": true}` | It failed because the path does not exist. |

The host never throws: an effect that throws becomes `{"error": ...}`, and an
effect it does not know becomes `{"error": "the host does not know the effect ..."}`.

## Effects

Every effect is a JSON object whose `effect` field names it.

### Files

| Effect | Fields | `ok` value |
| --- | --- | --- |
| `readFile` | `path` | The file's text. Text that is not UTF-8 is the error `stream did not contain valid UTF-8`. A byte-order mark is kept. |
| `writeAtomically` | `path`, `text` | `true` when the file changed; `false` when it already held the text. Writes through `<path>.tmp` beside it and renames, creating the directory. |
| `writeFile` | `path`, `text` | `null`. Writes directly. |
| `removeFile` | `path` | `null`. |
| `removeTree` | `path` | `null`. Removes a directory and everything in it. |
| `createDir` | `path` | `null`. Creates the directory and its parents. |
| `canonicalize` | `path` | The absolute path, symbolic links resolved. |
| `cwd` | none | The host's working directory. |

### The environment and tools

| Effect | Fields | `ok` value |
| --- | --- | --- |
| `env` | `name` | The variable's value, or `null` when it is not set. |
| `locate` | `variable`, `names`, `fallbacks` | The path in `variable` when set and not empty; else the first of `names` found as a file on `PATH`; else the first of `fallbacks` that is a file; else `null`. |
| `run` | `program`, `args`, `stream`, and optionally `cwd`, `env`, `inheritStdin` | `{success, code, stdout, stderr}`. `code` is `null` when a signal ended the process. With `stream` true the output goes to the terminal and `stdout` and `stderr` are empty. `env` is added to the host's environment. Standard input is closed unless `inheritStdin` is true. A program that cannot start is an error. |
| `readStdin` | none | Everything on standard input, as UTF-8 text. |
| `tempDir` | none | `TMPDIR` as it is, else `/tmp`. |
| `processId` | none | The host's process id. |

`run` is how the core drives podman, OpenTofu, the CALM CLI, git and an
application's own command.

### Network and time

| Effect | Fields | `ok` value |
| --- | --- | --- |
| `http` | `method`, `url`, `headers`, `timeoutMs`, and optionally `body` | `{status, body}`, redirects followed. When nothing answers, the error is the root cause, such as `operation timed out`. |
| `tcpProbe` | `endpoint`, `host`, `port`, `timeoutMs` | `true` when a connection to one of the host's addresses opens within the timeout and then sends a byte or stays open for 300 ms; a port forwarder that closes at once does not count. `endpoint` is the text `host` and `port` were split from. |
| `sleep` | `ms` | `null`, after that many milliseconds. |
| `now` | none | `{seconds, nanos}` since the Unix epoch, in UTC. Node's clock gives millisecond precision. |
| `monotonic` | none | A monotonic clock in milliseconds, for deadlines. |
| `uuid` | none | A fresh random UUID. |

`http` is how the core speaks to a twin's control plane.

### Output

| Effect | Fields | `ok` value |
| --- | --- | --- |
| `print` | `stream` (`stdout` or `stderr`), `text` | `null`, once the stream has taken the text, so output keeps its order. |
| `progress` | `text` | `null`. The host writes `ironframe: <text>` and a newline to standard error. |

### Cloud calls

A cloud call is named `<cloud>.<call>`. The host makes it with the cloud's
official JavaScript SDK (`npm/clouds/`), loaded on first use. A failure's
error is the SDK's reason. ref:DEC-config-sync

| Effect | Fields | `ok` value |
| --- | --- | --- |
| `aws.findApplication` | `region`, `name` | The application's id, or `null`. |
| `aws.createApplication` | `region`, `name` | The new id. |
| `aws.findEnvironment` | `region`, `application`, `name` | The environment's id, or `null`. |
| `aws.createEnvironment` | `region`, `application`, `name` | The new id. |
| `aws.findProfile` | `region`, `application`, `name` | The configuration profile's id, or `null`. |
| `aws.createProfile` | `region`, `application`, `name` | The new id of a hosted, freeform profile. |
| `aws.latestVersion` | `region`, `application`, `profile` | `{number, content}` of the latest hosted version, or `null`. |
| `aws.createVersion` | `region`, `application`, `profile`, `content` | The new version number. |
| `aws.deploy` | `region`, `application`, `environment`, `profile`, `version`, `strategy` | The deployment number. |
| `gcp.parameterExists` | `name` | Whether the parameter exists. |
| `gcp.createParameter` | `parent`, `id` | `null`. Creates a JSON-format parameter. |
| `gcp.createVersion` | `parameter`, `id`, `data` | `"created"`, or `"exists"` when a version of that id is already there. |
| `azure.get` | `endpoint`, `connectionStringEnv`, `key`, `label` | The key-value's value, or `null` when there is none. |
| `azure.put` | `endpoint`, `connectionStringEnv`, `key`, `label`, `value` | `null`. |

The AWS client authenticates through the SDK's default chain, the GCP client
through Application Default Credentials, and the Azure client with the
connection string in the variable `connectionStringEnv` names, used against
`endpoint`; the Azure SDK signs each request.

## Methods

| Method | Parameters | Result |
| --- | --- | --- |
| `version` | none | The host-protocol compatibility version (`0.1.0`). Use CLI `--version` for the release version. |
| `cli` | `argv`, `cwd` | `{exitCode}`. The `ironframe` command: `npm/bin/ironframe.mjs` runs it and exits with that code, or 2 when the method fails. |
| `configService.handle` | `settingsPath`, `method`, `path` | `{status, contentType, body}`. One answer of the [configuration service](config-service.md). |
| `corpus.check` | `case`, `fixtures` | `{pass, ...}`: whether one corpus case is reproduced, run over a scripted host inside the core. |

The core also answers methods for each operation and each library it is built
on, such as `manifest.parse`, `settings.resolve`, `compose.file`, `tofu.root`,
`attestation.fromJson`, `calm.parseArchitecture`, `json.decode`,
`yaml.decode`, `schema.validate` and `semver.requirement`. They exist so the
corpus can check each operation alone; `src/Ironframe/Api.hs` and
`src/Ironframe/Library.hs` list them. They are not a stable interface.

## The library

The package's main module, `npm/api.mjs`, exposes the same protocol:
`createIronframe({host, core})` gives `call(request)`, one raw call, and
`run(method, params)`, a method run to its end over the host. `createHost`
takes replacements for every outside dependency (files, processes, network,
fetch, clock, clouds), so a test can answer any effect itself.
