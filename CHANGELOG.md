# Changelog

All notable changes to Ironframe are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and
Ironframe adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- The calm-shop example pins LawSpec 0.29.2 instead of 0.26.0. Its laws and
  adapter use `Maybe`'s renamed constructors, `Present` and `Absent`
  (`LawSpecPresent` and `LawSpecAbsent` in Go); the laws are otherwise
  unchanged, and LawSpec's law-set analysis reports nothing for them. LawSpec
  0.27 onward consumes completed-run attestations, so `make e2e-calm` checks
  completed evidence against the published pin and `IRONFRAME_LAWSPEC_PACKAGE`
  is needed only for an unpublished build.

## [0.1.0] - 2026-10-21

### Added

- The CALM acceptance test checks completed LawSpec evidence separately from
  cached startup wiring, retains attestations and exports on request, and can
  select local compiler archives and fresh fixture/application image builds.
  Missing diagram edges, infrastructure modules and injected settings are
  exercised as negative correspondence controls.

- CALM 1.2 architectures as the source of wiring (`--architecture`): the
  architecture is checked against the embedded CALM 1.2 meta schemas (and by
  `calm validate` with `validate --calm-cli`); `ironframe-contract`,
  `ironframe-binding` and `ironframe-environment` decorators, each a JSON
  Schema extending CALM's base decorator, give nodes and edges their LawSpec
  contract identities and nodes their real or twin binding per environment.
- `ironframe resolve`: one environment's resolved topology, or a refusal
  naming every unresolved, ambiguous or incompatible element (a twin's
  stand-in package, version range, abilities and accepted conformance levels
  are checked against its node's contract).
- `ironframe export topology | diagram | settings | tofu | compose`, each from
  the resolved topology and without deploying: Mermaid and Graphviz diagrams
  marking real and twin, an annotated CALM architecture and its rendering by
  the CALM CLI's block-architecture widget, per-application settings, the
  OpenTofu root.
- `ironframe run`, `ironframe app` (managed applications, as a process or a
  podman image) and `ironframe attest --app | --complete` (applications
  deployed by other tooling): settings injected, the run attested as it begins
  and when it completes.
- The attestation, still version 1, gains optional `architecture`,
  `application` and `execution` (wired, running, completed), and per
  dependency `node`, `edge`, `contract`, `implementation` (real provider or
  fixture), `completed` and `stand_in.stands_in_for`.
- `ironframe twin <dependency> replay`.
- `examples/calm-shop` and `make e2e-calm`: one Go application's LawSpec laws
  run unchanged against twin, real and mixed bindings of Kafka and a Petstore
  API, with a shared dependency, faults, resets and deterministic replay, and
  `lawspec evidence` reading each completed attestation.
- `proposals/lawspec-completed-run-attestations.md`.

- The manifest, `ironframe.yaml`: environments, and per environment each
  dependency bound to `real` (endpoint, credentials reference, optionally an
  image to run locally) or `twin` (image, version, configuration, declared
  conformance level, ports). A JSON Schema and cross-field rules check it, and
  every problem is reported with the path of the field at fault.
- `ironframe up`, `down`, `status`, `compose` and `settings` for podman
  environments, through a generated compose file. `up` checks every image
  before starting anything and names each missing one.
- `ironframe plan` and `up` and `down` for AWS, GCP and Azure environments,
  through OpenTofu modules for ECS Fargate, Cloud Run and Container Apps, each
  tested with `tofu test` against a mocked provider.
- The configuration service, a small HTTP server in a container that serves
  each environment's settings as JSON, dotenv or single values.
- `ironframe sync`: settings written to env files, AWS AppConfig, GCP
  Parameter Manager and Azure App Configuration, writing nothing when a target
  already holds them.
- The environment attestation, version 1, written by `up` and
  `ironframe attest`, and its JSON Schema.
- `examples/kafka-app`, an application that reads its Kafka bootstrap servers
  from its configuration, with a manifest for a local twin, a local Apache
  Kafka, and AWS.
- canon's canonical format from the first commit, with vetting deferred to
  1.0.
- Twins set up through their control plane: a twin binding takes `seed`,
  `contract` (both handed over in `TWIN_CONFIG`), `state`, `faults` and
  `admin`. `up` waits for each twin's control plane, sets its seed, forces its
  state and raises its faults in order, and keeps what it learnt in
  `.ironframe/<environment>/twins.json`.
- `ironframe twin <dependency> inspect|force|fault|faults|history|advance|seed|reset|laws`,
  which speaks a twin's admin API with `lawtwin`'s meaning and exit statuses.
- Conformance read from evidence: `conformance` may name a twin release's
  report or an image label; a declared level that disagrees, or a report for
  another release, twin or contract, is refused with the field at fault.
- The attestation's stand-in gains optional `seed`, `history_digest`
  (`sha256:<hex>`) and `history_entries`; `ironframe attest` reads them from
  each twin's control plane, keeps the history beside the attestation, and
  lists each dependency.
- `examples/kafka-app` runs LawTwin's `lawtwin/kafka:0.1.0` in `local`, at
  level 3 (answers) from LawTwin's published report, and also asks for its
  topic's metadata; `examples/petstore-app`, new, runs against
  `lawtwin/http:0.1.0` serving the Petstore contract. `make e2e` brings both
  up, runs both apps, drives the twins, attests and takes them down.
- `modules/gcp-compute-engine`, for TCP twins such as Kafka on GCP, which
  Cloud Run cannot serve: a twin with `protocol: tcp` runs there, and
  `advertise_variable` hands it its reserved address. Each module is handed
  only the inputs it takes.

### Changed

- Ironframe is a pure Haskell core compiled to WebAssembly with a thin Node
  host, distributed as the npm package `ironframe` (`npm i -g ironframe`),
  instead of Rust crates. The core does no IO: it names each effect it needs
  and the host performs it (`docs/reference/host-protocol.md`). Behaviour is
  held to a corpus recorded from the Rust implementation; the deliberate
  differences are listed in `docs/explanation/architecture.md`.
- The configuration service runs the npm package's Node host over the same
  core, in an image built from `config-service/Containerfile` on
  `node:22-alpine`.
- Cloud sync calls the official JavaScript SDKs, `@aws-sdk/client-appconfig`,
  `@google-cloud/parametermanager` and `@azure/app-configuration`, which also
  sign Azure's requests.
- The examples `kafka-app` and `petstore-app` are Node applications, run with
  `node app.mjs`.
- `make` keeps its verbs over stack, `tools/wasm.sh` and `node --test`, and
  adds `make wasm` and `make integrity`.
