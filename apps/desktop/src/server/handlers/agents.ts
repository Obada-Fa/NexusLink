// Agent gateway: run AI coding agents (Claude Code, Cursor CLI) on the host
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
  /** Candidate binaries, first match on PATH (plus well-known install dirs) wins. */
  bins?: string[];
  makeAdapter(session: AgentSession, bin?: string): AgentAdapter;
}

function extraBinDirs(): string[] {
  const home = homedir();
  return [
    `${home}/.local/bin`,
    `${home}/.cursor/bin`,
    `${home}/.cursor/cli`,
    '/usr/local/bin',
    '/opt/cursor/bin',
  ];
}

export function which(bin: string): string | null {
  const dirs = [...(process.env.PATH ?? '').split(':'), ...extraBinDirs()];
  const seen = new Set<string>();
  for (const dir of dirs) {
    if (!dir || seen.has(dir)) continue;
    seen.add(dir);
    const p = `${dir}/${bin}`;
    if (existsSync(p)) return p;
  }
  return null;
}

export function resolveAgentBin(bins: string[]): string | null {
  for (const bin of bins) {
    const found = which(bin);
    if (found) return found;
  }
  return null;
}

function spawnEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (typeof v === 'string') env[k] = v;
  }
  env.PATH = `${extraBinDirs().join(':')}:${env.PATH ?? ''}`;
  return env;
}

const AGENT_DEFS: AgentDef[] = [
  {
    id: 'claude',
    name: 'Claude Code',
    bins: ['claude'],
    makeAdapter: (s, bin) => new ClaudeAdapter(s, bin ?? 'claude'),
  },
  {
    id: 'cursor',
    name: 'Cursor CLI',
    bins: ['cursor-agent', 'agent'],
    makeAdapter: (s, bin) => new CursorAdapter(s, bin ?? 'cursor-agent'),
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
    available: d.bins ? resolveAgentBin(d.bins) !== null : true,
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
  const bin = def.bins ? resolveAgentBin(def.bins) : undefined;
  if (def.bins && !bin) throw new Error(`${def.name} CLI not installed on the host`);

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
  session.adapter = def.makeAdapter(session, bin ?? undefined);
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
    const tail = buf.trim();
    if (tail) {
      try {
        onLine(JSON.parse(tail));
      } catch {
        // leftover non-JSON
      }
    }
  } finally {
    reader.releaseLock();
  }
}

async function collectStream(stream: ReadableStream<Uint8Array> | undefined): Promise<string> {
  if (!stream) return '';
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let out = '';
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      out += decoder.decode(value, { stream: true });
    }
  } finally {
    reader.releaseLock();
  }
  return out.trim();
}

/** Nested Cursor CLI tool_call payload → a display name + args/result. */
export function parseCursorToolCall(msg: Record<string, unknown>): {
  name: string;
  args: unknown;
  result: unknown;
} {
  const nested = msg.tool_call;
  if (nested && typeof nested === 'object') {
    const rec = nested as Record<string, unknown>;
    if (typeof rec.name === 'string') {
      return { name: rec.name, args: rec.args ?? rec.arguments ?? rec, result: rec.result };
    }
    const entries = Object.entries(rec);
    if (entries.length) {
      const [key, val] = entries[0]!;
      const body = val && typeof val === 'object' ? (val as Record<string, unknown>) : {};
      const name =
        key === 'function' && typeof body.name === 'string'
          ? body.name
          : key.replace(/ToolCall$/, '') || 'tool';
      return { name, args: body.args ?? body.arguments ?? body, result: body.result };
    }
  }
  return {
    name: String(msg.name ?? 'tool'),
    args: msg.args ?? {},
    result: msg.result,
  };
}

/**
 * Headless Cursor CLI argv. `--trust` and `--force` are required: without them
 * `cursor-agent --print` blocks on a TTY workspace/permission prompt, stdout
 * stays empty, and the phone chat looks frozen after the user's bubble.
 */
