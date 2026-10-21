---
id: ironframe.explanation.architecture
kind: explanation
title: Architecture
---
# Architecture

Ironframe is a pure Haskell core compiled to WebAssembly and a thin Node host
around it, shipped as the npm package `ironframe`. The core decides
everything. The host performs effects and nothing else.
ref:DEC-haskell-wasm-core

```text
ironframe (npm/bin/ironframe.mjs)        config-service.mjs (in its image)
        │                                         │
        └────────► npm/protocol.mjs: run(core, method, params, host)
                        │                    ▲
             request    │                    │ effect result
                        ▼                    │
              npm/core.wasm  ──effect──►  npm/host.mjs ──► files, processes,
              (src/Ironframe, pure)                        HTTP, TCP, clocks,
                                                           cloud SDKs
```

## The core

All logic is Haskell under `src/Ironframe/`:

- the manifest, its JSON Schema and its rules across fields;
- CALM 1.2 architectures, their schema checks, identities and decorators;
- resolving real and twin bindings, and every refusal;
- the exports: Mermaid, Graphviz, the annotated architecture for `calm
  docify`, settings, the OpenTofu root and the compose file;
- building and verifying the attestation;
- planning a sync: what to create, when to write, when to leave alone;
- the configuration service's answers;
- the command line.

The core never does IO. It is built natively with stack for its tests, and to
WASM by `tools/wasm.sh` with ghc-wasm-meta's `wasm32-wasi-cabal`. The result is
`npm/core.wasm` and its JavaScript glue `npm/core_jsffi.js`, both fingerprinted
in `npm/build.json`. `stack run ironframe-dev -- integrity` checks the
fingerprints against the sources. ref:ghc-wasm-meta

## The host

The host is a few small modules in `npm/`:

| File | Does |
| --- | --- |
| `launcher.mjs` | Loads `core.wasm` under `node:wasi`, with no files and no environment. |
| `protocol.mjs` | Runs a method to its end: call, perform, append, call again. |
| `host.mjs` | Performs each effect with Node: files, processes, `fetch`, TCP, clocks, UUIDs, printing. |
| `clouds/aws.mjs`, `gcp.mjs`, `azure.mjs` | Perform cloud calls with the official SDKs. |
| `bin/ironframe.mjs` | The command: the core's `cli` method. |
| `config-service.mjs` | The configuration service: an HTTP server whose every answer is the core's `configService.handle`. |

The host holds no rules of its own. It reports results in the words the Rust
implementation used, so the core's messages stay the same.
ref:DEC-config-service ref:DEC-config-sync

## Replay

A command is a program over the results of the effects performed so far. Run
over those results, it either finishes or names the next effect it needs. The
host performs that effect and calls again with one more result. The core runs
the program again from the start; every effect it asked for before gets the
same answer, so it reaches the same point and asks for the next one.
ref:DEC-host-protocol

Replay costs time: a command that needs n effects runs its program n times.
It buys three things:

- **One core, many hosts.** The Node host, the native test host and the
  corpus's scripted host answer the same effects. The core cannot tell them
  apart.
- **Determinism.** The same inputs and the same results give the same
  requests in the same order. A test checks the order of a command's steps by
  reading its effects, such as that every image is checked before anything
  starts.
- **No IO in WASM.** The core needs no WASI files, sockets or clocks, so it
  runs anywhere Node runs.

[Host protocol](../reference/host-protocol.md) lists the request, the
response and every effect.

## What is pure and what is an effect

| Pure, in the core | An effect, in the host |
| --- | --- |
| Reading and checking JSON, YAML and JSON Schema | Reading and writing files |
| Resolving settings, bindings and topologies | Running podman, OpenTofu, the CALM CLI, git and applications |
| Generating compose files, OpenTofu roots, diagrams and dotenv | HTTP to a twin's control plane |
| Building and checking attestations, SHA-256 digests | TCP probes of endpoints |
| Deciding what a sync writes | Cloud SDK calls |
| Wording every message and exit status | Clocks, UUIDs, the process id, printing |

