import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, readFile, readdir, rm} from 'node:fs/promises';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createServer, connect} from 'node:net';
import {createHash} from 'node:crypto';
import os from 'node:os';
import path from 'node:path';

const exec = promisify(execFile);
const cli = new URL('../bin/ironframe.mjs', import.meta.url).pathname;
const digest = value => createHash('sha256').update(value).digest('hex');

async function fixture(t, scenario = 'pass') {
  const root = await mkdtemp(path.join(os.tmpdir(), 'ironframe components '));
  t.after(() => rm(root, {recursive: true, force: true}));
  const reservation = createServer();
  await new Promise(resolve => reservation.listen(0, '127.0.0.1', resolve));
  const port = reservation.address().port;
  await new Promise(resolve => reservation.close(resolve));
  const tool = path.join(root, 'lawspec-fixture.mjs');
  await writeFile(tool, `#!${process.execPath}
import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
const args=process.argv.slice(2), verb=args[0], file=args[args.indexOf('--config')+1], root=path.dirname(file), node=path.basename(root);
const contract={contract:'example.graph',version:'1.0.0',digest:'b'.repeat(64),abilities:['example.graph::ability::Graph']};
if(verb==='describe')console.log(JSON.stringify({format:'lawspec-component',version:1,manifest:file,root,component:{name:node,version:'0.1.0'},fingerprint:createHash('sha256').update(fs.readFileSync(path.join(root,'native.txt'))).digest('hex'),provides:node==='server'?[contract]:[],requires:node==='server'?{}:{graph:{...contract,declarations:[node+'::read'],settings:['BASE_URL']}},targets:node==='server'?[]:[{language:'javascript',root:'.'}],declarations:[node+'::read','example.graph::ability::Graph']}));
else if(verb==='generate')fs.writeFileSync(path.join(root,'native.txt'),'generated');
else if(verb==='test'){fs.appendFileSync(path.join(root,'tests-ran'),'test\\n');if(process.env.SCENARIO==='native-failure')process.exit(1);}
else if(verb==='evidence'){
 const attestation=JSON.parse(fs.readFileSync(args[args.indexOf('--attestation')+1]));
 if(attestation.execution.status!=='completed')throw Error('evidence did not receive a completed run');
 if(process.env.SCENARIO==='target'&&!args.includes('--target'))throw Error('evidence target selection missing');
 const current=!['empty','stale'].includes(process.env.SCENARIO);
 console.log(JSON.stringify([{declaration:node+'::law::read',stage:'law',nativeEvidence:{status:attestation.execution.exit_code?'failed':'passed',observations:[{freshness:'matching-inputs',attempt:{executionRun:current?attestation.run.id:'earlier-run'}}]}}]));
}else throw Error('unexpected fixture verb '+verb);
`, {mode: 0o755});
  for (const node of ['client', 'server', 'other']) {
    await mkdir(path.join(root, node));
    await writeFile(path.join(root, node, 'lawspec.edn'), '{:fixture true}');
    await writeFile(path.join(root, node, 'native.txt'), 'initial');
  }
  const node = name => ({'unique-id': name, 'node-type': 'service', name, description: name});
  const edge = name => ({'unique-id': name+'-server', description: 'reads', protocol: 'HTTP', 'relationship-type': {connects: {source: {node: name}, destination: {node: 'server'}}}});
  await writeFile(path.join(root, 'system.calm.json'), JSON.stringify({'unique-id':'integration',nodes:['client','server','other'].map(node),relationships:['client','other'].map(edge)}));
  const decorate = (id, type, target, data) => ({'unique-id':id,type,target:['integration'],'applies-to':[target],data});
  const endpoint = `http://127.0.0.1:${port}`;
  const serverScript = `require('node:http').createServer((q,r)=>{r.statusCode=q.url==='/never'?503:200;r.end('ok')}).listen(${port},'127.0.0.1',()=>console.log(process.pid));`;
  const decorations = [
    ...['client','server','other'].map(name=>decorate(name+'-contract','ironframe-contract',name,{component:{manifest:name+'/lawspec.edn'}})),
    ...['client','other'].map(name=>decorate(name+'-edge','ironframe-contract',name+'-server',{connection:{requirement:'graph',settings:{BASE_URL:'${endpoint}'}}})),
    decorate('local','ironframe-environment','client',{environment:'local',project:'component-tests',runtime:'podman'}),
    ...['client','other'].map(name=>decorate(name+'-binding','ironframe-binding',name,{environment:'local',component:{external:{}}})),
    decorate('server-binding','ironframe-binding','server',{environment:'local',component:{endpoint,build:{command:[process.execPath,'-e',`require('node:fs').writeFileSync('native.txt','built')`]},managed:{process:{command:[process.execPath,'-e',serverScript]}},ready:{url:'${endpoint}/'+(scenario==='readiness'?'never':''),timeoutSeconds:1}}}),
  ];
  await writeFile(path.join(root, 'system.decorators.json'), JSON.stringify(decorations));
  const run = async (extra=[]) => {
    try {const result=await exec(process.execPath,[cli,'-a','system.calm.json','test','--env','local','--app','client',...extra],{cwd:root,env:{...process.env,IRONFRAME_LAWSPEC:tool,SCENARIO:scenario},timeout:30000,maxBuffer:4*1024*1024});return {...result,code:0};}
    catch(error){return {...error,code:error.code};}
  };
  const attestations = async () => {
    const directory=path.join(root,'.ironframe/local/runs');
    return Promise.all((await readdir(directory)).map(async file=>JSON.parse(await readFile(path.join(directory,file),'utf8'))));
  };
  return {root,port,run,attestations};
}

async function isListening(port) {
  return new Promise(resolve=>{const socket=connect({host:'127.0.0.1',port});socket.once('connect',()=>{socket.destroy();resolve(true)});socket.once('error',()=>resolve(false));});
}

test('integration brackets the selected process and freezes post-preparation component inputs', async t=>{
  const f=await fixture(t), result=await f.run();
  assert.equal(result.code,0,result.stderr);
  assert.equal(await isListening(f.port),false);
  const records=await f.attestations(), component=records.find(value=>value.application), integration=records.find(value=>!value.application);
  assert.equal(component.application.component.fingerprint,digest('generated'));
  assert.equal(component.execution.environment_run,integration.run.id);
  assert.equal(integration.execution.status,'completed');assert.equal(integration.execution.exit_code,0);
  assert.equal(integration.architecture.topology_digest,component.architecture.topology_digest);
  await assert.rejects(readFile(path.join(f.root,'other/tests-ran')),/ENOENT/);
});

for(const scenario of ['readiness','native-failure','empty','stale'])test(`integration rejects ${scenario} and cleans its owned service`,async t=>{
  const f=await fixture(t,scenario),result=await f.run(scenario==='empty'?['--','--tag','none']:[]);
  assert.notEqual(result.code,0,result.stdout);
  assert.equal(await isListening(f.port),false);
  const integration=(await f.attestations()).find(value=>!value.application);
  assert.equal(integration.execution.status,'completed');assert.equal(integration.execution.exit_code,1);
});

test('completed evidence receives the executed target selection',async t=>{
  const f=await fixture(t,'target'),result=await f.run(['--','--target','javascript']);
  assert.equal(result.code,0,result.stderr);assert.equal(await isListening(f.port),false);
});
