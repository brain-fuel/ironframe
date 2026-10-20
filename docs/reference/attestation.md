---
id: ironframe.reference.attestation
kind: reference
title: Environment attestation
---
# Environment attestation

An environment attestation records, for one run in one environment, which
endpoint each dependency was wired to, whether it answered, and whether it was
the real dependency or a stand-in. Any tool may write one and any tool may read
one: nothing in the format names Ironframe, LawSpec or LawTwin. Ironframe
writes it during `ironframe up` and on demand with `ironframe attest`; a tool
such as `lawspec evidence` reads it to report which obligations ran against
stand-ins. ref:DEC-attestation-format ref:DEC-three-planes

The JSON Schema is `schema/attestation-v1.schema.json`, and `ironframe schema
attestation` prints it. ref:json-schema-2020-12

## Format, version 1

```json
{
  "format": "environment-attestation",
  "version": 1,
  "environment": "local",
  "run": {
    "id": "839f6cf4-02e4-4a52-971f-e1dbdca1d141",
    "started_at": "2026-10-09T19:30:31.606738Z",
    "recorded_at": "2026-10-09T19:30:33.153789Z"
  },
  "producer": { "name": "ironframe", "version": "0.1.0" },
  "dependencies": [
    {
      "name": "kafka",
      "endpoint": "localhost:9092",
      "reached": true,
      "kind": "stand-in",
      "stand_in": {
        "product": "lawtwin/kafka",
        "version": "0.1.0",
        "conformance": "answers",
        "seed": 42,
        "history_digest": "sha256:63fbfb17b3e4fb876dd0a4d01835e3dbd53000decce89aeff6eb103253acbd08",
        "history_entries": 3
      }
    },
    {
      "name": "payments",
      "endpoint": "https://payments.example.com",
      "reached": true,
      "kind": "real"
    }
  ]
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `format` | `"environment-attestation"` | Identifies the document. |
| `version` | `1` | The format version. |
| `environment` | string, not empty | The environment's name, as the writer names it. |
| `run.id` | string, not empty | Unique to the run; readers compare it and never parse it. |
| `run.started_at` | RFC 3339 time | When the run began. ref:rfc3339 |
| `run.recorded_at` | RFC 3339 time | When the document was written; not before `started_at`. |
| `producer` | object, optional | The writing tool's `name` and `version`. Informative only. |
| `dependencies[].name` | string, unique | The dependency. |
| `dependencies[].endpoint` | string, not empty | The endpoint the application was handed, `host:port` or a URL. |
| `dependencies[].reached` | boolean | Whether the writer reached the endpoint when it recorded the run. |
| `dependencies[].kind` | `"real"` or `"stand-in"` | The real dependency, hosted or run from its own image, or a stand-in. |
| `dependencies[].stand_in` | object | Present exactly when `kind` is `stand-in`: `product`, `version` and the declared `conformance` level, and optionally the three fields below. |
| `stand_in.seed` | integer, optional | The seed of the stand-in's random choices in the run. |
| `stand_in.history_digest` | string, optional | `sha256:` and 64 lowercase hex digits: the SHA-256 of the stand-in's history of the run, as its maker's tool exports it, when the document was recorded. ref:DEC-history-digest ref:fips-180-4 |
| `stand_in.history_entries` | integer, optional | How many entries that history held. |

## Runs resolved from an architecture

A run of an application resolved from a CALM architecture (`ironframe run`,
`ironframe app`, or `ironframe attest --app` and `--complete` around a run
another tool performs) adds optional fields, which a version 1 reader that
does not know them ignores. ref:DEC-attestation-architecture ref:DEC-calm-run

| Field | Meaning |
| --- | --- |
| `architecture` | `document`, `digest` (sha256 of the architecture's bytes), `unique_id`, `decorators`, `decorators_digest`, `topology_digest` (the resolved topology: the planned wiring) and `elements`, the unique-ids of the application node, its relationships and the dependency nodes they reach. ref:DEC-calm-identity |
| `application` | `node`, `contract` (`package`, `version`) and `implementation` (`kind` `application`, `product`, `version`, `commit`, `image_digest`). |
| `execution` | `status`: `wired` (up and attest: endpoints probed, nothing ran), `running` (the run had begun) or `completed`; `command`; `exit_code` and `finished_at`, present exactly when completed; `environment_run`, the run `up` started. ref:DEC-calm-planned-vs-completed |
| `dependencies[].name` | The application ability that reaches the dependency, `unit::ability::Name`, as LawSpec matches it; one record per ability. |
| `dependencies[].node`, `.edge` | The dependency node and the relationship the application reached it through. |
| `dependencies[].contract` | The contract the binding had to satisfy: `package`, version requirement, `abilities`. |
| `dependencies[].implementation` | `kind` `real-provider` or `fixture`, `product`, `version`, `image_digest`. |
| `stand_in.stands_in_for` | The contract identity the twin stands in for. |
| `dependencies[].completed` | Only on a completed run: `reached` when it completed, and a stand-in's `history_digest` and `history_entries` then. |

The version 1 fields record the run as it began, including each stand-in's
`history_digest`, and stay the same when it completes, because LawSpec keys a
law's native result by them; what was seen at completion is under `completed`.

## Rules for readers and writers

- A reader rejects a document whose `format` is not
  `environment-attestation`, or whose `version` it does not know.
- A reader ignores fields it does not know, so a writer may add fields without
  changing the version. A change that would mislead an older reader raises the
  version.
- Dependency names are unique, and `stand_in` is present exactly when `kind`
  is `stand-in`; the schema states the second rule, and the reader in the
  `ironframe-attestation` crate checks both.
- The conformance level is the one the stand-in's maker declares for that
  release. The attestation records it and does not judge it.
- `seed`, `history_digest` and `history_entries` were added to version 1 as
  optional fields, which older readers ignore. A reader that knows them
  rejects a `history_digest` of any other form. With a deterministic
  stand-in, the same seed and the same requests give the same history, so the
  same digest names the same run, and evidence can cite exactly what the
  application talked to. ref:REQ-attestation-stand-in-run
- `reached` is a TCP connection that opens and stays open for a moment.
  Podman's port forwarder accepts a connection before anything listens behind
  it, so a connection closed at once does not count.

## Where Ironframe writes it

`ironframe up <environment>` writes `.ironframe/<environment>/attestation.json`
beside the manifest, after it has set up each twin, waited for each started
container and run the sync targets. `ironframe attest <environment> [--output
<path>]` writes it again, for the run `up` started, with every endpoint probed
afresh; run it after the application, so the digest covers what it did.

For each twin with a control plane, Ironframe reads the seed from `GET
/v1/twin` and the history from `GET /v1/history?format=jsonl`, digests the
history as it was served, and keeps it in
`.ironframe/<environment>/history/<dependency>.jsonl`, so

```sh
shasum -a 256 .ironframe/local/history/kafka.jsonl
```

prints the digest the attestation records, and the history can be replayed
through the twin's contract with `lawtwin replay`. The level is the one read
from the twin's report or image label, as the manifest says
(ref:DEC-conformance-from-report).
