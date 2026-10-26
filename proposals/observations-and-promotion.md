# Disposable observations and evidence-backed binding promotion

Owner authorization: implement the design discussed on 26 October 2026. Keep
checks focused during development; assemble the feature before running large
integration or release harnesses. No release or cloud deployment is implied.

Requirements:

1. Run-scoped OTLP logs/traces receiver, with explicit application, topology,
   configuration and edge identities. Durable observations remain separate from
   provider histories and runner diagnostics.
2. Declared receiver faults; producer flush checkpoints, collection loss and
   incomplete outcomes. Export and persist before fixture teardown, including
   failing runs. Independent runner capture survives receiver failure.
3. CALM node/edge isolation: distinct run resources, shared dependency nodes
   within a run, and explicit selected bindings; no claim that settings enforce
   network isolation.
4. Immutable configuration bundles from resolved topology and per-app settings,
   content identity, completed fixture/provider evidence, and refusal of stale,
   incomplete or incompatible promotion inputs.
5. Controlled activation with compare-and-swap, immutable history, per-app
   adoption records, drain/restart semantics and reversible selection. Reverting
   selection cannot undo external side effects or migrate dependency data.
6. AWS AppConfig, Azure App Configuration and GCP Parameter Manager publishing
   use existing writers. Publication is distinct from application adoption;
   provider-specific gradual rollout does not imply a cross-app transaction.
7. Haskell owns Ironframe decisions; native and WASM agree. Host adapters perform
   filesystem/network/process effects only. LawTwin owns the observation fixture.
8. Document supported protocol/fragment, trust boundaries, lifecycle, examples
   and remaining unsupported cases. Verify assembled public paths and negative
   controls; no fabricated provider, cloud or 1.0 sign-off.

Implementation order: observation fixture; revision/evidence policy; activation
and adoption; lifecycle integration; docs/examples; focused checks and final
assembled integration. Existing release tags and generated WASM are not edited
by hand. Use tools/wasm.sh after core changes.

Precedent: OpenTelemetry OTLP specification and Logs SDK ForceFlush (primary
specifications); AWS AppConfig deployment/rollback; Azure immutable snapshots
and snapshot references; Google Parameter Manager versions. These supply the
transport and revision semantics, not proof of business behavior or complete
observation. This adds no solver or proof backend.


Implementation and verification are recorded in
[the acceptance receipt](../docs/explanation/observation-acceptance.md) and
[the user guide](../docs/how-to/observe-and-promote-bindings.md). The implementation
keeps native/WASM policy in Haskell, the receiver in LawTwin, and LawSpec language
and compiler behavior unchanged. Cloud deployment and logging-provider fidelity
are outside the demonstrated local acceptance scope.
