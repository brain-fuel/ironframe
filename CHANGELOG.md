# Changelog

All notable changes to Ironframe are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and
Ironframe adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
- The configuration service, a 2.4 MB static image that serves each
  environment's settings as JSON, dotenv or single values.
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
