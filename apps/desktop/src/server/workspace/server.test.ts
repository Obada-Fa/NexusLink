import {afterAll,expect,test} from 'bun:test';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {enableEnrollment,revokeDevice} from './security';
import {startRpcServer} from '../index';
const directory=await mkdtemp(join(tmpdir(),'nexuslink-rpc-test-'));
const stop=await startRpcServer(0,'127.0.0.1');
afterAll(async()=>{await stop.stop();await rm(directory,{recursive:true,force:true});});
function client(){
  return new Promise<{ws:WebSocket;call:(method:string,params?:Record<string,unknown>)=>Promise<any>}>(resolve=>{
    const ws=new WebSocket(`ws://127.0.0.1:${stop.port}/rpc`);
    let id=0;const pending=new Map<number,(value:any)=>void>();
    ws.onmessage=event=>{const body=JSON.parse(event.data as string);if(body.type==='rpc-response'){pending.get(Number(body.response.id))?.(body.response);pending.delete(Number(body.response.id));}};
    ws.onopen=()=>resolve({ws,call:(method,params={})=>new Promise(done=>{const seq=++id;pending.set(seq,done);ws.send(JSON.stringify({type:'rpc-request',request:{id:seq,method,params}}));})});
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
