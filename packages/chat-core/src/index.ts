import { existsSync, statSync, watch, type FSWatcher } from 'node:fs';
import type { AgentEvent, AgentSessionInfo } from '../../rpc-types/src/index';
import type { ChatSummary, ChatLive, ChatQuery, ChatSend, ChatDelivery, ChatHistoryEvent, ChatHistoryPage, ContinuationSafety } from '../../rpc-types/src/chat';
import { identity, folderIdentity } from './identity';
import { workerPath } from './worker-path';
import { defaultRoots, watchSpecs, type ProviderRoots } from './paths';
import { LIVE, executionFor } from './providers/live';
export { identity, folderIdentity } from './identity';
export type { ProviderRoots } from './paths';

export const CHAT_METHODS = ['chat.list','chat.folders','chat.historyPage','chat.refresh','chat.subscribe','chat.send','chat.sendStatus','chat.cancel','chat.setState'] as const;
const SOURCES = ['claude','cursor','codex','opencode','antigravity'];
export interface ChatGateway {
  sessions(): AgentSessionInfo[];
  history(id: string, params: { beforeSeq?: number; afterSeq?: number; limit: number }): Promise<{ events: AgentEvent[]; hasMore: boolean }>;
  send(id: string, text: string, options: Pick<ChatSend, 'images' | 'model' | 'thinking' | 'mode'>): { ok: boolean; reason?: string };
  flush(): Promise<void>;
  bin(source: string): string | null;
  /** Attach a NexusLink session to a native chat. `history` seeds it without a synchronous transcript parse. */
  openHostChat?(params: { agent: string; hostChatId: string; cwd?: string; title?: string; history?: Array<Omit<AgentEvent, 'seq'>>; updatedAt?: number }): AgentSessionInfo;
  cancel?(id: string): { ok: boolean };
  /** Step/todos of a turn NexusLink is driving right now. */
  live?(agentSessionId: string): ChatLive | undefined;
}
export interface ProviderResponse { result: any[]; reason?: string; fingerprint?: string; unchanged?: boolean; complete?: boolean }
export interface ChatServiceOptions {
  directory: string;
  hostId: string;
  gateway: ChatGateway;
  notify(connection: object, revision: number): void;
  provider?: (source: string, op: string, nativeId?: string, extra?: Record<string, unknown>) => Promise<ProviderResponse>;
  backgroundDiscovery?: boolean;
  /** Where native chats live (tests point this at fixtures). */
  roots?: Partial<ProviderRoots>;
  /** Hot-chat live poll interval while a phone is subscribed. */
  pollMs?: number;
  /** Coalescing window for bursts of file-watch events. */
  watchDebounceMs?: number;
  /** Minimum gap between two library notifications to the phones. */
  notifyMs?: number;
}
function validActivity(value: number | undefined) { return Number.isFinite(value) && value! > 0 ? value! : null; }
function sessionLive(session: AgentSessionInfo, live?: ChatLive): ChatLive {
  const state: ChatLive['state'] = session.taskState === 'waiting' ? 'waiting' : session.busy ? 'working' : session.taskState === 'failed' ? 'failed' : session.taskState === 'completed' ? 'done' : 'idle';
  const base: ChatLive = { state, updatedAt: session.updatedAt, via: 'nexuslink' };
  if (session.activity) base.activity = session.activity;
  return { ...base, ...(live || {}), state, via: 'nexuslink' };
}
export function sessionSummary(hostId: string, session: AgentSessionInfo, live?: ChatLive): ChatSummary {
  const folder = folderIdentity(session.cwd);
  const imported = session.imported === true;
  const interrupted = session.taskState === 'interrupted';
  const safety = session.busy ? 'busy' : interrupted ? 'unknown' : 'ready';
  return {id:identity(hostId,session.agent,session.hostChatId || session.agentSessionId),hostId,source:session.agent,sourceName:sourceName(session.agent),nativeId:session.hostChatId,agentSessionId:session.agentSessionId,managed:!imported,title:session.title,preview:session.preview,folderId:folder.id,folderPath:folder.path,folderName:folder.name,activityAt:validActivity(session.updatedAt) || validActivity(session.createdAt),archived:session.archived === true,taskState:session.taskState,activity:session.activity,execution:session.taskState === 'waiting' ? 'needsReply' : session.busy ? 'working' : interrupted ? 'unknown' : 'idle',capabilities:{read:true,continue:safety === 'ready' && session.status === 'running',safety,reason:safety === 'busy' ? 'This chat is working on the PC.' : interrupted ? 'This chat was interrupted by a host restart. Check the original run on the PC, or start a new chat.' : undefined},live:sessionLive(session,live)};
}
function sourceName(source: string) { return ({claude:'Claude Code',cursor:'Cursor',codex:'Codex',opencode:'OpenCode',antigravity:'Antigravity',mock:'NexusLink'} as Record<string,string>)[source] || source; }

