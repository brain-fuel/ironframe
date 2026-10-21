// The cloud adapters over stubbed SDK clients: each call's arguments, the
// paging of list calls and the mapping of the SDKs' errors.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createAws } from "../clouds/aws.mjs";
import { createGcp } from "../clouds/gcp.mjs";
import { createAzure, parseConnectionString } from "../clouds/azure.mjs";

/** A fake AWS SDK: every command class records its name and input; answer(name, input) replies. */
function fakeAws(answer) {
  const sent = [];
  const regions = [];
  const sdk = new Proxy(
    {},
    {
      // Not a thenable: a module namespace has no "then".
      get: (_, name) =>
        name === "then" ? undefined : class {
          constructor(input) {
            this.name = name;
            this.input = input;
          }
        },
    },
  );
  const aws = createAws({
    load: async () => sdk,
    client: (_, region) => {
      regions.push(region);
      return {
        send: async (command) => {
          sent.push([command.name, command.input]);
          return answer(command.name, command.input);
        },
      };
    },
  });
  return { aws, sent, regions };
}

test("aws: finding pages through every list, by name", async () => {
  const pages = {
    undefined: { Items: [{ Name: "other", Id: "o" }], NextToken: "t2" },
    t2: { Items: [{ Name: "x", Id: "x0" }], NextToken: "t3" },
    t3: { Items: [{ Name: "shop", Id: "app-7" }] },
  };
  const { aws, sent, regions } = fakeAws((_, input) => pages[input.NextToken]);
  assert.deepEqual(await aws.findApplication({ region: "eu-west-1", name: "shop" }), { ok: "app-7" });
  assert.deepEqual(sent.map(([name, input]) => [name, input.NextToken]), [
    ["ListApplicationsCommand", undefined],
    ["ListApplicationsCommand", "t2"],
    ["ListApplicationsCommand", "t3"],
  ]);
  assert.deepEqual(await aws.findApplication({ region: "eu-west-1", name: "absent" }), { ok: null });
  assert.deepEqual(regions, ["eu-west-1"]);

  const scoped = fakeAws(() => ({ Items: [{ Name: "Staging", Id: "env-1" }] }));
  assert.deepEqual(await scoped.aws.findEnvironment({ region: "r", application: "app-7", name: "Staging" }), { ok: "env-1" });
  assert.deepEqual(await scoped.aws.findProfile({ region: "r", application: "app-7", name: "nope" }), { ok: null });
  assert.deepEqual(scoped.sent, [
    ["ListEnvironmentsCommand", { ApplicationId: "app-7", NextToken: undefined }],
    ["ListConfigurationProfilesCommand", { ApplicationId: "app-7", NextToken: undefined }],
  ]);
});

