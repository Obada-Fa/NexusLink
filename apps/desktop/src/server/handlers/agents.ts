// Agent gateway: run AI coding agents (Claude Code, Cursor CLI, OpenCode,
// Antigravity) on the host and expose them to the phone as chat sessions with a
// normalized event stream — the phone renders a native chat UI, never a terminal.
//
// Each CLI gets an adapter that translates its stream-json output into
// AgentEvent records. Events are buffered per session (so a reconnecting
// phone can replay history via agent.history) and pushed live as
// `agent-event` WebSocket messages.

import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import type { AgentEvent, AgentInfo, AgentSessionInfo, WsMessage } from '@nexuslink/rpc-types';

type SpawnOpts = Parameters<typeof Bun.spawn>[1];
type Proc = ReturnType<typeof Bun.spawn>;

const HISTORY_CAP = 1000;

type BroadcastFn = (msg: WsMessage) => void;
let broadcast: BroadcastFn = () => {};

export function setAgentBroadcast(fn: BroadcastFn): void {
  broadcast = fn;
}

// ---------------------------------------------------------------------------
// Agent catalog
// ---------------------------------------------------------------------------

interface AgentDef {
  id: string;
  name: string;
  bin?: string;
  makeAdapter(session: AgentSession): AgentAdapter;
}

/** Extra dirs GUI/systemd launches often omit from PATH. */
function extraBinDirs(): string[] {
  const home = homedir();
  return [
    `${home}/.local/bin`,
    `${home}/.opencode/bin`,
    `${home}/.cursor/bin`,
    `${home}/.gemini/antigravity-cli`,
    `${home}/bin`,
    '/usr/local/bin',
  ];
}

export function resolveBin(bin: string): string | null {
  const seen = new Set<string>();
  for (const dir of [...(process.env.PATH ?? '').split(':'), ...extraBinDirs()]) {
    if (!dir || seen.has(dir)) continue;
    seen.add(dir);
    const p = `${dir}/${bin}`;
    if (existsSync(p)) return p;
  }
  return null;
}

function which(bin: string): string | null {
  return resolveBin(bin);
}

const AGENT_DEFS: AgentDef[] = [
  {
    id: 'claude',
    name: 'Claude Code',
    bin: 'claude',
    makeAdapter: (s) => new ClaudeAdapter(s),
  },
  {
    id: 'cursor',
    name: 'Cursor CLI',
    bin: 'cursor-agent',
    makeAdapter: (s) => new CursorAdapter(s),
  },
  {
    id: 'opencode',
    name: 'OpenCode',
    bin: 'opencode',
    makeAdapter: (s) => new OpenCodeAdapter(s),
  },
  {
    id: 'antigravity',
    name: 'Antigravity',
    bin: 'agy',
    makeAdapter: (s) => new AntigravityAdapter(s),
  },
  {
    id: 'mock',
    name: 'Demo Agent',
    makeAdapter: (s) => new MockAdapter(s),
  },
];

