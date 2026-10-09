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
      "stand_in": { "product": "lawtwin/kafka", "version": "0.1.0", "conformance": "unrated" }
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
| `dependencies[].stand_in` | object | Present exactly when `kind` is `stand-in`: `product`, `version` and the declared `conformance` level. |

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
- `reached` is a TCP connection that opens and stays open for a moment.
  Podman's port forwarder accepts a connection before anything listens behind
  it, so a connection closed at once does not count.

## Where Ironframe writes it

`ironframe up <environment>` writes `.ironframe/<environment>/attestation.json`
beside the manifest, after it has waited for each started container and run
the sync targets. `ironframe attest <environment> [--output <path>]` writes it
again, for the run `up` started, with every endpoint probed afresh.
