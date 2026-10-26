import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, readFile, rm, access} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {createHost} from '../host.mjs';

test('compare-and-swap preserves a competing selection', async t => {
  const folder = await mkdtemp(join(tmpdir(), 'ironframe-cas-'));
  t.after(() => rm(folder, {recursive: true, force: true}));
  const path = join(folder, 'state.json');
  const host = createHost();
  t.after(() => host.close());
  assert.deepEqual(await host.perform({effect:'compareAndSwap',path,expected:null,text:'first'}),{ok:true});
  assert.deepEqual(await host.perform({effect:'compareAndSwap',path,expected:null,text:'second'}),{ok:false});
  assert.equal(await readFile(path,'utf8'),'first');
  assert.deepEqual(await host.perform({effect:'compareAndSwap',path,expected:'first',text:'second'}),{ok:true});
  assert.equal(await readFile(path,'utf8'),'second');
});

test('operation locks exclude another host and are released on close', async t => {
  const folder = await mkdtemp(join(tmpdir(), 'ironframe-lock-'));
  t.after(() => rm(folder, {recursive: true, force: true}));
  const path = join(folder, 'operation.lock');
  const first=createHost(), second=createHost();
  t.after(() => Promise.all([first.close(),second.close()]));
  assert.deepEqual(await first.perform({effect:'lockDirectory',path}),{ok:null});
  assert.ok((await second.perform({effect:'lockDirectory',path})).error);
  assert.ok((await second.perform({effect:'unlockDirectory',path})).error);
  await first.close();
  await assert.rejects(access(path));
  assert.deepEqual(await second.perform({effect:'lockDirectory',path}),{ok:null});
  assert.deepEqual(await second.perform({effect:'unlockDirectory',path}),{ok:null});
});
