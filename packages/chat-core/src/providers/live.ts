// Live status for chats that run anywhere on the PC (not only ones NexusLink
// started). Everything here is pure: callers hand in the tail of a native
// transcript plus its mtime, and get back a ChatLive snapshot. No I/O except the
// optional, cached /proc probe used to tell a long-running command from a
// permission prompt.
import { readdirSync, readFileSync } from 'node:fs';
import type { ChatLive } from '../../../rpc-types/src/chat';

export type Todo = NonNullable<ChatLive['todos']>[number];

export const LIVE = {
  /** A transcript written this recently is being produced right now. */
  freshMs: 6_000,
  /** A pending, permission-gated tool with no writes for this long is probably waiting on the user. */
  waitingMs: 8_000,
  /** An open turn with no writes for this long is reported idle, not working. */
  staleMs: 20 * 60_000,
  /** Chats written within this window are polled every ~2 s while a phone watches. */
  hotMs: 10 * 60_000,
  /** Only chats written within this window get a computed live state at all. */
  warmMs: 24 * 3_600_000,
} as const;

export function clip(text: unknown, max = 280): string | undefined {
  if (typeof text !== 'string') return undefined;
  const t = text.replace(/\s+/g, ' ').trim();
  if (!t) return undefined;
  return t.length > max ? `${t.slice(0, max - 1)}…` : t;
}

export function parseJsonLines(text: string): any[] {
  const out: any[] = [];
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    try { out.push(JSON.parse(line)); } catch { /* bounded reads cut lines; never an error */ }
  }
  return out;
}

