# Ironframe

**Making codebases safe for autonomous change.** Let agents work aggressively
without letting the codebase drift.

Ironframe by GoForge belongs to a family: LawSpec and LawTwin, canon and
Rice's Tax, with Rune and Wavelet on the roadmap. This release does one job:
it wires applications to their dependencies per environment, either the real
dependency or a [LawTwin](https://github.com/brain-fuel/lawtwin) twin.
[LawSpec](https://github.com/brain-fuel/lawspec) knows nothing about LawTwin,
and Ironframe never contains contracts or twin internals.

- **A manifest**, `ironframe.yaml`, says what each dependency is in each
  environment: `real`, with its endpoint and a credentials reference, or
  `twin`, with its image, version, configuration and declared conformance
  level. It is checked against a JSON Schema and its cross-field rules, and
  every problem is reported with its path.
- **`ironframe up <env>`** runs twins locally through podman and a generated
  compose file, or deploys them to AWS ECS Fargate, GCP Cloud Run or Azure
  Container Apps through OpenTofu modules. `down`, `status` and `plan` do what
  they say.
- **A configuration service** serves each environment's connection settings,
  and sync adapters write the same settings into AWS AppConfig, GCP Parameter
  Manager, Azure App Configuration and `.env` files, so applications read
  configuration the way they already do.
- **An environment attestation**, a small tool-neutral JSON format, records
  which endpoint each dependency reached and whether it was real or a
  stand-in, for tools such as `lawspec evidence`.

## Quick start

```sh
cargo build
cd examples/kafka-app
../../target/debug/ironframe validate
../../target/debug/ironframe up local-broker   # Apache Kafka in podman
cargo run -p kafka-app                        # reads KAFKA_BOOTSTRAP_SERVERS from .env
cat .ironframe/local-broker/attestation.json
../../target/debug/ironframe down local-broker
```

`ironframe up local` asks for the twin `lawtwin/kafka:0.1.0`, which is not
released yet, and stops before starting anything, naming the missing image.
The tutorial, `docs/tutorials/wire-the-kafka-example.md`, walks through it.

## Layout

| Path | What it holds |
| --- | --- |
| `crates/ironframe-attestation` | The attestation format: types, reader, writer, embedded schema. |
| `crates/ironframe-core` | The manifest and its checks, settings resolution, compose and OpenTofu generation, the podman and OpenTofu drivers, configuration sync, attestation, and the commands as functions. |
| `crates/ironframe-cli` | The `ironframe` binary. |
| `crates/ironframe-config-service` | The configuration service and its `Containerfile`. |
| `modules/` | OpenTofu modules for AWS ECS Fargate, GCP Cloud Run and Azure Container Apps, each with a `tofu test` against a mocked provider. |
| `schema/` | The JSON Schemas of the manifest and the attestation. |
| `examples/kafka-app` | A tiny application reading its Kafka bootstrap servers from configuration, and its manifest. |
| `docs/` | Tutorials, how-to guides, reference and explanation. |

## Developing

```sh
make test         # cargo tests
make lint         # rustfmt and clippy
make tofu-check   # tofu validate and tofu test for every module
make canon        # canon check, with CANON_HOME pointing at a canon checkout
make check        # all of the above
```

There is no hosted CI; every check runs locally. You need Rust 1.90 or later,
podman with a compose provider for local environments, and OpenTofu for cloud
environments and `make tofu-check`.

The repository follows canon's canonical format: `canon.yaml`,
`canonical_refs.yaml` for every work cited, `canonical_decisions.yaml` for
every decision, and `canonical_exemptions.yaml`, which defers vetting to 1.0.

## License

MIT; see `LICENSE`.
