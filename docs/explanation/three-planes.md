---
id: ironframe.explanation.three-planes
kind: explanation
title: The three planes
---
# The three planes

Ironframe by GoForge makes codebases safe for autonomous change: agents work
aggressively without letting the codebase drift. Its family divides the work
into planes that never reach into each other. ref:DEC-three-planes

| Plane | Owns | Never contains |
| --- | --- | --- |
| LawSpec, the business contract | The application's laws. A dependency is an ability; its production handler is the real client library. ref:lawspec | Anything about twins, endpoints or environments. |
| LawTwin, the stand-ins | Dependency contracts as LawSpec packages, twin servers, their control plane, conformance, record and replay. ref:lawtwin | Business laws; which environment uses what. |
| Ironframe, the wiring | Environment manifests, the configuration service and its cloud sync, the environment attestation. | Contracts; twin internals. |

## Why the wiring is separate

A test that runs against a stand-in proves less than one that runs against the
real dependency, and how much less depends on the stand-in's conformance. That
fact belongs to the run, not to the contract: the same law is checked against
a twin on a laptop and against the real cluster in staging. So the contract
says nothing about environments, and the wiring says nothing about laws.
ref:DEC-wiring-in-ironframe

Ironframe decides, per environment and per dependency, whether the application
talks to the real thing or a twin; it hands the application the endpoint
through the configuration it already reads; and it records what the run
actually reached. It runs a twin's image and passes the twin its
configuration as `TWIN_CONFIG`, but what the twin does with it is LawTwin's
business. ref:DEC-config-service ref:DEC-config-sync

## The one thing that crosses

The attestation is the only thing that leaves Ironframe for LawSpec. It is a
tool-neutral JSON format: an environment, a run, and per dependency the
endpoint reached, whether it was `real` or a `stand-in`, and a stand-in's
declared conformance level. LawSpec reads it without importing, naming or
calling Ironframe or LawTwin, and any other tool that wires environments can
write it. ref:DEC-attestation-format
