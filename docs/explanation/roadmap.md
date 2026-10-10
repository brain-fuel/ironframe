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

## 0.1.x: LawTwin's twins

- LawTwin's Kafka and HTTP twins in the examples, set up through their control
  plane at start, and driven with `ironframe twin`. ref:DEC-twin-control-plane
- Conformance levels read from a twin release's report or image label and
  checked against the declared level. ref:DEC-conformance-from-report
- A stand-in's seed and history digest in the attestation. ref:DEC-history-digest
- TCP twins on GCP through Compute Engine. ref:DEC-gce-for-tcp-twins

## Still open

- A GKE Autopilot module, for teams that run GKE. ref:DEC-cloud-run-http-only
- The address a TCP twin advertises on ECS Fargate and Container Apps, set by
  the module as Compute Engine's is.
- Exercising the AWS client against an emulator: LocalStack's image now
  requires an auth token. ref:DEC-config-sync
- Shared OpenTofu state for cloud environments.
- Vetting every comment, page, decision and reference, deferred to 1.0.
  ref:DEC-vetting-deferred
