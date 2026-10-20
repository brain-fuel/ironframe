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

podman with a compose provider, Go 1.25 or later, npm, and these images:
`lawtwin/kafka:0.1.0` and `lawtwin/http:0.1.0` (built in the lawtwin
repository with `make image image-http`), `apache/kafka:4.1.0`, and
`localhost/lawtwin/petstore3-native:latest` (the Swagger Petstore built for
the machine's architecture, `podman build -t lawtwin/petstore3-native
examples/http/petstore3` in the lawtwin repository). The CALM CLI is optional.

## Run it all

```sh
make e2e-calm
```

The test copies the example to a scratch directory and does every step below,
asserting each.

## Step by step

```sh
cargo build
cd examples/calm-shop/app && npm ci && npx lawspec generate && go build -o shop-bin ./cmd/shop && cd ..
cd architecture
I=../../../target/debug/ironframe
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
`lawspec evidence` with no attestation shows the run each law last passed in.
Keep attestations outside the application's directory: LawSpec digests the
project's files into the inputs its results are keyed by. ref:DEC-calm-run

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
