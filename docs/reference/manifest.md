---
id: ironframe.reference.manifest
kind: reference
title: The manifest, ironframe.yaml
---
# The manifest, `ironframe.yaml`

The manifest says which dependencies an application has, how the application
reads them from its configuration, and what each one is in every environment:
the real dependency or a twin. It is the only source; everything Ironframe
generates lives in `.ironframe/<environment>/` beside it, which git ignores.
ref:DEC-manifest-shape

Its JSON Schema is `schema/ironframe-v1.schema.json`; `ironframe schema`
prints it, and an editor with a YAML language server can use it directly.
ref:json-schema-2020-12

## Example

```yaml
version: 1
project: kafka-app

dependencies:
  kafka:
    description: The Kafka cluster the app talks to.
    settings:
      KAFKA_BOOTSTRAP_SERVERS: ${endpoint}

environments:
  local:
    runtime: podman
    dependencies:
      kafka:
        twin:
          image: lawtwin/kafka
          version: 0.1.0
          conformance:
            level: answers
            report: conformance/lawtwin-kafka-0.1.0.json
          ports: [9092]
          seed: 42
          config:
            clock: frozen
          admin:
            port: 9644
    sync:
      - env_file:
          path: .env
  production:
    runtime: aws
    cloud:
      region: us-east-1
      vpc_id: vpc-0123456789abcdef0
      subnet_ids: [subnet-0123456789abcdef0]
    dependencies:
      kafka:
        real:
          endpoint: b-1.kafka-app.example.internal:9092
          credentials: aws-secretsmanager:kafka-app/production/kafka
    sync:
      - aws_appconfig: {region: us-east-1, application: kafka-app, profile: connections}
```

## Top level

| Key | Required | Meaning |
| --- | --- | --- |
| `version` | yes | `1`. |
| `project` | yes | The project's name. It prefixes every container, compose project and cloud resource. |
| `dependencies` | yes | Each dependency the application has, with `settings` and an optional `description`. |
| `environments` | yes | Each environment, which must bind every declared dependency and no other. |

Names of projects, environments and dependencies are lowercase letters,
digits, `-` and `_`, start with a letter, and are at most 40 characters.

## Settings

A dependency's `settings` maps each name the application reads, an
environment variable name, to a template over the endpoint the environment
binds. One setting belongs to one dependency. The placeholders are:

| Placeholder | Value |
| --- | --- |
| `${endpoint}` | The endpoint, as bound or resolved. |
| `${host}` | The endpoint's host. |
| `${port}` | The endpoint's port; a URL without one takes 443 for `https` and 80 for `http`. |
| `${credentials}` | The binding's credentials reference; every binding must then name one. |
| `${kind}` | `real` or `twin`. |
| `${name}` | The dependency's name. |

Inside a YAML flow mapping, `{...}`, quote a template: `{URL: '${endpoint}'}`.

## Environments

| Key | Required | Meaning |
| --- | --- | --- |
| `runtime` | yes | `podman`, `aws`, `gcp` or `azure`. |
| `cloud` | for a cloud | The cloud's inputs, below. |
| `dependencies` | yes | Each declared dependency, bound to `real` or `twin`. |
| `sync` | no | Where the settings are written, below. |
| `config_service` | no, podman only | Runs the configuration service: `image`, default `localhost/ironframe-config-service:0.1.0`, and `port`, default 8700. |

### `real`

| Key | Required | Meaning |
| --- | --- | --- |
| `endpoint` | yes | Where the application reaches it, `host:port` or a URL. |
| `credentials` | no | A reference `<scheme>:<location>`, scheme `env`, `file`, `aws-secretsmanager`, `gcp-secretmanager`, `azure-keyvault` or `vault`. Ironframe never reads the secret. ref:DEC-credentials-by-reference |
| `image` | no, podman only | An image of the real product, with its tag, to run locally, such as `apache/kafka:4.1.0`. |
| `ports` | with `image` | The container ports to publish. |
| `env` | no | Environment variables for the container. |

### `twin`

| Key | Required | Meaning |
| --- | --- | --- |
| `image` | yes | The image name without a tag, such as `lawtwin/kafka`. |
| `version` | yes | The image tag, which is the twin's version. |
| `conformance` | yes | The conformance level the twin's release declares, or where to read it; below. Recorded in the attestation. |
| `ports` | yes | The container ports; the first is the endpoint's. On `gcp` with `protocol: http`, exactly one. |
| `config` | no | A mapping handed to the twin as JSON in the `TWIN_CONFIG` environment variable. |
| `seed` | no | The seed of the twin's random choices: `seed` in `TWIN_CONFIG`, checked through the control plane once the twin answers. |
| `contract` | no | For a twin that serves several contracts, the one to serve: `contract` in `TWIN_CONFIG`, such as `petstore` for `lawtwin/http`. |
| `state` | no, needs `admin` | A state to force once the twin answers: a JSON file relative to the manifest, or the state itself. |
| `faults` | no, needs `admin` | Faults to raise once the twin answers, in order: each `name` and `params`, a mapping of strings and whole numbers. |
| `admin` | no | Where the twin's control plane is reached; below. |
| `protocol` | no | `http` (the default) or `tcp`: what the twin serves on its first port. On `gcp`, `tcp` runs it on Compute Engine rather than Cloud Run. ref:DEC-gce-for-tcp-twins |
| `advertise_variable` | no, podman or GCP `tcp` | An environment variable the twin reads the address to tell clients from, set to the endpoint's `host:port`, such as `LAWTWIN_ADVERTISE`. |
| `env` | no | Further environment variables. `TWIN_CONFIG` is reserved. |
| `endpoint` | no | Pins the endpoint the application is handed, such as `http://localhost:8080`. |
| `credentials` | no | A credentials reference, as for `real`. |

