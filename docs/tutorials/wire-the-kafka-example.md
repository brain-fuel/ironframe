---
id: ironframe.tutorials.wire-the-kafka-example
kind: tutorial
title: Wire the examples to LawTwin's twins
---
# Wire the examples to LawTwin's twins

In this tutorial you run two tiny applications against LawTwin's twins:
`examples/kafka-app`, which reads `KAFKA_BOOTSTRAP_SERVERS` and asks the
broker for its API versions and its topic, and `examples/petstore-app`, which
reads `PETSTORE_URL`, adds a pet and reads it back. You bring each
application's dependency up with Ironframe as a twin, drive the twin, and read
the attestation of the run. The applications never change.
ref:REQ-example-reads-config ref:REQ-end-to-end-with-twins

You need Node 22 or later, podman with a running machine, podman-compose,
and a checkout of LawTwin beside this one.

## Install Ironframe and build the images

Install the command from the npm package:

```sh
npm i -g ironframe
```

From a checkout of this repository, the package is in `npm/`; run
`tools/wasm.sh` first if you changed the core:

```sh
alias ironframe="node $PWD/npm/bin/ironframe.mjs"
```

LawTwin's images are built in its repository; Ironframe's configuration
service in this one:

```sh
(cd ../lawtwin && make image image-http)
make config-service-image
```

## Bring the Kafka twin up

```sh
cd examples/kafka-app
ironframe validate
ironframe up local
```

`validate` reads LawTwin's conformance report for the Kafka twin's release,
`conformance/lawtwin-kafka-0.1.0.json`, and checks that the level the manifest
declares, `answers`, is the report's: level 3. `up` starts
`lawtwin/kafka:0.1.0` and the configuration service, waits for the twin's
control plane on port 9644, checks that its seed is 42, waits for the broker
on `localhost:9092`, writes `.env`, and writes the attestation.

Run the app:

```sh
node app.mjs
```

It reads `.env` the way a dotenv library would and prints
`kafka-app: localhost:9092 supports 22 APIs; topic kafka-app has 1
partition(s)`. Ask the configuration service for the same setting:

```sh
curl localhost:8700/v1/environments/local
```

## Drive the twin

```sh
ironframe twin kafka inspect
ironframe twin kafka history
ironframe twin kafka faults
ironframe twin kafka advance 5s
```

The history holds what the app did, as calls of the Kafka contract: a
metadata request, the topic it created, and the metadata answer.

## Read the attestation

```sh
ironframe attest local
cat .ironframe/local/attestation.json
```

The record for `kafka` says `"kind": "stand-in"`, `lawtwin/kafka` `0.1.0`,
conformance `answers`, seed 42, and the SHA-256 digest of the history, which
is kept in `.ironframe/local/history/kafka.jsonl`. A tool such as `lawspec
evidence` reads the file to report which obligations ran against a stand-in,
and at what level. ref:DEC-attestation-format ref:DEC-history-digest

## The Petstore

```sh
cd ../petstore-app
ironframe up local
node app.mjs
ironframe twin petstore history
ironframe attest local
```

The Petstore twin, `lawtwin/http:0.1.0` serving the `petstore` contract,
starts with a 5 ms `latency` fault raised, as the manifest asks; its control
plane is on 9645, so both examples run side by side. The app prints
`petstore-app: http://localhost:8080 added pet 1 and read it back`, and the
attestation records conformance `conformant`, from the report of `lawtwin
conform http` beside the manifest. Run it twice from a fresh `up` and the
history digest is the same: the same seed and the same requests give the same
history.

## Clean up

```sh
ironframe down local
cd ../kafka-app && ironframe down local
```

`make e2e` runs this whole tutorial as a test, in a scratch directory.
