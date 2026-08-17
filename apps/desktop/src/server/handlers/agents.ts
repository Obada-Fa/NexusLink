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
  bin?: string;
  makeAdapter(session: AgentSession): AgentAdapter;
}

function which(bin: string): string | null {
  for (const dir of (process.env.PATH ?? '').split(':')) {
    const p = `${dir}/${bin}`;
    if (dir && existsSync(p)) return p;
  }
  return null;
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

// ---------------------------------------------------------------------------
// Claude Code adapter — persistent `claude --print` with stream-json in/out.
// ---------------------------------------------------------------------------

class ClaudeAdapter implements AgentAdapter {
  private proc: Proc | null = null;

  constructor(private session: AgentSession) {}

  private ensureProc(): Proc {
    if (this.proc && this.proc.exitCode === null && !this.proc.killed) return this.proc;
    this.proc = Bun.spawn(
      [
        'claude', '--print',
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

  constructor(private session: AgentSession) {}

  prompt(text: string): void {
    this.sawResult = false;
    const argv = ['cursor-agent', '--print', '--output-format', 'stream-json'];
    if (this.chatId) argv.push('--resume', this.chatId);
    argv.push(text);
    this.proc = Bun.spawn(argv, {
      cwd: this.session.info.cwd,
      stdin: 'ignore',
      stdout: 'pipe',
      stderr: 'ignore',
    } as unknown as SpawnOpts);
    void pumpJsonLines(this.proc, (msg) => this.onEvent(msg)).catch(() => {});
    this.proc.exited.then(() => {
      if (this.session.info.busy) {
        setBusy(this.session, false);
        if (!this.sawResult) emit(this.session, { kind: 'result', text: '' });
      }
    }).catch(() => {});
  }

  private onEvent(msg: Record<string, unknown>): void {
    const s = this.session;
    // Remember the chat id from any event that carries one (init/system events).
    for (const key of ['chatId', 'chat_id', 'sessionId', 'session_id']) {
      if (typeof msg[key] === 'string') this.chatId = msg[key] as string;
    }
    const type = msg.type;
    if (type === 'assistant') {
      const message = msg.message as Record<string, unknown> | undefined;
      const text = contentToText(message?.content);
      if (text.trim()) emit(s, { kind: 'text', text });
    } else if (type === 'tool_call') {
      const sub = msg.subtype;
      if (sub === 'started') {
        emit(s, {
          kind: 'tool-start',
          toolName: String(msg.name ?? (msg.tool_call as Record<string, unknown>)?.name ?? 'tool'),
          toolInput: JSON.stringify(msg.args ?? msg.tool_call ?? {}, null, 2).slice(0, 4000),
          refId: String(msg.call_id ?? msg.id ?? ''),
        });
      } else if (sub === 'completed') {
        emit(s, {
          kind: 'tool-end',
          refId: String(msg.call_id ?? msg.id ?? ''),
          toolOutput: JSON.stringify(msg.result ?? {}, null, 2).slice(0, 4000),
        });
      }
    } else if (type === 'result') {
      this.sawResult = true;
      setBusy(s, false);
      emit(s, { kind: 'result', text: typeof msg.result === 'string' ? msg.result : '' });
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
