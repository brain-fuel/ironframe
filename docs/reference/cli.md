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
| `attest` | Writes the attestation now, for the run `up` started. ref:DEC-attestation-format |

## Exit status

| Status | Meaning |
| --- | --- |
| 0 | Done. |
| 1 | `up` finished, but a dependency did not answer; the attestation records it as not reached. |
| 2 | The command failed; the message says why. |

## Environment variables

| Variable | Meaning |
| --- | --- |
| `IRONFRAME_PODMAN` | The podman binary. Otherwise `podman` on `PATH`, then `/opt/podman/bin/podman`. |
| `IRONFRAME_TOFU` | The OpenTofu binary. Otherwise `tofu`, then `terraform`, on `PATH`. |
| `AWS_*`, `AWS_ENDPOINT_URL` | AWS credentials and endpoint for `aws_appconfig`, as the AWS CLI reads them. |
| `GOOGLE_APPLICATION_CREDENTIALS` | Google credentials for `gcp_parameter_manager`, or Application Default Credentials. |
| `AZURE_APPCONFIG_CONNECTION_STRING` | The App Configuration store's connection string, or the variable a target names. |
