---
id: ironframe.explanation.observation-acceptance
kind: explanation
title: Observation and binding promotion acceptance, 26 October 2026
---
# Observation and binding promotion acceptance

## Feature acceptance before 0.3.0

The assembled implementation at `6b17dcb` ran the released LawSpec 0.31.0
archive against actual native Go handlers, LawTwin Kafka/HTTP 0.2.1, Apache
Kafka 4.3.1 and the native Swagger Petstore. LawTwin's observer source is
`ef5edb5`. This check covered the then-unreleased feature increment; it was not a release or
1.0 sign-off. Existing provider conformance scopes remain unchanged.

The retained run is `.artifacts/observed-shop/run-d2LQMY/acceptance.json`.
Its SHA-256 is `108976a664ce44092c92097cf577a094f3dd2ba4b5d7bf7adad0111954863dff`. The same authored laws had SHA-256
`05fe31b4de377663f0321fdfb4f2938e467e06a83464f99664444cc3a7b02621` throughout. Four native law instances passed in each of the
four runs; the deliberate logging-loss run still failed collection and could
not qualify as fixture evidence for promotion.

| Run | Retained logs | Collection | Native execution id |
| --- | ---: | --- | --- |
| fixture | 945 | complete | `a0c18d52-de8f-4213-bd1f-2cb61abab099` |
| receiver-loss | 944 | incomplete | `a69e0ebe-5e54-4869-8a37-b633f2293c91` |
| provider-first | 945 | complete | `b84f1e87-cfba-438e-8c02-44c38b2f956f` |
| provider-second | 945 | complete | `8222938e-a527-4253-9e78-000c37f79b1a` |

The first real configuration was selected only after completed fixture and
provider tests; one complete per-app binding was published to an env file and
loaded through the packaged helper. Application adoption acknowledged the exact
settings digest and activation transition. Before each acknowledgement, freshly
started Go application and audit processes loaded that published binding and
actually published/read an adoption against the real providers. The three
post-activation/reversion adoptions used pet ids 1000001, 1001001 and 1002001;
the independent audit read 211, 422 and 423 adoptions respectively. Changing the HTTP edge from localhost
to its loopback address required a fresh provider run. Previously valid fixture
evidence was reusable because application code and contract interfaces did not
change. Both candidates were adopted, the first was selected again with a fresh
transition and adoption, and a stale expected revision was refused. The local
configuration service served the selected reverted binding. Containers and the
owned observation servers were removed; journals, exact per-run fixture histories
and independent runner diagnostics remain in the artifact directory.

Validation:

- 2,248 native Haskell examples passed, including the frozen CLI corpus. Existing
  schema corpus checks read the additive environment schema, as they already did
  for other extended schemas; historical corpus bytes were not reblessed.
- The initial assembled npm run passed 1,427 cases, with seven affected cases
  failing and two opt-in tests skipped. Observation-only sidecar compatibility
  and the additive schema expectation were repaired; all 111 cases in affected
  CLI, component, configuration-service and observation/host groups then passed.
  Unrelated large cross-project harnesses were not rerun per edit.
- Eight focused revision-policy examples also passed, including the barrier
  that keeps a multi-application selection pending until every application adopts.
- Eight receiver lifecycle tests passed: logs/traces accounting, isolation,
  immutable checkpoints, incomplete collection, recoverable unavailability and
  irrecoverable declared observation loss. The existing LawTwin CLI was also
  checked (16 CLI tests passed) and its observation launcher exercised.
- Native/WASM responses matched on four requests using the actual retained
  evidence: eligibility, incomplete refusal, binding construction and changed
  content refusal. Results are in `native-wasm-parity.json` beside the run.
- `tools/wasm.sh` rebuilt the shipped core; integrity verified its source and
  artifact fingerprints. A freshly packed/installed development archive loaded
  the actual published binding through `ironframe/observation`.
- Canon passed under the existing owner-deferred vetting policy; no human
  readability or canonical verdict was fabricated.

