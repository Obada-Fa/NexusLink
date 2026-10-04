import { existsSync, statSync, watch, type FSWatcher } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import type { AgentEvent, AgentSessionInfo, AgentImageAttachment } from '../../rpc-types/src/index';
import type { ChatSummary, ChatQuery, ChatSend, ChatDelivery, ChatHistoryEvent, ChatHistoryPage } from '../../rpc-types/src/chat';
import { identity, folderIdentity } from './identity';
import { workerPath } from './worker-path';
export { identity, folderIdentity } from './identity';

export const CHAT_METHODS = ['chat.list','chat.folders','chat.historyPage','chat.refresh','chat.subscribe','chat.send','chat.sendStatus'] as const;
const SOURCES = ['claude','cursor','codex','opencode','antigravity'];
export interface ChatGateway {
  sessions(): AgentSessionInfo[];
  history(id: string, params: { beforeSeq?: number; afterSeq?: number; limit: number }): Promise<{ events: AgentEvent[]; hasMore: boolean }>;
  send(id: string, text: string, options: Pick<ChatSend, 'images' | 'model' | 'thinking' | 'mode'>): { ok: boolean };
  flush(): Promise<void>;
  bin(source: string): string | null;
}
export interface ChatServiceOptions {
  directory: string;
  hostId: string;
  gateway: ChatGateway;
  notify(connection: object, revision: number): void;
  provider?: (source: string, op: string, nativeId?: string) => Promise<{ result: any[]; reason?: string }>;
  backgroundDiscovery?: boolean;
}
function validActivity(value: number | undefined) { return Number.isFinite(value) && value! > 0 ? value! : null; }
export function sessionSummary(hostId: string, session: AgentSessionInfo): ChatSummary {
  const folder = folderIdentity(session.cwd);
  const imported = session.imported === true;
  const interrupted = session.taskState === 'interrupted';
  const safety = session.busy ? 'busy' : imported || interrupted ? 'unknown' : 'ready';
  return {id:identity(hostId,session.agent,session.hostChatId || session.agentSessionId),hostId,source:session.agent,sourceName:sourceName(session.agent),nativeId:session.hostChatId,agentSessionId:session.agentSessionId,managed:!imported,title:session.title,preview:session.preview,folderId:folder.id,folderPath:folder.path,folderName:folder.name,activityAt:imported?null:validActivity(session.updatedAt) || validActivity(session.createdAt),archived:session.archived === true,execution:session.busy ? 'working' : session.taskState === 'waiting' ? 'needsReply' : imported || interrupted ? 'unknown' : 'idle',capabilities:{read:true,continue:safety === 'ready' && session.status === 'running',safety,reason:safety === 'busy' ? 'This chat is working on the PC.' : interrupted ? 'This chat was interrupted by a host restart. Check the original run on the PC, or start a new chat.' : imported ? 'Replying is unavailable until the source confirms this PC chat is safe to continue.' : undefined}};
}
function sourceName(source: string) { return ({claude:'Claude Code',cursor:'Cursor',codex:'Codex',opencode:'OpenCode',antigravity:'Antigravity',mock:'NexusLink'} as Record<string,string>)[source] || source; }

