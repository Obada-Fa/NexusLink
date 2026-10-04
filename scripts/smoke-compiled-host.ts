import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const executable=resolve(process.argv[2] || 'dist/windows/nexuslink-host.exe');
const directory=mkdtempSync(join(tmpdir(),'nexuslink-compiled-smoke-'));
const child=Bun.spawn([executable],{cwd:directory,stdout:'pipe',stderr:'pipe',env:{...process.env,NEXUSLINK_WORKER_DIAGNOSTICS:'1',NEXUSLINK_DATA_DIR:join(directory,'store'),NEXUSLINK_LEGACY_AGENT_STORE:join(directory,'absent.json'),NEXUSLINK_NO_TRAY:'1',NEXUSLINK_NO_FIREWALL:'1',NEXUSLINK_DISABLE_PUSH:'1',NEXUSLINK_DISABLE_CHAT_DISCOVERY:'1',NEXUSLINK_DEV:'1',NEXUSLINK_HOST:'127.0.0.1'}});
let output='';let errors='';let socket:WebSocket|undefined;
const read=async(stream:ReadableStream<Uint8Array>,write:(text:string)=>void)=>{for await(const bytes of stream)write(new TextDecoder().decode(bytes));};
const stdout=read(child.stdout,text=>output+=text),stderr=read(child.stderr,text=>errors+=text);
try {
  const deadline=Date.now()+15000;
  while(!output.includes('[windows-host] listening') && Date.now()<deadline && child.exitCode===null)await Bun.sleep(100);
  if(!output.includes('[windows-host] listening'))throw new Error(`Compiled host failed to start: ${errors}`);
  socket=new WebSocket('ws://127.0.0.1:45678/rpc');
  await new Promise<void>((resolve,reject)=>{socket!.onopen=()=>resolve();socket!.onerror=()=>reject(new Error('Compiled host socket failed'));});
  let id=0;const pending=new Map<number,(response:any)=>void>();
  socket.onmessage=event=>{const message=JSON.parse(String(event.data));if(message.type==='rpc-response'){pending.get(Number(message.response.id))?.(message.response);pending.delete(Number(message.response.id));}};
  const call=(method:string,params={})=>Promise.race([new Promise<any>(resolve=>{const seq=++id;pending.set(seq,resolve);socket!.send(JSON.stringify({type:'rpc-request',request:{id:seq,method,params}}));}),Bun.sleep(5000).then(()=>{throw new Error(`Compiled host ${method} timed out`);})]);
  const capabilities=await call('session.getCapabilities');
  if(!capabilities.result?.features.includes('chat.library.v1'))throw new Error('Compiled library capability missing');
  const page=await call('chat.list');
  if(!Array.isArray(page.result?.items))throw new Error(`Compiled SQLite library failed: ${page.error}`);
  console.log('Compiled Windows host starts outside source tree; embedded SQLite workers and chat.list pass.');
} finally {
  socket?.close();child.kill();await child.exited;await Promise.all([stdout,stderr]);rmSync(directory,{recursive:true,force:true});
}
