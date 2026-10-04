import {afterAll,expect,test} from 'bun:test';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {enableEnrollment,revokeDevice} from './security';
import {startRpcServer} from '../index';
import {persistAgent,flushAgents,storedActivityV2} from './agent-store';
const directory=await mkdtemp(join(tmpdir(),'nexuslink-rpc-test-'));
const previousDataDirectory=process.env.NEXUSLINK_DATA_DIR;
process.env.NEXUSLINK_DATA_DIR=directory;
const stop=await startRpcServer(40000+Math.floor(Math.random()*20000),'127.0.0.1');
afterAll(async()=>{await stop.stop();await rm(directory,{recursive:true,force:true});if(previousDataDirectory===undefined)delete process.env.NEXUSLINK_DATA_DIR;else process.env.NEXUSLINK_DATA_DIR=previousDataDirectory;});
function client(){
  return new Promise<{ws:WebSocket;events:any[];call:(method:string,params?:Record<string,unknown>)=>Promise<any>}>(resolve=>{
    const ws=new WebSocket(`ws://127.0.0.1:${stop.port}/rpc`);
    let id=0;const pending=new Map<number,(value:any)=>void>();const events:any[]=[];
    ws.onmessage=event=>{const body=JSON.parse(event.data as string);if(body.type==='rpc-response'){pending.get(Number(body.response.id))?.(body.response);pending.delete(Number(body.response.id));}else events.push(body);};
    ws.onopen=()=>resolve({ws,events,call:(method,params={})=>new Promise(done=>{const seq=++id;pending.set(seq,done);ws.send(JSON.stringify({type:'rpc-request',request:{id:seq,method,params}}));})});
  });
}
test('real dispatcher rejects unauthenticated RPC and HTTP, then revocation invalidates both',async()=>{
  const {ws,call}=await client();
  const path=join(directory,'download.txt');await writeFile(path,'private bytes');
  const url=new URL(`http://127.0.0.1:${stop.port}/files`);url.searchParams.set('path',path);
  try {
    expect((await call('session.heartbeat')).code).toBe('UNAUTHENTICATED');
    expect((await fetch(url)).status).toBe(401);
    const code=enableEnrollment();
    expect((await call('session.enroll',{code:'00000000',name:'bad'})).code).toBe('UNAUTHENTICATED');
    const auth=(await call('session.enroll',{code,name:'test phone'})).result;
    expect(auth.credential).toBeString();
    const capabilities=(await call('session.getCapabilities')).result;
    expect(capabilities.protocolVersion).toBe(2);expect(capabilities.methods).toContain('terminal.attach');
    const transfer=(await call('transfer.authorize',{path})).result;
    const headers={Authorization:`Bearer ${transfer.token}`};
    expect(await (await fetch(url,{headers})).text()).toBe('private bytes');
    expect((await fetch(url,{method:'POST',headers,body:'bad'})).status).toBe(401);
    revokeDevice(auth.deviceId);
    expect((await call('session.heartbeat')).code).toBe('UNAUTHENTICATED');
    expect((await fetch(url,{headers})).status).toBe(401);
  } finally {ws.close();}
},20000);

test('revoked attachment receives no further terminal output and shell survives',async()=>{
  const first=await client();const second=await client();
  try {
    const firstAuth=(await first.call('session.enroll',{code:enableEnrollment(),name:'revoked phone'})).result;
    await second.call('session.enroll',{code:enableEnrollment(),name:'other phone'});
    const created=(await first.call('terminal.create',{cols:80,rows:24,detached:true,operationId:crypto.randomUUID()})).result;
    expect(created.terminalId).toBeString();
    await first.call('terminal.attach',{terminalId:created.terminalId,afterSeq:0});
    first.events.length=0;
    revokeDevice(firstAuth.deviceId);
    await second.call('terminal.input',{terminalId:created.terminalId,data:'printf revoked_output_check\\n\n'});
    await Bun.sleep(150);
    expect(first.events.filter(e=>e.type==='terminal-output')).toHaveLength(0);
    expect((await second.call('terminal.list')).result.some((s:any)=>s.terminalId===created.terminalId)).toBe(true);
    await second.call('terminal.kill',{terminalId:created.terminalId});
  } finally {first.ws.close();second.ws.close();}
},20000);