export class ChatService {
  private worker?: Worker;
  private nextId=0;
  private pending=new Map<number,{resolve:(value:any)=>void;reject:(error:Error)=>void}>();
  private connections=new Set<object>();
  private scans=new Map<string,Promise<void>>();
  private scanQueue: Array<() => void> = [];
  private activeScans=0;
  private timer?: ReturnType<typeof setInterval>;
  private watches: FSWatcher[]=[];
  private watchTimer?: ReturnType<typeof setTimeout>;
  private sendQueue=new Map<string,Promise<any>>();
  private historyLoads=new Map<string,Promise<any>>();
  revision=0;
  initialized=false;
  constructor(private options: ChatServiceOptions) {}
  async initialize() {
    this.worker=new Worker(workerPath('./worker.ts',import.meta.url,'packages/chat-core/src/worker.ts'));
    this.worker.onmessage=event=>{
      const request=this.pending.get(event.data.id); if (!request) return;
      this.pending.delete(event.data.id);
      event.data.error ? request.reject(new Error(event.data.error)) : request.resolve(event.data.result);
    };
    this.worker.onerror=event=>{ for(const request of this.pending.values()) request.reject(new Error(event.message)); this.pending.clear();this.worker?.terminate();this.worker=undefined;this.initialized=false; };
    this.revision=await this.call('init',{directory:this.options.directory});
    await this.syncSessions(); this.initialized=true;
    if (this.options.backgroundDiscovery !== false) this.refresh();
    return this;
  }
  private call(op:string,data:any={}):Promise<any> {
    if (!this.worker) return Promise.reject(new Error('Chat library is not initialized'));
    return new Promise((resolve,reject)=>{const id=++this.nextId;this.pending.set(id,{resolve,reject});this.worker!.postMessage({id,op,data});});
  }
  private notify(revision=this.revision) {
    this.revision=revision;
    for(const connection of this.connections) this.options.notify(connection,revision);
  }
  async syncSessions() {
    const previous=this.revision;
    this.revision=await this.call('upsert',{rows:this.options.gateway.sessions().map(session=>sessionSummary(this.options.hostId,session))});
    if (this.revision !== previous) this.notify();
  }
  subscribe(connection: object, enabled: boolean) {
    if(enabled) this.connections.add(connection); else this.connections.delete(connection);
    if(this.connections.size && !this.timer) {
      this.timer=setInterval(()=>{this.refresh();void this.syncSessions().catch(()=>{});},30000);
      this.watchSources(); this.refresh();
    } else if(!this.connections.size) {clearInterval(this.timer);this.timer=undefined;this.watches.forEach(w=>w.close());this.watches=[];}
    return {revision:this.revision};
  }
  private watchSources() {
    for(const dir of [process.env.CODEX_HOME || join(homedir(),'.codex'),join(homedir(),'.claude','projects'),join(homedir(),'.cursor'),join(homedir(),'.gemini')]) {
      if(!existsSync(dir)) continue;
      try {
        const watcher=watch(dir,{recursive:true},()=>{
          clearTimeout(this.watchTimer);
          this.watchTimer=setTimeout(()=>{this.refresh();},500);
        });
        watcher.on('error',()=>watcher.close());this.watches.push(watcher);
      } catch { /* Reconciliation is the fallback on unsupported filesystems. */ }
    }
  }
  refresh(source?: string) {
    if (process.env.NEXUSLINK_DISABLE_CHAT_DISCOVERY === '1' && !this.options.provider) return {ok:true,revision:this.revision};
    if(source && !SOURCES.includes(source)) throw new Error('Unknown source app');
    for(const name of source ? [source] : SOURCES) {
      if(this.scans.has(name)) continue;
      const scan=new Promise<void>(resolve=>{
        this.scanQueue.push(()=>{void this.scan(name).finally(()=>{this.activeScans--;this.scans.delete(name);resolve();this.pump();});});
      });
      this.scans.set(name,scan);
    }
    this.pump(); return {ok:true,revision:this.revision};
  }
  private pump() {while(this.activeScans<2 && this.scanQueue.length){this.activeScans++;this.scanQueue.shift()!();}}
  private async provider(source:string,op:string,nativeId?:string):Promise<{result:any[];reason?:string}> {
    if (this.options.provider) return this.options.provider(source,op,nativeId);
    const worker=new Worker(workerPath('./providers/worker.ts',import.meta.url,'packages/chat-core/src/providers/worker.ts'));
    return new Promise((resolve,reject)=>{
      const children=new Set<number>();let settled=false;
      const finish=(error?:Error,value?:any)=>{if(settled)return;settled=true;clearTimeout(timer);for(const pid of children){try{process.kill(pid);}catch{}}worker.terminate();error?reject(error):resolve(value);};
      const timer=setTimeout(()=>finish(new Error(`Couldn’t refresh ${sourceName(source)} within 15 seconds. Retry.`)),15000);
      worker.onmessage=event=>{if(typeof event.data.pid==='number'){children.add(event.data.pid);return;}event.data.error?finish(new Error(event.data.error)):finish(undefined,event.data);};
      worker.onerror=event=>finish(new Error(event.message));
      worker.postMessage({source,op,nativeId,bin:this.options.gateway.bin(source)});
    });
  }
  private async scan(source:string) {
    const start=Date.now();
    try {
      await this.call('health',{source,state:'scanning'});this.notify();
      const response=await this.provider(source,'scan');
      const rows:ChatSummary[]=response.result.filter(row=>typeof row.hostChatId === 'string').map(row=>{
        const folder=folderIdentity(row.cwd);
        return {id:identity(this.options.hostId,source,row.hostChatId),hostId:this.options.hostId,source,sourceName:row.source || sourceName(source),nativeId:row.hostChatId,title:row.title,preview:row.preview,folderId:folder.id,folderPath:folder.path,folderName:folder.name,activityAt:validActivity(row.updatedAt),archived:row.archived === true,execution:row.busy ? 'working' : 'unknown',capabilities:{read:true,continue:false,safety:row.busy?'busy':'unknown',reason:row.hostChatId.startsWith('ide:')?'Cursor IDE chats are read only. Start a new chat to use Cursor CLI.':'Replying is unavailable until this app confirms the original PC chat is safe to continue.'}};
      });
      // Legacy readers cannot distinguish a partial scan from disappearance.
      // Only authoritative app-server/export scans may remove missing records.
      this.revision=await this.call('upsert',{rows,source,removeMissing:!response.reason && ['codex','opencode'].includes(source)});
      await this.syncSessions();
      await this.call('health',{source,state:response.reason?'error':'ready',reason:response.reason,lastSuccessAt:Date.now(),durationMs:Date.now()-start});
    } catch(error) {
      await this.call('health',{source,state:'error',reason:error instanceof Error?error.message:'Couldn’t refresh this app. Retry.',durationMs:Date.now()-start});
    }
    this.notify();
  }
  async list(query:ChatQuery,folders=false) {await this.syncSessions();return this.call(folders?'folders':'list',query);}
  async historyPage(params:{chatId:string;olderCursor?:string;newerCursor?:string;limit?:number}):Promise<ChatHistoryPage> {
    const row:ChatSummary|undefined=await this.call('get',{id:params.chatId});
    if(!row) throw new Error('Chat no longer exists in the library');
    const limit=Math.min(100,Math.max(1,params.limit || 100));
    if(!Number.isInteger(limit) || (params.olderCursor && params.newerCursor)) throw new Error('Invalid history request');
    if(row.agentSessionId && row.managed === true) {
      const cursor=params.olderCursor || params.newerCursor;
      const seq=cursor ? Number(cursor) : undefined;
      if(cursor && (!Number.isSafeInteger(seq) || seq! < 0)) throw new Error('Invalid history cursor');
      const page=await this.options.gateway.history(row.agentSessionId,{limit,beforeSeq:params.olderCursor?seq:undefined,afterSeq:params.newerCursor?seq:undefined});
      const events=page.events.map(event=>({...event,id:identity(row.id,String(event.seq))}));
      return this.boundHistory(events,{appendOnly:true,olderCursor:page.hasMore&&!params.newerCursor?String(events[0]?.seq):null,newerCursor:events.length?String(events.at(-1)!.seq):null,revision:String(events.at(-1)?.seq || 0),completeness:'complete'});
    }
    if(!row.nativeId) return {events:[],olderCursor:null,newerCursor:null,revision:'0',completeness:'unavailable',reason:'This conversation has no saved messages.'};
    const fingerprint=row.activityAt == null ? `unknown:${Math.floor(Date.now()/30000)}` : String(row.activityAt);
    const savedFingerprint=await this.call('historyFingerprint',{chat:row.id});
    if(savedFingerprint !== fingerprint) {
      let load=this.historyLoads.get(row.id);
      if(!load) {
        load=this.provider(row.source,'history',row.nativeId).then(response=>{
          if(response.reason && response.result.length===0)throw new Error(response.reason);
          return this.call('indexHistory',{chat:row.id,fingerprint,events:response.result,reason:response.reason});
        }).finally(()=>this.historyLoads.delete(row.id));
        this.historyLoads.set(row.id,load);
      }
      try {await load;} catch(error) {return {events:[],olderCursor:null,newerCursor:null,revision:'0',completeness:'unavailable',reason:error instanceof Error?error.message:'This app’s history could not be read.'};}
    }
    return this.call('historyPage',{chat:row.id,params});
  }
  private boundHistory(events:ChatHistoryEvent[],info:Omit<ChatHistoryPage,'events'>):ChatHistoryPage {
    let bytes=0; const bounded:ChatHistoryEvent[]=[];
    // Trim individual oversized fields, preserving every event cursor.
    for(const original of events) {
      const event={...original};
      for(const key of ['text','toolInput','toolOutput'] as const) if(event[key] && Buffer.byteLength(event[key]!)>65536) {event[key]=Buffer.from(event[key]!).subarray(0,65536).toString('utf8');event.truncated=true;}
      const size=Buffer.byteLength(JSON.stringify(event));
      if(bytes+size>500*1024) {
        event.text='Content omitted because this history page exceeds its size limit.';delete event.toolInput;delete event.toolOutput;event.truncated=true;
      }
      bytes+=Buffer.byteLength(JSON.stringify(event));bounded.push(event);
    }
    return {...info,events:bounded,completeness:bounded.some(e=>e.truncated)?'partial':info.completeness};
  }
  async send(device:string,params:ChatSend):Promise<ChatDelivery> {
    if(typeof params.chatId!=='string' || typeof params.text!=='string' || !params.text.trim() || params.text.length>100000 || typeof params.operationId!=='string' || !params.operationId || params.operationId.length>200) throw new Error('Invalid chat message');
    const previous=this.sendQueue.get(params.chatId) || Promise.resolve();
    const action=previous.catch(()=>{}).then(async()=>{
      const claimed=await this.call('claim',{device,operationId:params.operationId,args:JSON.stringify(params)});
      if(!claimed.fresh)return claimed;
      let dispatched=false;
      try {
        await this.syncSessions();
        const row:ChatSummary|undefined=await this.call('get',{id:params.chatId});
        if(!row || !row.agentSessionId || !row.capabilities.continue || row.capabilities.safety!=='ready') throw new Error(row?.capabilities.reason || 'This chat is read only. Start a new chat to reply.');
        if(row.source !== 'mock' && !this.options.gateway.bin(row.source)) throw new Error(`${row.sourceName} is unavailable. Install or sign in to this app on the PC.`);
        if(params.expectedRevision!==undefined && params.expectedRevision!==this.revision) throw new Error('Chat changed. Refresh it before replying.');
        if(!row.folderPath || !existsSync(row.folderPath) || !statSync(row.folderPath).isDirectory()) throw new Error('The recorded folder is unavailable. Choose a folder before replying.');
        if(params.requiredFolder && folderIdentity(params.requiredFolder).id!==row.folderId) throw new Error('The reply folder differs from the recorded chat folder.');
        await this.call('finish',{device,body:{operationId:params.operationId,state:'dispatching',agentSessionId:row.agentSessionId}});
        dispatched=true;
        if(!this.options.gateway.send(row.agentSessionId,params.text,{images:params.images,model:params.model,thinking:params.thinking,mode:params.mode}).ok) throw new Error('Provider did not confirm dispatch');
        await this.options.gateway.flush();
        const delivery=await this.call('finish',{device,body:{operationId:params.operationId,state:'delivered',agentSessionId:row.agentSessionId}});
        await this.syncSessions(); return delivery;
      } catch(error) {return this.call('finish',{device,body:{operationId:params.operationId,state:dispatched?'uncertain':'rejected',reason:error instanceof Error?error.message:'Reply could not be sent'}});}
    });
    this.sendQueue.set(params.chatId,action);
    try{return await action;}finally{if(this.sendQueue.get(params.chatId)===action)this.sendQueue.delete(params.chatId);}
  }
  async request(method:string,params:any,connection:object,device:string):Promise<any> {
    if(!params || typeof params!=='object' || Array.isArray(params))throw new Error('Invalid chat request');
    for(const key of ['query','source','cursor','chatId','olderCursor','newerCursor','operationId']) if(params[key]!==undefined && typeof params[key]!=='string')throw new Error(`Invalid ${key}`);
    switch(method) {
      case 'chat.list': return this.list(params);
      case 'chat.folders': return this.list(params,true);
      case 'chat.historyPage': await this.syncSessions();return {...await this.historyPage(params),chat:await this.call('get',{id:params.chatId})};
      case 'chat.refresh': return this.refresh(params.source);
      case 'chat.subscribe': if(typeof params.enabled!=='boolean')throw new Error('Invalid subscription');return this.subscribe(connection,params.enabled);
      case 'chat.send': return this.send(device,params);
      case 'chat.sendStatus': return this.call('status',{device,operationId:params.operationId});
      default: throw new Error('Unknown chat method');
    }
  }
  async close() {
    this.initialized=false;clearInterval(this.timer);clearTimeout(this.watchTimer);this.watches.forEach(w=>w.close());
    await Promise.all(this.scans.values());await Promise.allSettled(this.sendQueue.values());
    await this.call('close');this.worker?.terminate();this.worker=undefined;
  }
}