## Trust boundaries

Some libraries the Rust implementation used have no pure Haskell equal that
builds under ghc-wasm. Ironframe has its own, each checked against the corpus
and none proven equivalent.

- **JSON Schema.** A bespoke minimal validator for draft 2020-12
  (`src/Ironframe/Json/Schema.hs`, `Regex.hs`). The maintained Haskell
  libraries do not fit: hjsonschema is draft 4 and needs PCRE's C library and
  Template Haskell, aeson-schema is draft 3, json-schema is not json-schema.org's
  language, and aeson-schemas is type-level. It implements `$ref` (JSON
  pointers, CALM's `#/defs` included), `type`, `const`, `enum`, `required`, the
  length, size and range keywords, `pattern`, `properties`,
  `patternProperties`, `additionalProperties`, `propertyNames`, `items`,
  `allOf`, `anyOf`, `oneOf`, `not` and `if`/`then`/`else`. `format` is an
  annotation, as jsonschema-rs treats it for 2020-12. Any other keyword, such
  as `contains`, `uniqueItems` or `$dynamicRef`, is refused when the schema is
  compiled, so a schema that needs one fails loudly. Its errors match
  jsonschema-rs 0.33 over 313 corpus cases. ref:json-schema-2020-12
  ref:jsonschema-rs
- **YAML.** A port to Haskell of unsafe-libyaml 0.2.11's reader, scanner,
  parser and emitter and of serde_yaml 0.9.34's loader and quoting rules
  (`src/Ironframe/Yaml.hs`). YAML is read, refused and written as the Rust
  implementation did, error messages included. Besides the corpus, it was
  compared with the real serde_yaml over about 100,000 generated cases.
  ref:unsafe-libyaml ref:serde-yaml
- **JSON, versions, times, digests.** JSON is read and written as
  serde_json 1.0.151 does, floats included; semantic versions as the semver
  crate 1.0.28; RFC 3339 times as the time crate; SHA-256 with the pure SHA
  package. ref:sha-package ref:rfc3339
- **Clouds.** The official JavaScript SDKs are the boundary. The corpus checks
  the calls the core asks for and how it reads their answers, not the SDKs.
  ref:DEC-config-sync

## The corpus

`corpus/*.json` was captured from the Rust implementation before the port: the
inputs and exact outputs of every core operation, the command line and the
configuration service, and `corpus/libs-*.json` for each library the core
emulates. It is the parity oracle. The capture harnesses were Rust tests,
removed with the Rust code: `crates/ironframe-core/tests/corpus.rs`,
`corpus_libs.rs` and `crates/ironframe-cli/tests/corpus_cli.rs` in the
commits that added the corpus. One recorded case was corrected after the
capture: a fake twin's random port the harness had left in a progress line.

- `Ironframe.Corpus` checks every case with a scripted host: files in memory,
  and each process, HTTP request and cloud call answered from the recording,
  in order. It runs natively under `stack test` and in WASM under
  `node --test npm/test/corpus.test.mjs`.
- The command's corpus runs through the real command
  (`npm/test/cli-corpus.test.mjs`) and through the native build
  (`test/CliCorpusSpec.hs`), with fake podman and OpenTofu scripts.

The deliberate differences from the Rust implementation:

- Azure App Configuration requests are signed by `@azure/app-configuration`,
  not by Ironframe's own HMAC code.
- Timestamps have the millisecond precision of Node's clock.
- The command's help and usage text is Ironframe's own, not clap's.
- Operating-system error texts are mapped from Node's error codes.

## Separate from LawSpec

LawSpec's compiler is the precedent: a Haskell core compiled with ghc-wasm-meta
and hosted by a thin npm package. Ironframe follows its launcher, its
`tools/wasm.sh` and its integrity check, but shares no code with it. Ironframe
has no Haskell dependency on LawSpec, and LawSpec never imports Ironframe. The
attestation is the only thing that crosses, as a neutral published JSON
schema, `schema/attestation-v1.schema.json`. ref:DEC-three-planes ref:lawspec
