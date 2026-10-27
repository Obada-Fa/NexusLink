import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { createInterface } from 'node:readline';
import { readdirSync, existsSync, readFileSync, statSync, openSync, readSync, closeSync } from 'node:fs';
import { join } from 'node:path';
import { roots } from '../paths';
import type { AgentHostChat } from '../../../rpc-types/src/index';
import type { HostChatDelta } from './local';

export class CodexAppServer {
  constructor(private handlers: { spawned?: (pid:number) => void; notification?: (method: string, params: any) => void; request?: (id: string | number, method: string, params: any) => void; closed?: () => void } = {}) {}
  private process?: ChildProcessWithoutNullStreams;
  private nextId = 0;
  private pending = new Map<number,{ resolve: (value: any) => void; reject: (error: Error) => void; timer: ReturnType<typeof setTimeout> }>();
  async initialize(bin = 'codex', env?: Record<string,string>, argv = ['app-server']) {
    const wrapped = process.platform === 'win32' && /\.(cmd|bat)$/i.test(bin);
    this.process = spawn(wrapped ? 'cmd.exe' : bin, wrapped ? ['/d','/s','/c',bin,...argv] : argv,{windowsHide:true,stdio:'pipe',env:{...process.env,...env}});
    if(this.process.pid)this.handlers.spawned?.(this.process.pid);
    this.process.stderr.resume();
    const lines = createInterface({input:this.process.stdout});
    lines.on('line',line=>{
      let response: any;
      try { response = JSON.parse(line); } catch { return; }
      const request = this.pending.get(response.id);
      if (request) {
        clearTimeout(request.timer); this.pending.delete(response.id);
        response.error ? request.reject(new Error(response.error.message || 'Codex request failed')) : request.resolve(response.result);
      } else if (response.id !== undefined && response.method) {
        if(this.handlers.request) this.handlers.request(response.id,response.method,response.params);
        else this.process?.stdin.write(JSON.stringify({id:response.id,error:{code:-32601,message:'Read-only library client'}})+'\n');
      } else if (response.method) {
        this.handlers.notification?.(response.method,response.params);
      }
    });
    const fail = () => { for (const request of this.pending.values()) { clearTimeout(request.timer); request.reject(new Error('Codex app-server unavailable. Check the PC installation and sign-in.')); } this.pending.clear();this.handlers.closed?.(); };
    this.process.on('error',fail); this.process.on('exit',fail);
    await this.request('initialize',{clientInfo:{name:'nexuslink',title:'NexusLink',version:'1.0.0'}});
    this.process.stdin.write(JSON.stringify({method:'initialized',params:{}})+'\n');
  }
  request(method: string, params: unknown): Promise<any> {
    return new Promise((resolve,reject)=>{
      const id = ++this.nextId;
      const timer = setTimeout(()=>{ this.pending.delete(id); reject(new Error('Codex discovery timed out')); },12000);
      this.pending.set(id,{resolve,reject,timer});
      this.process?.stdin.write(JSON.stringify({id,method,params})+'\n');
    });
  }
  async list(): Promise<Array<AgentHostChat & { preview?: string; archived?: boolean; busy?: boolean }>> {
    const rows: any[] = [];
    for (const archived of [false,true]) {
      let cursor: string | null = null;
      const seen = new Set<string>();
      do {
        const page = await this.request('thread/list',{cursor,limit:100,sortKey:'updated_at',sortDirection:'desc',sourceKinds:['cli','vscode','exec','appServer','unknown'],archived});
        if (!Array.isArray(page.data)) throw new Error('Unsupported Codex thread list format');
        rows.push(...page.data.map((thread: any)=>({agent:'codex',hostChatId:thread.id,title:thread.name || thread.preview?.slice(0,72) || 'Codex conversation',preview:thread.preview,cwd:thread.cwd || '',updatedAt:validTime(thread.updatedAt,1000),resumable:false,source:'Codex',archived,busy:thread.status?.type === 'active'})));
        cursor = page.nextCursor || null;
        if (cursor && seen.has(cursor)) throw new Error('Codex returned a repeated discovery cursor');
        if (cursor) seen.add(cursor);
      } while (cursor);
    }
    return rows;
  }
  async history(id: string): Promise<HostChatDelta[]> {
    const response = await this.request('thread/read',{threadId:id,includeTurns:true});
    if (!Array.isArray(response.thread?.turns)) throw new Error('Codex history is unavailable in this version');
    const events: HostChatDelta[] = [];
    for (const turn of response.thread.turns) for (const item of turn.items || []) {
      if (item.type === 'userMessage') {
        const text = (item.content || []).filter((part: any)=>part.type === 'text').map((part: any)=>part.text).join('\n');
        if (text) events.push({kind:'user',text,refId:item.id,ts:validTime(turn.startedAt,1000)});
      } else if (item.type === 'agentMessage' && item.text) events.push({kind:'text',text:item.text,refId:item.id,ts:validTime(turn.completedAt || turn.startedAt,1000)});
      else if (item.type === 'commandExecution') events.push({kind:'tool-end',toolName:'Command',toolInput:item.command,toolOutput:item.aggregatedOutput,refId:item.id,ts:0});
    }
    return events;
  }
  respond(id: string | number, result: unknown) { this.process?.stdin.write(JSON.stringify({id,result})+'\n'); }
  reject(id: string | number) { this.process?.stdin.write(JSON.stringify({id,error:{code:-32601,message:'Open this interaction on the PC'}})+'\n'); }
  close() { this.process?.kill(); }
}

