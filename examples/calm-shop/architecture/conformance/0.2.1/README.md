# Current CALM example provider receipts

`context.json` maps these byte-for-byte raw LawTwin report copies to the current
example. Kafka comes from LawTwin commit `914a95c`; HTTP comes from `51fe43b`.
The HTTP directory retains the original report summary and identity/coverage
context. Kafka's complete wire traces remain in the upstream report directory.

- `kafka/report.json`: release 0.2.1, level 3 `answers`, checked against Apache
  Kafka 4.3.1; 24 real and 24 twin runs, eight ledger-accounted divergences.
- `http/python.json`: **conformant** within 44 modeled-resource requests,
  seven laws, seed 1, two rounds and retries. The HTTP fixture bindings use
  this receipt. Valid behavior of eight unmodelled operations is outside it.
- `http/python-invalid.json`: lawful, 84 requests and six invalid/unmodelled
  answer differences. It does not broaden the conformant claim.
- `http/swagger-petstore3.json`: **lawful**, 84 requests, 36 answer differences,
  no resource-law violations and two invalid-input findings. This is the local
  Swagger image's receipt, retained separately from the HTTP fixture's scoped
  conformant receipt. The real binding supports provider identity rather than
  a conformance-report field. No hosted staging endpoint run is claimed.
- `http/python-forget-delete.json`: independent negative control, divergent;
  six deleted-resource-law violations, exit 1.

The fixture implementation version is 0.2.1. Both dependency contract packages
remain at version 0.1.0. Historical receipts beside this directory are unchanged.
Image IDs identify locally tested content; they do not assert registry publication.
