---
id: ironframe.how-to.run-the-calm-demonstrations
kind: how-to
title: Run the CALM demonstrations
---
# Run the CALM demonstrations

Run one application's unchanged LawSpec laws against real, twin and mixed
bindings of its Kafka and HTTP dependencies, and read which obligations ran
against which. ref:REQ-calm-end-to-end

The example is `examples/calm-shop`: a Go application, `example.com/calm-shop`,
whose laws (`app/spec/shop.lawspec`) say that an adoption is published under
its pet and that an adopted pet keeps its name. Its two dependencies are
LawSpec abilities, `Adoptions` (a Kafka topic) and `Pets` (a Petstore API),
whose production handlers (`app/shop/adoptions/adapter.go`) read
`KAFKA_BOOTSTRAP_SERVERS` and `PETSTORE_URL` from the environment or a `.env`
file. `architecture/` holds its CALM architecture and decorators: the
adoptions service and an audit share the Kafka log; the Petstore is the
service's alone; environments `twin`, `real`, `mixed` and `staging`.

## What you need

Ironframe (`npm i -g ironframe`, or `node npm/bin/ironframe.mjs` from a
checkout), podman with a compose provider, Go 1.25 or later, Node 22 or later
with npm, and these images:
`lawtwin/kafka:0.1.0` and `lawtwin/http:0.1.0` (built in the lawtwin
repository with `make image image-http`), `apache/kafka:4.1.0`, and
`localhost/lawtwin/petstore3-native:latest` (the Swagger Petstore built for
the machine's architecture, `podman build -t lawtwin/petstore3-native
examples/http/petstore3` in the lawtwin repository). The CALM CLI is optional
for normal use. Set `IRONFRAME_CALM` to its
executable when accepting the CALM validation and diagram tooling path.

## Run it all

The demonstration requires a LawSpec build that consumes completed-run
attestations. The example's registry pin, 0.26.0, predates that behavior. Until
that compiler is published and the pin advances, pack the merged LawSpec
checkout (`npm pack` in its `npm/` directory), then provide the archive:

```sh
IRONFRAME_LAWSPEC_PACKAGE=/absolute/path/lawspec-0.26.0.tgz \
IRONFRAME_E2E_ARTIFACTS=/absolute/path/acceptance-outputs \
IRONFRAME_CALM=/absolute/path/calm \
make e2e-calm
```

The test copies the example to a scratch directory and does every step below,
asserting each. The archive is installed only in the scratch application;
its laws stay byte-identical across all bindings. The retained outputs include
completed service, managed and external attestations, explicit and cached
LawSpec evidence, diagram and infrastructure exports, settings and replay
histories. Containers are torn down on success and failure.

To select fresh fixture builds without replacing the example's image tags,
tag them under a separate repository prefix at version `0.1.0`, and set
`IRONFRAME_TWIN_IMAGE_PREFIX` to that prefix. For example,
`localhost/ironframe-acceptance` selects `localhost/ironframe-acceptance/kafka:0.1.0`
and `localhost/ironframe-acceptance/http:0.1.0`. Their actual image digests are
recorded in attestations. `IRONFRAME_APP_IMAGE` can similarly select a fresh
tag for the managed audit image, built from the scratch application's current
Linux executable when absent.

## Step by step

```sh
export IRONFRAME_LAWSPEC_PACKAGE=/absolute/path/lawspec-0.26.0.tgz
cd examples/calm-shop/app
npm ci
npm install --no-save --package-lock=false "$IRONFRAME_LAWSPEC_PACKAGE"
npx lawspec generate
go build -o shop-bin ./cmd/shop
cd ..
cd architecture
I=ironframe    # or, from a checkout: I="node ../../../npm/bin/ironframe.mjs"
$I -a shop.calm.json validate
$I -a shop.calm.json up twin
$I -a shop.calm.json run -e twin --app adoptions-service --dir ../app -- \
  sh -c 'npx --no-install lawspec test --attestation "$IRONFRAME_ATTESTATION" --seed 7'
```

`run` hands the laws' native handlers their settings and the running
attestation's path, and completes the attestation when `lawspec test` exits;
it prints where it wrote it, under `.ironframe/twin/runs/`. Then:

```sh
cd ../app && npx lawspec evidence --attestation ../architecture/.ironframe/twin/runs/<run>.json
```

Each law that ran under the native `Adoptions` and `Pets` handlers is
reported property tested, against `stand-in lawtwin/kafka 0.1.0 (conformance
answers)` and `stand-in lawtwin/http 0.1.0 (conformance conformant)`.
The explicit completed file yields `against`, `environmentRun.execution.status:
"completed"` and `environmentOutcome: "passed"` for all four native law
instances, with real-provider or fixture identity and completed fixture history
digests. Without that file, `lawspec evidence` reads the startup snapshot cached
by the child: its wiring stays `plannedAgainst` while native test results remain
visible. LawSpec does not infer environment completion from a passing child.
Attestation documents are excluded from application input digests.
ref:DEC-calm-run

The shared log and the managed audit:

```sh
$I -a shop.calm.json app adoptions-audit -e twin      # reads what the service published
```

The service as an external deployment, reading its synced `.env`, with
Ironframe recording a run it did not start:

```sh
$I -a shop.calm.json attest twin --app adoptions-service   # prints the running attestation
(cd ../app && ./shop-bin rex ada)
$I -a shop.calm.json attest twin --complete <that file> --exit-code 0
```

Faults, resets and deterministic replay, through the twins' control planes:

```sh
$I -a shop.calm.json twin pet-registry -e twin fault server-error status=503
(cd ../app && ./shop-bin rex ada)        # fails: the Petstore answered 503
$I -a shop.calm.json twin pet-registry -e twin fault clear
$I -a shop.calm.json twin adoptions-log -e twin reset
(cd ../app && SHOP_PET_ID_BASE=1000 ./shop-bin rex ada)
$I -a shop.calm.json twin adoptions-log -e twin history   # the same bytes after every reset
$I -a shop.calm.json twin adoptions-log -e twin replay    # no divergence, no broken law
$I -a shop.calm.json down twin
```

Then `real` (Apache Kafka and the Swagger Petstore; here the audit is a managed
image, built from `app/Containerfile` once
`GOOS=linux CGO_ENABLED=0 go build -o shop-linux ./cmd/shop` has run) and
`mixed` (real Kafka, Petstore twin) the same way. The laws and the
application do not change; only the settings and the attestation do.

## Haskell/WASM port acceptance, 2026-10-21

The `b178230` core passed this chain with LawSpec `03218926` (including the cached-run
evidence correction) and
fresh fixtures from LawTwin `8c592d7`. All 46 recorded core source/artifact
fingerprints remained unchanged. Architecture and decorator digests match the
retained source bytes, and the topology digest matches the compact exported
JSON; the maintained test checks these exact identities in every binding.
Dependency contracts, node/edge identities and both applications' settings also
match the retained topology. The two authored laws produced four native
law instances in each binding (12 executed instances), all property tested and
linked to their completed service run. This establishes the local integration;
provider conformance remains a separate LawTwin check.

| Check | Result |
| --- | --- |
| Real, twin and mixed bindings; unchanged laws | Passed with both original and freshly rebuilt fixture images |
| Managed process, freshly built managed image, external application | Completed attestations in every binding; shared Kafka exercised |
| Kafka/HTTP faults, recovery, resets and deterministic replay | Passed, including a completed failed audit after Kafka reset |
| CALM CLI 1.65.0 validation and diagram rendering | Passed |
| Diagram, settings and OpenTofu correspondence | Passed, including missing-edge/key/module negative controls |
| Exported staging root | Initialized and validated against the repository modules |
| Native and shipped WASM regression suites | 2,231 native examples and 1,417 Node tests passed; two opt-in tests run separately |
| Configuration service and original examples in Podman | Passed with a freshly built WASM-host configuration-service image |
| Cloud modules | All four validated; 14 mocked provider tests passed |

No cloud resources were deployed. All demonstration containers were removed.
The compiler and images were exercised locally; these checks do not publish an
npm release or establish the remaining 1.0 gates. ref:REQ-calm-end-to-end
