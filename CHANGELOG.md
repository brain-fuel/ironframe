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
