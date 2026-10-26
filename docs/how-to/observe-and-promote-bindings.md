---
id: ironframe.how-to.observe-and-promote-bindings
kind: how-to
title: Observe isolated runs and promote dependency bindings
---
# Observe isolated runs and promote dependency bindings

An observation session owns a disposable LawTwin OTLP receiver. Configuration
revisions freeze the resolved topology, application implementations and settings.
Promotion checks completed LawSpec observations and retained fixture histories;
publication and application adoption are separate operations. No language or
solver behavior changes, and these checks do not establish provider fidelity.

## Declare observation in CALM

Add a dedicated service node, for example `run-observer`, and one CALM `interacts`
relationship from each application to it:

```json
{
  "unique-id": "worker-observations",
  "protocol": "HTTP",
  "relationship-type": {
    "interacts": {"actor": "notification-worker", "nodes": ["run-observer"]}
  }
}
```

In each environment decorator's `data`, add:

```json
{"observation": {
  "node": "run-observer",
  "relationships": ["api-observations", "worker-observations"]
}}
```

These relationships describe observation, rather than business dependency
abilities. Resolution refuses a missing receiver, missing application relationship,
duplicate relationship or another destination. The resolved topology and Mermaid
export include the receiver and its telemetry connections. Logging remains
supplementary to independent provider histories and business assertions.

Every application needs a checked component fingerprint, or an explicit clean
implementation commit in its binding. A version string alone cannot identify the
tested implementation. Keep the same application identities, architecture,
contracts and settings names in fixture and candidate environments; bindings and
endpoint values may differ. Network policies, credentials and isolated topic,
consumer-group and database namespaces remain deployment responsibilities.

## Prepare and observe

Build LawTwin's receiver with `make build-observation` in the LawTwin checkout.
After resolving deployed endpoints, freeze a configuration:

```sh
ironframe -a notifications.calm.json revision prepare --env aws-twin \
  --output aws-twin.configuration.json

ironframe -a notifications.calm.json observe --env aws-twin \
  --revision aws-twin.configuration.json \
  --observer /absolute/path/lawtwin/target/release/lawtwin-observation \
  --output /absolute/path/test-artifacts/aws-twin-run \
  -- ./run-notification-scenarios
```

The command after `--` is your runner. It must stop admission, drain its work,
flush SDKs and submit producer checkpoints before returning. The receiver defaults
to `127.0.0.1:4318`, with private administration on `127.0.0.1:9646`; use `--listen`
and `--admin-listen` for other free addresses. `--endpoint` gives applications an
advertised intake URL when different. The caller running this command must reach
the admin address. Cloud applications need private connectivity to that receiver;
this command launches a program on the runner, not a cloud resource.

The runner receives `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_PROTOCOL`,
`IRONFRAME_OBSERVATION_CONFIG`, `IRONFRAME_OBSERVATION_ADMIN`,
`IRONFRAME_OBSERVATION_RUN_ID`, `IRONFRAME_OBSERVATION_DIR` and
`IRONFRAME_CONFIGURATION_REVISION`. Nested `ironframe run` and component tests
add the expected resource identities through `OTEL_RESOURCE_ATTRIBUTES`, including
the native execution id. Applications launched by other tooling read the receiver
configuration and supply the same identities themselves.

The receiver supports uncompressed OTLP/HTTP JSON logs and traces. SDKs using
protobuf or gRPC need a real OpenTelemetry Collector configured to export JSON to
it; changing an environment variable does not add JSON support to an SDK. Count
the final exports to this receiver, including any sampling or transformations in
that Collector. Unknown completeness must be reported as incomplete.

Instrument the application with its existing SDK. Submit `POST /v1/checkpoint`
on the admin port after ForceFlush, for each producer:

```json
{"producer":"notification-worker","counts":{"logs":42,"spans":12},"flushed":true,"dropped":0}
```

Counts come from producer-side accounting, including intended observations that
failed export. Do not copy the receiver's counts to manufacture a checkpoint.
The optional `ironframe/observation` helper calls an SDK's `forceFlush` and submits
successful or explicitly failed accounting:

```js
import {checkpointAfterFlush} from 'ironframe/observation';
const checkpoint = await checkpointAfterFlush({
  sdk: loggerProvider,
  producer: 'notification-worker',
  counts: () => intendedExportCounts,
  dropped: () => producerDroppedCount,
});
if (!checkpoint.flushed) process.exitCode = 1;
```

When using separate log and trace providers, supply a `forceFlush` function that
awaits both. A checkpoint is final: further exports from that producer are refused.

After the runner exits, Ironframe retains diagnostics, seals and exports the
collection, and stops its owned receiver. Missing checkpoints, failed flushes,
count mismatches or deliberate losses make the command fail. Failed runner runs
also retain observations. A terminated or unreachable receiver leaves its journal
and an incomplete collection record; its absence never establishes success.

The session directory contains `session.json`, `configuration.json`,
`receiver.json`, `receiver.log`, `runner.json`, `observations.jsonl` and
`bundle.json`. Each completed native application run within an observation session also gets a
`<attestation>.histories.json` sidecar containing the exact histories whose
digests were recorded at that run's completion. These remain available when later
tests reset a shared fixture or component integration tears down its containers.

## Check and activate a candidate

