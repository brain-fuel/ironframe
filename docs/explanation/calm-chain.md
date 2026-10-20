---
id: ironframe.explanation.calm-chain
kind: explanation
title: The CALM chain
---
# The CALM chain

The family's path to 1.0 runs one chain: **LawSpec contracts → a CALM
architecture and Ironframe bindings → real services or LawTwin fixtures →
execution evidence**. ref:lawspec-pre-1-0-path This page explains what each
link owns, why the architecture is the source of wiring, and how a run comes
back to LawSpec as evidence. ref:DEC-calm-architecture

## Who owns what

| Project | Owns | Never contains |
| --- | --- | --- |
| LawSpec | Business laws, dependency abilities, checked reference models, verification evidence. ref:lawspec | Anything about LawTwin, CALM, endpoints or environments. |
| LawTwin | Protocol fixtures around those models, declared faults, deterministic time, control APIs, histories, replay, provider conformance. ref:lawtwin | Business laws; which environment uses what. |
| Ironframe | CALM service nodes and dependency edges, resolved LawSpec contract identities, explicit per-environment real or twin bindings, the settings applications read, the attestation of each run. | Contracts' contents; twin internals. |

An application never learns which of these produced its settings: it reads
them as it always has, from its environment, a `.env` file or its cloud's
configuration store. ref:DEC-calm-deployment

## Why a CALM architecture

An architecture already names the services and the edges between them. A CALM
1.2 document does so in a form other tools read: the FINOS CLI validates it,
draws it and documents it. Ironframe adds nothing to the document itself.
Everything it needs is attached by **decorators**, standalone CALM documents
that apply to elements by unique-id: ref:DEC-calm-decorators ref:calm-decorators

- a **contract decorator** says what LawSpec contract an element stands for:
  the package an application implements, the package, version range and
  abilities a dependency must provide, and on each edge, which of the
  application's abilities reach the dependency and which settings the
  application reads it through;
- a **binding decorator** says what one node is in one environment: the real
  provider, or a LawTwin twin with the contract identity it stands in for, its
  seed, faults and conformance report; for an application, whether its own
  tooling deploys it or Ironframe runs it;
- an **environment decorator** says where the environment runs and where its
  settings are synced.

The architecture stays the architecture. A team that does not use Ironframe
reads it unchanged, and the decorators can sit beside other tools' decorators
in one file.

## Resolution

`ironframe resolve` turns the architecture, its decorators and an environment
into a **resolved topology**: every application, every dependency with the
binding it has there, and every edge between them. Resolution refuses rather
than guesses: an edge without a contract, a dependency without a binding, two
bindings for one node, or a twin whose stand-in contract has another package,
a version outside the dependency's range, a missing ability or a conformance
level the dependency does not accept, is reported by element, all at once.
ref:DEC-calm-resolution ref:DEC-calm-refusals ref:DEC-calm-compatibility

The topology is **planned wiring**. Everything Ironframe generates comes from
it: diagrams, the settings each application reads, the OpenTofu root and the
compose file. Each export works on its own, so another deployment tool can take
the settings or the OpenTofu root and never run Ironframe. ref:DEC-calm-exports

## Completed runs as evidence

A plan is not evidence. When an application runs, under `ironframe run`, as a
managed application, or deployed by its own tooling and bracketed by
`ironframe attest --app` and `--complete`, Ironframe writes an attestation as
the run begins and again when it completes. ref:DEC-calm-run
ref:DEC-calm-planned-vs-completed

- Each dependency is named by the application **ability** that reaches it,
  `shop.adoptions::ability::Adoptions`, which is how LawSpec matches it to the
  laws that ran under that ability's production handler.
- Each says whether a **real provider** or a **fixture** answered, with the
  provider's name and version or the twin's image, digest, seed and the
  contract it stands in for.
- The document carries the **architecture** (document and decorator digests,
  the topology's digest and the elements involved), the **application** (its
  contract and commit) and the **run** (its id, command, exit code and
  completion, and each twin's history digest when it completed).

`lawspec test --attestation` and `lawspec evidence --attestation` read the same
document, version 1 of the environment attestation, and report each law with
the dependencies it ran against. LawSpec never learns that Ironframe or LawTwin
wrote it. ref:DEC-attestation-architecture

## What stays the same across bindings

The laws do not change when a binding does. The calm-shop example runs one Go
application's laws against twins, against Apache Kafka and the Swagger
Petstore, and against a mix, and only the endpoints in its settings differ; the
evidence says which obligations ran against which. See [Run the CALM
demonstrations](../how-to/run-the-calm-demonstrations.md).