LawTwin's development observation image
`e704ffb22b451fd8db6a81f3905c7a322f47ce9ee9715e00a0bfd0b8a21ea136`
was built and run. It accepted a log, required a producer checkpoint, sealed and
exported a complete bundle, and retained byte-identical journal/export SHA-256
`33076f76470a5bb86f636e1210214219d7d9626d0d05b708542291af05271489`
after container teardown. Its bundle is in LawTwin's
`.artifacts/observation-image/c317c2bb-d650-4db6-b744-6ea364c6680d/`.

No cloud resources or registries were changed. AWS/Azure/GCP publication uses
existing SDK writers and their checked behavior; the assembled publication here
used an actual env file. The observation transport is uncompressed OTLP/HTTP JSON
logs/traces, not all Collector protocols or cloud logging fidelity. Producer
accounting and local runner reports remain trusted inputs. Component revisions
bind the checked law inventory; legacy application contracts rely on the runner
supplying its complete report. Declarations/normal exports describe candidates;
the revision store and binding endpoint describe the selected snapshot, including
a reverted snapshot when declarations still describe a newer candidate.

The example establishes the selected Kafka/HTTP integration. It does not add
email/Cassandra twins, migrate Kafka offsets or database state, undo notifications,
or complete any remaining human/external 1.0 gate.

## 0.3.0 release verification

The assembled 0.3.0 release at `93f97b8` repeated the observed workflow with
LawTwin 0.3.0 images and its 0.3.0 observation binary, using the same released
LawSpec 0.31.0 archive. The release check passed; this is not a 1.0 sign-off.

The retained receipt is `.artifacts/0.3.0/observed-shop/run-Ooj64d/acceptance.json`,
with SHA-256 `6eaf1c9f80c490acd2ced856c3cd279de4460abbbe6925f74af2b433267d3288`. Authored laws retained the same SHA-256 shown above.

| Run | Logs | Collection | Native execution id |
| --- | ---: | --- | --- |
| fixture | 945 | complete | `dda6546e-ad55-4b53-973a-85da160d1d3a` |
| receiver-loss | 944 | incomplete | `6a112434-b443-4e4e-903b-879c27e22d42` |
| provider-first | 945 | complete | `fd045401-d5e7-46a5-a23d-843563247de7` |
| provider-second | 945 | complete | `b6fcbf13-f368-4cef-99cc-c57d94976025` |

Both real candidates were published and adopted only after completed fixture
and matching provider runs. Fresh application and audit processes exercised
each selection and the reverted binding. The loss control still ran the native
laws successfully but could not qualify as completed collection evidence.

Release checks completed:

- The npm suite passed 1,434 tests; two opt-in deployments were skipped there.
  The separate CALM deployment acceptance passed with the 0.3.0 images in real,
  twin and mixed modes, including external/managed apps, faults, reset/replay
  and topology correspondence for exports and settings.
- The first native run exposed five historical framework-version assumptions.
  After narrowly updating those comparisons, all 1,422 affected serde/corpus
  cases passed; the remaining 826 cases had passed in the assembled run.
  Frozen provider versions and historical receipt bytes were preserved.
- The actual `tools/wasm.sh` rebuilt the shipped core. Integrity and four
  native/WASM comparisons on the fresh evidence passed: eligibility, incomplete
  collection refusal, binding construction and changed-content refusal.
- Strict compilation, all infrastructure module checks and canon passed under
  the existing deferred human-vetting policy.
- A clean installation of `ironframe-0.3.0.tgz` reported the release version,
  matched the shipped WASM digest and loaded the selected binding through
  `ironframe/observation`. The archive remains ready for owner npm publication.
- The freshly built `localhost/ironframe-config-service:0.3.0` container
  served the exact selected reverted application binding before teardown.

Fresh independent Kafka and HTTP provider reports are retained in
`examples/calm-shop/architecture/conformance/0.3.0/`. Their scopes and limitations
are described in the CALM demonstration guide; historical 0.2.1 reports remain.
The observation image was independently built, exercised and removed. No live
cloud resources or registries were changed.