test("aws: creating applications, environments, profiles, versions and deployments", async () => {
  const replies = {
    CreateApplicationCommand: { Id: "app-1" },
    CreateEnvironmentCommand: { Id: "env-1" },
    CreateConfigurationProfileCommand: { Id: "prof-1" },
    CreateHostedConfigurationVersionCommand: { VersionNumber: 4 },
    StartDeploymentCommand: { DeploymentNumber: 9 },
  };
  const { aws, sent } = fakeAws((name) => replies[name]);
  assert.deepEqual(await aws.createApplication({ region: "r", name: "shop" }), { ok: "app-1" });
  assert.deepEqual(await aws.createEnvironment({ region: "r", application: "app-1", name: "staging" }), { ok: "env-1" });
  assert.deepEqual(await aws.createProfile({ region: "r", application: "app-1", name: "connections" }), { ok: "prof-1" });
  assert.deepEqual(await aws.createVersion({ region: "r", application: "app-1", profile: "prof-1", content: "{\"A\":\"é\"}" }), { ok: 4 });
  assert.deepEqual(
    await aws.deploy({ region: "r", application: "app-1", environment: "env-1", profile: "prof-1", version: 4, strategy: "AppConfig.AllAtOnce" }),
    { ok: 9 },
  );
  assert.deepEqual(sent[0], ["CreateApplicationCommand", { Name: "shop" }]);
  assert.deepEqual(sent[1], ["CreateEnvironmentCommand", { ApplicationId: "app-1", Name: "staging" }]);
  assert.deepEqual(sent[2], [
    "CreateConfigurationProfileCommand",
    { ApplicationId: "app-1", Name: "connections", LocationUri: "hosted", Type: "AWS.Freeform" },
  ]);
  const [, version] = sent[3];
  assert.equal(version.ContentType, "application/json");
  assert.equal(new TextDecoder().decode(version.Content), "{\"A\":\"é\"}");
  assert.deepEqual({ ...version, Content: undefined }, {
    ApplicationId: "app-1", ConfigurationProfileId: "prof-1", ContentType: "application/json", Content: undefined,
  });
  assert.deepEqual(sent[4], [
    "StartDeploymentCommand",
    { ApplicationId: "app-1", EnvironmentId: "env-1", ConfigurationProfileId: "prof-1", ConfigurationVersion: "4", DeploymentStrategyId: "AppConfig.AllAtOnce" },
  ]);
  const empty = fakeAws(() => ({}));
  assert.deepEqual(await empty.aws.createApplication({ region: "r", name: "x" }), { error: "AppConfig returned no application id" });
});

test("aws: the latest version, its content, or none", async () => {
  const { aws, sent } = fakeAws((name) =>
    name === "ListHostedConfigurationVersionsCommand"
      ? { Items: [{ VersionNumber: 3 }] }
      : { Content: new TextEncoder().encode("{\"K\":\"v\"}") },
  );
  assert.deepEqual(await aws.latestVersion({ region: "r", application: "a", profile: "p" }), { ok: { number: 3, content: "{\"K\":\"v\"}" } });
  assert.deepEqual(sent, [
    ["ListHostedConfigurationVersionsCommand", { ApplicationId: "a", ConfigurationProfileId: "p", MaxResults: 1 }],
    ["GetHostedConfigurationVersionCommand", { ApplicationId: "a", ConfigurationProfileId: "p", VersionNumber: 3 }],
  ]);
  const none = fakeAws(() => ({ Items: [] }));
  assert.deepEqual(await none.aws.latestVersion({ region: "r", application: "a", profile: "p" }), { ok: null });
});

test("aws: an SDK failure is the error and its causes", async () => {
  const { aws } = fakeAws(() => {
    throw new Error("AccessDeniedException: not allowed", { cause: new Error("signature mismatch") });
  });
  assert.deepEqual(await aws.findApplication({ region: "r", name: "x" }), { error: "AccessDeniedException: not allowed: signature mismatch" });
});

test("gcp: existence, creation and versions, with NOT_FOUND and ALREADY_EXISTS mapped", async () => {
  const calls = [];
  const grpc = (code, message) => Object.assign(new Error(message), { code });
  const fake = {
    getParameter: async (request) => {
      calls.push(["getParameter", request]);
      if (request.name.endsWith("/missing")) throw grpc(5, "5 NOT_FOUND: no parameter");
      if (request.name.endsWith("/denied")) throw grpc(7, "7 PERMISSION_DENIED: no access");
      return [{ name: request.name }];
    },
    createParameter: async (request) => (calls.push(["createParameter", request]), [{}]),
    createParameterVersion: async (request) => {
      calls.push(["createParameterVersion", request]);
      if (request.parameterVersionId === "sha256-old") throw grpc(6, "6 ALREADY_EXISTS: version exists");
      return [{}];
    },
  };
  let made = 0;
  const gcp = createGcp({ client: async () => (made++, fake) });
  const parent = "projects/p/locations/global";
  assert.deepEqual(await gcp.parameterExists({ name: `${parent}/parameters/present` }), { ok: true });
  assert.deepEqual(await gcp.parameterExists({ name: `${parent}/parameters/missing` }), { ok: false });
  assert.deepEqual(await gcp.parameterExists({ name: `${parent}/parameters/denied` }), { error: "7 PERMISSION_DENIED: no access" });
  assert.deepEqual(await gcp.createParameter({ parent, id: "shop" }), { ok: null });
  assert.deepEqual(await gcp.createVersion({ parameter: `${parent}/parameters/shop`, id: "sha256-new", data: "{\"K\":\"v\"}" }), { ok: "created" });
  assert.deepEqual(await gcp.createVersion({ parameter: `${parent}/parameters/shop`, id: "sha256-old", data: "{}" }), { ok: "exists" });
  assert.equal(made, 1);
  assert.deepEqual(calls[3], ["createParameter", { parent, parameterId: "shop", parameter: { format: "JSON" } }]);
  const [, version] = calls[4];
  assert.equal(version.parent, `${parent}/parameters/shop`);
  assert.equal(version.parameterVersionId, "sha256-new");
  assert.equal(Buffer.from(version.parameterVersion.payload.data).toString("utf8"), "{\"K\":\"v\"}");
});

