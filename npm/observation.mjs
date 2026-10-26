// Application-side transport helpers. Identity and revision checks stay in the
// Haskell core; SDK instrumentation and counts stay with the application.
import {createIronframe} from './api.mjs';

/** Unwrap one complete binding before creating clients or starting new work. */
export async function loadApplicationBinding(value, {ironframe = createIronframe()} = {}) {
  const binding = typeof value === 'string' ? JSON.parse(value) : value;
  const result = await ironframe.run('revision.bindingSettings', {binding});
  if (!('done' in result)) throw new Error(result.failed);
  if (result.done.error) throw new Error(result.done.error);
  return {binding, settings: result.done};
}

/**
 * Flush an existing OpenTelemetry SDK, then report producer-side accounting.
 * Failure still submits an explicitly failed checkpoint. Accepted HTTP exports
 * alone do not prove SDK queue completeness. Counts include all intended exports.
 */
export async function checkpointAfterFlush({sdk, producer, counts, dropped = 0,
  admin = process.env.IRONFRAME_OBSERVATION_ADMIN, timeoutMs = 10000, fetch = globalThis.fetch}) {
  if (!sdk || typeof sdk.forceFlush !== 'function') throw new Error('An SDK forceFlush operation is required');
  if (!admin || !producer || !Number.isSafeInteger(timeoutMs) || timeoutMs <= 0) throw new Error('admin, producer and positive timeoutMs are required');
  let timer;
  let flushed = false;
  let reason;
  try {
    const result = await Promise.race([
      Promise.resolve().then(() => sdk.forceFlush()),
      new Promise((_, reject) => {timer = setTimeout(() => reject(new Error('SDK flush timed out')), timeoutMs);}),
    ]);
    if (result === false) throw new Error('SDK flush reported failure');
    flushed = true;
  } catch (error) { reason = error.message ?? String(error); }
  finally { clearTimeout(timer); }
  const report = {producer, counts: typeof counts === 'function' ? counts() : counts,
    dropped: typeof dropped === 'function' ? dropped() : dropped, flushed};
  const response = await fetch(new URL('/v1/checkpoint', admin), {
    method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify(report),
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) throw new Error(`Observation checkpoint failed: ${response.status} ${await response.text()}`);
  return {...report, ...(reason ? {reason} : {})};
}
