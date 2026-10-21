// AWS AppConfig over the official SDK, @aws-sdk/client-appconfig: the calls
// Ironframe's sync makes, each answering {ok: value} or {error: reason}.
// Credentials come from the SDK's default chain; AWS_ENDPOINT_URL points it at
// an emulator. Mirrors the Rust adapter it replaced. ref:DEC-config-sync
import { chainText } from "../errors.mjs";

/**
 * The AWS calls. load() gives the SDK module and client(sdk, region) a client
 * with send(command); tests replace both.
 */
export function createAws({
  load = () => import("@aws-sdk/client-appconfig"),
  client = (sdk, region) => new sdk.AppConfigClient({ region }),
} = {}) {
  let sdk;
  const clients = new Map();
  async function send(region, command, input) {
    sdk ??= await load();
    if (!clients.has(region)) clients.set(region, client(sdk, region));
    return clients.get(region).send(new sdk[command](input));
  }

  // The id of the item named `name` across every page of a list call.
  async function find(region, command, input, name) {
    let NextToken;
    do {
      const page = await send(region, command, { ...input, NextToken });
      for (const item of page.Items ?? []) if (item.Name === name) return item.Id ?? null;
      NextToken = page.NextToken;
    } while (NextToken);
    return null;
  }

  function created(kind, id) {
    if (id === undefined || id === null) throw new Error(`AppConfig returned no ${kind} id`);
    return id;
  }

  const calls = {
    findApplication: ({ region, name }) => find(region, "ListApplicationsCommand", {}, name),
    createApplication: async ({ region, name }) =>
      created("application", (await send(region, "CreateApplicationCommand", { Name: name })).Id),
    findEnvironment: ({ region, application, name }) =>
      find(region, "ListEnvironmentsCommand", { ApplicationId: application }, name),
    createEnvironment: async ({ region, application, name }) =>
      created(
        "environment",
        (await send(region, "CreateEnvironmentCommand", { ApplicationId: application, Name: name })).Id,
      ),
    findProfile: ({ region, application, name }) =>
      find(region, "ListConfigurationProfilesCommand", { ApplicationId: application }, name),
    createProfile: async ({ region, application, name }) =>
      created(
        "profile",
        (
          await send(region, "CreateConfigurationProfileCommand", {
            ApplicationId: application,
            Name: name,
            LocationUri: "hosted",
            Type: "AWS.Freeform",
          })
        ).Id,
      ),
    async latestVersion({ region, application, profile }) {
      const listed = await send(region, "ListHostedConfigurationVersionsCommand", {
        ApplicationId: application,
        ConfigurationProfileId: profile,
        MaxResults: 1,
      });
      const first = (listed.Items ?? [])[0];
      if (!first) return null;
      const number = first.VersionNumber;
      const version = await send(region, "GetHostedConfigurationVersionCommand", {
        ApplicationId: application,
        ConfigurationProfileId: profile,
        VersionNumber: number,
      });
      const content = version.Content ? new TextDecoder("utf-8", { ignoreBOM: true }).decode(version.Content) : "";
      return { number, content };
    },
    createVersion: async ({ region, application, profile, content }) =>
      (
        await send(region, "CreateHostedConfigurationVersionCommand", {
          ApplicationId: application,
          ConfigurationProfileId: profile,
          ContentType: "application/json",
          Content: new TextEncoder().encode(content),
        })
      ).VersionNumber,
    deploy: async ({ region, application, environment, profile, version, strategy }) =>
      (
        await send(region, "StartDeploymentCommand", {
          ApplicationId: application,
          EnvironmentId: environment,
          ConfigurationProfileId: profile,
          ConfigurationVersion: String(version),
          DeploymentStrategyId: strategy,
        })
      ).DeploymentNumber,
  };
  return answering(calls);
}

/** Wraps each call so it answers {ok} or {error: the SDK's reason}. */
export function answering(calls) {
  return Object.fromEntries(
    Object.entries(calls).map(([name, call]) => [
      name,
      async (fields) => {
        try {
          return { ok: await call(fields) };
        } catch (error) {
          return { error: chainText(error) };
        }
      },
    ]),
  );
}
