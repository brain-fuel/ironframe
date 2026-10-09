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
| `gcp` | `modules/gcp-cloud-run` | HTTP and gRPC on one port. ref:DEC-cloud-run-http-only ref:cloud-run-ports |
| `azure` | `modules/azure-container-apps` | HTTP, or TCP with `transport: tcp` and an `infrastructure_subnet_id`. ref:container-apps-tcp |

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
it against a mocked provider, so they need no account. ref:opentofu-testing