// A connection string built at run time, so nothing credential-shaped is committed.
const secretPart = ["c2VjcmV0", "LWJ5dGVz"].join("");
const connection = (endpoint) => [`End${"point"}=${endpoint}`, "Id=key-1", `Sec${"ret"}=${secretPart}`].join(";");

test("azure: parsing a connection string", () => {
  assert.deepEqual(parseConnectionString(connection("https://elsewhere.example")), { endpoint: "https://elsewhere.example", id: "key-1", secret: secretPart });
  assert.throws(() => parseConnectionString("Endpoint=https://x;Id=a"), /connection string has no secret/);
  assert.throws(() => parseConnectionString("Endpoint"), /has no =/);
});

test("azure: get and put through a client for the target's endpoint", async () => {
  const made = [];
  const calls = [];
  const store = {
    getConfigurationSetting: async (request) => {
      calls.push(["get", request]);
      if (request.key === "shop:MISSING") throw Object.assign(new Error("not found"), { statusCode: 404 });
      if (request.key === "shop:DENIED") throw Object.assign(new Error("Forbidden"), { statusCode: 403 });
      return { key: request.key, label: request.label, value: "v1" };
    },
    setConfigurationSetting: async (request) => (calls.push(["put", request]), {}),
  };
  const env = { SHOP_APPCONFIG: connection("https://ignored.example") };
  const azure = createAzure({ client: async (text) => (made.push(text), store), env });
  const target = { endpoint: "https://shop.azconfig.io", connectionStringEnv: "SHOP_APPCONFIG" };
  assert.deepEqual(await azure.get({ ...target, key: "shop:KAFKA", label: "staging" }), { ok: "v1" });
  assert.deepEqual(await azure.get({ ...target, key: "shop:MISSING", label: "staging" }), { ok: null });
  assert.deepEqual(await azure.get({ ...target, key: "shop:DENIED", label: "staging" }), { error: "GET shop:DENIED: HTTP 403 Forbidden: Forbidden" });
  assert.deepEqual(await azure.put({ ...target, key: "shop:KAFKA", label: "staging", value: "v2" }), { ok: null });
  assert.deepEqual(calls[0], ["get", { key: "shop:KAFKA", label: "staging" }]);
  assert.deepEqual(calls[3], ["put", { key: "shop:KAFKA", label: "staging", value: "v2" }]);
  assert.deepEqual(made, [connection("https://shop.azconfig.io")]);
  assert.deepEqual(
    await azure.get({ endpoint: "https://x", connectionStringEnv: "UNSET_VARIABLE", key: "k", label: "l" }),
    { error: "set UNSET_VARIABLE to the store's connection string" },
  );
  const broken = createAzure({ client: async () => store, env: { BAD: "Endpoint=https://x;Id=a" } });
  assert.deepEqual(await broken.put({ endpoint: "https://x", connectionStringEnv: "BAD", key: "k", label: "l", value: "v" }), { error: "connection string has no secret" });
});
