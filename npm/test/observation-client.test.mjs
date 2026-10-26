import {test} from 'node:test';
import assert from 'node:assert/strict';
import {checkpointAfterFlush, loadApplicationBinding} from '../observation.mjs';

test('flush completion precedes checkpoint; counters are read after flush', async () => {
  let flushed = false;
  const report = await checkpointAfterFlush({
    sdk: {async forceFlush() {flushed = true;}}, producer: 'worker', admin: 'http://localhost:9646',
    counts() {assert.equal(flushed, true); return {logs: 3, spans: 2};},
    async fetch(_, request) {assert.equal(flushed, true); assert.equal(JSON.parse(request.body).flushed, true); return {ok: true};},
  });
  assert.equal(report.flushed, true);
  assert.deepEqual(report.counts, {logs: 3, spans: 2});
});

test('failed SDK flush still records an explicitly incomplete checkpoint', async () => {
  const report = await checkpointAfterFlush({
    sdk: {async forceFlush() {throw new Error('queue did not drain');}}, producer: 'worker', admin: 'http://localhost:9646',
    counts: {logs: 3, spans: 0},
    async fetch(_, request) {assert.equal(JSON.parse(request.body).flushed, false); return {ok: true};},
  });
  assert.equal(report.flushed, false);
  assert.match(report.reason, /queue did not drain/);
});

test('application binding loader delegates identity checks to the core', async () => {
  await assert.rejects(loadApplicationBinding('{}', {ironframe: {async run() {return {done: {error: 'settings digest does not match'}};}}}), /digest/);
});
