---
id: ironframe.reference.calm-decorators
kind: reference
title: CALM decorators
---
# CALM decorators

Ironframe reads a CALM 1.2 architecture and three decorator types attached to
its elements by unique-id. Each type's JSON Schema extends CALM's base
decorator and is printed by `ironframe schema contract | binding |
environment`; the files are `schema/calm/ironframe-*.decorator.schema.json`.
ref:DEC-calm-decorators ref:calm-decorators

## The decorators file

A JSON array of decorators, or an object with one under `decorators`, by
default `<name>.decorators.json` beside the architecture `<name>.calm.json`
(`--decorators` names another). Decorators of other types are kept and not
read. Every Ironframe decorator has CALM's base fields:

| Field | Meaning |
| --- | --- |
| `$schema` | Optional; CALM's documentation gives `https://calm.finos.org/release/1.2/meta/decorators.json#/defs/decorator`. |
| `unique-id` | The decorator's own id, unique in the file. |
| `type` | `ironframe-contract`, `ironframe-binding` or `ironframe-environment`. |
| `target` | The architecture, by file name (or a path or URL ending in it) or by its top-level `unique-id`. |
| `applies-to` | Unique-ids of elements of the architecture. |
| `data` | The type's data, below. |

Relative paths in `data`, such as a conformance report or an application's
directory, are read against the decorators file's directory.

## `ironframe-contract`

`data` has exactly one of:

| Key | Applies to | Fields |
| --- | --- | --- |
| `application` | an application node | `package` (a LawSpec package name), `version` (exact), `description` |
| `dependency` | a dependency node | `package`, `version` (a requirement: `>=0.1.0, <0.2.0`, `^0.1`, `~0.1.0`, `=0.1.0`, `*`), `abilities` (one or more `unit::ability::Name` of that package), `conformance.accept` (levels a twin must have, by name or number), `description` |
| `connection` | a `connects` relationship from an application to a dependency | `consumes` (the application's abilities whose production handler reaches the destination, each of the application's package), `settings` (setting name to template: `${endpoint}`, `${host}`, `${port}`, `${credentials}`, `${kind}`, `${name}`) |

```json
{
  "unique-id": "service-publishes-adoptions-contract",
  "type": "ironframe-contract",
  "target": ["shop.calm.json"],
  "applies-to": ["service-publishes-adoptions"],
  "data": {
    "connection": {
      "consumes": ["shop.adoptions::ability::Adoptions"],
      "settings": { "KAFKA_BOOTSTRAP_SERVERS": "${endpoint}" }
    }
  }
}
```

## `ironframe-binding`

What one node is in one environment. `data.environment` names the environment;
`data` has exactly one of:

| Key | Applies to | Fields |
| --- | --- | --- |
| `real` | a dependency node | the fields of a manifest's `real` binding ([manifest](manifest.md)), and `provider` (`name`, `version`), recorded in the attestation |
| `twin` | a dependency node | the fields of a manifest's `twin` binding, and `stands-in-for` (`package`, exact `version`, `abilities`): the contract identity the twin stands in for |
| `application` | an application node | `external` (deployed by its own tooling; the default) or `managed` with `process` (`command`, `dir`) or `image` (`image`, `args`, `build.context`, `build.containerfile`); optional `implementation` (`version`, `commit`) |

```json
{
  "unique-id": "adoptions-log-twin",
  "type": "ironframe-binding",
  "target": ["shop.calm.json"],
  "applies-to": ["adoptions-log"],
  "data": {
    "environment": "twin",
    "twin": {
      "image": "lawtwin/kafka",
      "version": "0.1.0",
      "stands-in-for": {
        "package": "lawtwin.kafka",
        "version": "0.1.0",
        "abilities": ["lawtwin.kafka::ability::Broker"]
      },
      "conformance": { "report": "conformance/lawtwin-kafka-0.1.0.json" },
      "ports": [9092],
      "seed": 42,
      "admin": { "port": 9644 }
    }
  }
}
```

A twin is compatible with its node when it stands in for the node's package, at
a version within the node's requirement, for every ability the node requires;
its conformance report agrees with it and checked that package; and its level
is one the node accepts. ref:DEC-calm-compatibility

## `ironframe-environment`

Applies to the system node (or nodes) the environment deploys.

| Field | Meaning |
| --- | --- |
| `environment` | The environment's name: lowercase letters, digits and `-`. |
| `project` | The name every container, compose project and cloud resource is prefixed with. |
| `runtime` | `podman`, `aws`, `gcp` or `azure`. |
| `cloud`, `sync`, `config_service` | As in a manifest's environment. |
| `description` | For a reader. |
| `observation` | Optional run receiver: `node` names a dedicated CALM node; `relationships` names exactly one CALM `interacts` relationship from every application to that node. |

## Refusals

`ironframe resolve` and every verb given `--architecture` refuse, naming the
element or decorator, an architecture that breaks CALM 1.2 or repeats a
unique-id, a decorator that breaks its schema, targets another architecture
or applies to a missing element, an undeclared or doubly declared environment,
two contracts on one element, an edge from an application to a dependency
without a connection contract, a dependency without a binding or with two, an
ability of another package or consumed over two edges, a setting read two ways,
and an incompatible twin. ref:DEC-calm-refusals

```text
ironframe: shop.decorators.json is refused:
  - decorator "adoptions-log-twin": the twin stands in for lawtwin.kafka 0.9.0, outside node "adoptions-log"'s requirement >=0.1.0, <0.2.0; it is incompatible
  - node "pet-registry": has no binding in environment "twin"; it is unresolved
```
