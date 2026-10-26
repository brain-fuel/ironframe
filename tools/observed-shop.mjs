#!/usr/bin/env node
// Assembled acceptance: actual LawSpec native Go laws, Kafka/HTTP providers,
// disposable observations, immutable revisions, publication, adoption and revert.
// All application/configuration changes happen in this run's scratch copy.
import {cp, mkdtemp, mkdir, readFile, writeFile} from 'node:fs/promises';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createServer} from 'node:net';
import {randomUUID,createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {resolve, join} from 'node:path';
import assert from 'node:assert/strict';

const exec = promisify(execFile);
const root = fileURLToPath(new URL('..', import.meta.url));
const cli = join(root,'npm/bin/ironframe.mjs');
const observer = process.env.IRONFRAME_OBSERVATION_CORE;
if (!observer) throw new Error('Set IRONFRAME_OBSERVATION_CORE to the built lawtwin-observation executable');
const artifacts = resolve(process.env.IRONFRAME_OBSERVATION_ARTIFACTS ?? join(root,'.artifacts/observed-shop'));
await mkdir(artifacts,{recursive:true});
const scratch = await mkdtemp(join(artifacts,'run-'));
const source = join(root,'examples/calm-shop');
await cp(source,scratch,{recursive:true,filter:path=>!/(?:^|\/)(?:node_modules|\.ironframe|\.lawspec)(?:\/|$)/.test(path)});
const app=join(scratch,'app'), architecture=join(scratch,'architecture/observed.calm.json');
const decorators=join(scratch,'architecture/observed.decorators.json');
const project='observed-'+randomUUID().slice(0,8);
const recording={scratch,project,runs:[],checks:[]};
const lawDigest=createHash('sha256').update(await readFile(join(app,'spec/shop.lawspec'))).digest('hex');
recording.lawDigest=lawDigest;

async function command(program,args,options={}) {
  const result=await exec(program,args,{cwd:scratch,maxBuffer:16*1024*1024,env:process.env,...options});
  return result.stdout;
}
async function iron(args,options={}) { return command(process.execPath,[cli,'-a',architecture,...args],options); }
async function json(path) { return JSON.parse(await readFile(path,'utf8')); }
async function save(path,value) { await writeFile(path,JSON.stringify(value,null,2)+'\n'); }
async function port() {
  const server=createServer();
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
  const result=server.address().port;
  await new Promise(resolve=>server.close(resolve));
  return result;
}
const [kafka,http,kafkaAdmin,httpAdmin,intake,admin]=await Promise.all(Array.from({length:6},port));
const implementationCommit=(await command('git',['rev-parse','HEAD'],{cwd:root})).trim();
let decorations=await json(decorators);
for (const decoration of decorations) {
  if(decoration.type==='ironframe-environment') decoration.data.project=project;
  if(decoration.type==='ironframe-binding'&&decoration.data.application) decoration.data.application.implementation={commit:implementationCommit,version:'0.1.0'};
  const binding=decoration.data.twin??decoration.data.real;
  if(!binding)continue;
  if(decoration['applies-to'].includes('adoptions-log')) {
    binding.endpoint=`localhost:${kafka}`;
    if(decoration.data.twin) {
      binding.advertise_variable='LAWTWIN_ADVERTISE';
      binding.admin.port=kafkaAdmin;
    } else binding.env={...binding.env,
      KAFKA_NODE_ID:'1',KAFKA_PROCESS_ROLES:'broker,controller',
      KAFKA_LISTENERS:'PLAINTEXT://:9092,CONTROLLER://:9093',
      KAFKA_ADVERTISED_LISTENERS:`PLAINTEXT://localhost:${kafka}`,
      KAFKA_CONTROLLER_LISTENER_NAMES:'CONTROLLER',
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP:'CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT',
      KAFKA_CONTROLLER_QUORUM_VOTERS:'1@localhost:9093',
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR:'1',
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR:'1',
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR:'1',KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS:'0'};
  } else {
    const suffix=decoration.data.real?'/api/v3':'';
    binding.endpoint=`http://localhost:${http}${suffix}`;
    if(binding.admin)binding.admin.port=httpAdmin;
  }
}
await save(decorators,decorations);

const npmPackage=process.env.IRONFRAME_LAWSPEC_PACKAGE;
await command('npm',['install','--no-audit','--no-fund','--package-lock=false',...(npmPackage?[resolve(npmPackage)]:[])],{cwd:app});
const lawspec=join(app,'node_modules/lawspec/bin/lawspec.mjs');
process.env.IRONFRAME_LAWSPEC=lawspec;
await command(process.execPath,[lawspec,'generate'],{cwd:app});
await command('go',['mod','download'],{cwd:app});
const application=join(app,'shop-bin');
await command('go',['build','-o',application,'./cmd/shop'],{cwd:app});
await iron(['validate']);

// A runner inside `observe` reads this file's generated helper. Its telemetry
// comes from the application's four real dependency adapter operations.
const runner=join(scratch,'native-runner.mjs');
await writeFile(runner,`
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {writeFile,readFile} from 'node:fs/promises';
import {join} from 'node:path';
const exec=promisify(execFile), [cli,arch,app,lawspec,environment,output]=process.argv.slice(2);
if(process.env.OBSERVED_DROP==='1') {
 const fault=await fetch(process.env.IRONFRAME_OBSERVATION_ADMIN+'/v1/faults',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({dropRequests:1})});
 if(!fault.ok)throw new Error('receiver fault refused');
}
await exec(process.execPath,[cli,'-a',arch,'run','--env',environment,'--app','adoptions-service','--dir',app,'--attestation',output,'--','sh','-c','node "$OBSERVED_LAWSPEC" test --fresh --seed 7 --attestation "$IRONFRAME_ATTESTATION"'],{env:{...process.env,OBSERVED_LAWSPEC:lawspec},maxBuffer:16*1024*1024});
const evidence=await exec(process.execPath,[lawspec,'evidence','--json','--attestation',output],{cwd:app,maxBuffer:16*1024*1024});
await writeFile(output+'.laws.json',evidence.stdout);
const run=JSON.parse(await readFile(output,'utf8')).run.id;
const countsText=await readFile(join(process.env.IRONFRAME_OBSERVATION_DIR,'adoptions-service-'+run+'.counts.jsonl'),'utf8');
const rows=countsText.trim().split('\\n').map(line=>JSON.parse(line));
const checkpoint={producer:'adoptions-service',counts:{logs:rows.filter(row=>row.kind==='intended').length,spans:0},dropped:rows.filter(row=>row.kind==='dropped').length,flushed:true};
const response=await fetch(process.env.IRONFRAME_OBSERVATION_ADMIN+'/v1/checkpoint',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(checkpoint)});
if(!response.ok)throw new Error('checkpoint refused: '+await response.text());
`);

async function observe(environment,name,{drop=false}={}) {
  const configuration=join(scratch,name+'.configuration.json');
  await iron(['revision','prepare','--env',environment,'--output',configuration]);
  const folder=join(scratch,name+'-observations');
  const attestation=join(scratch,name+'-run.json');
  const invocation=['observe','--env',environment,'--revision',configuration,'--observer',resolve(observer),
    '--listen',`127.0.0.1:${intake}`,'--admin-listen',`127.0.0.1:${admin}`,'--output',folder,
    '--',process.execPath,runner,cli,architecture,app,lawspec,environment,attestation];
  if(drop)await assert.rejects(iron(invocation,{env:{...process.env,OBSERVED_DROP:'1'}}));
  else await iron(invocation);
  const bundle=await json(join(folder,'bundle.json'));
  assert.equal(bundle.status,drop?'incomplete':'complete');
  assert.equal(createHash('sha256').update(await readFile(join(app,'spec/shop.lawspec'))).digest('hex'),lawDigest);
  assert.ok(bundle.counts['adoptions-service'].logs>0);
  recording.runs.push({environment,name,revision:(await json(configuration)).revision,run:(await json(attestation)).run.id,logs:bundle.counts['adoptions-service'].logs});
  return {configuration,attestation,laws:attestation+'.laws.json',observations:join(folder,'bundle.json'),histories:attestation+'.histories.json'};
}

async function promote(candidate,fixture,previous='none') {
  const manifest=join(scratch,'promotion-'+randomUUID()+'.json');
  await save(manifest,{format:'ironframe-promotion-evidence',version:1,runs:[{role:'fixture',...fixture},{role:'provider',...candidate}]});
  await iron(['revision','check','--env','real','--revision',candidate.configuration,'--evidence',manifest]);
  let state=JSON.parse(await iron(['revision','activate','--env','real','--revision',candidate.configuration,'--evidence',manifest,'--expected',previous]));
  assert.equal(state.phase,'awaiting-adoption');
  await adopt(state);
  return state.desired;
}

async function adopt(state) {
  await iron(['revision','publish','--env','real','--app','adoptions-service','--expected',state.desired]);
  const configuration=await json(join(scratch,'architecture/.ironframe/real/revisions',state.desired.slice(7)+'.json'));
  const {createIronframe}=await import('../npm/api.mjs');
  const api=createIronframe();
  const response=await api.run('revision.binding',{configuration,state,node:'adoptions-service'});
  assert.ok(response.done && !response.done.error);
  const binding=response.done;
  const published=await api.run('dotenv.parse',{text:await readFile(join(app,'.env.adoptions-service'),'utf8')});
  assert.deepEqual(JSON.parse(published.done.IRONFRAME_CONFIGURATION_BUNDLE),binding);
  const loaded=await api.run('revision.bindingSettings',{binding});
  assert.equal(loaded.done.IRONFRAME_CONFIGURATION_REVISION,state.desired);
  // Previous test/application jobs have exited. Start fresh real clients from
  // the published bundle before acknowledging adoption, including after revert.
  const adoptionIndex=recording.adoptions?.length??0;
  const environment={...process.env,...loaded.done,IRONFRAME_OBSERVATION_CONFIG:'',SHOP_PET_ID_BASE:String(1000000+adoptionIndex*1000)};
  const adoptedOutput=await command(application,['rex','ada'],{cwd:app,env:environment});
  assert.match(adoptedOutput,/rex/);assert.match(adoptedOutput,/ada/);
  const audit=JSON.parse(await command(application,['audit'],{cwd:app,env:environment}));
  assert.ok(audit.adoptions>0);
  (recording.adoptions??=[]).push({revision:state.desired,transition:state.transition,application:JSON.parse(adoptedOutput),audit});
  const ack=join(scratch,'adopt-'+state.transition+'.json');
  await save(ack,{node:binding.node,implementation:binding.implementation,revision:binding.revision,transition:binding.transition,settingsDigest:binding.settingsDigest,drainedFrom:binding.previous,drained:true});
  const adopted=JSON.parse(await iron(['revision','adopt','--env','real','--expected',state.desired,'--ack',ack]));
  assert.equal(adopted.phase,'active');
  const served=await api.run('configService.handle',{settingsPath:join(scratch,'architecture/.ironframe/real/settings.json'),method:'GET',path:'/v1/environments/real/bindings/adoptions-service'});
  assert.equal(served.done.status,200);
  assert.equal(JSON.parse(served.done.body).revision,state.desired);
}

let live;
try {
  live='twin'; await iron(['up',live,'--no-sync']);
  const fixture=await observe(live,'fixture');
  const lost=await observe(live,'receiver-loss',{drop:true});
  recording.checks.push('receiver loss preserves diagnostics and produces incomplete collection');
  await iron(['down',live]);live=undefined;
  live='real'; await iron(['up',live,'--no-sync']);
  const first=await observe(live,'provider-first');
  const firstId=await promote(first,fixture);
  const rejected=join(scratch,'incomplete-promotion.json');
  await save(rejected,{format:'ironframe-promotion-evidence',version:1,runs:[{role:'fixture',...lost},{role:'provider',...first}]});
  await assert.rejects(iron(['revision','check','--env','real','--revision',first.configuration,'--evidence',rejected]));
  recording.checks.push('fixture and real native laws; completed observations; exact histories; publication and adoption');
  // Change one edge endpoint without changing application source or contracts.
  decorations=await json(decorators);
  for(const decoration of decorations)if(decoration.data.environment==='real'&&decoration.data.real&&decoration['applies-to'].includes('pet-registry'))decoration.data.real.endpoint=`http://127.0.0.1:${http}/api/v3`;
  await save(decorators,decorations);
  const second=await observe(live,'provider-second');
  const secondId=await promote(second,fixture,firstId);
  assert.notEqual(firstId,secondId);
  const reverted=JSON.parse(await iron(['revision','revert','--env','real','--expected',secondId]));
  assert.equal(reverted.desired,firstId);
  await adopt(reverted);
  await assert.rejects(iron(['revision','revert','--env','real','--expected',secondId]));
  recording.checks.push('changed edge needs fresh provider test; fixture evidence reuse; fresh real clients exercise each activated/reverted binding; stale selection refused');
  recording.status='passed';
} catch(error) {recording.status='failed';recording.error=error.stack??String(error);throw error;}
finally {
  if(live)try{await iron(['down',live]);}catch(error){recording.cleanupError=error.message;recording.status='failed';}
  await save(join(scratch,'acceptance.json'),recording);
  console.log('Observed binding acceptance:',join(scratch,'acceptance.json'));
  if(recording.status!=='passed')process.exitCode=1;
}