test('activity v2 replays committed records and deduplicates monitor replies',async()=>{
  const control=await client();const monitor=await client();
  let task:string|undefined;
  try {
    const auth=(await control.call('session.enroll',{code:enableEnrollment(),name:'activity phone'})).result;
    await monitor.call('session.resume',{credential:auth.credential,role:'monitor'});
    expect((await monitor.call('session.getCapabilities')).result.features).toContain('activity.v2');
    await monitor.call('session.subscribe',{topics:['activity']});
    const created=(await control.call('agent.createSession',{agent:'mock',cwd:directory,title:'Activity test'})).result;
    task=created.agentSessionId;
    expect(task).toBeString();
    const prompt=(await control.call('agent.prompt',{agentSessionId:task,text:'hello'})).result;
    expect(prompt.ok).toBe(true);
    await Bun.sleep(650);
    const snapshot=(await monitor.call('activity.snapshotV2',{cursor:0})).result;
    expect(snapshot.throughCursor).toBeGreaterThan(0);
    expect(snapshot.events.length).toBeGreaterThan(0);
    expect(snapshot.nextCursor).toBe(snapshot.events.at(-1).cursor);
    expect(monitor.events.some(e=>e.type==='activity-update')).toBe(true);
    const approval=snapshot.events.find((e:any)=>e.agentSessionId===task && e.kind==='approval-requested');
    expect(approval).toBeDefined();
    expect(approval.availableActions).toContain('approve');
    const decision={operationId:crypto.randomUUID(),hostId:approval.hostId,agentSessionId:task,expectedTurnId:approval.turnId,sourceCursor:approval.cursor,action:'approve',requestId:approval.requestId};
    expect((await monitor.call('activity.action',decision)).result.state).toBe('succeeded');
    expect((await monitor.call('activity.action',decision)).result.state).toBe('succeeded');
    const competing=(await monitor.call('activity.action',{...decision,operationId:crypto.randomUUID(),action:'deny'})).result;
    expect(competing.state).toBe('rejected');
    const completed=(await monitor.call('activity.snapshotV2',{cursor:snapshot.nextCursor})).result;
    const completion=completed.events.find((e:any)=>e.agentSessionId===task && e.kind==='completed');
    expect(completion).toBeDefined();
    const action={operationId:crypto.randomUUID(),hostId:completion.hostId,agentSessionId:task,expectedTurnId:completion.turnId,sourceCursor:completion.cursor,action:'reply',text:'follow up'};
    const first=(await monitor.call('activity.action',action)).result;
    const second=(await monitor.call('activity.action',action)).result;
    expect(first.state).toBe('succeeded');expect(second.state).toBe('succeeded');
    expect((await monitor.call('activity.actionStatus',{operationId:action.operationId})).result.state).toBe('succeeded');
    expect((await control.call('agent.history',{agentSessionId:task})).result.filter((e:any)=>e.kind==='user' && e.text==='follow up')).toHaveLength(1);
    const stale=(await monitor.call('activity.action',{...action,operationId:crypto.randomUUID()})).result;
    expect(stale.state).toBe('rejected');
  } finally {
    if(task)await control.call('agent.close',{agentSessionId:task});
    control.ws.close();monitor.ws.close();
  }
},20000);

test('activity pages stop at a fixed watermark and signal retention gaps',async()=>{
  const task=crypto.randomUUID();
  const info={agentSessionId:task,agent:'mock',cwd:directory,title:'Replay pages',createdAt:Date.now(),updatedAt:Date.now(),busy:false,status:'running',taskState:'completed',turnId:'turn-replay'};
  const events=Array.from({length:10005},(_,i)=>({seq:i+1,ts:Date.now(),kind:'result',turnId:'turn-replay',text:`result ${i+1}`}));
  await persistAgent({info,events});await flushAgents();
  const first=await storedActivityV2(0);
  expect(first.replayGap).toBe(true);
  expect(first.events).toHaveLength(200);
  expect(first.nextCursor).toBe(first.events.at(-1).cursor);
  expect(first.hasMore).toBe(true);
  const watermark=first.throughCursor;
  await persistAgent({info,events:[{seq:10006,ts:Date.now(),kind:'result',turnId:'turn-replay',text:'later'}]});await flushAgents();
  const next=await storedActivityV2(first.nextCursor,watermark);
  expect(next.throughCursor).toBe(watermark);
  expect(next.events[0].cursor).toBe(first.nextCursor+1);
  expect(next.events.every((e:any)=>e.cursor<=watermark)).toBe(true);
},20000);
