---
id: ironframe.how-to.sync-configuration
kind: how-to
title: Sync configuration to where applications read it
---
# Sync configuration to where applications read it

Applications keep reading configuration the way they already do. Ironframe
writes an environment's settings to the places they read from: an env file,
AWS AppConfig, GCP Parameter Manager or Azure App Configuration, besides the
configuration service. ref:DEC-config-sync

Name the targets in the environment:

```yaml
environments:
  staging:
    sync:
      - env_file: {path: .env.staging}
      - aws_appconfig: {region: us-east-1, application: kafka-app, profile: connections}
      - gcp_parameter_manager: {project: kafka-app-staging, parameter: kafka-app-staging}
      - azure_app_configuration: {endpoint: 'https://kafka-app.azconfig.io', prefix: 'kafka-app:'}
```

`ironframe up` runs them after the environment is up; `ironframe sync staging`
runs them alone. Each target is left alone when it already holds the
settings, so syncing twice changes nothing.

## What each target receives

| Target | What is written | Credentials |
| --- | --- | --- |
| `env_file` | `KEY=value` lines under a header, relative to the manifest. | None. |
| `aws_appconfig` | A hosted, freeform configuration profile holding the settings as one JSON object, under an application and environment created when missing; a new version is created and deployed only when the content changed. ref:aws-appconfig | The AWS SDK's default chain: environment, profile, SSO or role. ref:aws-sdk-js-appconfig |
| `gcp_parameter_manager` | A JSON-format parameter, created when missing, with one version per distinct content, its id the content's digest. ref:gcp-parameter-manager | Application Default Credentials. ref:google-cloud-parametermanager-node |
| `azure_app_configuration` | One key-value per setting, keyed `<prefix><KEY>`, labelled with the environment's name unless `label` is set; only changed keys are written. ref:azure-app-configuration | The store's connection string in `AZURE_APPCONFIG_CONNECTION_STRING`, or the variable `connection_string_env` names; the Azure SDK signs each request with its access key. ref:azure-app-configuration-js |

Settings removed from the manifest are not deleted from a cloud store.

Each cloud call is made by the command's Node host with the cloud's official
JavaScript SDK, `@aws-sdk/client-appconfig`, `@google-cloud/parametermanager`
or `@azure/app-configuration`, installed with the `ironframe` package. Set
`AWS_ENDPOINT_URL` to point the AWS SDK at an emulator. ref:DEC-config-sync
