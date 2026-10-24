import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, readFile, rm} from 'node:fs/promises';
import {createServer} from 'node:net';
import os from 'node:os';
import path from 'node:path';
import {createHost} from '../host.mjs';

async function context(t, signal) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'ironframe-owned-'));
  const host = createHost({signal});
  t.after(async () => {await host.close(); await rm(root, {recursive: true, force: true});});
  return {host, root, request: {effect: 'startService', command: [process.execPath, '-e', 'console.log("ready"); setInterval(() => {}, 1000)'], cwd: root, env: {}, log: path.join(root, 'service.log')}};
}

test('a process fixture has a private handle, retained log and owned cleanup', async t => {
  const {host, request} = await context(t);
  const result = await host.perform(request);
  assert.ok(result.ok, JSON.stringify(result));
  const {id, pid, log} = result.ok;
  const deadline = Date.now() + 5000;
  while (!(await readFile(log, 'utf8')).includes('ready')) {
    assert.ok(Date.now() < deadline, 'service emitted its startup message');
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  assert.equal((await host.perform({effect: 'serviceStatus', id})).ok.running, true);
  assert.deepEqual(await host.perform({effect: 'stopService', id}), {ok: null});
  assert.throws(() => process.kill(pid, 0), error => error.code === 'ESRCH');
  assert.match((await host.perform({effect: 'stopService', id})).error, /Unknown owned service/);
});

test('an occupied service port is rejected without replacing its listener', async t => {
  const {host, request} = await context(t);
  const server = createServer();
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const result = await host.perform({...request, endpoint: `http://127.0.0.1:${server.address().port}`});
  assert.ok(result.error, JSON.stringify(result));
  assert.equal(server.listening, true);
});

test('cancellation cleans owned services and prevents another startup', async t => {
  const controller = new AbortController();
  const {host, request} = await context(t, controller.signal);
  const result = await host.perform(request);
  controller.abort();
  await host.close();
  assert.throws(() => process.kill(result.ok.pid, 0), error => error.code === 'ESRCH');
  assert.ok((await host.perform(request)).error);
});

test('a missing executable is an explicit startup failure', async t => {
  const {host, request} = await context(t);
  const result = await host.perform({...request, command: [path.join(request.cwd, 'not-an-executable')]});
  assert.ok(result.error, JSON.stringify(result));
  await host.close();
});
