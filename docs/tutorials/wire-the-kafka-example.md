---
id: ironframe.tutorials.wire-the-kafka-example
kind: tutorial
title: Wire the Kafka example
---
# Wire the Kafka example

In this tutorial you run `examples/kafka-app`, a tiny application that reads
`KAFKA_BOOTSTRAP_SERVERS` from its configuration and asks the broker which
Kafka APIs it supports. You bring its Kafka up with Ironframe, first as the
twin that does not exist yet, then as the real broker, and you read the
attestation of the run. The application never changes. ref:REQ-example-reads-config

You need Rust, podman with a running machine, and podman-compose.

## Build Ironframe

From the repository root:

```sh
cargo build
export PATH="$PWD/target/debug:$PATH"
cd examples/kafka-app
ironframe validate
```

`validate` prints the project and its four environments: `local`,
`local-broker`, `staging` and `production`.

## Ask for the twin

The `local` environment binds Kafka to the twin `lawtwin/kafka:0.1.0`:

```sh
ironframe up local
```

The image has not been released, so Ironframe stops before starting anything
and says so: `dependency "kafka" needs docker.io/lawtwin/kafka:0.1.0`. Nothing
is running and no file has been written.

## Use the real broker instead

`local-broker` binds Kafka to the real thing, run from Apache's image, with
the configuration service beside it. Build the service's image once, from the
repository root, then bring the environment up:

```sh
(cd ../.. && make config-service-image)
ironframe up local-broker
```

Ironframe pulls `apache/kafka:4.1.0`, starts it, waits until it answers on
`localhost:9092`, writes `.env`, and writes the attestation. Run the app:

```sh
cargo run -p kafka-app
```

It reads `.env` the way a dotenv library would and prints
`kafka-app: localhost:9092 supports ... APIs`. Ask the configuration service
for the same setting:

```sh
curl localhost:8700/v1/environments/local-broker
```

## Read the attestation

```sh
cat .ironframe/local-broker/attestation.json
```

The record for `kafka` says `"kind": "real"`, the endpoint, and `"reached":
true`. Once the twin exists, the same file for `local` will say `"kind":
"stand-in"` with the twin's product, version and declared conformance level,
and a tool such as `lawspec evidence` will report which obligations ran
against it. ref:DEC-attestation-format

## Clean up

```sh
ironframe down local-broker
```