A twin's endpoint is the pinned one; otherwise, on podman, `localhost` and its
first port; an explicit local endpoint port publishes the first container port at that host port. Other published ports keep their numbers. Otherwise, in a cloud,
the endpoint the deployment reports, known after `ironframe up`.

`seed` and `contract` may also be written inside `config`, but not both ways
with different values. Ironframe hands `config` over and never reads it; what
the twin makes of it is its own business. ref:DEC-three-planes

Short image names are Docker Hub names: `apache/kafka:4.1.0` is run as
`docker.io/apache/kafka:4.1.0`. ref:DEC-podman-compose

#### `conformance`

Either the level as a word, `conformance: answers`, or a mapping
(ref:DEC-conformance-from-report, ref:REQ-conformance-matches-report):

| Key | Meaning |
| --- | --- |
| `report` | The twin release's conformance report, a JSON file relative to the manifest, read when the manifest is loaded. |
| `image_label` | A label of the twin's image holding the level, read by `up` once the image is present. |
| `level` | The level declared. With a report or a label, it must name the same level. |

A report's level is either an object with `number` and `name`, as LawTwin's
Kafka reports give it (`{"number": 3, "name": "answers"}`), or a word, as
`lawtwin conform http` writes it (`conformant`, `lawful` or `divergent`). A
declared level matches by name, ignoring case, by number, or as
`<number>-<name>`: `answers`, `3` and `3-answers` all match level 3. A report
that names its release, its twin or its contract must name this twin's
`version`, the last part of its `image`, and its `contract`. Any disagreement
stops the manifest from loading, at the field at fault:

```text
environments.local.dependencies.kafka.twin.conformance.report: the twin declares conformance "exact", but its report gives level 3 (answers)
```

The attestation records the report's level name, else the label's, else the
declared level, else `unrated`.

#### `admin`

The twin's control plane, which `up` uses to set the twin up and `ironframe
twin` to drive it (ref:DEC-twin-control-plane):

| Key | Default | Meaning |
| --- | --- | --- |
| `port` | `container_port` | On podman, the port published on this machine. It is checked with every other published port of the environment. |
| `container_port` | `9644` | The control plane's port inside the container, LawTwin's default. Do not list it in `ports` as well. |
| `url` | | The control plane's URL, which wins over the ports. A cloud twin's control plane is reached only through `url`. |

### `cloud`

| Runtime | Required | Optional |
| --- | --- | --- |
| `aws` | `region` (provider), `vpc_id`, `subnet_ids` | `cpu`, `memory`, `assign_public_ip`, `allowed_cidr_blocks`, `internal` |
| `gcp` | `project`, `region` | `cpu`, `memory`, `public` (Cloud Run); `zone`, `machine_type`, `network`, `subnetwork`, `allowed_cidr_blocks`, `public` (Compute Engine, for `protocol: tcp`) |
| `azure` | `location`, `resource_group_name` | `subscription_id` (provider), `cpu`, `memory`, `infrastructure_subnet_id`, `transport`, `external` |

Each module is handed only the inputs it takes. `cloud.modules` names a module
source to use instead of the released modules: a path, relative to the
manifest, or a git source. ref:DEC-opentofu

### `sync`

A list of targets, each a mapping with one key. ref:DEC-config-sync

| Target | Keys |
| --- | --- |
| `env_file` | `path`, relative to the manifest. |
| `aws_appconfig` | `region`, `application`, `profile`; `environment` (default: the environment's name), `deployment_strategy` (default `AppConfig.AllAtOnce`). |
| `gcp_parameter_manager` | `project`, `parameter`; `location` (default `global`). |
| `azure_app_configuration` | `endpoint` (`https://...`); `label` (default: the environment's name), `prefix`, `connection_string_env` (default `AZURE_APPCONFIG_CONNECTION_STRING`). |

## How it is checked

`ironframe validate`, and every other command, reads the manifest in two
passes. The first checks its shape against the schema; the second checks the
rules across fields: every declared dependency bound and nothing undeclared,
known placeholders, one owner per setting, credentials where templates use
them, a twin's image without a tag, a real image only on podman, the inputs a
cloud needs and no unknown ones, one port per Cloud Run twin, and no port
published twice on one machine. Each pass reports every problem it finds,
each with the dotted path of the field at fault:

```text
ironframe: ironframe.yaml: 2 problems
  - environments.local.dependencies.kafka.twin.image: name the image without a tag or digest; the twin's `version` is its tag
  - environments.local.dependencies: dependency "redis" is declared but not bound; bind it to `real` or `twin`
```
