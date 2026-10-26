# Historical CALM corpus inputs

These four files are exact copies of `examples/calm-shop/architecture` at
Ironframe commit `0487828` (the last example before its 0.2.1 fixture refresh).
They preserve the input bytes, decorator digests and 0.1.0 implementation
versions recorded in the Rust parity corpus. Native and Node corpus loaders
map them to the original logical `examples/calm-shop/architecture` paths.
The corpus inputs, expected values and historical receipts are not re-blessed
when the runnable example changes.

| File | SHA-256 |
| --- | --- |
| `shop.calm.json` | `163637bf35589a8625a4ae9b690a68bd576323bbfaf9f5cdfea31770e57ad124` |
| `shop.decorators.json` | `cc8b0b54398742dc6b42dafa1cc181746721679042cf0535f6833138bac19564` |
| `conformance/lawtwin-kafka-0.1.0.json` | `72da3cc9b80c37d8fb0e736ab18a7322ccd105f2167c0618e39853bef4e85927` |
| `conformance/lawtwin-http-0.1.0-petstore.json` | `b29ce2a0a58d464e92a5edd221d7727cbfe7f1ea66ac7887652c7e0041d30fff` |
