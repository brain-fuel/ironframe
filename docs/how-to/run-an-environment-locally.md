---
id: ironframe.how-to.run-an-environment-locally
kind: how-to
title: Run an environment locally
---
# Run an environment locally

A `podman` environment runs its twins, and any real dependency bound with an
`image`, on this machine with podman and a compose file Ironframe generates.
ref:DEC-podman-compose

## Requirements

- podman, with a running machine on macOS (`podman machine start`). Ironframe
  looks at `IRONFRAME_PODMAN`, then `PATH`, then `/opt/podman/bin/podman`.
  ref:podman
- A compose provider for `podman compose`: `brew install podman-compose`, or
  docker-compose. ref:compose-spec

## Bring it up

```sh
ironframe up local
```

Ironframe checks the manifest, then every image the environment needs. An
image not present locally is pulled. If any image is still missing, nothing
starts, and every missing image is named with the dependency that needs it and
podman's reason:

```text
ironframe: 1 image(s) the environment needs are not available, so nothing was started:
  - dependency "kafka" needs docker.io/lawtwin/kafka:0.1.0: not present locally, and pulling it failed: ... requested access to the resource is denied
Build or pull each image, or bind the dependency to something else in the manifest.
```

Otherwise it writes `.ironframe/local/settings.json` and
`.ironframe/local/compose.yaml`, starts the project
`ironframe-<project>-local`, waits for each started container to answer on
its endpoint, runs the sync targets, such as an env file, and writes the
attestation. A container that does not answer within `--wait` seconds is
recorded as not reached, and `up` exits with status 1.

The application then reads its settings as it always has: from the env file,
the configuration service, or the environment variables you export from them.

## Look at it, and take it down

```sh
ironframe status local
ironframe down local
```

`status` finds the containers by their labels, `io.ironframe.project`,
`io.ironframe.environment` and `io.ironframe.dependency`, and probes each
endpoint. `down` removes the containers; the files in `.ironframe/` stay.

## See what would run

```sh
ironframe compose local
ironframe settings local
```
