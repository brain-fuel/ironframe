// Azure App Configuration over the official client, @azure/app-configuration,
// with the access key of the connection string in the environment variable the
// target names, used against the target's endpoint, as the Rust adapter it
// replaced was. ref:DEC-config-sync
import { STATUS_CODES } from "node:http";
import { answering } from "./aws.mjs";

/** The parts of a connection string, Endpoint=...;Id=...;Secret=..., or the reason it is not one. */
export function parseConnectionString(text) {
  const parts = new Map();
  for (const part of text.split(";")) {
    if (part.trim() === "") continue;
    const at = part.indexOf("=");
    if (at < 0) throw new Error(`connection string part ${JSON.stringify(part)} has no =`);
    parts.set(part.slice(0, at).trim().toLowerCase(), part.slice(at + 1).trim());
  }
  const take = (key) => {
    if (!parts.has(key)) throw new Error(`connection string has no ${key}`);
    return parts.get(key);
  };
  return { endpoint: take("endpoint"), id: take("id"), secret: take("secret") };
}

/**
 * The Azure calls. client(connectionString) gives an AppConfigurationClient
 * and env the environment the connection string is read from; tests replace
 * both.
 */
export function createAzure({
  client = async (connectionString) =>
    new (await import("@azure/app-configuration")).AppConfigurationClient(connectionString),
  env = process.env,
} = {}) {
  const clients = new Map();
  async function store(endpoint, connectionStringEnv) {
    const text = env[connectionStringEnv];
    if (text === undefined) throw new Error(`set ${connectionStringEnv} to the store's connection string`);
    const credential = parseConnectionString(text);
    const connection = ["Endpoint=" + endpoint, "Id=" + credential.id, "Secret=" + credential.secret].join(";");
    if (!clients.has(connection)) clients.set(connection, await client(connection));
    return clients.get(connection);
  }
  const reason = (verb, key, error) => {
    const status = error && error.statusCode;
    if (typeof status !== "number") return error;
    return new Error(`${verb} ${key}: HTTP ${status} ${STATUS_CODES[status] ?? ""}: ${error.message}`);
  };
  return answering({
    async get({ endpoint, connectionStringEnv, key, label }) {
      const configuration = await store(endpoint, connectionStringEnv);
      try {
        const setting = await configuration.getConfigurationSetting({ key, label });
        return typeof setting.value === "string" ? setting.value : null;
      } catch (error) {
        if (error && error.statusCode === 404) return null;
        throw reason("GET", key, error);
      }
    },
    async put({ endpoint, connectionStringEnv, key, label, value }) {
      const configuration = await store(endpoint, connectionStringEnv);
      try {
        await configuration.setConfigurationSetting({ key, label, value });
        return null;
      } catch (error) {
        throw reason("PUT", key, error);
      }
    },
  });
}