/** Discovery row (from the provider worker) → library row. */
export function scanSummary(hostId: string, source: string, row: any): ChatSummary {
  const folder=folderIdentity(row.cwd);
  const isIde=String(row.hostChatId).startsWith('ide:');
  const canContinue=!isIde && row.resumable !== false;
  const live:ChatLive|undefined=row.live;
  // A chat that another app is running (or blocked on an approval prompt there) must not be driven concurrently.
  const nativeBusy=live?.state === 'working' || (live?.state === 'waiting' && live.via !== 'claude-desktop');
  const safety:ContinuationSafety=nativeBusy ? 'busy' : canContinue ? 'ready' : 'unknown';
  const name=row.source || sourceName(source);
  const summary:ChatSummary={id:identity(hostId,source,row.hostChatId),hostId,source,sourceName:name,nativeId:row.hostChatId,title:row.title,preview:row.preview,folderId:folder.id,folderPath:folder.path,folderName:folder.name,activityAt:validActivity(row.updatedAt),archived:row.archived === true,execution:live ? executionFor(live) : 'idle',capabilities:{read:true,continue:canContinue,safety,reason:row.readOnlyReason || (isIde ? 'Cursor IDE chats are read only. Start a new chat to use Cursor CLI.' : nativeBusy ? `This chat is ${live?.state === 'waiting' ? 'waiting for you' : 'working'} in ${name} on the PC.` : undefined)}};
  if(live) summary.live=live;
  if(live?.activity) summary.activity=live.activity;
  if(live?.state === 'failed') summary.taskState='failed';
  if(row.parentHostChatId) summary.parentId=identity(hostId,source,row.parentHostChatId);
  if(summary.preview === undefined) delete summary.preview;
  return summary;
}