export function listAgents(): AgentInfo[] {
  return AGENT_DEFS.map((d) => ({
    id: d.id,
    name: d.name,
    available: d.bin ? which(d.bin) !== null : true,
  }));
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

interface AgentSession {
  info: AgentSessionInfo;
  history: AgentEvent[];
  adapter: AgentAdapter;
  seq: number;
  pendingPermissions: Map<string, (allow: boolean) => void>;
}

interface AgentAdapter {
  prompt(text: string): void;
  cancel(): void;
  close(): void;
  permission?(requestId: string, allow: boolean): void;
}

const agentSessions = new Map<string, AgentSession>();

function emit(session: AgentSession, event: Omit<AgentEvent, 'seq' | 'ts'>): void {
  const full: AgentEvent = { ...event, seq: ++session.seq, ts: Date.now() };
  session.history.push(full);
  if (session.history.length > HISTORY_CAP) session.history.splice(0, 100);
  broadcast({ type: 'agent-event', agentSessionId: session.info.agentSessionId, event: full });
}

function setBusy(session: AgentSession, busy: boolean): void {
  session.info.busy = busy;
}

export function createAgentSession(agentId: string, cwd?: string, title?: string): AgentSessionInfo {
  const def = AGENT_DEFS.find((d) => d.id === agentId);
  if (!def) throw new Error(`unknown agent: ${agentId}`);
  if (def.bin && !which(def.bin)) throw new Error(`${def.name} CLI not installed on the host`);

  const info: AgentSessionInfo = {
    agentSessionId: crypto.randomUUID(),
    agent: agentId,
    cwd: cwd || homedir(),
    title: title || def.name,
    createdAt: Date.now(),
    busy: false,
    status: 'running',
  };
  const session: AgentSession = {
    info, history: [], adapter: null as unknown as AgentAdapter, seq: 0,
    pendingPermissions: new Map(),
  };
  session.adapter = def.makeAdapter(session);
  agentSessions.set(info.agentSessionId, session);
  return { ...info };
}

export function listAgentSessions(): AgentSessionInfo[] {
  return [...agentSessions.values()].map((s) => ({ ...s.info }));
}

export function agentHistory(agentSessionId: string): AgentEvent[] {
  return agentSessions.get(agentSessionId)?.history.slice() ?? [];
}

export function promptAgent(agentSessionId: string, text: string): { ok: boolean } {
  const session = agentSessions.get(agentSessionId);
  if (!session || session.info.status !== 'running' || !text.trim()) return { ok: false };
  const key = parseEnvApiKey(text, ['CURSOR_API_KEY', 'GEMINI_API_KEY', 'GOOGLE_API_KEY']);
  emit(session, { kind: 'user', text: key ? `${key.name}=••••` : text });
  setBusy(session, true);
  session.adapter.prompt(text);
  return { ok: true };
}

export function cancelAgent(agentSessionId: string): { ok: boolean } {
  const session = agentSessions.get(agentSessionId);
  if (!session) return { ok: false };
  session.adapter.cancel();
  setBusy(session, false);
  emit(session, { kind: 'status', text: 'cancelled' });
  return { ok: true };
}

export function closeAgentSession(agentSessionId: string): { ok: boolean } {
  const session = agentSessions.get(agentSessionId);
  if (!session) return { ok: false };
  session.adapter.close();
  session.info.status = 'exited';
  agentSessions.delete(agentSessionId);
  return { ok: true };
}

/** ACP-shaped session/request_permission response from the phone. */
export function resolveAgentPermission(
  agentSessionId: string,
  requestId: string,
  allow: boolean,
): { ok: boolean } {
  const session = agentSessions.get(agentSessionId);
  if (!session) return { ok: false };
  const pending = session.pendingPermissions.get(requestId);
  if (pending) {
    session.pendingPermissions.delete(requestId);
    pending(allow);
    return { ok: true };
  }
  session.adapter.permission?.(requestId, allow);
  return { ok: true };
}

// ---------------------------------------------------------------------------
// Shared stream-json plumbing
// ---------------------------------------------------------------------------

async function pumpJsonLines(proc: Proc, onLine: (msg: Record<string, unknown>) => void): Promise<void> {
  const reader = (proc.stdout as unknown as ReadableStream<Uint8Array>).getReader();
  const decoder = new TextDecoder();
  let buf = '';
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      let nl: number;
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (!line) continue;
        try {
          onLine(JSON.parse(line));
        } catch {
          // non-JSON noise (progress spinners etc.)
        }
      }
    }
  } finally {
    reader.releaseLock();
  }
}

function contentToText(content: unknown): string {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .map((p) => {
        if (typeof p === 'string') return p;
        const part = p as Record<string, unknown>;
        if (typeof part.text === 'string') return part.text;
        return '';
      })
      .join('');
  }
  return '';
}

type AgentDelta = Omit<AgentEvent, 'seq' | 'ts'>;

async function collectText(stream: unknown): Promise<string> {
  if (!stream || typeof stream !== 'object' || !('getReader' in stream)) return '';
  const reader = (stream as ReadableStream<Uint8Array>).getReader();
  const decoder = new TextDecoder();
  let out = '';
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      out += decoder.decode(value, { stream: true });
    }
    out += decoder.decode();
  } finally {
    reader.releaseLock();
  }
  return out.replace(/\x1b\[[0-9;]*m/g, '').trim();
}

/** When a CLI dies without a result event, turn stderr into a phone-visible error. */
export function finishCliTurn(opts: {
  sawResult: boolean;
  exitCode: number | null;
  stderr: string;
}): AgentDelta | null {
  if (opts.sawResult) return null;
  const err = opts.stderr.trim();
  if (err) return { kind: 'error', text: err };
  return {
    kind: 'error',
    text: `Agent CLI exited without a reply (code ${opts.exitCode ?? '?'})`,
  };
}

export function sessionIdFromEvent(msg: Record<string, unknown>): string | undefined {
  for (const key of [
    'chatId', 'chat_id', 'sessionId', 'session_id', 'sessionID',
    'conversation_id', 'conversationId',
  ]) {
    if (typeof msg[key] === 'string' && msg[key]) return msg[key] as string;
  }
  const nested = [msg.step_update, msg.result, msg.init];
  for (const raw of nested) {
    if (!raw || typeof raw !== 'object') continue;
    const inner = sessionIdFromEvent(raw as Record<string, unknown>);
    if (inner) return inner;
  }
  return undefined;
}