Prepare the real or mixed candidate, then run native laws against that exact
candidate as well as the fully isolated fixture configuration. Retain the actual
LawSpec JSON evidence using each completed attestation. Create an evidence manifest
whose paths are relative to the manifest file:

```json
{
  "format": "ironframe-promotion-evidence",
  "version": 1,
  "runs": [
    {
      "role": "fixture",
      "configuration": "aws-twin.configuration.json",
      "attestation": "fixture-worker-run.json",
      "laws": "fixture-worker-laws.json",
      "observations": "aws-twin-run/bundle.json",
      "histories": "fixture-worker-run.json.histories.json"
    },
    {
      "role": "provider",
      "configuration": "aws-real.configuration.json",
      "attestation": "real-worker-run.json",
      "laws": "real-worker-laws.json",
      "observations": "aws-real-run/bundle.json",
      "histories": "real-worker-run.json.histories.json"
    }
  ]
}
```

Include fixture evidence for every application and exact candidate provider
evidence for every application with outgoing real edges. The abbreviated manifest
above needs corresponding API application entries in a two-application system.
Fixture evidence must isolate every outgoing business dependency; a real database
in a mixed environment does not qualify as a Cassandra fixture. Unimplemented
fixtures therefore remain visible blockers rather than being renamed as twins.

```sh
ironframe -a notifications.calm.json revision check --env aws-real \
  --revision aws-real.configuration.json --evidence promotion.json

ironframe -a notifications.calm.json revision activate --env aws-real \
  --revision aws-real.configuration.json --evidence promotion.json --expected none
```

For subsequent activations, `--expected` is the full currently selected
`sha256:...` revision. Stale or concurrent selection changes are refused. The
revision, input evidence and promotion receipt are stored immutably under
`.ironframe/<environment>/revisions/`. Local runner reports, SDK accounting and
filesystem ownership remain trusted inputs; hashes are content/staleness checks,
not signatures, solver proofs or independent provider conformance.

## Publish, drain and acknowledge adoption

```sh
ironframe -a notifications.calm.json revision publish --env aws-real \
  --app notification-worker --expected sha256:CURRENT_REVISION
```

Publication uses the environment's configured sync targets, separated by app:
the env-file path gets `.<node>`, AWS profile and GCP parameter get `-<node>`,
and Azure prefix gets `<node>:`. One setting, `IRONFRAME_CONFIGURATION_BUNDLE`,
contains the complete application binding with revision, transition, implementation,
previous revision, settings and their digest. Azure therefore does not ask readers
to assemble a revision from separately updated endpoint keys. Credential values
are not fetched into that bundle; declared references remain references.

Applications load that single value through their normal configuration client.
`loadApplicationBinding` from `ironframe/observation` validates it through the core
and returns ordinary settings. Drain old work and restart clients/processes with
the complete new settings. Reading AppConfig does not itself reconnect Kafka.
AWS rollout settings are honored by its writer; Azure and GCP publication do not
gain AWS alarm/rollout behavior. There is no cross-cloud activation transaction.

Submit an application acknowledgement with fields `node`, `implementation`,
`revision`, `transition`, `settingsDigest`, `drainedFrom` (the previous revision,
or null on first adoption), and `drained: true`:

```sh
ironframe -a notifications.calm.json revision adopt --env aws-real \
  --expected sha256:CURRENT_REVISION --ack worker-adopted.json

ironframe -a notifications.calm.json revision status --env aws-real
```

Selection stays `awaiting-adoption` until every application acknowledges that
transition. This validates application declarations; it does not inspect sockets
or enforce a drain. Coordinate shared Kafka endpoints: stop admission and drain
both applications before moving either side, or use a separately designed
migration protocol. Generic Kafka log/offset or database state migration is not
implemented here.

`revision revert --env aws-real --expected sha256:CURRENT_REVISION` selects the
previously eligible revision with a fresh transition. Republish and obtain fresh
adoption acknowledgements. Reversion cannot undo emails, restore offsets or move
database writes. Operations serialize through an owned filesystem lock; a hard
kill can leave a stale lock, which an operator removes only after establishing
that its owner has stopped. Use a single authoritative/shared state location;
independent checkout-local stores do not coordinate deployments.

## Run the assembled local example

The observed calm-shop variant has one application, actual Kafka/HTTP native
handlers, synchronous OTLP operation observations and durable producer accounting.
It does not replace the generated Go TestMain. It tests the exact same laws
against real and twin providers, changes an HTTP endpoint with a new provider
run, then exercises publication, adoption and reversion. It uses separate scratch
copies, container project names and allocated ports; the source application laws
are not edited by the runner.

After building the current Ironframe WASM core and the observation receiver,
with the existing calm-shop provider images available:

```sh
IRONFRAME_OBSERVATION_CORE=/absolute/path/lawtwin/target/release/lawtwin-observation \
IRONFRAME_LAWSPEC_PACKAGE=/absolute/path/lawspec-0.31.0.tgz \
node tools/observed-shop.mjs
```

`IRONFRAME_LAWSPEC_PACKAGE` is optional once the pinned version is published.
The runner prints its retained `acceptance.json` path. No cloud resources are
created. This example establishes the selected Kafka/HTTP execution paths; it
adds neither an email provider model nor a Cassandra fixture.
