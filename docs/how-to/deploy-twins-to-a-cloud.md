---
id: ironframe.how-to.deploy-twins-to-a-cloud
kind: how-to
title: Deploy twins to a cloud
---
# Deploy twins to a cloud

An `aws`, `gcp` or `azure` environment deploys each twin with OpenTofu, through
the module for its cloud. Real dependencies are hosted already and are only
named by their endpoints. ref:DEC-opentofu ref:opentofu

| Runtime | Module | Serves |
| --- | --- | --- |
| `aws` | `modules/aws-ecs-fargate` | Any TCP protocol: one network load balancer listener per port. |
| `gcp`, `protocol: http` | `modules/gcp-cloud-run` | HTTP and gRPC on one port. ref:DEC-cloud-run-http-only ref:cloud-run-ports |
| `gcp`, `protocol: tcp` | `modules/gcp-compute-engine` | Any TCP protocol, on every port, at a reserved address. ref:DEC-gce-for-tcp-twins ref:gce-container-optimized-os |
| `azure` | `modules/azure-container-apps` | HTTP, or TCP with `transport: tcp` and an `infrastructure_subnet_id`. ref:container-apps-tcp |

A twin's `protocol` says what it serves; `http` is the default. Cloud Run
cannot serve Kafka's wire protocol, so a Kafka twin on GCP says `protocol:
tcp` and runs on a Compute Engine instance: Container-Optimized OS starting the
image under systemd through cloud-init (ref:cos-cloud-init), a reserved
internal address, or an external one with `public: true`, and a firewall rule
admitting `allowed_cidr_blocks` (default `10.0.0.0/8`) to its ports. A Kafka
client connects to the address the broker advertises, so give the twin
`advertise_variable: LAWTWIN_ADVERTISE`: the module sets it to the reserved
address and the first port. Teams that already run GKE may prefer a GKE
Autopilot deployment behind a TCP load balancer; this release ships no module
for it.

```yaml
staging-gcp:
  runtime: gcp
  cloud: {project: kafka-app-staging, region: europe-west1, allowed_cidr_blocks: [10.0.0.0/8]}
  dependencies:
    kafka:
      twin:
        image: lawtwin/kafka
        version: 0.1.0
        conformance: {report: conformance/lawtwin-kafka-0.1.0.json}
        ports: [9092]
        protocol: tcp
        seed: 42
        advertise_variable: LAWTWIN_ADVERTISE
```

On ECS Fargate and Container Apps, pin the advertised address in the twin's
`config` or `env` once the load balancer's name is known.

A cloud twin's control plane is not opened: list its port among `ports` only
for an environment reached privately, and give `admin.url` for `up` and
`ironframe twin` to reach it.

## Requirements

- OpenTofu 1.6 or later (`brew install opentofu`), or Terraform. Ironframe
  looks at `IRONFRAME_TOFU`, then `tofu`, then `terraform`.
- The cloud's credentials, as its CLI reads them.

## Plan

```sh
ironframe plan staging
```

Ironframe writes `.ironframe/staging/tofu/main.tf.json`: the provider,
configured from the environment's `cloud` inputs, one module instance per
twin, passed the twin's name, image, ports and environment, `TWIN_CONFIG`
included, and an `endpoints` output. It then runs `tofu init` and `tofu plan`
there.

The modules are fetched from this repository at the release's tag unless
`cloud.modules` names another source, such as `../../modules` in a checkout.

## Apply

```sh
ironframe up staging
```

`up` runs `tofu apply`, reads each twin's endpoint from the `endpoints` output
into `.ironframe/staging/endpoints.json`, renders the settings from them, runs
the sync targets, and writes the attestation. Later commands, such as
`settings` and `status`, use the kept endpoints. `ironframe down staging` runs
`tofu destroy` and forgets them.

Keep OpenTofu's state somewhere shared before more than one person deploys an
environment; the generated root uses the local backend in
`.ironframe/<environment>/tofu/`.

## Check the modules

```sh
make tofu-check
```

runs `tofu validate` and `tofu test` on every module. Each module's tests plan
it, or apply it, against a mocked provider, so they need no account; they run
LawTwin's images, `lawtwin/kafka:0.1.0` and `lawtwin/http:0.1.0`.
ref:opentofu-testing ref:REQ-modules-plan