/** Chat text that should run the CLI's login subcommand, not a model prompt. */
export function looksLikeAgentLogin(text: string): boolean {
  const t = text.trim().toLowerCase().replace(/^\/+/, '');
  return (
    t === 'login' ||
    t === 'agent login' ||
    t === 'auth login' ||
    t === 'agy login' ||
    t === 'agy auth login' ||
    t === 'cursor-agent login'
  );
}

export function parseEnvApiKey(text: string, names: string[]): { name: string; value: string } | undefined {
  const trimmed = text.trim().replace(/^export\s+/i, '');
  for (const name of names) {
    const m = trimmed.match(new RegExp(`^${name}\\s*=\\s*(\\S+)`, 'i'));
    if (m?.[1]) return { name, value: m[1] };
  }
  return undefined;
}

export function extractAuthUrl(text: string): string | undefined {
  const m = text.match(/https?:\/\/[^\s"'<>\\]+/i);
  if (!m) return undefined;
  return m[0].replace(/[.,;:)\\]+$/, '');
}

export function isCliAuthError(text: string): boolean {
  return /authentication required|not authenticated|not logged in|please run ['`]?agent login/i.test(text);
}

export function rewriteCliAuthError(stderr: string, agentName: string): string {
  if (agentName === 'Cursor CLI') {
    return [
      "Cursor CLI isn't signed in on the PC.",
      'Send **login** in this chat to open a sign-in link, or paste `CURSOR_API_KEY=…` from https://cursor.com/dashboard/api',
    ].join('\n\n');
  }
  if (agentName === 'Antigravity') {
    return [
      "Antigravity isn't signed in on the PC.",
      'Run `agy` once on the PC to sign in, or paste `GEMINI_API_KEY=…` here.',
    ].join('\n\n');
  }
  return stderr.trim();
}

/** Cursor CLI nests tools as `{ readToolCall: { args, result } }` rather than `{ name, args }`. */
export function describeCursorToolCall(toolCall: unknown): {
  name: string;
  args: unknown;
  result: unknown;
} {
  if (!toolCall || typeof toolCall !== 'object') {
    return { name: 'tool', args: {}, result: {} };
  }
  const obj = toolCall as Record<string, unknown>;
  for (const [key, raw] of Object.entries(obj)) {
    if (!raw || typeof raw !== 'object') continue;
    const inner = raw as Record<string, unknown>;
    if (key === 'function') {
      return {
        name: String(inner.name ?? 'function'),
        args: inner.arguments ?? inner.args ?? {},
        result: inner.result ?? {},
      };
    }
    const name = key.replace(/ToolCall$/, '') || 'tool';
    return { name, args: inner.args ?? inner, result: inner.result ?? {} };
  }
  return {
    name: String(obj.name ?? 'tool'),
    args: obj.args ?? obj,
    result: obj.result ?? {},
  };
}

export function parseCursorStreamEvent(msg: Record<string, unknown>): AgentDelta[] {
  const type = msg.type;
  if (type === 'assistant') {
    const message = msg.message as Record<string, unknown> | undefined;
    const text = contentToText(message?.content);
    if (text.trim()) return [{ kind: 'text', text }];
    return [];
  }
  if (type === 'tool_call') {
    const meta = describeCursorToolCall(msg.tool_call ?? msg);
    const refId = String(msg.call_id ?? msg.id ?? '');
    if (msg.subtype === 'started') {
      return [{
        kind: 'tool-start',
        toolName: meta.name,
        toolInput: JSON.stringify(meta.args, null, 2).slice(0, 4000),
        refId,
      }];
    }
    if (msg.subtype === 'completed') {
      return [{
        kind: 'tool-end',
        toolName: meta.name,
        refId,
        toolOutput: JSON.stringify(meta.result, null, 2).slice(0, 4000),
      }];
    }
    return [];
  }
  if (type === 'result') {
    const text = typeof msg.result === 'string' ? msg.result : '';
    if (msg.is_error === true || msg.subtype === 'error') {
      return [{ kind: 'error', text: text || 'Cursor CLI reported an error' }];
    }
    return [{ kind: 'result', text }];
  }
  if (type === 'system' && msg.subtype === 'init') {
    return [];
  }
  return [];
}

export function parseOpencodeStreamEvent(msg: Record<string, unknown>): AgentDelta[] {
  const type = msg.type;
  const part = (msg.part as Record<string, unknown> | undefined) ?? {};
  if (type === 'text' || part.type === 'text') {
    const text = typeof part.text === 'string' ? part.text : typeof msg.text === 'string' ? msg.text : '';
    if (text.trim()) return [{ kind: 'text', text }];
    return [];
  }
  if (type === 'tool_use') {
    const state = (part.state as Record<string, unknown> | undefined) ?? {};
    const status = String(state.status ?? 'completed');
    const refId = String(part.callID ?? part.id ?? '');
    const name = String(part.tool ?? part.name ?? 'tool');
    const input = JSON.stringify(state.input ?? part.input ?? {}, null, 2).slice(0, 4000);
    const output = typeof state.output === 'string'
      ? state.output.slice(0, 4000)
      : JSON.stringify(state.output ?? {}, null, 2).slice(0, 4000);
    if (status === 'pending' || status === 'running') {
      return [{ kind: 'tool-start', toolName: name, toolInput: input, refId }];
    }
    return [
      { kind: 'tool-start', toolName: name, toolInput: input, refId },
      { kind: 'tool-end', toolName: name, toolOutput: output, refId },
    ];
  }
  if (type === 'step_start') {
    return [];
  }
  if (type === 'step_finish') {
    return [{ kind: 'result', text: '' }];
  }
  if (type === 'error') {
    const text =
      (typeof msg.error === 'string' && msg.error) ||
      (typeof part.message === 'string' && part.message) ||
      (typeof msg.message === 'string' && msg.message) ||
      JSON.stringify(msg.error ?? part ?? msg);
    return [{ kind: 'error', text }];
  }
  return [];
}

export function parseAgyStreamEvent(msg: Record<string, unknown>): AgentDelta[] {
  const event = String(msg.event ?? msg.type ?? '');
  if (event === 'init') return [];
  if (event === 'step_update') {
    const step = (msg.step_update as Record<string, unknown> | undefined) ?? {};
    const stepType = String(step.step_type ?? '');
    const state = String(step.state ?? '');
    if (stepType === 'agent_response') {
      const text = typeof step.text_delta === 'string' ? step.text_delta : '';
      if (text) return [{ kind: 'text-delta', text }];
      return [];
    }
    if (stepType === 'tool') {
      const info = (step.tool_info as Record<string, unknown> | undefined) ?? {};
      const name = String(step.tool_name ?? info.name ?? 'tool');
      const refId = String(step.step_index ?? info.name ?? name);
      const input = JSON.stringify(info.parameters ?? {}, null, 2).slice(0, 4000);
      const output = typeof info.output === 'string'
        ? info.output.slice(0, 4000)
        : JSON.stringify(info.output ?? {}, null, 2).slice(0, 4000);
      if (state === 'ACTIVE') {
        return [{ kind: 'tool-start', toolName: name, toolInput: input, refId }];
      }
      return [{ kind: 'tool-end', toolName: name, toolOutput: output, refId }];
    }
    return [];
  }
  if (event === 'result') {
    const result = (msg.result as Record<string, unknown> | undefined) ?? msg;
    const status = String(result.status ?? '');
    const response = typeof result.response === 'string' ? result.response : '';
    const error = typeof result.error === 'string' ? result.error : '';
    if (status === 'ERROR' || (error && status !== 'SUCCESS')) {
      return [{ kind: 'error', text: error || 'Antigravity reported an error' }];
    }
    return [{ kind: 'result', text: response }];
  }
  return [];
}

function hostEnv(extra?: Record<string, string>): Record<string, string> {
  return { ...(process.env as Record<string, string>), ...extra };
}

function spawnJsonCli(
  argv: string[],
  cwd: string,
  onEvent: (msg: Record<string, unknown>) => void,
  extraEnv?: Record<string, string>,
): { proc: Proc; stderr: Promise<string> } {
  const proc = Bun.spawn(argv, {
    cwd,
    stdin: 'ignore',
    stdout: 'pipe',
    stderr: 'pipe',
    env: hostEnv(extraEnv),
  } as unknown as SpawnOpts);
  void pumpJsonLines(proc, onEvent).catch(() => {});
  return { proc, stderr: collectText(proc.stderr) };
}

async function pumpTextStream(
  stream: unknown,
  onChunk: (chunk: string) => void,
): Promise<string> {
  if (!stream || typeof stream !== 'object' || !('getReader' in stream)) return '';
  const reader = (stream as ReadableStream<Uint8Array>).getReader();
  const decoder = new TextDecoder();
  let out = '';
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      const chunk = decoder.decode(value, { stream: true });
      out += chunk;
      if (chunk) onChunk(chunk);
    }
    const tail = decoder.decode();
    if (tail) {
      out += tail;
      onChunk(tail);
    }
  } finally {
    reader.releaseLock();
  }
  return out.replace(/\x1b\[[0-9;]*m/g, '');
}

function openUrlOnHost(url: string): void {
  try {
    Bun.spawn([resolveBin('xdg-open') ?? 'xdg-open', url], {
      stdin: 'ignore',
      stdout: 'ignore',
      stderr: 'ignore',
      env: hostEnv({ DISPLAY: process.env.DISPLAY || ':0' }),
    } as unknown as SpawnOpts);
  } catch {
    // Phone still gets the URL in chat.
  }
}

// ---------------------------------------------------------------------------
// Claude Code adapter — persistent `claude --print` with stream-json in/out.
// ---------------------------------------------------------------------------

class ClaudeAdapter implements AgentAdapter {
  private proc: Proc | null = null;

  constructor(private session: AgentSession) {}

  private ensureProc(): Proc {
    if (this.proc && this.proc.exitCode === null && !this.proc.killed) return this.proc;
    const bin = resolveBin('claude') ?? 'claude';
    this.proc = Bun.spawn(
      [
        bin, '--print',
        '--input-format', 'stream-json',
        '--output-format', 'stream-json',
        '--verbose',
        '--permission-mode', 'acceptEdits',
      ],
      {
        cwd: this.session.info.cwd,
        stdin: 'pipe',
        stdout: 'pipe',
        stderr: 'pipe',
        env: process.env as Record<string, string>,
      } as unknown as SpawnOpts,
    );
    const stderrP = collectText(this.proc.stderr);
    void pumpJsonLines(this.proc, (msg) => this.onEvent(msg)).catch(() => {});
    const spawned = this.proc;
    spawned.exited.then(async (code) => {
      if (this.proc !== spawned) return;
      const stderr = await stderrP.catch(() => '');
      if (this.session.info.busy) {
        setBusy(this.session, false);
        emit(this.session, finishCliTurn({
          sawResult: false,
          exitCode: code,
          stderr: stderr || 'Claude Code process exited',
        })!);
      }
      this.proc = null;
    }).catch(() => {});
    return this.proc;
  }

  private onEvent(msg: Record<string, unknown>): void {
    const s = this.session;
    const type = msg.type;
    if (type === 'assistant') {
      const message = msg.message as Record<string, unknown> | undefined;
      const content = message?.content;
      if (Array.isArray(content)) {
        for (const raw of content) {
          const part = raw as Record<string, unknown>;
          if (part.type === 'text' && typeof part.text === 'string' && part.text.trim()) {
            emit(s, { kind: 'text', text: part.text });
          } else if (part.type === 'thinking' && typeof part.thinking === 'string') {
            emit(s, { kind: 'thinking', text: part.thinking });
          } else if (part.type === 'tool_use') {
            emit(s, {
              kind: 'tool-start',
              toolName: String(part.name ?? 'tool'),
              toolInput: JSON.stringify(part.input ?? {}, null, 2),
              refId: String(part.id ?? ''),
            });
          }
        }
      }
    } else if (type === 'user') {
      // Tool results come back as user messages in the transcript stream.
      const message = msg.message as Record<string, unknown> | undefined;
      const content = message?.content;
      if (Array.isArray(content)) {
        for (const raw of content) {
          const part = raw as Record<string, unknown>;
          if (part.type === 'tool_result') {
            emit(s, {
              kind: 'tool-end',
              refId: String(part.tool_use_id ?? ''),
              toolOutput: contentToText(part.content).slice(0, 4000),
            });
          }
        }
      }
    } else if (type === 'result') {
      setBusy(s, false);
      emit(s, {
        kind: 'result',
        text: typeof msg.result === 'string' ? msg.result : '',
      });
    } else if (type === 'system' && msg.subtype === 'init') {
      emit(s, { kind: 'status', text: 'ready' });
    } else if (type === 'control_request' || msg.subtype === 'can_use_tool') {
      const requestId = String(msg.request_id ?? msg.id ?? crypto.randomUUID());
      const tool = (msg.request as Record<string, unknown> | undefined) ?? msg;
      emit(s, {
        kind: 'permission-request',
        refId: requestId,
        toolName: String(tool.tool_name ?? tool.name ?? 'tool'),
        toolInput: JSON.stringify(tool.input ?? tool.tool_input ?? {}, null, 2),
        text: `Allow ${String(tool.tool_name ?? tool.name ?? 'this tool')}?`,
      });
      s.pendingPermissions.set(requestId, (allow) => {
        try {
          const stdin = this.proc?.stdin as unknown as { write(s: string): unknown; flush?: () => void } | undefined;
          stdin?.write(JSON.stringify({
            type: 'control_response',
            request_id: requestId,
            response: { allowed: allow },
          }) + '\n');
          stdin?.flush?.();
        } catch {
          emit(s, { kind: 'error', text: 'failed to send permission response' });
        }
      });
    }
  }

  prompt(text: string): void {
    const proc = this.ensureProc();
    const line = JSON.stringify({
      type: 'user',
      message: { role: 'user', content: [{ type: 'text', text }] },
    });
    try {
      const stdin = proc.stdin as unknown as { write(s: string): unknown; flush?: () => void };
      stdin.write(line + '\n');
      stdin.flush?.();
    } catch {
      setBusy(this.session, false);
      emit(this.session, { kind: 'error', text: 'failed to reach the Claude Code process' });
    }
  }

  cancel(): void {
    // Claude Code has no in-band cancel on stream-json stdin; drop the process.
    try {
      this.proc?.kill();
    } catch {
      // already gone
    }
    this.proc = null;
  }

  close(): void {
    this.cancel();
  }
}

// ---------------------------------------------------------------------------
// Cursor CLI adapter — one `cursor-agent --print` process per prompt, chained
// with --resume for multi-turn conversations.
// ---------------------------------------------------------------------------

class CursorAdapter implements AgentAdapter {
  private proc: Proc | null = null;
  private chatId: string | null = null;
  private sawResult = false;
  private apiKey = process.env.CURSOR_API_KEY || '';
  private loggingIn = false;
  private autoLoginAttempted = false;
  private loginTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(private session: AgentSession) {}

  private extraEnv(): Record<string, string> {
    const env: Record<string, string> = {};
    if (this.apiKey) env.CURSOR_API_KEY = this.apiKey;
    return env;
  }

  prompt(text: string): void {
    const key = parseEnvApiKey(text, ['CURSOR_API_KEY']);
    if (key) {
      this.apiKey = key.value;
      this.cancel();
      setBusy(this.session, false);
      emit(this.session, {
        kind: 'status',
        text: 'Saved CURSOR_API_KEY for this chat. Send your task again.',
      });
      return;
    }
    if (looksLikeAgentLogin(text)) {
      this.startLogin();
      return;
    }
    this.runPrompt(text);
  }

  private runPrompt(text: string): void {
    this.cancel();
    this.sawResult = false;
    const bin = resolveBin('cursor-agent') ?? 'cursor-agent';
    const argv = [
      bin, '--print', '--output-format', 'stream-json',
      '--trust', '--force',
      '--workspace', this.session.info.cwd,
    ];
    if (this.chatId) argv.push('--resume', this.chatId);
    argv.push(text);
    const { proc, stderr } = spawnJsonCli(
      argv,
      this.session.info.cwd,
      (msg) => this.onEvent(msg),
      this.extraEnv(),
    );
    this.proc = proc;
    proc.exited.then(async (code) => {
      if (this.proc !== proc) return;
      const errText = await stderr.catch(() => '');
      if (!this.session.info.busy) return;
      setBusy(this.session, false);
      const fail = finishCliTurn({
        sawResult: this.sawResult,
        exitCode: code,
        stderr: errText,
      });
      if (!fail) return;
      if (isCliAuthError(fail.text ?? '')) {
        emit(this.session, {
          kind: 'error',
          text: rewriteCliAuthError(fail.text ?? '', 'Cursor CLI'),
        });
        if (!this.autoLoginAttempted) {
          this.autoLoginAttempted = true;
          this.startLogin();
        }
        return;
      }
      emit(this.session, fail);
    }).catch(() => {});
  }

  private startLogin(): void {
    if (this.loggingIn && this.proc && this.proc.exitCode === null) {
      setBusy(this.session, false);
      emit(this.session, {
        kind: 'status',
        text: 'Sign-in is already waiting — open the link above, or paste `CURSOR_API_KEY=…`.',
      });
      return;
    }
    this.cancel();
    this.loggingIn = true;
    setBusy(this.session, true);
    const bin = resolveBin('cursor-agent') ?? 'cursor-agent';
    const proc = Bun.spawn([bin, 'login'], {
      cwd: this.session.info.cwd,
      stdin: 'ignore',
      stdout: 'pipe',
      stderr: 'pipe',
      env: hostEnv({
        NO_OPEN_BROWSER: '1',
        DISPLAY: process.env.DISPLAY || ':0',
        ...this.extraEnv(),
      }),
    } as unknown as SpawnOpts);
    this.proc = proc;
    emit(this.session, { kind: 'status', text: 'Starting Cursor sign-in on the PC…' });

    let combined = '';
    let urlEmitted = false;
    const onChunk = (chunk: string) => {
      combined += chunk;
      if (urlEmitted) return;
      const url = extractAuthUrl(combined);
      if (!url) return;
      urlEmitted = true;
      openUrlOnHost(url);
      setBusy(this.session, false);
      emit(this.session, {
        kind: 'text',
        text: [
          'Open this link to sign in (a browser may also open on the PC):',
          '',
          url,
          '',
          'Or paste a key from https://cursor.com/dashboard/api as `CURSOR_API_KEY=…`.',
        ].join('\n'),
      });
    };

    this.loginTimer = setTimeout(() => {
      try { proc.kill(); } catch { /* already gone */ }
    }, 5 * 60 * 1000);

    void Promise.all([
      pumpTextStream(proc.stdout, onChunk),
      pumpTextStream(proc.stderr, onChunk),
      proc.exited,
    ]).then(([, , code]) => {
      if (this.proc !== proc) return;
      this.loggingIn = false;
      if (this.loginTimer) {
        clearTimeout(this.loginTimer);
        this.loginTimer = null;
      }
      setBusy(this.session, false);
      if (code === 0) {
        this.autoLoginAttempted = false;
        emit(this.session, {
          kind: 'result',
          text: 'Signed in to Cursor CLI. Send your task again.',
        });
      } else if (!urlEmitted) {
        emit(this.session, {
          kind: 'error',
          text: rewriteCliAuthError(combined || 'login failed', 'Cursor CLI'),
        });
      }
    }).catch(() => {
      this.loggingIn = false;
      setBusy(this.session, false);
    });
  }

  private onEvent(msg: Record<string, unknown>): void {
    const sid = sessionIdFromEvent(msg);
    if (sid) this.chatId = sid;
    const events = parseCursorStreamEvent(msg);
    for (const ev of events) {
      if (ev.kind === 'result' || ev.kind === 'error') {
        this.sawResult = true;
        setBusy(this.session, false);
      }
      emit(this.session, ev);
    }
  }

  cancel(): void {
    if (this.loginTimer) {
      clearTimeout(this.loginTimer);
      this.loginTimer = null;
    }
    this.loggingIn = false;
    try {
      this.proc?.kill();
    } catch {
      // already gone
    }
    this.proc = null;
  }

  close(): void {
    this.cancel();
  }
}

// ---------------------------------------------------------------------------
// OpenCode adapter — `opencode run --format json` per prompt, resumed with
// --session. JSONL events are step_start / text / tool_use / step_finish.
// ---------------------------------------------------------------------------

class OpenCodeAdapter implements AgentAdapter {
  private proc: Proc | null = null;
  private ocSession: string | null = null;
  private sawResult = false;

  constructor(private session: AgentSession) {}

  prompt(text: string): void {
    this.cancel();
    this.sawResult = false;
    const bin = resolveBin('opencode') ?? 'opencode';
    const argv = [
      bin, 'run', '--format', 'json', '--auto',
      '--dir', this.session.info.cwd,
    ];
    if (this.ocSession) argv.push('--session', this.ocSession);
    argv.push(text);
    const { proc, stderr } = spawnJsonCli(argv, this.session.info.cwd, (msg) => this.onEvent(msg));
    this.proc = proc;
    proc.exited.then(async (code) => {
      if (this.proc !== proc) return;
      const errText = await stderr.catch(() => '');
      if (this.session.info.busy) {
        setBusy(this.session, false);
        const fail = finishCliTurn({
          sawResult: this.sawResult,
          exitCode: code,
          stderr: errText,
        });
        if (fail) emit(this.session, fail);
      }
    }).catch(() => {});
  }

  private onEvent(msg: Record<string, unknown>): void {
    const sid = sessionIdFromEvent(msg);
    if (sid) this.ocSession = sid;
    const events = parseOpencodeStreamEvent(msg);
    for (const ev of events) {
      if (ev.kind === 'result' || ev.kind === 'error') {
        this.sawResult = true;
        setBusy(this.session, false);
      }
      emit(this.session, ev);
    }
  }

  cancel(): void {
    try {
      this.proc?.kill();
    } catch {
      // already gone
    }
    this.proc = null;
  }

  close(): void {
    this.cancel();
  }
}

// ---------------------------------------------------------------------------
// Antigravity adapter — `agy -p` with stream-json, resumed via --conversation.
// ---------------------------------------------------------------------------

class AntigravityAdapter implements AgentAdapter {
  private proc: Proc | null = null;
  private conversationId: string | null = null;
  private sawResult = false;
  private streamedText = false;
  private apiKey = process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY || '';

  constructor(private session: AgentSession) {}

  private extraEnv(): Record<string, string> {
    const env: Record<string, string> = {};
    if (this.apiKey) {
      env.GEMINI_API_KEY = this.apiKey;
      env.GOOGLE_API_KEY = this.apiKey;
    }
    return env;
  }

  prompt(text: string): void {
    const key = parseEnvApiKey(text, ['GEMINI_API_KEY', 'GOOGLE_API_KEY']);
    if (key) {
      this.apiKey = key.value;
      this.cancel();
      setBusy(this.session, false);
      emit(this.session, {
        kind: 'status',
        text: `Saved ${key.name} for this chat. Send your task again.`,
      });
      return;
    }
    if (looksLikeAgentLogin(text)) {
      setBusy(this.session, false);
      emit(this.session, {
        kind: 'text',
        text: [
          'Antigravity has no headless login command.',
          'Run `agy` once in a terminal on the PC to sign in, or paste `GEMINI_API_KEY=…` here.',
        ].join('\n\n'),
      });
      return;
    }
    this.cancel();
    this.sawResult = false;
    this.streamedText = false;
    const bin = resolveBin('agy') ?? 'agy';
    const argv = [
      bin,
      '--output-format', 'stream-json',
      '--dangerously-skip-permissions',
      '--print-timeout', '15m',
    ];
    if (this.conversationId) argv.push('--conversation', this.conversationId);
    argv.push('-p', text);
    const { proc, stderr } = spawnJsonCli(
      argv,
      this.session.info.cwd,
      (msg) => this.onEvent(msg),
      this.extraEnv(),
    );
    this.proc = proc;
    proc.exited.then(async (code) => {
      if (this.proc !== proc) return;
      const errText = await stderr.catch(() => '');
      if (!this.session.info.busy) return;
      setBusy(this.session, false);
      const fail = finishCliTurn({
        sawResult: this.sawResult,
        exitCode: code,
        stderr: errText,
      });
      if (!fail) return;
      emit(this.session, isCliAuthError(fail.text ?? '')
        ? { kind: 'error', text: rewriteCliAuthError(fail.text ?? '', 'Antigravity') }
        : fail);
    }).catch(() => {});
  }

  private onEvent(msg: Record<string, unknown>): void {
    const sid = sessionIdFromEvent(msg);
    if (sid) this.conversationId = sid;
    const events = parseAgyStreamEvent(msg);
    for (const ev of events) {
      if (ev.kind === 'text' || ev.kind === 'text-delta') this.streamedText = true;
      if (ev.kind === 'result' || ev.kind === 'error') {
        this.sawResult = true;
        setBusy(this.session, false);
      }
      if (ev.kind === 'result' && this.streamedText) {
        emit(this.session, { kind: 'result', text: '' });
        continue;
      }
      emit(this.session, ev);
    }
  }

  cancel(): void {
    try {
      this.proc?.kill();
    } catch {
      // already gone
    }
    this.proc = null;
  }

  close(): void {
    this.cancel();
  }
}

// ---------------------------------------------------------------------------
// Mock adapter — deterministic canned conversation for tests and demos, so the
// whole gateway → WS → phone chat pipeline can be exercised without any CLI.
// ---------------------------------------------------------------------------

class MockAdapter implements AgentAdapter {
  private timers: ReturnType<typeof setTimeout>[] = [];

  constructor(private session: AgentSession) {}

  prompt(text: string): void {
    const s = this.session;
    const at = (ms: number, fn: () => void) => this.timers.push(setTimeout(fn, ms));
    at(150, () => emit(s, { kind: 'thinking', text: 'Looking at the request…' }));
    at(400, () =>
      emit(s, {
        kind: 'tool-start',
        toolName: 'Shell',
        toolInput: JSON.stringify({ command: 'echo demo' }, null, 2),
        refId: 'mock-1',
      }));
    at(500, () => {
      emit(s, {
        kind: 'permission-request',
        refId: 'mock-perm',
        toolName: 'Shell',
        toolInput: JSON.stringify({ command: 'echo demo' }, null, 2),
        text: 'Allow the demo agent to run `echo demo`?',
      });
      s.pendingPermissions.set('mock-perm', (allow) => {
        if (!allow) {
          emit(s, { kind: 'error', text: 'Permission denied' });
          setBusy(s, false);
          emit(s, { kind: 'result', text: '' });
          return;
        }
        emit(s, { kind: 'tool-end', refId: 'mock-1', toolOutput: 'demo\n' });
        emit(s, {
          kind: 'text',
          text: `You said: "${text}"\n\nThis is the **demo agent** — install Claude Code, Cursor CLI, OpenCode, or Antigravity on the PC to chat with a real agent here.\n\n\`\`\`diff\n--- a/README.md\n+++ b/README.md\n@@ -1,3 +1,4 @@\n # NexusLink\n+Phone OS for your PC\n\`\`\``,
        });
        setBusy(s, false);
        emit(s, { kind: 'result', text: '' });
      });
    });
  }

  cancel(): void {
    this.timers.forEach(clearTimeout);
    this.timers = [];
  }

  close(): void {
    this.cancel();
  }
}
