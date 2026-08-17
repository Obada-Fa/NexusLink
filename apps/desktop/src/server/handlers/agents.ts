// Agent gateway: run AI coding agents (Claude Code, Cursor CLI, OpenCode,
// Antigravity) on the host and expose them to the phone as chat sessions.
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
    `${home}/.opencode/bin`,
    `${home}/.local/share/opencode/bin`,
    `${home}/.local/share/agy/bin`,
    `${home}/.gemini/antigravity-cli`,
    '/opt/Antigravity/bin',
    '/opt/antigravity/bin',
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
  // Headless: never wait on a TTY login/trust prompt.
  env.CI = env.CI || '1';
  env.TERM = 'dumb';
  env.NO_COLOR = '1';
  return env;
}

/** How long to wait for the first JSON event before declaring Cursor CLI hung. */
export function cursorSilenceTimeoutMs(): number {
  const n = Number(process.env.NEXUS_AGENT_SILENCE_MS);
  return Number.isFinite(n) && n > 0 ? n : 20_000;
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
    id: 'opencode',
    name: 'OpenCode',
    bins: ['opencode'],
    makeAdapter: (s, bin) => new OpenCodeAdapter(s, bin ?? 'opencode'),
  },
  {
    id: 'antigravity',
    name: 'Antigravity',
    bins: ['agy', 'antigravity'],
    makeAdapter: (s, bin) => new AntigravityAdapter(s, bin ?? 'agy'),
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
 * `--stream-partial-output` makes tokens appear on the phone as they arrive.
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
    '--stream-partial-output',
    '--trust',
    '--force',
    '--approve-mcps',
    '--workspace', opts.cwd,
  ];
  if (opts.sessionId) argv.push('--resume', opts.sessionId);
  argv.push(prompt);
  return argv;
}

export type CursorAssistantEmit = 'text' | 'text-delta' | 'skip';

/**
 * Classify a Cursor CLI `assistant` event.
 *
 * Without `--stream-partial-output`, each event is a complete message (several
 * per turn, between tool calls). With it:
 * - `timestamp_ms` present, `model_call_id` absent → streaming delta
 * - both present → duplicate flush before a tool call
 * - both absent after deltas → duplicate final flush
 */
export function classifyCursorAssistant(
  msg: Record<string, unknown>,
  opts: { streamedDeltas: boolean },
): CursorAssistantEmit {
  const hasTs = typeof msg.timestamp_ms === 'number';
  const hasMc = Boolean(msg.model_call_id);
  if (hasTs && !hasMc) return 'text-delta';
  if (hasTs && hasMc) return 'skip';
  // Complete message (no partial streaming), or the duplicate end-of-turn flush.
  if (opts.streamedDeltas) return 'skip';
  return 'text';
}

/** OpenCode headless: `opencode run --format json --auto`. */
export function buildOpenCodeArgs(
  bin: string,
  prompt: string,
  opts: { sessionId?: string | null; cwd: string },
): string[] {
  const argv = [bin, 'run', '--format', 'json', '--auto', '--dir', opts.cwd];
  if (opts.sessionId) argv.push('--session', opts.sessionId);
  argv.push(prompt);
  return argv;
}

