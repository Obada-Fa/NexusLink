// Agent gateway: run AI coding agents (Claude Code, Cursor CLI, OpenCode) on the host
// and expose them to the phone as chat sessions with a normalized event
// stream — the phone renders a native chat UI, never a terminal.
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
  return [`${home}/.local/bin`, `${home}/.opencode/bin`, `${home}/bin`, '/usr/local/bin'];
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
  emit(session, { kind: 'user', text });
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
  for (const key of ['chatId', 'chat_id', 'sessionId', 'session_id', 'sessionID']) {
    if (typeof msg[key] === 'string' && msg[key]) return msg[key] as string;
  }
  return undefined;
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

function spawnJsonCli(
  argv: string[],
  cwd: string,
  onEvent: (msg: Record<string, unknown>) => void,
): { proc: Proc; stderr: Promise<string> } {
  const proc = Bun.spawn(argv, {
    cwd,
    stdin: 'ignore',
    stdout: 'pipe',
    stderr: 'pipe',
    env: process.env as Record<string, string>,
  } as unknown as SpawnOpts);
  void pumpJsonLines(proc, onEvent).catch(() => {});
  return { proc, stderr: collectText(proc.stderr) };
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

  constructor(private session: AgentSession) {}

  prompt(text: string): void {
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
          text: `You said: "${text}"\n\nThis is the **demo agent** — install Claude Code, Cursor CLI, or OpenCode on the PC to chat with a real agent here.\n\n\`\`\`diff\n--- a/README.md\n+++ b/README.md\n@@ -1,3 +1,4 @@\n # NexusLink\n+Phone OS for your PC\n\`\`\``,
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
