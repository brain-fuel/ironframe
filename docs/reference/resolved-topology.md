---
id: ironframe.reference.resolved-topology
kind: reference
title: Resolved topology
---
# Resolved topology

`ironframe resolve <architecture> --env <environment>` prints one environment
of a CALM architecture, resolved: the planned wiring every export and run
comes from. `up` writes it to `.ironframe/<environment>/topology.json` beside
the decorators. ref:DEC-calm-resolution ref:DEC-calm-planned-vs-completed

| Field | Meaning |
| --- | --- |
| `format`, `version` | `ironframe-resolved-topology`, `1`. |
| `architecture` | `document` and `digest` (sha256 of its bytes), its `unique_id`, `decorators` and `decorators_digest`. |
| `environment`, `project`, `runtime` | From the environment decorator. |
| `applications[]` | `node`, `name`, `contract` (package and version), `deployment` (`external`, `process` with `command` and `dir`, or `image` with `image`, `args`, `build_context`, `containerfile`), `version`, `commit`, `edges`. |
| `dependencies[]` | `node`, `name`, `contract` (package, version requirement, abilities), `binding` (the binding decorator's id), `kind` (`real` or `twin`), `provider` for a real one, `twin` (`image`, `version`, `stands_in_for`, `conformance`, `seed`, `faults`) for a twin, and `consumers`: how many application edges reach it, more than one for a shared dependency. |
| `edges[]` | `relationship`, `source`, `destination`, `protocol`, `consumes`, `settings` (templates), `kind`. |

The topology's identity is the sha256 digest of its JSON, recorded in each
run's attestation as `architecture.topology_digest`. ref:DEC-calm-identity

## Exports

`ironframe export <what> --env <environment>` writes each from the topology
alone; none deploys anything. ref:DEC-calm-exports

| `what` | Format | Output |
| --- | --- | --- |
| `topology` | | The topology as JSON. |
| `diagram` | `mermaid` (default), `dot` | A flowchart: applications, dependencies labelled `twin lawtwin/kafka:0.1.0 (answers)` or `real apache/kafka 4.1.0` and classed `real` or `twin`, edges labelled with the abilities they carry. |
| `diagram` | `calm` | The architecture with each binding in its node's name and under `metadata."ironframe-binding"`, still CALM 1.2, for any CALM tool. |
| `diagram` | `calm-template` | That architecture rendered by the CALM CLI's block-architecture widget through `calm docify`: Markdown holding a Mermaid diagram. Needs `calm` on `PATH` or in `IRONFRAME_CALM`. |
| `settings` | `json` (default), `env` with `--app` | Each application's settings, from its own edges only. A cloud twin's endpoint is known after `up`. |
| `tofu` | | The OpenTofu root of a cloud environment, one module instance `twin_<node>` per twin; `-o <dir>` writes `main.tf.json` there. |
| `compose` | | The compose file of a podman environment. |
