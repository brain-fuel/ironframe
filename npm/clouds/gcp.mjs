// GCP Parameter Manager over Google's official client,
// @google-cloud/parametermanager, with Application Default Credentials.
// Mirrors crates/ironframe-core/src/sync/gcp.rs. ref:DEC-config-sync
import { answering } from "./aws.mjs";

const NOT_FOUND = 5;
const ALREADY_EXISTS = 6;

/** The GCP calls. client() gives a ParameterManagerClient; tests replace it. */
export function createGcp({
  client = async () => new (await import("@google-cloud/parametermanager")).ParameterManagerClient(),
} = {}) {
  let made;
  const get = async () => (made ??= await client());
  return answering({
    async parameterExists({ name }) {
      try {
        await (await get()).getParameter({ name });
        return true;
      } catch (error) {
        if (error && error.code === NOT_FOUND) return false;
        throw error;
      }
    },
    async createParameter({ parent, id }) {
      await (await get()).createParameter({ parent, parameterId: id, parameter: { format: "JSON" } });
      return null;
    },
    async createVersion({ parameter, id, data }) {
      try {
        await (await get()).createParameterVersion({
          parent: parameter,
          parameterVersionId: id,
          parameterVersion: { payload: { data: Buffer.from(data, "utf8") } },
        });
        return "created";
      } catch (error) {
        if (error && error.code === ALREADY_EXISTS) return "exists";
        throw error;
      }
    },
  });
}
