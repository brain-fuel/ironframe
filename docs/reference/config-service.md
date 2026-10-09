---
id: ironframe.reference.config-service
kind: reference
title: Configuration service
---
# Configuration service

`ironframe-config-service` is a small HTTP server that serves each
environment's connection settings, the same settings Ironframe writes to env
files and syncs into the clouds. It reads a settings document on every
request, so the settings a new `ironframe up` writes are served at once, and
it never writes. ref:DEC-config-service

## Running it

A podman environment runs it beside its dependencies when the manifest asks:

```yaml
environments:
  local:
    runtime: podman
    config_service:
      port: 8700
```

Build the image first, from the repository root:

```sh
make config-service-image
```

It is a static binary in a scratch image of about 2.4 MB. Run on its own, it
reads two environment variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `IRONFRAME_SETTINGS` | `/etc/ironframe/settings.json` | The settings document. |
| `IRONFRAME_LISTEN` | `0.0.0.0:8700` | The address to listen on. |

## Routes

| Route | Response |
| --- | --- |
| `GET /healthz` | `ok`. |
| `GET /v1/environments` | `{"project": ..., "environments": [...]}`. |
| `GET /v1/environments/{environment}` | The environment's settings as a JSON object. |
| `GET /v1/environments/{environment}/env` | The settings as a dotenv file. |
| `GET /v1/environments/{environment}/settings/{key}` | One setting's value as plain text. |

An unknown environment or setting is a 404 with a JSON `error` naming what
exists. An unreadable settings document is a 503.

## The settings document

```json
{
  "project": "kafka-app",
  "environments": {
    "local": { "KAFKA_BOOTSTRAP_SERVERS": "localhost:9092" }
  }
}
```

`ironframe up <environment>` writes the environment's document to
`.ironframe/<environment>/settings.json`, and the compose file mounts it read
only into the service's container.
