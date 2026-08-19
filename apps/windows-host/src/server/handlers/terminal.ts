import type { WsMessage } from '@nexuslink/rpc-types';
import { existsSync } from 'node:fs';
import { join, resolve } from 'node:path';

type SpawnOpts = Parameters<typeof Bun.spawn>[1];

interface TerminalSession {
  proc: ReturnType<typeof Bun.spawn>;
  ws: WebSocket;
  cols: number;
  rows: number;
  resizePipe?: string;
}

type SendFn = (ws: WebSocket, msg: WsMessage) => void;

const terminals = new Map<string, TerminalSession>();
let sendFn: SendFn;

export function setSend(fn: SendFn) {
  sendFn = fn;
}

function defaultShell(): string {
  return process.env.NEXUSLINK_SHELL
    || process.env.ComSpec
    || 'powershell.exe';
}

function conptyHostPath(): string | null {
  const named = process.env.NEXUSLINK_CONPTY;
  if (named && existsSync(named)) return named;
  const candidates = [
    resolve(import.meta.dir, '../../../../native/conpty-host.exe'),
    resolve(import.meta.dir, '../../native/conpty-host.exe'),
    join(process.env.ProgramFiles || 'C:\\Program Files', 'NexusLink', 'conpty-host.exe'),
  ];
  return candidates.find((p) => existsSync(p)) ?? null;
}

export function handleTerminalCreate(
  cols: number,
  rows: number,
  shell?: string,
  ws?: WebSocket,
): { terminalId: string } {
  const id = crypto.randomUUID();
  const cmd = shell?.trim() || defaultShell();
  const host = conptyHostPath();
  const argv = host
    ? [host, '--cols', String(cols || 80), '--rows', String(rows || 24), '--', cmd]
    : [cmd];

  const proc = Bun.spawn(argv, {
    stdin: 'pipe',
    stdout: 'pipe',
    stderr: 'pipe',
    env: {
      ...process.env,
      TERM: 'xterm-256color',
      COLUMNS: String(cols || 80),
      LINES: String(rows || 24),
      NEXUSLINK_PTY_ID: id,
    },
  } as unknown as SpawnOpts);

  const session: TerminalSession = {
    proc,
    ws: ws!,
    cols,
    rows,
    resizePipe: host ? `\\\\.\\pipe\\nexuslink-pty-${proc.pid}` : undefined,
  };
  terminals.set(id, session);

  const decoder = new TextDecoder();
  const push = async (stream: AsyncIterable<Uint8Array>) => {
    for await (const chunk of stream) {
      const data = decoder.decode(chunk);
      if (sendFn && session.ws) {
        sendFn(session.ws, { type: 'terminal-output', terminalId: id, data });
      }
    }
  };
  void push(proc.stdout).catch(() => {});
  void push(proc.stderr).catch(() => {});
  proc.exited.then(() => terminals.delete(id)).catch(() => {});

  return { terminalId: id };
}

function writeStdin(session: TerminalSession, s: string): void {
  const stdin = session.proc.stdin as unknown as { write(s: string): unknown; flush?: () => void };
  stdin.write(s);
  stdin.flush?.();
}

export function handleTerminalInput(terminalId: string, data: string): void {
  const session = terminals.get(terminalId);
  if (!session) return;
  try {
    writeStdin(session, data);
  } catch {
    // shell went away
  }
}

export function handleTerminalResize(terminalId: string, cols: number, rows: number): void {
  const session = terminals.get(terminalId);
  if (!session) return;
  session.cols = cols;
  session.rows = rows;
  if (session.resizePipe) {
    try {
      Bun.spawnSync(['powershell.exe', '-NoProfile', '-Command',
        `try { $c = [System.IO.File]::OpenWrite('${session.resizePipe}'); $b = [Text.Encoding]::UTF8.GetBytes('{"cols":${cols},"rows":${rows}}\\n'); $c.Write($b,0,$b.Length); $c.Close() } catch {}`,
      ], { stdout: 'ignore', stderr: 'ignore' });
    } catch {
      // pipe not ready
    }
  }
}

export function handleTerminalKill(terminalId: string): void {
  const session = terminals.get(terminalId);
  if (!session) return;
  try {
    session.proc.kill();
  } catch {
    // already gone
  }
  terminals.delete(terminalId);
}

export function killTerminalsForSocket(ws: WebSocket): void {
  for (const [id, session] of [...terminals.entries()]) {
    if (session.ws === ws) handleTerminalKill(id);
  }
}
