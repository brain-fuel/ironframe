# Ironframe

**Making codebases safe for autonomous change.** Let agents work aggressively
without letting the codebase drift.

Ironframe by GoForge belongs to a family: LawSpec and LawTwin, canon and
Rice's Tax, with Rune and Wavelet on the roadmap. This release does one job:
it wires applications to their dependencies per environment, either the real
dependency or a [LawTwin](https://github.com/brain-fuel/lawtwin) twin.
[LawSpec](https://github.com/brain-fuel/lawspec) knows nothing about LawTwin,
and Ironframe never contains contracts or twin internals.

- **A manifest**, `ironframe.yaml`, says what each dependency is in each
  environment: `real`, with its endpoint and a credentials reference, or
  `twin`, with its image, version, configuration and declared conformance
  level. It is checked against a JSON Schema and its cross-field rules, and
  every problem is reported with its path.
- **`ironframe up <env>`** runs twins locally through podman and a generated
  compose file, or deploys them to AWS ECS Fargate, GCP Cloud Run (HTTP
  twins), GCP Compute Engine (TCP twins such as Kafka) or Azure Container Apps
  through OpenTofu modules. `down`, `status` and `plan` do what
  they say.
- **A configuration service** serves each environment's connection settings,
  and sync adapters write the same settings into AWS AppConfig, GCP Parameter
  Manager, Azure App Configuration and `.env` files, so applications read
  configuration the way they already do.
- **Twins set up and driven through their control plane.** A twin binding
  gives its seed, the contract it serves, a state to force and faults to
  raise at start, and where its admin API is; `ironframe twin <dependency>
  inspect|force|fault|history|advance` drives it as `lawtwin` does. A twin's
  conformance level is read from its release's conformance report, or its
  image's label, and a declared level that disagrees is refused.
- **An environment attestation**, a small tool-neutral JSON format, records
  which endpoint each dependency reached and whether it was real or a
  stand-in, with the stand-in's level, seed and the SHA-256 digest of its
  history, for tools such as `lawspec evidence`.

- **CALM architectures as the source of wiring.** A CALM 1.2 architecture
  names the services and the edges between them; Ironframe's decorators,
  attached by unique-id, give each node and edge its LawSpec contract identity
  and each node its real or twin binding per environment. `ironframe resolve`
  refuses unresolved, ambiguous or incompatible bindings by element; diagrams
  (Mermaid, Graphviz, or CALM's own widgets), each application's settings and
  the OpenTofu root are exported from the one resolved topology without
  deploying anything; `ironframe run` and `ironframe app` run an application
  with its settings and attest the completed run with architecture, contract,
  implementation and run identities, which `lawspec evidence` reads.
  `examples/calm-shop` runs one application's unchanged laws against real,
  twin and mixed bindings: `docs/how-to/run-the-calm-demonstrations.md`.

## Install

Node 22 or later is required. No Haskell toolchain is needed.

```sh
npm i -g ironframe
ironframe --version
```

From a checkout, the package is in `npm/` with its WASM core built:
`node npm/bin/ironframe.mjs` runs the command. Run `tools/wasm.sh` after
changing the core, and `npm ci` in `npm/` before syncing to a cloud, which
needs the cloud SDKs.

## Quick start

LawTwin's images, `lawtwin/kafka:0.1.0` and `lawtwin/http:0.1.0`, are built in
the lawtwin repository with `make image image-http`.

```sh
make config-service-image
cd examples/kafka-app
ironframe validate               # reads the twin's conformance report
ironframe up local               # LawTwin's Kafka twin in podman, seed 42
node app.mjs                     # reads KAFKA_BOOTSTRAP_SERVERS from .env
ironframe twin kafka history     # what the app did, as contract calls
ironframe attest local           # stand-in, level answers, seed, history digest
ironframe down local
```

`examples/petstore-app` does the same against LawTwin's HTTP twin serving the
Petstore contract. The tutorial, `docs/tutorials/wire-the-kafka-example.md`,
walks through both, and `make e2e` runs them as a test.

## Layout

| Path | What it holds |
| --- | --- |
| `src/Ironframe/` | The pure Haskell core: the manifest and its checks, CALM architectures and decorators, resolution, the exports, compose and OpenTofu generation, sync planning, the attestation, the configuration service's answers and the command line. |
| `test/` | The core's native tests, the corpus included. |
| `dev/` | `ironframe-dev`: generates the embedded schemas and checks `npm/build.json`. |
| `wasm/`, `tools/wasm.sh` | The WASM build of the core with ghc-wasm-meta. |
| `npm/` | The npm package `ironframe`: the WASM core, the Node host that performs its effects, the cloud SDK adapters, the `ironframe` command and the configuration service. |
| `config-service/` | The configuration service's `Containerfile`. |
| `corpus/` | The parity corpus recorded from the Rust implementation before the port. |
| `modules/` | OpenTofu modules for AWS ECS Fargate, GCP Cloud Run, GCP Compute Engine and Azure Container Apps, each with a `tofu test` against a mocked provider. |
| `schema/` | The JSON Schemas of the manifest and the attestation. |
| `examples/kafka-app` | A tiny Node application reading its Kafka bootstrap servers from configuration, its manifest, and LawTwin's conformance report for the Kafka twin. |
| `examples/petstore-app` | A tiny Node application reading its Petstore API's URL from configuration, its manifest, and a conformance report for the Petstore twin. |
| `examples/calm-shop` | A Go application whose LawSpec laws use Kafka and Petstore abilities, its CALM architecture and decorators for twin, real, mixed and staging environments. |
| `schema/calm/` | The Ironframe decorator schemas and the CALM 1.2 meta schemas they extend. |
| `proposals/` | Changes proposed to the family's other projects. |
| `docs/` | Tutorials, how-to guides, reference and explanation. |

## Developing

```sh
make build        # the core natively and to WASM
make test         # stack test, then the npm package's tests over the WASM core
make e2e          # both examples against LawTwin's images in podman
make e2e-calm     # real/twin/mixed CALM acceptance; set IRONFRAME_LAWSPEC_PACKAGE
make lint         # -Werror build and node --check
make integrity    # npm/build.json matches the sources and the WASM core
make tofu-check   # tofu validate and tofu test for every module
make canon        # canon check, with CANON_HOME pointing at a canon checkout
make check        # lint, test, integrity, tofu-check and canon
```

For completed-run CALM acceptance, set `IRONFRAME_LAWSPEC_PACKAGE` to a packed
build of the merged LawSpec checkout. The example's published 0.26.0 pin predates
completed-run evidence. The [CALM demonstration guide](docs/how-to/run-the-calm-demonstrations.md)
shows the archive, CALM tooling and retained-evidence options.


There is no hosted CI; every check runs locally. You need stack, ghc-wasm-meta
(`wasm32-wasi-ghc` and `wasm32-wasi-cabal`, GHC 9.14) for the WASM core, Node 22
or later, podman with a compose provider for local environments, and OpenTofu
for cloud environments and `make tofu-check`.
`docs/explanation/architecture.md` explains the core, the host and the corpus.

The repository follows canon's canonical format: `canon.yaml`,
`canonical_refs.yaml` for every work cited, `canonical_decisions.yaml` for
every decision, and `canonical_exemptions.yaml`, which defers vetting to 1.0.

## License

MIT; see `LICENSE`.
