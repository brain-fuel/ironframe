---
id: ironframe.how-to.start-the-aws-pilot
kind: how-to
title: Start and hand over the AWS pilot
---
# Start and hand over the AWS pilot

This is the shared handoff for the AWS pilot as of 2026-10-31. Account
creation and authentication are pending. No AWS infrastructure has been
created by this work. Cloud module tests use mocked providers; a live
deployment, distributed application test and complete teardown have not
been verified. See [cloud deployment](deploy-twins-to-a-cloud.md) for the
existing commands and their scope. ref:DEC-opentofu

## Repositories and branches

The tool repositories already exist:

| Repository | Work to use or review |
| --- | --- |
| [Ironframe](https://github.com/brain-fuel/ironframe) | `main` has 0.3.0. `aws-pilot` holds this handoff and is the starting branch for the AWS work. |
| [LawTwin](https://github.com/brain-fuel/lawtwin) | `main` has 0.3.0, the twin sources, image builds and scoped conformance reports. |
| [LawSpec](https://github.com/brain-fuel/lawspec) | `review/lawspec-0.31.1` holds the Learn patch sources. `prepare/lawspec-0.31.1` preserves the broader project helpers, dependent model work and formatting changes for review. These branches overlap; do not merge both wholesale. |
| [GoForge site](https://github.com/brain-fuel/dev.goforge) | `main` already contains the published Learn artifact. Access is needed only to maintain the site. |
| [Canon](https://github.com/brain-fuel/canon) | Needed to build and run the repositories' Canon checks. |

LawSpec 0.31.1 is published on npm. Its source candidate is still awaiting
completion of full CI and human Canon review before the main/tag release
workflow can be reconciled. Publishing its review branch does not establish
that those gates passed. The broader preparation branch is also unreleased.

Give the colleague access to these existing repositories. A separate
application repository is useful when the pilot has its own services,
contracts, CALM architecture, Ironframe manifest and application deployment
configuration. No new repository is required to start from Ironframe's
existing examples. Do not put product implementation in the tool repositories
solely to share the pilot.

```sh
git clone git@github.com:brain-fuel/ironframe.git
cd ironframe
git switch aws-pilot
```

Clone LawSpec, LawTwin and Canon alongside Ironframe when working on their
sources. Each repository's README describes its build requirements. A
colleague who only runs published CLIs does not need all source toolchains.

## AWS account and local authentication

For an Azure user, an AWS account is roughly the subscription boundary; a VPC
is the VNet, ECR is the container registry and ECS/Fargate runs containers.

The initial recommendation is a dedicated sandbox using AWS's
[advanced signup](https://docs.aws.amazon.com/accounts/latest/reference/getting-started.html),
the Free account plan and Basic support. Advanced signup and the paid account
plan are separate choices. If the account was already created through the
new simplified signup, inspect its assigned region and identity restrictions
before changing the account setup. That experience has different human access
controls; do not assume the IAM console-user instructions apply to it.

Protect the root identity with MFA. With advanced signup, use a separate
sandbox administrator with MFA for bootstrap and browser-based temporary CLI
credentials. Do not create long-lived access keys for this pilot. Each
colleague authenticates with their own identity.

Install AWS CLI v2.32 or newer, OpenTofu, Node 22 or newer and Ironframe.
The first workstation has AWS CLI 2.38.5, OpenTofu 1.13.1 and Ironframe
0.3.0. Podman is also available for local image builds; these are machine
setup facts, not dependencies pinned for the pilot.

Configure two local profiles. `ironframe-login` owns the browser session;
`ironframe` exposes temporary credentials through the standard process
interface understood by older SDKs. The CLI documents this compatibility
pattern in [console sign-in](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html).

```sh
aws configure set region us-east-1 --profile ironframe-login
aws configure set output json --profile ironframe-login
aws configure set region us-east-1 --profile ironframe
aws configure set output json --profile ironframe
aws configure set credential_process 'aws configure export-credentials --profile ironframe-login --format process' --profile ironframe
aws login --profile ironframe-login --region us-east-1
aws sts get-caller-identity --profile ironframe
```

Use `AWS_PROFILE=ironframe` for tools. Verify the intended account and
non-root identity before provisioning. `us-east-1` is the proposed region;
confirm it against the actual account. If the organization uses IAM Identity
Center, configure its SSO profile instead of inventing a new IAM user.

## Work required before the first deployment

The existing AWS module deploys twins, not the whole application or its real
managed dependencies. Application deployment and real service provisioning
still need explicit configuration.

1. Authenticate, then inspect the account's VPCs, subnets, quotas, registry
   access and service eligibility. Prepare a costed deployment plan before
   creating resources; Free account signup is not evidence of zero cost.
2. Separate load balancer client ingress from task ingress. The current
   module shares one security group and defaults to unrestricted IPv4
   ingress. Tasks need rules that admit load balancer traffic and health
   checks while client access stays restricted.
3. Resolve Kafka's advertised endpoint. AWS currently requires a pinned
   address in configuration; automatic advertisement is not implemented.
4. Match image architecture to Fargate. The local Podman machine is ARM64;
   Fargate tasks default to X86_64. Confirm registry publication rather than
   assuming local image tags are available remotely.
5. Run an actual deployed application against declared real/twin bindings,
   retain its scoped evidence, and exercise faults and replay where supported.
6. Verify complete teardown, including a retry after partial failure.

Only one operator should provision a given pilot environment until shared,
locked state is configured and tested. The generated OpenTofu root currently
uses local state under `.ironframe/<environment>/tofu/`. Git does not share
that state. Another checkout cannot destroy the first operator's resources
just by having the manifest. Keep state available to the deployment operator
until cleanup is verified; do not commit state, plans, credentials or login
caches to Git.

## Teardown acceptance

Complete cleanup is a user requirement for this pilot. The existing command,
run from the pilot's manifest directory with its state available, is:

```sh
AWS_PROFILE=ironframe ironframe down aws-pilot
```

This destroys resources in that environment's OpenTofu state and removes its
saved endpoints. It does not currently guarantee removal of separately
created VPCs, registries, application infrastructure or SDK-created AppConfig
resources. Do not describe the command as complete pilot cleanup yet.

Before deploying, establish ownership and a cleanup path for every resource
the pilot creates. The final teardown must have one documented entry point,
preserve enough state to retry after partial failure, and verify that no
pilot-owned billable compute, load balancers, public IPs, images, log/config
stores or storage remain. Explicitly identify any retained evidence. Cleanup
must leave unrelated account resources alone. Live verification remains open.
