# Proposal to LawSpec: completed-run attestations

From Ironframe's gate 2 work (CALM identity resolution and real/twin
bindings), 20 October 2026. Nothing here was changed in LawSpec; Ironframe
works with LawSpec 0.26.0 as it is, and these are the gaps it found. Each item
says what was observed, why it matters to the 1.0 path's evidence rule
("distinguish planned wiring from completed execution"), and a minimal change.

## What works today with 0.26.0

- `lawspec test --attestation <file>` and `lawspec evidence --attestation
  <file>` accept Ironframe's attestation unchanged: it stays
  `"version": 1` and only adds fields (architecture, application, execution,
  per-dependency node, edge, contract, implementation, completed,
  `stand_in.stands_in_for`), which the reader ignores.
- Dependency names are the application's abilities,
  `shop.adoptions::ability::Adoptions`, and match laws run under those
  abilities' native production handlers.
- With the completed attestation named, each such law stays `property-tested`
  with `matching-inputs`, because Ironframe keeps every version 1 field as the
  run began. Without a named attestation, `lawspec evidence` links each law
  to the run it last passed in (`environmentRun`, `against`).

## 1. A named attestation of a completed run reports its obligations as planned

Observed: `lawspec evidence --attestation <completed run>` reports each touched
law's dependencies under `plannedAgainst` / `plannedEnvironmentRun`, and the
ENVIRONMENT section says "N planned obligation(s); no completed run linked",
even though `.lawspec/results` records that very run id as the run the laws
passed in. Without `--attestation` the same laws are linked (`against`,
"N tested obligation(s)") but reported `PLANNED`, because the attestation is
part of the inputs and none is named.

Proposal: when the named attestation's `run.id` is the run id recorded for a
law's passing native result, report `environment`, `environmentRun` and
`against` (tested), not the planned fields.

## 2. Read `execution.status`

Ironframe writes `execution.status`: `wired` (endpoints probed, nothing ran),
`running` (a run under way: the file `lawspec test` reads) or `completed` (with
`exit_code` and `finished_at`). Proposal: `lawspec evidence` treats a named
attestation whose status is present and not `completed` as planned wiring
only, and says so; `completed` with a non-zero `exit_code` is reported beside
the laws it touches. Absent `execution`, today's behaviour stands.

## 3. Do not key results by a stand-in's history digest

Observed: changing `stand_in.history_digest` between the attestation given to
`lawspec test` and the one given to `lawspec evidence` makes every touched law
`stale` ("Specification, selection, bindings, native source or toolchain
inputs differ"). A history digest is an observation of the run, not wiring:
it necessarily changes while the run runs. Ironframe therefore keeps the
digest as the run began and records the completed digest under
`dependencies[].completed.history_digest`. Proposal: key results by endpoint,
kind, product, version and conformance only; or read
`completed.history_digest` and show it.

## 4. Attestations inside the project make results stale

Observed: an attestation file written inside the LawSpec project's root (for
example `.lawspec-attestation.json` beside `lawspec.json`) is digested into the
project inputs, so rewriting it after the run makes every law stale. Ironframe
now writes attestations outside the project. Proposal: exclude the named
attestation (and `.env`-style files the harness does not read) from the
project digest, or document the rule.

## 5. A refinement alias in an ability operation's type

Observed while writing the example: `register :: PetName -> Int64`, with
`refinement PetName is (v :: Text where v matches regex "[a-z]{1,12}") end
refinement`, fails `lawspec check` with `definition: unelaborated type at core
boundary`, naming no source position. Using `Text` in the operation and the
refinement in the procedure's parameter works. Proposal: elaborate refinement
aliases in operation signatures, or reject them with a positioned diagnostic.
Similarly, a record field typed by a refinement alias
(`petName :: PetName`) gives `constructor field refinement could not be
proved` for `Adoption pet name customer` even though `name :: PetName`.
