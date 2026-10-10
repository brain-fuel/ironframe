---
id: ironframe.how-to.drive-a-twin
kind: how-to
title: Set up and drive a twin
---
# Set up and drive a twin

A LawTwin twin has a control plane: an admin API on a port of its own that
forces states, raises faults, moves the twin clock and reports the state and
the history (ref:lawtwin-control-plane). Ironframe uses it to set a twin up
as the manifest asks when the environment starts, and passes your commands to
it while it runs. Ironframe knows the API, never what the twin does behind
it. ref:DEC-twin-control-plane ref:REQ-twin-start-setup

## Publish the control plane

Give the twin `admin` in the manifest. On podman, `port` is the port on this
machine; the container's is 9644 unless `container_port` says otherwise:

```yaml
petstore:
  twin:
    image: lawtwin/http
    version: 0.1.0
    contract: petstore
    conformance: {report: conformance/lawtwin-http-0.1.0-petstore.json}
    ports: [8080]
    admin:
      port: 9645
```

Two twins in one environment need two ports. In a cloud the control plane is
not published; give `admin.url` when you can reach it, through a VPN or a
tunnel.

## Set it up when it starts

```yaml
    seed: 42
    state: fixtures/two-pets.json
    faults:
      - name: latency
        params: {delay: 5ms}
      - name: server-error
        params: {status: 503, count: 1, operation: addPet}
```

`seed` and `contract` reach the twin in `TWIN_CONFIG`. Once the twin answers
on `/healthz`, `ironframe up` checks the seed through `GET /v1/twin` and sets
it again if the twin reports another, forces `state`, a JSON file relative to
the manifest or the state itself, then raises each fault in order. A state
the contract forbids, or a fault the twin does not declare, stops `up` with
the twin's reason:

```text
ironframe: twin "kafka": refused: the law `a topic's partitions only grow` forbids this state: orders has 3 partitions and cannot have 2
```

The faults and states a twin takes are the twin's: `ironframe twin <dependency>
faults` lists them, and LawTwin's reference describes each.

## Drive it while it runs

```sh
ironframe twin petstore inspect
ironframe twin petstore fault server-error status=503 count=1
ironframe twin petstore fault clear
ironframe twin kafka advance 5s
ironframe twin kafka history --since 10
echo '{"resources": {"Pet": [{"id": 7, "name": "Rex", "photoUrls": []}]}}' | ironframe twin petstore force -
```

`--env <environment>` names an environment other than `local`. Each action
means what the same `lawtwin` command means, with its exit statuses: 2 when a
law refuses a forced state, 1 when the twin answers with any other failure.
Ironframe calls the admin API itself, so `lawtwin` need not be installed; with
it installed, `lawtwin --admin http://127.0.0.1:9645 inspect` does the same.

## Cite what the application talked to

```sh
ironframe attest local
```

records each twin's seed and the SHA-256 digest of its history in the
attestation, and keeps the history in
`.ironframe/local/history/<dependency>.jsonl`. With the same seed and the same
requests a LawTwin twin writes the same history, byte for byte, so the digest
names the run. ref:DEC-history-digest