/** Antigravity CLI headless: `agy -p --output-format stream-json`. */
export function buildAntigravityArgs(
  bin: string,
  prompt: string,
  opts: { sessionId?: string | null; cwd: string },
): string[] {
  const argv = [
    bin,
    '--print',
    '--output-format', 'stream-json',
    '--dangerously-skip-permissions',
    '--print-timeout', '15m',
  ];
  if (opts.sessionId) argv.push('--conversation', opts.sessionId);
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
  private streamedDeltas = false;
  private stderr = '';
  private silenceTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(private session: AgentSession, private bin = 'cursor-agent') {}

  prompt(text: string): void {
    this.cancel();
    this.sawResult = false;
    this.sawAssistantText = false;
    this.streamedDeltas = false;
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
    this.armSilenceWatchdog(proc);
    const stderrP = collectStream(proc.stderr as unknown as ReadableStream<Uint8Array>);
    void pumpJsonLines(proc, (msg) => {
      if (this.proc === proc) this.onEvent(msg);
    }).catch(() => {});
    proc.exited.then(async (code) => {
      const errText = await stderrP.catch(() => '');
      this.clearSilenceWatchdog();
      if (this.proc !== proc) return;
      this.proc = null;
      this.stderr = errText;
      if (this.sawResult) return;
      setBusy(this.session, false);
      emit(this.session, { kind: 'error', text: this.failMessage(code) });
    }).catch(() => {});
  }

  private armSilenceWatchdog(proc: Proc): void {
    this.clearSilenceWatchdog();
    this.silenceTimer = setTimeout(() => {
      if (this.proc !== proc || this.sawResult || this.sawAssistantText) return;
      this.clearSilenceWatchdog();
      setBusy(this.session, false);
      emit(this.session, {
        kind: 'error',
        text: 'Cursor CLI did not respond. On the PC run `cursor-agent login` (or set CURSOR_API_KEY), then try again.',
      });
      this.cancel();
    }, cursorSilenceTimeoutMs());
  }

  private clearSilenceWatchdog(): void {
    if (this.silenceTimer) {
      clearTimeout(this.silenceTimer);
      this.silenceTimer = null;
    }
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
    this.clearSilenceWatchdog();
    const s = this.session;
    for (const key of ['chatId', 'chat_id', 'sessionId', 'session_id']) {
      if (typeof msg[key] === 'string' && (msg[key] as string).length > 0) {
        this.chatId = msg[key] as string;
      }
    }
    const type = msg.type;
    if (type === 'assistant') {
      const message = msg.message as Record<string, unknown> | undefined;
      const text = contentToText(message?.content);
      if (!text.trim()) return;
      const action = classifyCursorAssistant(msg, { streamedDeltas: this.streamedDeltas });
      if (action === 'skip') return;
      if (action === 'text-delta') {
        emit(s, { kind: 'text-delta', text });
        this.sawAssistantText = true;
        this.streamedDeltas = true;
      } else {
        emit(s, { kind: 'text', text });
        this.sawAssistantText = true;
      }
    } else if (type === 'tool_call') {
      this.streamedDeltas = false;
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
    this.clearSilenceWatchdog();
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

abstract class JsonLineCliAdapter implements AgentAdapter {
  protected proc: Proc | null = null;
  protected chatId: string | null = null;
  protected sawResult = false;
  protected sawAssistantText = false;
  protected stderr = '';

  constructor(
    protected session: AgentSession,
    protected bin: string,
    private meta: { label: string; waitingText: string; loginCmd: string },
  ) {}

  protected abstract buildArgv(prompt: string): string[];
  protected abstract handleEvent(msg: Record<string, unknown>): void;

  prompt(text: string): void {
    this.cancel();
    this.sawResult = false;
    this.sawAssistantText = false;
    this.stderr = '';
    emit(this.session, { kind: 'thinking', text: this.meta.waitingText });

    let proc: Proc;
    try {
      proc = Bun.spawn(this.buildArgv(text), {
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
        text: `Could not start ${this.meta.label} (${this.bin}): ${err instanceof Error ? err.message : String(err)}`,
      });
      return;
    }

    this.proc = proc;
    const stderrP = collectStream(proc.stderr as unknown as ReadableStream<Uint8Array>);
    void pumpJsonLines(proc, (msg) => {
      if (this.proc === proc) this.handleEvent(msg);
    }).catch(() => {});
    proc.exited.then(async (code) => {
      const errText = await stderrP.catch(() => '');
      if (this.proc !== proc) return;
      this.proc = null;
      this.stderr = errText;
      if (this.sawResult) return;
      if (this.sawAssistantText && (code === 0 || code === null)) {
        setBusy(this.session, false);
        emit(this.session, { kind: 'result', text: '' });
        return;
      }
      setBusy(this.session, false);
      emit(this.session, { kind: 'error', text: this.failMessage(code) });
    }).catch(() => {});
  }

  protected finishTurn(errorText?: string): void {
    this.sawResult = true;
    setBusy(this.session, false);
    if (errorText) emit(this.session, { kind: 'error', text: errorText });
    else emit(this.session, { kind: 'result', text: '' });
    try {
      this.proc?.kill();
    } catch {
      // already exiting
    }
  }

  protected failMessage(code: number | null): string {
    const err = this.stderr.replace(/\s+/g, ' ').trim();
    const loginHint = ` On the PC run \`${this.meta.loginCmd}\`.`;
    if (/log ?in|auth|api[- ]key|unauthorized|not signed|authentication required/i.test(err)) {
      return (err || `${this.meta.label} is not signed in.`) + loginHint;
    }
    if (err) return err.slice(0, 1500);
    return `${this.meta.label} exited without a reply (code ${code ?? 'unknown'}).${loginHint}`;
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

class OpenCodeAdapter extends JsonLineCliAdapter {
  constructor(session: AgentSession, bin = 'opencode') {
    super(session, bin, {
      label: 'OpenCode',
      waitingText: 'Waiting for OpenCode…',
      loginCmd: 'opencode auth login',
    });
  }

  protected buildArgv(prompt: string): string[] {
    return buildOpenCodeArgs(this.bin, prompt, {
      sessionId: this.chatId,
      cwd: this.session.info.cwd,
    });
  }

  protected handleEvent(msg: Record<string, unknown>): void {
    if (typeof msg.sessionID === 'string' && msg.sessionID) this.chatId = msg.sessionID;
    const type = msg.type;
    const part = msg.part as Record<string, unknown> | undefined;
    if (type === 'text') {
      const text = String(part?.text ?? msg.text ?? '');
      if (!text.trim()) return;
      emit(this.session, { kind: 'text', text });
      this.sawAssistantText = true;
    } else if (type === 'reasoning') {
      const text = String(part?.text ?? '');
      if (text.trim()) emit(this.session, { kind: 'thinking', text });
    } else if (type === 'tool_use') {
      const state = (part?.state as Record<string, unknown> | undefined) ?? {};
      const refId = String(part?.callID ?? part?.id ?? '');
      emit(this.session, {
        kind: 'tool-start',
        toolName: String(part?.tool ?? 'tool'),
        toolInput: JSON.stringify(state.input ?? {}, null, 2).slice(0, 4000),
        refId,
      });
      emit(this.session, {
        kind: 'tool-end',
        toolName: String(part?.tool ?? 'tool'),
        refId,
        toolOutput: String(state.output ?? '').slice(0, 4000),
      });
    } else if (type === 'error') {
      const err = msg.error as Record<string, unknown> | string | undefined;
      const data = err && typeof err === 'object' ? (err.data as Record<string, unknown> | undefined) : undefined;
      const text = typeof err === 'string'
        ? err
        : String(data?.message ?? (err && typeof err === 'object' ? err.name : '') ?? 'OpenCode error');
      this.finishTurn(text);
    } else if (type === 'step_finish') {
      const reason = part?.reason;
      if (reason === 'tool-calls') return;
      this.finishTurn();
    }
  }
}

class AntigravityAdapter extends JsonLineCliAdapter {
  constructor(session: AgentSession, bin = 'agy') {
    super(session, bin, {
      label: 'Antigravity',
      waitingText: 'Waiting for Antigravity…',
      loginCmd: 'agy',
    });
  }

  protected buildArgv(prompt: string): string[] {
    return buildAntigravityArgs(this.bin, prompt, {
      sessionId: this.chatId,
      cwd: this.session.info.cwd,
    });
  }

  protected handleEvent(msg: Record<string, unknown>): void {
    const event = String(msg.event ?? msg.type ?? '');
    if (event === 'init') {
      const init = (msg.init as Record<string, unknown> | undefined) ?? msg;
      const id = String(msg.conversation_id ?? init.conversation_id ?? '');
      if (id) this.chatId = id;
      emit(this.session, { kind: 'status', text: 'ready' });
      return;
    }
    if (event === 'step_update') {
      const step = (msg.step_update as Record<string, unknown> | undefined) ?? msg;
      const conv = String(step.conversation_id ?? '');
      if (conv) this.chatId = conv;
      const stepType = String(step.step_type ?? '');
      const state = String(step.state ?? '');
      if (stepType === 'agent_response') {
        const delta = String(step.text_delta ?? '');
        if (!delta.trim()) return;
        if (state === 'ACTIVE') {
          emit(this.session, { kind: 'text-delta', text: delta });
          this.sawAssistantText = true;
        } else if (!this.sawAssistantText) {
          emit(this.session, { kind: 'text', text: delta });
          this.sawAssistantText = true;
        }
      } else if (stepType === 'tool') {
        const info = (step.tool_info as Record<string, unknown> | undefined) ?? {};
        const name = String(step.tool_name ?? info.name ?? 'tool');
        const refId = `${step.step_index ?? name}`;
        if (state === 'ACTIVE') {
          emit(this.session, {
            kind: 'tool-start',
            toolName: name,
            toolInput: JSON.stringify(info.parameters ?? {}, null, 2).slice(0, 4000),
            refId,
          });
        } else {
          emit(this.session, {
            kind: 'tool-end',
            toolName: name,
            refId,
            toolOutput: String(info.output ?? info.error ?? '').slice(0, 4000),
          });
        }
      }
      return;
    }
    if (event === 'result') {
      const result = (msg.result as Record<string, unknown> | undefined) ?? msg;
      const conv = String(result.conversation_id ?? '');
      if (conv) this.chatId = conv;
      const status = String(result.status ?? '');
      const text = String(result.response ?? '');
      if (status && status !== 'SUCCESS') {
        const err = String(result.error ?? '');
        this.finishTurn(err || text || `Antigravity status: ${status}`);
        return;
      }
      if (text && !this.sawAssistantText) {
        emit(this.session, { kind: 'text', text });
        this.sawAssistantText = true;
      }
      this.finishTurn();
    }
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