const time = (value: unknown): number => {
  const n = typeof value === 'number' ? value : typeof value === 'string' ? Date.parse(value) : NaN;
  return Number.isFinite(n) && n > 0 ? n : 0;
};
const baseName = (path: string) => path.replace(/[\\/]+$/, '').split(/[\\/]/).pop() || path;
/** Antigravity encodes every tool argument as a JSON string literal. */
function unwrap(value: unknown): unknown {
  if (typeof value !== 'string') return value;
  const t = value.trim();
  if ((t.startsWith('"') && t.endsWith('"')) || t.startsWith('[') || t.startsWith('{')) {
    try { return JSON.parse(t); } catch { return value; }
  }
  return value;
}
function arg(input: any, ...keys: string[]): string {
  if (!input || typeof input !== 'object') return '';
  for (const key of keys) {
    const value = unwrap(input[key]);
    if (typeof value === 'string' && value.trim()) return value.trim();
    if (Array.isArray(value) && value.length && value.every(v => typeof v === 'string')) return value.join(' ');
  }
  return '';
}
function parseInput(input: unknown): any {
  if (typeof input === 'string') { try { return JSON.parse(input); } catch { return { command: input }; } }
  return input && typeof input === 'object' ? input : {};
}
function shellCommand(cmd: string): string {
  // `bash -lc '…'` wrappers add nothing for a phone-sized step line.
  const m = cmd.match(/^(?:\/bin\/)?(?:ba|z)?sh\s+-l?c\s+(['"])([\s\S]*)\1$/);
  return (m ? m[2] : cmd).replace(/\s+/g, ' ').trim();
}

/** One human sentence for a tool call, shared by every provider. */
export function describeTool(rawName: string, rawInput: unknown): { step: string; activity: string } {
  const input = parseInput(rawInput);
  const name = (rawName || 'tool').toLowerCase();
  const short = name.replace(/^mcp__[^_]+(?:_[^_]+)*?__/, '');
  const file = arg(input, 'file_path', 'path', 'TargetFile', 'target_file', 'filePath', 'notebook_path', 'AbsolutePath', 'file');
  const action = arg(input, 'toolAction');
  if (/^(edit|multiedit|write|notebookedit|replace_file_content|multi_replace_file_content|write_to_file|create_file|edit_file|apply_patch|str_replace|str_replace_editor|patch|filechange|file changes)$/.test(name)) {
    let target = file;
    if (!target && name === 'apply_patch') target = (String(input.input || input.patch || rawInput || '').match(/\*\*\* (?:Update|Add|Delete) File: (.+)/) || [])[1] || '';
    return { step: target ? `Editing ${baseName(target)}` : action || 'Editing files', activity: 'editing' };
  }
  if (/^(bash|shell|exec_command|run_command|terminal|command|local_shell|commandexecution|powershell)$/.test(name)) {
    const cmd = shellCommand(arg(input, 'command', 'cmd', 'CommandLine', 'commandLine', 'script'));
    return { step: cmd ? `Running: ${cmd.slice(0, 60)}${cmd.length > 60 ? '…' : ''}` : action || 'Running a command', activity: 'running-command' };
  }
  if (/^(read|view_file|view|cat|read_file|imageview|view_image)$/.test(name)) return { step: file ? `Reading ${baseName(file)}` : action || 'Reading files', activity: 'reading' };
  if (/^(grep|glob|grep_search|find_by_name|search|codebase_search|file_search|toolsearch)$/.test(name)) {
    const pattern = arg(input, 'pattern', 'Query', 'query', 'Pattern', 'SearchPath');
    return { step: pattern ? `Searching: ${pattern.slice(0, 60)}` : action || 'Searching the code', activity: 'searching' };
  }
  if (/^(ls|list_dir|list_directory)$/.test(name)) return { step: file ? `Listing ${baseName(file)}` : 'Listing files', activity: 'reading' };
  if (/^(webfetch|read_url_content|fetch|web_fetch)$/.test(name)) {
    const url = arg(input, 'url', 'Url');
    let host = '';
    try { host = new URL(url).host; } catch { /* not a URL */ }
    return { step: host ? `Browsing ${host}` : 'Browsing the web', activity: 'browsing' };
  }
  if (/^(websearch|search_web|web_search|web\.search)$/.test(name)) {
    const q = arg(input, 'query', 'Query');
    return { step: q ? `Searching the web: ${q.slice(0, 50)}` : 'Searching the web', activity: 'browsing' };
  }
  if (/^(task|agent|invoke_subagent|invoke_subagents|spawn_agent|subagent)$/.test(name)) {
    const d = arg(input, 'description', 'Description', 'subagent_type');
    return { step: d ? `Delegating: ${d.slice(0, 60)}` : 'Delegating to a sub-agent…', activity: 'working' };
  }
  if (/^(todowrite|taskcreate|taskupdate|update_plan|manage_task|tasklist)$/.test(short)) return { step: 'Updating the plan', activity: 'thinking' };
  if (/^(askuserquestion|ask_question|request_user_input|request_user_input_async|ask_user|ask_permission)$/.test(short)) return { step: 'Asking you a question', activity: 'waiting' };
  if (short === 'exitplanmode') return { step: 'Waiting for plan approval', activity: 'waiting' };
  if (/browser|chrome|cua|computer|navigate|screenshot/.test(name)) return { step: action || 'Using the browser', activity: 'browsing' };
  if (/^(wait|sleep|schedule|monitor)$/.test(short)) return { step: action || 'Waiting for a running task', activity: 'running-command' };
  return { step: action || `Using ${rawName.replace(/^mcp__/, '').replace(/__/g, ' ')}`, activity: 'working' };
}

function question(input: unknown): string | undefined {
  const value = parseInput(input);
  const qs = unwrap(value.questions);
  if (Array.isArray(qs) && qs[0]) return clip(qs[0].question || qs[0].header || qs[0].prompt, 200);
  return clip(arg(value, 'question', 'prompt', 'Reason', 'message', 'plan'), 200);
}

function mapTodoState(status: unknown): Todo['state'] {
  const s = String(status || '').toLowerCase();
  if (/^(completed|complete|done|finished)$/.test(s)) return 'done';
  if (/^(in_progress|in-progress|active|running|started)$/.test(s)) return 'active';
  return 'pending';
}

/** Replays plan/todo tool calls in order; providers feed it every call they see. */
export class TodoTracker {
  todos: Array<Todo & { id?: string }> | undefined;
  private nextTask = 1;
  private created = new Map<string, number>();
  apply(rawName: string, rawInput: unknown, callId?: string) {
    const name = rawName.toLowerCase().replace(/^mcp__[a-z0-9_]+?__/, '');
    const input = parseInput(rawInput);
    if (name === 'todowrite' && Array.isArray(input.todos)) {
      this.todos = input.todos.map((t: any) => ({ text: clip(t.content || t.activeForm || t.text, 160) || 'Task', state: mapTodoState(t.status) }));
    } else if (name === 'taskcreate') {
      const id = String(this.nextTask++);
      if (callId) this.created.set(callId, (this.todos ||= []).length);
      (this.todos ||= []).push({ id, text: clip(input.subject || input.description, 160) || 'Task', state: 'pending' });
    } else if (name === 'taskupdate') {
      const todo = this.todos?.find(t => t.id === String(input.taskId));
      if (todo && input.status === 'deleted') this.todos = this.todos!.filter(t => t !== todo);
      else if (todo && input.status) todo.state = mapTodoState(input.status);
      if (todo && typeof input.subject === 'string') todo.text = clip(input.subject, 160) || todo.text;
    } else if (name === 'update_plan') {
      const items = Array.isArray(input.items) ? input.items : Array.isArray(input.plan) ? input.plan : undefined;
      if (items) this.todos = items.map((t: any) => ({ text: clip(t.content || t.step || t.text, 160) || 'Step', state: mapTodoState(t.status) }));
      else if (this.todos) {
        if (input.advance) {
          const active = this.todos.findIndex(t => t.state === 'active');
          if (active >= 0) this.todos[active].state = 'done';
          const next = this.todos.findIndex(t => t.state === 'pending');
          if (next >= 0) this.todos[next].state = 'active';
        }
        for (const n of Array.isArray(input.done) ? input.done : []) if (this.todos[n - 1]) this.todos[n - 1].state = 'done';
        if (typeof input.start === 'number' && this.todos[input.start - 1]) {
          for (const t of this.todos) if (t.state === 'active') t.state = 'done';
          this.todos[input.start - 1].state = 'active';
        }
      }
    }
  }
  /** TaskCreate results carry the real task number ("Task #4 created"). */
  result(callId: string, text: string) {
    const index = this.created.get(callId);
    const id = text.match(/Task #(\d+)/)?.[1];
    if (index !== undefined && id && this.todos?.[index]) this.todos[index].id = id;
  }
  snapshot(): Todo[] | undefined {
    return this.todos?.length ? this.todos.slice(0, 50).map(({ text, state }) => ({ text, state })) : undefined;
  }
}

export function executionFor(live: ChatLive | undefined): 'working' | 'needsReply' | 'idle' {
  return live?.state === 'working' ? 'working' : live?.state === 'waiting' ? 'needsReply' : 'idle';
}

/** Linux only: is a shell currently running this command? Distinguishes a long build from a permission prompt. */
let procCache: { at: number; lines: string[] } | undefined;
export function commandRunning(command: string, now = Date.now()): boolean {
  if (process.platform !== 'linux' || !command.trim()) return false;
  if (!procCache || now - procCache.at > 1000) {
    const lines: string[] = [];
    try {
      for (const entry of readdirSync('/proc')) {
        if (!/^\d+$/.test(entry) || Number(entry) === process.pid) continue;
        try { lines.push(readFileSync(`/proc/${entry}/cmdline`, 'utf8').replace(/\0/g, ' ')); } catch { /* exited */ }
      }
    } catch { /* no procfs */ }
    procCache = { at: now, lines };
  }
  // Claude Code runs commands as `eval '…'` with each ' escaped as '"'"', so compare without quoting.
  const plain = (text: string) => text.replace(/['"\\]/g, '').replace(/\s+/g, ' ').trim();
  const needle = plain(command).slice(0, 48);
  if (needle.length < 4) return false;
  return procCache.lines.some(line => plain(line).includes(needle) && !line.includes('nexuslink-probe'));
}

// ---------------------------------------------------------------------------
// Claude Code (~/.claude/projects/<slug>/<session>.jsonl)
// ---------------------------------------------------------------------------

export interface ClaudeTail {
  live: ChatLive;
  title?: string;
  lastPrompt?: string;
  model?: string;
  cwd?: string;
  permissionMode?: string;
}
export interface ClaudeLiveOptions {
  mtimeMs: number;
  now?: number;
  permissionMode?: string;
  /** Background sub-agent transcripts of this session (mtime + description). */
  subagents?: Array<{ mtimeMs: number; description?: string }>;
  isRunning?: (command: string) => boolean;
  /** Read a sub-agent's own transcript, whose rows are all marked isSidechain. */
  sidechain?: boolean;
}
const CLAUDE_UNGATED = /^(read|grep|glob|ls|todowrite|taskcreate|taskupdate|tasklist|taskget|toolsearch|agent|task|websearch|exitplanmode|askuserquestion|skill|bashoutput|monitor|sendmessage|subagenthandback|mcp__ccd_turn__.*|mcp__ccd_session__.*)$/i;
function claudeGated(tool: string, mode: string | undefined): boolean {
  if (mode && /^(auto|bypasspermissions|dontask)$/i.test(mode)) return false;
  if (CLAUDE_UNGATED.test(tool)) return false;
  if (mode === 'acceptEdits' && /^(edit|multiedit|write|notebookedit)$/i.test(tool)) return false;
  return true;
}

export function claudeLive(text: string, options: ClaudeLiveOptions): ClaudeTail {
  const now = options.now ?? Date.now();
  const out: Omit<ClaudeTail, 'live'> = {};
  const pending = new Map<string, { name: string; input: unknown; ts: number }>();
  const todos = new TodoTracker();
  let lastKind: 'prompt' | 'tool_result' | 'assistant' | 'interrupted' | 'error' | undefined;
  let lastStop: string | null | undefined;
  let lastText: string | undefined;
  let turnStartedAt: number | undefined;
  let lastThinking = false;
  let steps = 0;
  let errorText: string | undefined;
  for (const row of parseJsonLines(text)) {
    const type = row.type;
    if (type === 'custom-title' && typeof row.customTitle === 'string') { out.title = row.customTitle; continue; }
    if (type === 'agent-name' && typeof row.agentName === 'string' && !out.title) { out.title = row.agentName; continue; }
    if (type === 'summary' && typeof row.summary === 'string' && !out.title) { out.title = row.summary; continue; }
    if (type === 'last-prompt' && typeof row.lastPrompt === 'string') { out.lastPrompt = row.lastPrompt; continue; }
    if (row.isSidechain === true && !options.sidechain) continue;
    if (typeof row.cwd === 'string' && row.cwd) out.cwd = row.cwd;
    const message = row.message || {};
    const content = message.content;
    const ts = time(row.timestamp);
    if (type === 'user') {
      if (typeof row.permissionMode === 'string') out.permissionMode = row.permissionMode;
      const parts = typeof content === 'string' ? [{ type: 'text', text: content }] : Array.isArray(content) ? content : [];
      let prompt = false;
      for (const part of parts) {
        if (part?.type === 'tool_result') {
          const id = String(part.tool_use_id || '');
          pending.delete(id);
          const body = typeof part.content === 'string' ? part.content : Array.isArray(part.content) ? part.content.map((p: any) => p?.text || '').join('') : '';
          todos.result(id, body);
          lastKind = 'tool_result';
        } else if (part?.type === 'text' && typeof part.text === 'string') {
          const t = part.text.trim();
          if (/^\[Request interrupted by user/.test(t)) { lastKind = 'interrupted'; pending.clear(); continue; }
          if (row.isMeta || !t || /^<(command-|local-command|system-reminder|bash-|task-notification)/.test(t)) continue;
          prompt = true;
        } else if (part?.type === 'image') prompt = !row.isMeta;
      }
      if (prompt) {
        lastKind = 'prompt'; turnStartedAt = ts || turnStartedAt; pending.clear(); steps = 0; errorText = undefined;
      }
    } else if (type === 'assistant') {
      if (typeof message.model === 'string' && message.model !== '<synthetic>') out.model = message.model;
      lastKind = 'assistant';
      lastStop = message.stop_reason;
      lastThinking = false;
      if (row.isApiErrorMessage === true) { lastKind = 'error'; errorText = clip(Array.isArray(content) ? content.map((p: any) => p?.text || '').join(' ') : content, 200); continue; }
      for (const part of Array.isArray(content) ? content : []) {
        if (part?.type === 'text' && typeof part.text === 'string' && part.text.trim()) lastText = clip(part.text);
        else if (part?.type === 'thinking') lastThinking = true;
        else if (part?.type === 'tool_use') {
          const name = String(part.name || 'tool');
          pending.set(String(part.id || ''), { name, input: part.input, ts });
          todos.apply(name, part.input, String(part.id || ''));
          steps++;
        }
      }
    }
  }
  const age = Math.max(0, now - options.mtimeMs);
  const subagent = (options.subagents || []).filter(s => now - s.mtimeMs < 60_000).sort((a, b) => b.mtimeMs - a.mtimeMs)[0];
  const live: ChatLive = { state: 'idle', updatedAt: options.mtimeMs || undefined, turnStartedAt, lastText, model: out.model, todos: todos.snapshot(), steps: steps || undefined, via: 'transcript' };
  const mode = out.permissionMode || options.permissionMode;
  const latest = [...pending.values()].at(-1);
  if (lastKind === 'error') {
    Object.assign(live, { state: 'failed', step: 'The model request failed', lastText: errorText || lastText });
  } else if (lastKind === 'interrupted') {
    Object.assign(live, { state: 'idle', step: 'Interrupted' });
  } else if (latest) {
    const { step, activity } = describeTool(latest.name, latest.input);
    Object.assign(live, { state: 'working', step, activity, tool: latest.name });
    if (/^(askuserquestion|exitplanmode)$/i.test(latest.name)) {
      const plan = latest.name.toLowerCase() === 'exitplanmode';
      Object.assign(live, { state: 'waiting', activity: 'waiting', waitKind: plan ? 'plan' : 'question', waitingFor: plan ? 'Approve the plan' : question(latest.input) || 'Answer the question' });
    } else if (age > LIVE.waitingMs && claudeGated(latest.name, mode)) {
      const command = /^bash$/i.test(latest.name) ? String(parseInput(latest.input).command || '') : '';
      if (!(command && (options.isRunning || commandRunning)(command, now))) {
        Object.assign(live, { state: 'waiting', activity: 'waiting', waitKind: 'approval', waitingFor: `Approve: ${step.replace(/^Running: /, '')}`, via: 'transcript-heuristic' });
      }
    }
    if (live.state === 'working' && age > LIVE.staleMs && !subagent) Object.assign(live, { state: 'idle', step: 'No activity for 20+ min', activity: undefined });
  } else if (lastKind === 'prompt' || lastKind === 'tool_result') {
    Object.assign(live, { state: age > LIVE.staleMs ? 'idle' : 'working', step: age > LIVE.staleMs ? 'No activity for 20+ min' : 'Thinking', activity: age > LIVE.staleMs ? undefined : 'thinking' });
  } else if (lastKind === 'assistant') {
    const ended = lastStop === 'end_turn' || lastStop === 'stop_sequence' || lastStop === 'max_tokens';
    if (!ended && age < 30_000) Object.assign(live, { state: 'working', step: lastThinking ? 'Thinking' : 'Responding', activity: lastThinking ? 'thinking' : 'responding' });
    else live.state = 'done';
  }
  if (subagent && live.state !== 'working' && live.state !== 'waiting' && live.state !== 'failed') {
    Object.assign(live, { state: 'working', step: subagent.description ? `Background agent: ${clip(subagent.description, 60)}` : 'Background agents running', activity: 'working' });
  }
  return { ...out, live: prune(live) };
}

// ---------------------------------------------------------------------------
// Codex (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl, Desktop and CLI)
// ---------------------------------------------------------------------------

export interface CodexTail { live: ChatLive; cwd?: string; model?: string; title?: string }
export function codexLive(text: string, options: { mtimeMs: number; now?: number }): CodexTail {
  const now = options.now ?? Date.now();
  const out: Omit<CodexTail, 'live'> = {};
  const pending = new Map<string, { name: string; input: unknown }>();
  const todos = new TodoTracker();
  let open: boolean | undefined;
  let outcome: 'done' | 'failed' | 'idle' | undefined;
  let turnStartedAt: number | undefined;
  let lastText: string | undefined;
  let waitingFor: string | undefined;
  let lastStep: { step: string; activity: string; tool: string } | undefined;
  let thinking = false;
  let steps = 0;
  let errorText: string | undefined;
  for (const row of parseJsonLines(text)) {
    const p = row.payload || {};
    const ts = time(row.timestamp);
    if (row.type === 'session_meta') { if (typeof p.cwd === 'string') out.cwd = p.cwd; continue; }
    if (row.type === 'turn_context') { if (typeof p.cwd === 'string') out.cwd = p.cwd; if (typeof p.model === 'string') out.model = p.model; continue; }
    if (row.type === 'event_msg') {
      switch (p.type) {
        case 'task_started': case 'turn_started':
          open = true; outcome = undefined; turnStartedAt = time(p.started_at) * (p.started_at < 1e12 ? 1000 : 1) || ts; pending.clear(); waitingFor = undefined; steps = 0; errorText = undefined; lastStep = undefined; break;
        case 'task_complete': case 'turn_complete':
          open = false; outcome = 'done'; pending.clear(); waitingFor = undefined; if (typeof p.last_agent_message === 'string') lastText = clip(p.last_agent_message) || lastText; break;
        case 'turn_aborted':
          open = false; outcome = p.reason === 'interrupted' ? 'idle' : 'failed'; pending.clear(); waitingFor = undefined; break;
        case 'error': case 'stream_error':
          errorText = clip(p.message || p.error, 200); break;
        case 'agent_message':
          lastText = clip(p.message) || lastText; break;
        case 'exec_approval_request': case 'apply_patch_approval_request': case 'request_permissions': case 'elicitation_request':
          waitingFor = clip(Array.isArray(p.command) ? `Approve: ${shellCommand(p.command.join(' '))}` : p.reason || p.message || 'Approve the next step', 200); break;
        case 'exec_command_begin':
          waitingFor = undefined; lastStep = { ...describeTool('shell', { command: Array.isArray(p.command) ? p.command.join(' ') : p.command }), tool: 'shell' }; break;
        case 'item_started': case 'item_completed': {
          const item = p.item || {};
          const kind = String(item.type || '');
          if (kind === 'AgentMessage' || kind === 'agentMessage') {
            const t = Array.isArray(item.content) ? item.content.map((c: any) => c?.text || '').join('') : item.text;
            lastText = clip(t) || lastText;
          } else if (kind === 'CommandExecution' || kind === 'commandExecution') {
            lastStep = { ...describeTool('shell', { command: Array.isArray(item.command) ? item.command.join(' ') : item.command }), tool: 'shell' };
          } else if (kind === 'FileChange' || kind === 'fileChange') {
            const changes = item.changes && typeof item.changes === 'object' ? Object.keys(Array.isArray(item.changes) ? {} : item.changes) : [];
            const first = changes[0] || (Array.isArray(item.changes) ? item.changes[0]?.path : '');
            lastStep = { step: first ? `Editing ${baseName(first)}` : 'Editing files', activity: 'editing', tool: 'apply_patch' };
          } else if (kind === 'Reasoning' || kind === 'reasoning') thinking = true;
          break;
        }
      }
      continue;
    }
    if (row.type === 'response_item') {
      if (['function_call', 'custom_tool_call', 'local_shell_call'].includes(p.type)) {
        const name = String(p.name || (p.type === 'local_shell_call' ? 'shell' : 'tool'));
        const input = p.arguments ?? p.input ?? p.action;
        pending.set(String(p.call_id || p.id || ''), { name: p.namespace ? `${p.namespace}.${name}` : name, input });
        todos.apply(name, input);
        steps++; thinking = false;
      } else if (['function_call_output', 'custom_tool_call_output', 'local_shell_call_output'].includes(p.type)) {
        pending.delete(String(p.call_id || ''));
      } else if (p.type === 'message' && p.role === 'assistant') {
        const t = (p.content || []).filter((c: any) => c?.type === 'output_text' || c?.type === 'text').map((c: any) => c.text || '').join('');
        lastText = clip(t) || lastText; thinking = false;
      } else if (p.type === 'reasoning') thinking = true;
    }
  }
  const age = Math.max(0, now - options.mtimeMs);
  const live: ChatLive = { state: 'idle', updatedAt: options.mtimeMs || undefined, turnStartedAt, lastText, model: out.model, todos: todos.snapshot(), steps: steps || undefined, via: 'transcript' };
  // Long turns can outgrow the tail; without markers, freshness decides.
  const working = open === true || (open === undefined && (pending.size > 0 || age < 60_000));
  if (working) {
    const latest = [...pending.values()].at(-1);
    if (waitingFor) Object.assign(live, { state: 'waiting', activity: 'waiting', waitKind: 'approval', waitingFor });
    else if (latest && /request_user_input/.test(latest.name)) Object.assign(live, { state: 'waiting', activity: 'waiting', waitKind: 'question', step: 'Asking you a question', tool: latest.name, waitingFor: question(latest.input) || 'Answer the question' });
    else if (latest) Object.assign(live, { state: 'working', ...codexTool(latest.name, latest.input), tool: latest.name });
    else if (thinking) Object.assign(live, { state: 'working', step: 'Thinking', activity: 'thinking' });
    else if (lastStep) Object.assign(live, { state: 'working', step: lastStep.step, activity: lastStep.activity, tool: lastStep.tool });
    else Object.assign(live, { state: 'working', step: 'Working', activity: 'working' });
    if (live.state === 'working' && age > LIVE.staleMs) Object.assign(live, { state: 'idle', step: 'No activity for 20+ min', activity: undefined, tool: undefined });
  } else if (outcome === 'failed' || (outcome === undefined && errorText)) Object.assign(live, { state: 'failed', step: errorText || 'The last turn failed' });
  else if (outcome === 'idle') Object.assign(live, { state: 'idle', step: 'Interrupted' });
  else if (outcome === 'done' || lastText) live.state = 'done';
  return { ...out, live: prune(live) };
}
function codexTool(name: string, input: unknown): { step: string; activity: string } {
  const short = name.split('.').pop() || name;
  if (short === 'exec') {
    // Codex Desktop wraps shell calls in a JS orchestrator: tools.exec_command({cmd:"…"}).
    const source = typeof input === 'string' ? input : JSON.stringify(input || '');
    const m = source.match(/exec_command\(\{\s*cmd\s*:\s*"((?:[^"\\]|\\.)*)"/);
    if (m) { let cmd = m[1]; try { cmd = JSON.parse(`"${m[1]}"`); } catch { /* raw */ } return describeTool('shell', { command: cmd }); }
    if (/apply_patch/.test(source)) return { step: 'Editing files', activity: 'editing' };
    if (/web_search|search\(/.test(source)) return { step: 'Searching the web', activity: 'browsing' };
    return { step: 'Running a script', activity: 'running-command' };
  }
  if (short === 'wait') return { step: 'Waiting for a running command', activity: 'running-command' };
  if (short === 'js' || /cua/.test(name)) return { step: arg(parseInput(input), 'title') || 'Using the computer', activity: 'browsing' };
  if (short === 'sleep') return { step: 'Waiting', activity: 'working' };
  return describeTool(short, input);
}

// ---------------------------------------------------------------------------
// Antigravity IDE + agy CLI (brain/<id>/.system_generated/logs/transcript.jsonl)
// ---------------------------------------------------------------------------

export interface AgySummaryState { status?: string; notFullyIdle?: boolean; killed?: boolean; stepCount?: number }
export interface AgyTail { live: ChatLive; cwd?: string; firstPrompt?: string }
export function agyLive(text: string, options: { mtimeMs: number; now?: number; summary?: AgySummaryState }): AgyTail {
  const now = options.now ?? Date.now();
  const rows = parseJsonLines(text).filter(r => r && typeof r === 'object' && typeof r.type === 'string');
  const out: Omit<AgyTail, 'live'> = {};
  let lastText: string | undefined;
  let turnStartedAt: number | undefined;
  let lastCall: { name: string; args: any } | undefined;
  let steps = 0;
  for (const row of rows) {
    if (row.type === 'USER_INPUT') { turnStartedAt = time(row.created_at) || turnStartedAt; steps = 0; lastCall = undefined; }
    if (row.type === 'PLANNER_RESPONSE') {
      if (typeof row.content === 'string' && row.content.trim()) lastText = clip(row.content.replace(/<[^>]+>/g, ' '));
      const calls = Array.isArray(row.tool_calls) ? row.tool_calls : [];
      if (calls.length) { const c = calls.at(-1); lastCall = { name: String(c?.name || 'tool'), args: c?.args || {} }; steps += calls.length; }
      for (const c of calls) { const cwd = unwrap(c?.args?.Cwd); if (typeof cwd === 'string' && cwd.startsWith('/')) out.cwd = cwd; }
    }
  }
  const last = rows.at(-1);
  const age = Math.max(0, now - options.mtimeMs);
  const s = options.summary;
  const live: ChatLive = { state: 'idle', updatedAt: options.mtimeMs || undefined, turnStartedAt, lastText, steps: s?.stepCount || steps || undefined, via: s ? 'transcript+app-db' : 'transcript' };
  const runningInApp = !!s && (/RUNNING|BUSY|ACTIVE/i.test(s.status || '') || s.notFullyIdle === true) && !s.killed;
  const call = () => {
    if (!lastCall) return { step: 'Working', activity: 'working' };
    const described = describeTool(lastCall.name, lastCall.args);
    const action = arg(lastCall.args, 'toolAction');
    return lastCall.name === 'run_command' || !action ? described : { step: action, activity: described.activity };
  };
  if (!last) live.state = runningInApp ? 'working' : 'idle';
  else if (last.type === 'USER_INPUT') Object.assign(live, { state: 'working', step: 'Thinking', activity: 'thinking' });
  else if (last.type === 'PLANNER_RESPONSE' && Array.isArray(last.tool_calls) && last.tool_calls.length) {
    const c = call();
    Object.assign(live, { state: 'working', ...c, tool: lastCall?.name });
    if (/^(ask_question|ask_permission)$/.test(lastCall?.name || '')) {
      Object.assign(live, { state: 'waiting', activity: 'waiting', waitKind: lastCall?.name === 'ask_permission' ? 'approval' : 'question', waitingFor: question(lastCall?.args) || c.step });
    } else if (age > LIVE.waitingMs + 2_000 && /^(run_command|write_to_file|replace_file_content|multi_replace_file_content|read_url_content)$/.test(lastCall?.name || '') && !runningInApp) {
      Object.assign(live, { state: 'waiting', activity: 'waiting', waitKind: 'approval', waitingFor: `Approve: ${c.step.replace(/^Running: /, '')}`, via: 'transcript-heuristic' });
    }
  } else if (last.status === 'RUNNING') Object.assign(live, { state: 'working', ...call(), tool: lastCall?.name });
  else if (last.type === 'PLANNER_RESPONSE') live.state = runningInApp ? 'working' : 'done';
  else if (last.type === 'ERROR_MESSAGE') Object.assign(live, age < 60_000 || runningInApp ? { state: 'working', step: 'Retrying after a model error', activity: 'thinking' } : { state: 'failed', step: clip(last.error, 120) || 'The model request failed' });
  else Object.assign(live, { state: age < 60_000 || runningInApp ? 'working' : 'done', step: age < 60_000 || runningInApp ? 'Thinking' : undefined, activity: age < 60_000 || runningInApp ? 'thinking' : undefined });
  if (live.state === 'working' && runningInApp && !live.step) live.step = 'Working';
  if (live.state === 'working' && age > LIVE.staleMs && !runningInApp) Object.assign(live, { state: 'idle', step: 'No activity for 20+ min', activity: undefined, tool: undefined });
  if (s?.killed && live.state === 'working') Object.assign(live, { state: 'idle', step: 'Stopped' });
  return { ...out, live: prune(live) };
}
export function agyFirstPrompt(text: string): string | undefined {
  for (const row of parseJsonLines(text)) if (row?.type === 'USER_INPUT' && typeof row.content === 'string') return row.content;
  return undefined;
}
export function agyHeadCwd(text: string): string | undefined {
  for (const row of parseJsonLines(text)) for (const c of Array.isArray(row?.tool_calls) ? row.tool_calls : []) {
    const cwd = unwrap(c?.args?.Cwd);
    if (typeof cwd === 'string' && cwd.startsWith('/')) return cwd;
  }
  return undefined;
}

// ---------------------------------------------------------------------------
// OpenCode (~/.local/share/opencode/opencode.db, read-only)
// ---------------------------------------------------------------------------

export interface OpencodeMessage { data: any; time_created: number; time_updated: number; parts: any[] }
export function opencodeLive(messages: OpencodeMessage[], options: { updatedMs: number; now?: number; todos?: Array<{ content: string; status: string }> }): ChatLive {
  const now = options.now ?? Date.now();
  const age = Math.max(0, now - options.updatedMs);
  const live: ChatLive = { state: 'idle', updatedAt: options.updatedMs || undefined, via: 'app-db' };
  if (options.todos?.length) live.todos = options.todos.slice(0, 50).map(t => ({ text: clip(t.content, 160) || 'Task', state: mapTodoState(t.status) }));
  const lastUser = [...messages].reverse().find(m => m.data?.role === 'user');
  if (lastUser) live.turnStartedAt = lastUser.time_created;
  for (const m of messages) if (m.data?.role === 'assistant') {
    if (typeof m.data.modelID === 'string') live.model = m.data.modelID;
    const t = m.parts.filter(p => p?.type === 'text' && typeof p.text === 'string').map(p => p.text).join('');
    if (t.trim()) live.lastText = clip(t);
  }
  const last = messages.at(-1);
  if (!last) return live;
  if (last.data?.role === 'user') {
    Object.assign(live, age > LIVE.staleMs ? { state: 'idle', step: 'No activity for 20+ min' } : { state: 'working', step: 'Thinking', activity: 'thinking' });
    return prune(live);
  }
  if (last.data?.error) return prune(Object.assign(live, { state: 'failed', step: clip(last.data.error?.data?.message || last.data.error?.name || 'The last turn failed', 120) }));
  const finished = !!last.data?.time?.completed;
  const tool = [...last.parts].reverse().find(p => p?.type === 'tool' && ['running', 'pending'].includes(p.state?.status));
  if (!finished || tool) {
    if (tool) {
      const { step, activity } = describeTool(String(tool.tool || 'tool'), tool.state?.input);
      Object.assign(live, { state: 'working', step, activity, tool: tool.tool });
      if (tool.state?.status === 'pending' && age > LIVE.waitingMs) Object.assign(live, { state: 'waiting', activity: 'waiting', waitKind: 'approval', waitingFor: `Approve: ${step.replace(/^Running: /, '')}`, via: 'app-db-heuristic' });
    } else {
      const reasoning = last.parts.at(-1)?.type === 'reasoning';
      Object.assign(live, { state: 'working', step: reasoning ? 'Thinking' : 'Responding', activity: reasoning ? 'thinking' : 'responding' });
    }
    if (live.state === 'working' && age > LIVE.staleMs) Object.assign(live, { state: 'idle', step: 'No activity for 20+ min', activity: undefined, tool: undefined });
  } else live.state = 'done';
  return prune(live);
}

/** Freshness-only status for formats without turn markers (Cursor). */
export function freshnessLive(mtimeMs: number, now = Date.now(), lastText?: string): ChatLive {
  const working = now - mtimeMs < 30_000;
  return prune({ state: working ? 'working' : 'done', step: working ? 'Working' : undefined, activity: working ? 'working' : undefined, updatedAt: mtimeMs || undefined, lastText, via: 'transcript' });
}

function prune(live: ChatLive): ChatLive {
  for (const key of Object.keys(live) as (keyof ChatLive)[]) if (live[key] === undefined) delete live[key];
  return live;
}

/** Fields whose change is worth telling the phone about (not every token/mtime). */
export function liveSignature(live: ChatLive | undefined): string {
  if (!live) return '';
  const { updatedAt: _u, steps: _s, ...rest } = live;
  return JSON.stringify(rest);
}
