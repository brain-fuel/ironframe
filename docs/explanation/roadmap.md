---
id: ironframe.explanation.roadmap
kind: explanation
title: Roadmap
---
# Roadmap

Ironframe is one of a family by GoForge: LawSpec and LawTwin, canon and Rice's
Tax, with Rune and Wavelet on the roadmap. Versions follow Semantic
Versioning. ref:semver-2

## 0.1: wiring

This release does one thing: it wires applications to their dependencies per
environment, the real dependency or a LawTwin twin. ref:DEC-wiring-in-ironframe

- The manifest, `ironframe.yaml`, its JSON Schema and its checks.
  ref:DEC-manifest-shape
- `up`, `down`, `status` and `plan`, locally through podman and compose, and in
  AWS, GCP and Azure through OpenTofu modules. ref:DEC-podman-compose
  ref:DEC-opentofu
- The configuration service, and sync into AWS AppConfig, GCP Parameter
  Manager, Azure App Configuration and env files. ref:DEC-config-service
  ref:DEC-config-sync
- The environment attestation, version 1. ref:DEC-attestation-format

## Still open

- A TCP twin on GCP, which Cloud Run cannot serve. ref:DEC-cloud-run-http-only
- Exercising the AWS client against an emulator: LocalStack's image now
  requires an auth token. ref:DEC-config-sync
- Shared OpenTofu state for cloud environments.
- Vetting every comment, page, decision and reference, deferred to 1.0.
  ref:DEC-vetting-deferred