export class ChatService {
  private worker?: Worker;
  private nextId=0;
  private pending=new Map<number,{resolve:(value:any)=>void;reject:(error:Error)=>void}>();
  private providerWorker?: Worker;
  private providerNext=0;
  private providerPending=new Map<number,{resolve:(value:any)=>void;reject:(error:Error)=>void;timer:ReturnType<typeof setTimeout>}>();
  private connections=new Set<object>();
  private scans=new Map<string,Promise<void>>();
  private rescans=new Set<string>();
  private scanQueue: Array<() => void> = [];
  private activeScans=0;
  private timer?: ReturnType<typeof setInterval>;
  private pollTimer?: ReturnType<typeof setInterval>;
  private polling=false;
  private watches: FSWatcher[]=[];
  private watchTimer?: ReturnType<typeof setTimeout>;
  private dirty=new Set<string>();
  private notifyTimer?: ReturnType<typeof setTimeout>;
  private lastNotify=0;
  private closed=false;
  private sendQueue=new Map<string,Promise<any>>();
  private historyLoads=new Map<string,Promise<any>>();
  revision=0;
  initialized=false;
  /** Counters for diagnostics and tests. */
  readonly stats={scans:{} as Record<string,number>,scanMs:{} as Record<string,number>,polls:0,pollMs:0,watchEvents:0};
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
  /** Tell subscribed phones the library changed, at most once per `notifyMs`. */
  private notify() {
    const gap=(this.options.notifyMs ?? 1000)-(Date.now()-this.lastNotify);
    if(gap<=0) { this.lastNotify=Date.now(); this.emit(); return; }
    this.notifyTimer ??= setTimeout(()=>{this.notifyTimer=undefined;this.lastNotify=Date.now();this.emit();},gap);
  }
  private emit() { if(!this.closed) for(const connection of this.connections) this.options.notify(connection,this.revision); }
  private discovery() { return !(process.env.NEXUSLINK_DISABLE_CHAT_DISCOVERY === '1' && !this.options.provider); }
  async syncSessions() {
    const rows=this.options.gateway.sessions().map(session=>sessionSummary(this.options.hostId,session,this.options.gateway.live?.(session.agentSessionId)));
    const revision=await this.call('upsert',{rows});
    if (revision !== this.revision) { this.revision=revision; this.notify(); }
  }
  subscribe(connection: object, enabled: boolean) {
    if(enabled) this.connections.add(connection); else this.connections.delete(connection);
    if(this.connections.size && !this.timer) {
      this.timer=setInterval(()=>{this.refresh();void this.syncSessions().catch(()=>{});},30000);
      if(this.discovery()) { this.watchSources(); this.pollTimer=setInterval(()=>void this.poll(),this.options.pollMs ?? 2000); }
      this.refresh();
    } else if(!this.connections.size && this.timer) this.stopWatching();
    return {revision:this.revision};
  }
  private stopWatching() {
    clearInterval(this.timer);this.timer=undefined;clearInterval(this.pollTimer);this.pollTimer=undefined;
    clearTimeout(this.watchTimer);this.watchTimer=undefined;this.dirty.clear();
    this.watches.forEach(w=>w.close());this.watches=[];
  }
  /**
   * Watch only native transcript locations, and refresh only the source that
   * changed. Nothing this service runs writes into these paths, so a scan can
   * never trigger another scan.
   */
  private watchSources() {
    for(const spec of watchSpecs({...defaultRoots(),...this.options.roots})) {
      if(!existsSync(spec.dir)) continue;
      try {
        const watcher=watch(spec.dir,{recursive:spec.recursive},(_event,filename)=>{
          const name=filename == null ? '' : String(filename);
          if(name && !spec.match(name)) return;
          this.stats.watchEvents++;
          this.dirty.add(spec.source);
          this.watchTimer ??= setTimeout(()=>{
            this.watchTimer=undefined;
            const sources=[...this.dirty];this.dirty.clear();
            for(const source of sources) this.refresh(source);
          },this.options.watchDebounceMs ?? 750);
        });
        watcher.on('error',()=>watcher.close());this.watches.push(watcher);
      } catch { /* Reconciliation is the fallback on unsupported filesystems. */ }
    }
  }
  refresh(source?: string) {
    if (!this.discovery() || this.closed) return {ok:true,revision:this.revision};
    if(source && !SOURCES.includes(source)) throw new Error('Unknown source app');
    for(const name of source ? [source] : SOURCES) {
      // A change during a running scan is picked up by exactly one follow-up scan.
      if(this.scans.has(name)) { this.rescans.add(name); continue; }
      const scan=new Promise<void>(resolve=>{
        this.scanQueue.push(()=>{void this.scan(name).finally(()=>{
          this.activeScans--;this.scans.delete(name);resolve();
          if(this.rescans.delete(name) && !this.closed) this.refresh(name);
          this.pump();
        });});
      });
      this.scans.set(name,scan);
    }
    this.pump(); return {ok:true,revision:this.revision};
  }
  private pump() {while(this.activeScans<2 && this.scanQueue.length){this.activeScans++;this.scanQueue.shift()!();}}
  private ensureProviderWorker() {
    if (this.providerWorker) return this.providerWorker;
    const worker=new Worker(workerPath('./providers/worker.ts',import.meta.url,'packages/chat-core/src/providers/worker.ts'));
    worker.onmessage=event=>{
      const request=this.providerPending.get(event.data?.id); if(!request) return;
      this.providerPending.delete(event.data.id);clearTimeout(request.timer);
      event.data.error ? request.reject(new Error(event.data.error)) : request.resolve(event.data);
    };
    worker.onerror=event=>{this.dropProviderWorker(new Error(event.message || 'Chat discovery stopped unexpectedly. Retry.'));};
    worker.postMessage({id:0,op:'init',roots:this.options.roots,cursorBin:!!this.options.gateway.bin('cursor')});
    return this.providerWorker=worker;
  }
  /** Only after a hang or crash: the single worker is replaced, never one per request. */
  private dropProviderWorker(error: Error) {
    const worker=this.providerWorker;this.providerWorker=undefined;
    for(const request of this.providerPending.values()){clearTimeout(request.timer);request.reject(error);}
    this.providerPending.clear();
    try{worker?.terminate();}catch{ /* already gone */ }
  }
  private provider(source:string,op:string,nativeId?:string,extra:Record<string,unknown>={}):Promise<ProviderResponse> {
    if (this.options.provider) return this.options.provider(source,op,nativeId,extra);
    const worker=this.ensureProviderWorker();
    return new Promise((resolve,reject)=>{
      const id=++this.providerNext;
      const timer=setTimeout(()=>{this.dropProviderWorker(new Error(`Couldn’t read ${sourceName(source)} within 20 seconds. Retry.`));},20000);
      this.providerPending.set(id,{resolve,reject,timer});
      worker.postMessage({id,op,source,nativeId,...extra,...(source==='cursor'?{cursorBin:!!this.options.gateway.bin('cursor')}:{})});
    });
  }
  private async scan(source:string) {
    const start=performance.now();
    this.stats.scans[source]=(this.stats.scans[source] || 0)+1;
    const previous=this.revision;
    try {
      await this.call('health',{source,state:'scanning'});
      const response=await this.provider(source,'scan');
      const rows:ChatSummary[]=response.result.filter(row=>typeof row?.hostChatId === 'string').map(row=>scanSummary(this.options.hostId,source,row));
      this.revision=await this.call('upsert',{rows,source,removeMissing:!response.reason && response.complete !== false});
      await this.syncSessions();
      await this.call('health',{source,state:response.reason?'error':'ready',reason:response.reason,lastSuccessAt:Date.now(),durationMs:Math.round(performance.now()-start)});
    } catch(error) {
      await this.call('health',{source,state:'error',reason:error instanceof Error?error.message:'Couldn’t refresh this app. Retry.',durationMs:Math.round(performance.now()-start)}).catch(()=>{});
    }
    this.stats.scanMs[source]=performance.now()-start;
    if(this.revision!==previous) this.notify();
  }
  /** Every ~2 s while a phone watches: re-evaluate only recently active chats. */
  async poll() {
    if(this.polling || this.closed || !this.worker) return;
    this.polling=true;const start=performance.now();
    try {
      const hot:Array<{id:string;source:string;nativeId:string}>=await this.call('hot',{since:Date.now()-LIVE.hotMs});
      const bySource=new Map<string,string[]>();
      for(const row of hot) if(SOURCES.includes(row.source)) (bySource.get(row.source) || bySource.set(row.source,[]).get(row.source)!).push(row.nativeId);
      const previous=this.revision;
      for(const [source,ids] of bySource) {
        if(this.scans.has(source)) continue;
        try {
          const response=await this.provider(source,'live',undefined,{ids});
          const rows=(response.result || []).filter(row=>typeof row?.hostChatId === 'string').map(row=>scanSummary(this.options.hostId,source,row));
          if(rows.length) this.revision=await this.call('upsert',{rows});
        } catch { /* the next full scan reports source health */ }
      }
      await this.syncSessions();
      this.revision=await this.call('decay');
      if(this.revision!==previous) this.notify();
    } finally { this.polling=false;this.stats.polls++;this.stats.pollMs=performance.now()-start; }
  }
  async list(query:ChatQuery,folders=false) {
    await this.syncSessions();
    const previous=this.revision;
    this.revision=await this.call('decay');
    if(this.revision!==previous) this.notify();
    return this.call(folders?'folders':'list',query);
  }
  private ownedSession(row: ChatSummary) {
    return row.agentSessionId ? this.options.gateway.sessions().find(session=>session.agentSessionId===row.agentSessionId) : undefined;
  }
  async historyPage(params:{chatId:string;olderCursor?:string;newerCursor?:string;limit?:number}):Promise<ChatHistoryPage> {
    const row:ChatSummary|undefined=await this.call('get',{id:params.chatId});
    if(!row) throw new Error('Chat no longer exists in the library');
    const limit=Math.min(100,Math.max(1,params.limit || 100));
    if(!Number.isInteger(limit) || (params.olderCursor && params.newerCursor)) throw new Error('Invalid history request');
    const owned=this.ownedSession(row);
    const native=!!row.nativeId && SOURCES.includes(row.source);
    // The native transcript is the truth (it includes turns sent from the phone);
    // NexusLink's own stream is used while it drives a turn, and for chats it alone knows.
    if(row.agentSessionId && row.managed === true && (!native || owned?.busy || owned?.taskState === 'waiting')) {
      const cursor=params.olderCursor || params.newerCursor;
      const seq=cursor ? Number(cursor) : undefined;
      if(cursor && (!Number.isSafeInteger(seq) || seq! < 0)) throw new Error('Invalid history cursor');
      const page=await this.options.gateway.history(row.agentSessionId,{limit,beforeSeq:params.olderCursor?seq:undefined,afterSeq:params.newerCursor?seq:undefined});
      const events=page.events.map(event=>({...event,id:identity(row.id,String(event.seq))}));
      return this.boundHistory(events,{appendOnly:true,olderCursor:page.hasMore&&!params.newerCursor?String(events[0]?.seq):null,newerCursor:events.length?String(events.at(-1)!.seq):params.newerCursor || null,revision:String(events.at(-1)?.seq || 0),completeness:'complete'});
    }
    if(!row.nativeId) return {events:[],olderCursor:null,newerCursor:null,revision:'0',completeness:'unavailable',reason:'This conversation has no saved messages.'};
    const saved:string|null=await this.call('historyFingerprint',{chat:row.id});
    let load=this.historyLoads.get(row.id);
    if(!load) {
      load=this.provider(row.source,'history',row.nativeId,{fingerprint:saved}).then(response=>{
        if(response.unchanged) return;
        const fingerprint=response.fingerprint ?? (row.activityAt == null ? `unknown:${Math.floor(Date.now()/30000)}` : String(row.activityAt));
        if(fingerprint===saved) return;
        if(response.reason && response.result.length===0)throw new Error(response.reason);
        return this.call('indexHistory',{chat:row.id,fingerprint,events:response.result,reason:response.reason});
      }).finally(()=>this.historyLoads.delete(row.id));
      this.historyLoads.set(row.id,load);
    }
    try {await load;} catch(error) {
      // Serve the last indexed copy if the app's files are briefly unreadable.
      if(saved === null) return {events:[],olderCursor:null,newerCursor:null,revision:'0',completeness:'unavailable',reason:error instanceof Error?error.message:'This app’s history could not be read.'};
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
        let row:ChatSummary|undefined=await this.call('get',{id:params.chatId});
        if(!row || (!row.agentSessionId && !row.nativeId) || !row.capabilities.continue) throw new Error(row?.capabilities.reason || 'This chat is read only. Start a new chat to reply.');
        const owned=this.ownedSession(row);
        if(row.capabilities.safety==='busy' && !owned?.busy && owned?.taskState!=='waiting') {
          // Running in another app on the PC: NexusLink never signals processes it did not start.
          throw new Error(row.capabilities.reason || 'This chat is working on the PC. Let it finish, or stop it there first.');
        }
        if(!row.agentSessionId && row.nativeId && this.options.gateway.openHostChat) {
          // Seed from the read-only worker path; no transcript parse on the RPC thread.
          let history:any[]|undefined;
          try { history=(await this.provider(row.source,'history',row.nativeId,{})).result; } catch { history=undefined; }
          const session = this.options.gateway.openHostChat({agent: row.source, hostChatId: row.nativeId, cwd: row.folderPath || undefined, title: row.title, history, updatedAt: row.activityAt ?? undefined});
          if (session) {
            row.agentSessionId = session.agentSessionId;
            await this.syncSessions();
          }
        }
        if(!row.agentSessionId) throw new Error('Could not open conversation session');
        if (params.interrupt && this.options.gateway.cancel) {
          this.options.gateway.cancel(row.agentSessionId);
          await new Promise(r => setTimeout(r, 100));
          await this.syncSessions();
          row = await this.call('get', { id: params.chatId }) || row;
        } else if (this.ownedSession(row)?.busy) {
          throw new Error('This chat is working on the PC. Stop it before sending another prompt.');
        }
        if(row.source !== 'mock' && !this.options.gateway.bin(row.source)) throw new Error(`${row.sourceName} is unavailable. Install or sign in to this app on the PC.`);
        if(params.expectedRevision!==undefined && params.expectedRevision!==this.revision) throw new Error('Chat changed. Refresh it before replying.');
        if(!row.folderPath || !existsSync(row.folderPath) || !statSync(row.folderPath).isDirectory()) throw new Error('The recorded folder is unavailable. Choose a folder before replying.');
        if(params.requiredFolder && folderIdentity(params.requiredFolder).id!==row.folderId) throw new Error('The reply folder differs from the recorded chat folder.');
        await this.call('finish',{device,body:{operationId:params.operationId,state:'dispatching',agentSessionId:row.agentSessionId}});
        dispatched=true;
        const sent=this.options.gateway.send(row.agentSessionId,params.text,{images:params.images,model:params.model,thinking:params.thinking,mode:params.mode});
        if(!sent.ok) throw new Error(sent.reason || 'Provider did not confirm dispatch');
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
      case 'chat.historyPage': {
        // Reading never attaches or snapshots the chat; only chat.send does.
        await this.syncSessions();
        const page=await this.historyPage(params);
        return {...page,chat:await this.call('get',{id:params.chatId})};
      }
      case 'chat.refresh': return this.refresh(params.source);
      case 'chat.subscribe': if(typeof params.enabled!=='boolean')throw new Error('Invalid subscription');return this.subscribe(connection,params.enabled);
      case 'chat.send': return this.send(device,params);
      case 'chat.sendStatus': return this.call('status',{device,operationId:params.operationId});
      case 'chat.setState': {
        if(typeof params.chatId!=='string' || !params.chatId)throw new Error('Invalid chat');
        for(const key of ['acknowledged','hidden']) if(params[key]!==undefined && typeof params[key]!=='boolean')throw new Error(`Invalid ${key}`);
        if(params.acknowledged===undefined && params.hidden===undefined)throw new Error('Nothing to change');
        await this.syncSessions();
        const {row,revision}=await this.call('setState',{id:params.chatId,change:{acknowledged:params.acknowledged,hidden:params.hidden}});
        if(revision!==this.revision){this.revision=revision;this.notify();}
        return {ok:true,chat:row,revision};
      }
      case 'chat.cancel': {
        await this.syncSessions();
        const row: ChatSummary | undefined = await this.call('get', { id: params.chatId });
        if (row?.agentSessionId && this.options.gateway.cancel) {
          this.options.gateway.cancel(row.agentSessionId);
          await this.syncSessions();
          return { ok: true };
        }
        return { ok: false };
      }
      default: throw new Error('Unknown chat method');
    }
  }
  async close() {
    this.closed=true;this.initialized=false;this.stopWatching();clearTimeout(this.notifyTimer);
    await Promise.all(this.scans.values());await Promise.allSettled(this.sendQueue.values());
    this.dropProviderWorker(new Error('Chat library closed'));
    await this.call('close');this.worker?.terminate();this.worker=undefined;
  }
}
