import { dataDirectory } from './security';
let worker: Worker | undefined;
let nextId=0;
const pending=new Map<number,{resolve:(v:any)=>void,reject:(e:Error)=>void}>();
let rows:any[]=[];
let initialization:Promise<any> | undefined;
export function initializeAgentStore() {
  if(initialization) return initialization;
  worker=new Worker(new URL('./agent-store-worker.ts',import.meta.url).href);
  worker.onmessage=event=>{const p=pending.get(event.data.id); if(!p)return; pending.delete(event.data.id); event.data.error?p.reject(new Error(event.data.error)):p.resolve(event.data.result);};
  worker.onerror=event=>{for(const p of pending.values())p.reject(new Error(event.message));pending.clear();};
  initialization=call('init',{directory:dataDirectory(),legacy:process.env.NEXUSLINK_LEGACY_AGENT_STORE}).then(value=>rows=value);
  return initialization;
}
function call(op:string,data:any):Promise<any> {
  if(!worker) return Promise.resolve(op==='history'?{events:[],hasMore:false}:null);
  return new Promise((resolve,reject)=>{const id=++nextId;pending.set(id,{resolve,reject});worker!.postMessage({id,op,data});});
}
export function loadedAgentRows() { return rows; }
let queue:Array<{data:any,resolve:()=>void,reject:(e:Error)=>void}>=[];
let timer:ReturnType<typeof setTimeout> | undefined;
let tail=Promise.resolve();
export function persistAgent(data:any):Promise<void> {
  if(!worker) return Promise.resolve();
  return new Promise((resolve,reject)=>{queue.push({data,resolve,reject});if(queue.length>=128)void flushAgents().catch(()=>{});else timer??=setTimeout(()=>void flushAgents().catch(()=>{}),50);});
}
export function flushAgents():Promise<void> {
  clearTimeout(timer);timer=undefined;
  if(!queue.length)return tail;
  const batch=queue;queue=[];
  tail=tail.catch(()=>{}).then(async()=>{try {await call('batch',batch.map(e=>e.data));batch.forEach(e=>e.resolve());}catch(e){batch.forEach(row=>row.reject(e as Error));throw e;}});
  return tail;
}
export async function storedHistory(task:string,options:any={}) { await flushAgents(); return call('history',{task,...options}); }
export async function storedActivity(cursor:number) { await flushAgents(); return call('activity',{cursor}); }
export async function closeAgentStore() { await flushAgents();worker?.terminate();worker=undefined;initialization=undefined;rows=[]; }
