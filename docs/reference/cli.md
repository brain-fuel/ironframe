---
id: ironframe.reference.cli
kind: reference
title: CLI
---
# CLI

```text
ironframe [-f <manifest>] validate
ironframe schema [manifest | attestation]
ironframe [-f <manifest>] settings <environment> [--format env | json]
ironframe [-f <manifest>] compose <environment>
ironframe [-f <manifest>] up <environment> [--no-sync] [--wait <seconds>]
ironframe [-f <manifest>] down <environment>
ironframe [-f <manifest>] status <environment> [--json]
ironframe [-f <manifest>] plan <environment>
ironframe [-f <manifest>] sync <environment>
ironframe [-f <manifest>] attest <environment> [--output <path>]
ironframe [-f <manifest>] twin <dependency> [--env <environment>] <action>
ironframe --version
```

`-f` names the manifest; the default is `ironframe.yaml` in the current
directory. Ironframe keeps what it generates in `.ironframe/<environment>/`
beside the manifest. ref:DEC-manifest-shape

| Command | What it does |
| --- | --- |
| `validate` | Reads the manifest and reports every problem, or prints its project and environments. |
| `schema` | Prints the manifest's or the attestation's JSON Schema. |
| `settings` | Prints the settings the environment hands its application, as dotenv or JSON. A cloud twin's endpoint is known after `up`. |
| `compose` | Prints the compose file of a podman environment. |
| `up` | On podman: checks every image, pulling absent ones, and stops before starting anything if one is missing; writes the settings document and compose file and starts the project with `podman compose`; waits up to `--wait` seconds (default 90) for each started container; runs the sync targets unless `--no-sync`; writes the attestation. In a cloud: writes the OpenTofu root, runs `init` and `apply`, keeps the twins' endpoints, then syncs and attests. ref:DEC-podman-compose ref:DEC-opentofu |
| `down` | Stops and removes the compose project, or runs `tofu destroy`. |
| `status` | Each dependency's kind, container state (`running`, `exited`, `absent`, `hosted`, `deployed`, `not deployed`) and whether its endpoint answers now. |
| `plan` | Writes a cloud environment's OpenTofu root and runs `tofu init` and `tofu plan`. |
| `sync` | Writes the environment's settings to its sync targets. ref:DEC-config-sync |
| `attest` | Writes the attestation now, for the run `up` started, reading each twin's seed and history digest from its control plane, and lists each dependency: kind, whether it was reached, endpoint, and for a stand-in its product, version, level, seed and digest. ref:DEC-attestation-format ref:DEC-history-digest |
| `twin` | Drives the twin standing in for a dependency through its control plane; below. ref:DEC-twin-control-plane |

`up` also sets up each twin that has `admin`: it waits up to `--wait` seconds
for the control plane's `/healthz`, sets the seed when the twin reports
another, forces the `state` and raises the `faults` the manifest gives, and
stops on the first refusal.

## `ironframe twin`

`ironframe twin <dependency> [--env <environment>] <action>` speaks the
twin's admin API, at the URL `up` recorded or the one the manifest gives; the
environment is `local` unless `--env` names another. Each action means what
the same `lawtwin` command means, and prints the twin's answer as indented
JSON. ref:lawtwin-control-plane

| Action | Admin API | Does |
| --- | --- | --- |
| `inspect [--records]` | `GET /v1/state` | Shows the twin's state, and with `--records` every record. |
| `force <state.json \| ->` | `POST /v1/state` | Forces a state; exit 2 when a law refuses it, naming the law. |
| `fault <name> [<param>=<value>]...` | `POST /v1/faults/{name}` | Raises a declared fault; a whole-number value is sent as a number. |
| `fault clear [<name>]` | `DELETE /v1/faults[/{name}]` | Clears one fault, or every one. |
| `faults` | `GET /v1/faults` | Lists the declared faults and the active ones. |
| `history [--since <n>] [--limit <n>] [--array]` | `GET /v1/history` | Prints the history, as JSON lines unless `--array`. |
| `advance <duration>` | `POST /v1/clock/advance` | Moves the twin clock: `250ms`, `5s`, `2m`, `1h`. |
| `seed [<n>]` | `GET` or `POST /v1/seed` | Shows the seed, or starts again from an empty state with a new one. |
| `reset` | `DELETE /v1/reset` | Starts again from an empty state with the same seed. |
| `laws` | `GET /v1/laws` | Checks the contract's laws; exit 1 if one does not hold. |

## Exit status

| Status | Meaning |
| --- | --- |
| 0 | Done. |
| 1 | `up` finished, but a dependency did not answer; the attestation records it as not reached. |
| 2 | The command failed; the message says why. For `twin force`, a law refused the state. |

`ironframe twin` exits 1 when the twin answers with a failure or does not
answer, as `lawtwin` does.

## Environment variables

| Variable | Meaning |
| --- | --- |
| `IRONFRAME_PODMAN` | The podman binary. Otherwise `podman` on `PATH`, then `/opt/podman/bin/podman`. |
| `IRONFRAME_TOFU` | The OpenTofu binary. Otherwise `tofu`, then `terraform`, on `PATH`. |
| `AWS_*`, `AWS_ENDPOINT_URL` | AWS credentials and endpoint for `aws_appconfig`, as the AWS CLI reads them. |
| `GOOGLE_APPLICATION_CREDENTIALS` | Google credentials for `gcp_parameter_manager`, or Application Default Credentials. |
| `AZURE_APPCONFIG_CONNECTION_STRING` | The App Configuration store's connection string, or the variable a target names. |
