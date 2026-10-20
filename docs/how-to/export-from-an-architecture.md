---
id: ironframe.how-to.export-from-an-architecture
kind: how-to
title: Export from an architecture
---
# Export from an architecture

Take diagrams, settings and infrastructure from a resolved environment to use
with other tools. Nothing is deployed. ref:DEC-calm-exports

- A diagram marking each dependency real or twin:

  ```sh
  ironframe -a shop.calm.json export diagram --env mixed > mixed.mmd
  ironframe -a shop.calm.json export diagram --env mixed --format dot | dot -Tsvg > mixed.svg
  ```

- The same through CALM's own tooling: the architecture annotated with each
  binding, still CALM 1.2, and rendered by the CALM CLI's block-architecture
  widget:

  ```sh
  ironframe -a shop.calm.json export diagram --env mixed --format calm > mixed.calm.json
  calm docify --architecture mixed.calm.json --output site
  ironframe -a shop.calm.json export diagram --env mixed --format calm-template > mixed.md
  ```

- The settings an application reads, for a deployment tool to inject:

  ```sh
  ironframe -a shop.calm.json export settings --env twin --app adoptions-service --format env > .env
  ironframe -a shop.calm.json export settings --env twin            # every application, JSON
  ```

- The OpenTofu root of a cloud environment, for `tofu` or `terraform` and any
  pipeline that runs them, from the modules under `modules/`:

  ```sh
  ironframe -a shop.calm.json export tofu --env staging --output infra/
  tofu -chdir=infra init && tofu -chdir=infra plan
  ```

- The compose file of a podman environment:
  `ironframe -a shop.calm.json export compose --env twin > compose.yaml`.

Every export comes from the one resolved topology
(`ironframe -a shop.calm.json export topology --env twin`), so the diagram, the
settings and the root module show the same bindings.