function validTime(value: unknown, factor = 1): number {
  const n = typeof value === 'number' ? value * factor : typeof value === 'string' ? Date.parse(value) : 0;
  return Number.isFinite(n) && n > 0 ? n : 0;
}
const codexHome = () => roots().codex;
function rollouts(): Array<{path:string;archived:boolean}> {
  const files: Array<{path:string;archived:boolean}> = [];
  const visit = (path: string, archived: boolean) => {
    if (!existsSync(path)) return;
    for (const entry of readdirSync(path,{withFileTypes:true})) {
      const child = join(path,entry.name);
      if (entry.isDirectory() && !entry.isSymbolicLink()) visit(child,archived);
      else if (entry.isFile() && entry.name.endsWith('.jsonl')) files.push({path:child,archived});
    }
  };
  visit(join(codexHome(),'sessions'),false); visit(join(codexHome(),'archived_sessions'),true);
  return files;
}
const clipTool = (text: string) => text.length > 4000 ? `${text.slice(0, 4000)}…` : text;
function outputText(output: unknown): string {
  if (typeof output === 'string') return output;
  if (Array.isArray(output)) return output.map((part: any) => typeof part === 'string' ? part : part?.text || '').join('');
  if (output && typeof output === 'object') return JSON.stringify(output);
  return '';
}
/** Rollout JSONL → chat events (messages plus tool calls and their output). */
export function parseCodexJsonl(text: string): HostChatDelta[] {
  const out: HostChatDelta[] = [];
  for (const line of text.split('\n')) {
    let row: any;
    try { row=JSON.parse(line); } catch { continue; }
    const payload = row.payload;
    if (row.type !== 'response_item' || !payload) continue;
    const ts = validTime(row.timestamp);
    if (['function_call','custom_tool_call','local_shell_call'].includes(payload.type)) {
      const input = payload.arguments ?? payload.input ?? payload.action ?? {};
      out.push({kind:'tool-start',toolName:String(payload.name || 'shell'),toolInput:clipTool(typeof input === 'string' ? input : JSON.stringify(input,null,2)),refId:String(payload.call_id || payload.id || ''),ts});
      continue;
    }
    if (['function_call_output','custom_tool_call_output','local_shell_call_output'].includes(payload.type)) {
      out.push({kind:'tool-end',toolOutput:clipTool(outputText(payload.output)),refId:String(payload.call_id || ''),ts});
      continue;
    }
    if (payload.type !== 'message' || !['user','assistant'].includes(payload.role)) continue;
    const text = (payload.content || []).filter((part: any)=>['input_text','output_text','text'].includes(part.type)).map((part: any)=>part.text || '').join('\n');
    if (!text.trim() || /^# (?:AGENTS\.md instructions|Files mentioned by the user:)/.test(text) || /^<(?:environment_context|permissions|INSTRUCTIONS|system|user_instructions|turn_aborted)/.test(text)) continue;
    out.push({kind:payload.role === 'user' ? 'user' : 'text',text,ts,refId:payload.id});
  }
  return out;
}
/** Codex Desktop's paginated history (thread_history_N.sqlite item_json rows) → chat events. */
export function parseCodexHistoryItems(items: any[]): HostChatDelta[] {
  const out: HostChatDelta[] = [];
  for (const item of items) {
    const ts = Number(item?._ts) || 0;
    switch (item?.type) {
      case 'userMessage': {
        const text = (item.content || []).filter((part: any)=>part?.type === 'text').map((part: any)=>part.text).join('\n');
        if (text.trim()) out.push({kind:'user',text,refId:item.id,ts});
        break;
      }
      case 'agentMessage': if (item.text) out.push({kind:'text',text:item.text,refId:item.id,ts}); break;
      case 'commandExecution':
        out.push({kind:'tool-start',toolName:'Command',toolInput:clipTool(Array.isArray(item.command) ? item.command.join(' ') : String(item.command || '')),refId:item.id,ts});
        if (item.aggregatedOutput !== undefined) out.push({kind:'tool-end',toolName:'Command',toolOutput:clipTool(String(item.aggregatedOutput || '')),refId:item.id,ts});
        break;
      case 'fileChange': {
        const changes = Array.isArray(item.changes) ? item.changes : [];
        out.push({kind:'tool-start',toolName:'File changes',toolInput:clipTool(changes.map((c: any)=>c?.path).filter(Boolean).join('\n')),refId:item.id,ts});
        out.push({kind:'tool-end',toolName:'File changes',toolOutput:clipTool(changes.map((c: any)=>c?.diff || '').join('\n')),refId:item.id,ts});
        break;
      }
      case 'mcpToolCall': case 'webSearch':
        out.push({kind:'tool-start',toolName:item.type === 'webSearch' ? 'Web search' : `${item.server || 'mcp'}.${item.tool || 'tool'}`,toolInput:clipTool(JSON.stringify(item.arguments ?? item.query ?? {},null,2)),refId:item.id,ts});
        out.push({kind:'tool-end',toolOutput:clipTool(outputText(item.result?.content ?? item.result ?? '')),refId:item.id,ts});
        break;
      case 'plan': if (item.text) out.push({kind:'text',text:item.text,refId:item.id,ts}); break;
    }
  }
  return out;
}
export function listCodexLocal(): AgentHostChat[] {
  const rows = new Map<string,AgentHostChat>();
  const index = join(codexHome(),'session_index.jsonl');
  if (existsSync(index)) for (const line of readFileSync(index,'utf8').split('\n')) {
    try { const row=JSON.parse(line); if (typeof row.id === 'string') rows.set(row.id,{agent:'codex',hostChatId:row.id,title:row.thread_name || 'Codex conversation',cwd:'',updatedAt:validTime(row.updated_at),resumable:false,source:'Codex'}); } catch { /* partial records */ }
  }
  for (const file of rollouts()) {
    // Metadata is at the start. Never read full transcripts during discovery.
    const handle = openSync(file.path,'r');
    try {
      const buffer=Buffer.alloc(32768); const size=readSync(handle,buffer,0,buffer.length,0);
      const row=JSON.parse(buffer.subarray(0,size).toString('utf8').split('\n')[0]);
      if (row.type !== 'session_meta' || typeof row.payload?.id !== 'string') continue;
      const meta=row.payload; const old=rows.get(meta.id);
      rows.set(meta.id,{agent:'codex',hostChatId:meta.id,title:old?.title || 'Codex conversation',cwd:meta.cwd || '',updatedAt:Math.max(old?.updatedAt || 0,statSync(file.path).mtimeMs),resumable:false,source:'Codex',...({archived:file.archived} as any)});
    } catch { /* unreadable/partial metadata */ } finally { closeSync(handle); }
  }
  return [...rows.values()];
}
export function loadCodexLocal(id: string): HostChatDelta[] {
  if (!/^[a-zA-Z0-9_-]+$/.test(id)) throw new Error('Invalid Codex conversation identity');
  const file = rollouts().find(file=>file.path.endsWith(`-${id}.jsonl`));
  if (!file) throw new Error('Codex transcript is unavailable on this PC');
  return parseCodexJsonl(readFileSync(file.path,'utf8'));
}