export function buildCursorCliArgs(
  bin: string,
  prompt: string,
  opts: { sessionId?: string | null; cwd: string },
): string[] {
  const argv = [
    bin,
    '--print',
    '--output-format', 'stream-json',
    '--trust',
    '--force',
    '--approve-mcps',
    '--workspace', opts.cwd,
  ];
  if (opts.sessionId) argv.push('--resume', opts.sessionId);
  argv.push(prompt);
  return argv;
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

// ---------------------------------------------------------------------------
// Claude Code adapter — persistent `claude --print` with stream-json in/out.
// ---------------------------------------------------------------------------

class ClaudeAdapter implements AgentAdapter {
  private proc: Proc | null = null;

  constructor(private session: AgentSession, private bin = 'claude') {}

  private ensureProc(): Proc {
    if (this.proc && this.proc.exitCode === null && !this.proc.killed) return this.proc;
    this.proc = Bun.spawn(
      [
        this.bin, '--print',
        '--input-format', 'stream-json',
        '--output-format', 'stream-json',
        '--verbose',
        '--permission-mode', 'acceptEdits',
      ],
      {
        cwd: this.session.info.cwd,
        stdin: 'pipe',
        stdout: 'pipe',
        stderr: 'ignore',
        env: spawnEnv(),
      } as unknown as SpawnOpts,
    );
    void pumpJsonLines(this.proc, (msg) => this.onEvent(msg)).catch(() => {});
    this.proc.exited.then(() => {
      if (this.session.info.busy) {
        setBusy(this.session, false);
        emit(this.session, { kind: 'status', text: 'agent process exited' });
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
  private sawAssistantText = false;
  private stderr = '';

  constructor(private session: AgentSession, private bin = 'cursor-agent') {}

  prompt(text: string): void {
    this.cancel();
    this.sawResult = false;
    this.sawAssistantText = false;
    this.stderr = '';
    emit(this.session, { kind: 'thinking', text: 'Waiting for Cursor CLI…' });

    const argv = buildCursorCliArgs(this.bin, text, {
      sessionId: this.chatId,
      cwd: this.session.info.cwd,
    });

    let proc: Proc;
    try {
      proc = Bun.spawn(argv, {
        cwd: this.session.info.cwd,
        stdin: 'ignore',
        stdout: 'pipe',
        stderr: 'pipe',
        env: spawnEnv(),
      } as unknown as SpawnOpts);
    } catch (err) {
      setBusy(this.session, false);
      emit(this.session, {
        kind: 'error',
        text: `Could not start Cursor CLI (${this.bin}): ${err instanceof Error ? err.message : String(err)}`,
      });
      return;
    }

    this.proc = proc;
    const stderrP = collectStream(proc.stderr as unknown as ReadableStream<Uint8Array>);
    void pumpJsonLines(proc, (msg) => {
      if (this.proc === proc) this.onEvent(msg);
    }).catch(() => {});
    proc.exited.then(async (code) => {
      const errText = await stderrP.catch(() => '');
      if (this.proc !== proc) return;
      this.proc = null;
      this.stderr = errText;
      if (this.sawResult) return;
      setBusy(this.session, false);
      emit(this.session, { kind: 'error', text: this.failMessage(code) });
    }).catch(() => {});
  }

  private failMessage(code: number | null): string {
    const err = this.stderr.replace(/\s+/g, ' ').trim();
    const loginHint = ' On the PC run `cursor-agent login` (or set CURSOR_API_KEY).';
    if (/log ?in|auth|api[- ]key|unauthorized|not signed/i.test(err)) {
      return (err || 'Cursor CLI is not signed in.') + loginHint;
    }
    if (err) return err.slice(0, 1500);
    return `Cursor CLI exited without a reply (code ${code ?? 'unknown'}).${loginHint}`;
  }

  private onEvent(msg: Record<string, unknown>): void {
    const s = this.session;
    for (const key of ['chatId', 'chat_id', 'sessionId', 'session_id']) {
      if (typeof msg[key] === 'string' && (msg[key] as string).length > 0) {
        this.chatId = msg[key] as string;
      }
    }
    const type = msg.type;
    if (type === 'assistant') {
      // Skip duplicate flushes from --stream-partial-output (model_call_id, or
      // final flush with no timestamp after we already showed text).
      if (msg.model_call_id) return;
      const message = msg.message as Record<string, unknown> | undefined;
      const text = contentToText(message?.content);
      if (!text.trim()) return;
      const isDelta = typeof msg.timestamp_ms === 'number';
      if (isDelta) {
        emit(s, { kind: 'text-delta', text });
        this.sawAssistantText = true;
      } else if (!this.sawAssistantText || !msg.timestamp_ms) {
        // Complete assistant message (no --stream-partial-output). Skip the
        // trailing duplicate flush that has neither timestamp nor new content
        // after deltas — handled above via sawAssistantText + empty skip.
        if (this.sawAssistantText) return;
        emit(s, { kind: 'text', text });
        this.sawAssistantText = true;
      }
    } else if (type === 'tool_call') {
      const sub = msg.subtype;
      const parsed = parseCursorToolCall(msg);
      const refId = String(msg.call_id ?? msg.id ?? '');
      if (sub === 'started') {
        emit(s, {
          kind: 'tool-start',
          toolName: parsed.name,
          toolInput: JSON.stringify(parsed.args ?? {}, null, 2).slice(0, 4000),
          refId,
        });
      } else if (sub === 'completed') {
        emit(s, {
          kind: 'tool-end',
          toolName: parsed.name,
          refId,
          toolOutput: JSON.stringify(parsed.result ?? {}, null, 2).slice(0, 4000),
        });
      }
    } else if (type === 'result') {
      this.sawResult = true;
      setBusy(s, false);
      const text = typeof msg.result === 'string' ? msg.result : '';
      if (msg.is_error) {
        emit(s, { kind: 'error', text: text || this.stderr || 'Cursor CLI reported an error' });
      } else if (text && !this.sawAssistantText) {
        emit(s, { kind: 'text', text });
      } else {
        emit(s, { kind: 'result', text: '' });
      }
      // cursor-agent --print often hangs after writing the result event.
      try {
        this.proc?.kill();
      } catch {
        // already exiting
      }
    } else if (type === 'system' && msg.subtype === 'init') {
      emit(s, { kind: 'status', text: 'ready' });
    }
  }

  cancel(): void {
    const proc = this.proc;
    this.proc = null;
    try {
      proc?.kill();
    } catch {
      // already gone
    }
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
          text: `You said: "${text}"\n\nThis is the **demo agent** — install the Claude Code or Cursor CLI on the PC to chat with a real agent here.\n\n\`\`\`diff\n--- a/README.md\n+++ b/README.md\n@@ -1,3 +1,4 @@\n # NexusLink\n+Phone OS for your PC\n\`\`\``,
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
