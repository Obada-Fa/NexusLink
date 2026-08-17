// Phone-facing terminals. Shells run on a REAL pseudo-terminal via the
// pty-host.py helper (colors, job control, resize, TUI apps), falling back to
// a plain pipe when python3 is unavailable. RPC surface is unchanged:
// terminal.create/input/resize/kill + `terminal-output` pushes.

import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import type { WsMessage } from '@nexuslink/rpc-types';

type SpawnOpts = Parameters<typeof Bun.spawn>[1];

const PTY_HOST = join(dirname(fileURLToPath(import.meta.url)), '..', 'pty-host.py');

interface TerminalSession {
  proc: ReturnType<typeof Bun.spawn>;
  ws: WebSocket;
  cols: number;
  rows: number;
  /** true = pty-host.py protocol; false = legacy raw-pipe fallback */
  pty: boolean;
}

type SendFn = (ws: WebSocket, msg: WsMessage) => void;

const terminals = new Map<string, TerminalSession>();
let sendFn: SendFn;

export function setSend(fn: SendFn) {
  sendFn = fn;
}

let ptyAvailable: boolean | null = null;

function hasPty(): boolean {
  if (ptyAvailable !== null) return ptyAvailable;
  try {
    const probe = Bun.spawnSync(['python3', '-c', 'import pty, termios, fcntl'], {
      stdout: 'ignore',
      stderr: 'ignore',
    } as unknown as SpawnOpts);
    ptyAvailable = probe.exitCode === 0;
  } catch {
    ptyAvailable = false;
  }
  return ptyAvailable;
}

export function handleTerminalCreate(cols: number, rows: number, shell?: string, ws?: WebSocket): { terminalId: string } {
  const id = crypto.randomUUID();
  const cmd = shell || process.env.SHELL || '/bin/bash';
  const usePty = hasPty();

  const proc = usePty
    ? Bun.spawn(['python3', PTY_HOST, cmd, String(cols || 80), String(rows || 24)], {
        stdin: 'pipe',
        stdout: 'pipe',
        stderr: 'ignore',
      } as unknown as SpawnOpts)
    : Bun.spawn([cmd], {
        stdin: 'pipe',
        stdout: 'pipe',
        stderr: 'pipe',
        env: { ...process.env, TERM: 'xterm-256color', COLUMNS: String(cols), LINES: String(rows) },
      } as unknown as SpawnOpts);

  const session: TerminalSession = { proc, ws: ws!, cols, rows, pty: usePty };
  terminals.set(id, session);

  (async () => {
    const decoder = new TextDecoder();
    for await (const chunk of proc.stdout) {
      const data = decoder.decode(chunk);
      if (sendFn && session.ws) {
        sendFn(session.ws, { type: 'terminal-output', terminalId: id, data });
      }
    }
  })().catch(() => {});

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
    if (session.pty) {
      writeStdin(session, JSON.stringify({ t: 'd', d: Buffer.from(data, 'utf8').toString('base64') }) + '\n');
    } else {
      writeStdin(session, data);
    }
  } catch {
    // shell went away; exit handler cleans up
  }
}

export function handleTerminalResize(terminalId: string, cols: number, rows: number): void {
  const session = terminals.get(terminalId);
  if (!session) return;
  session.cols = cols;
  session.rows = rows;
  try {
    if (session.pty) {
      writeStdin(session, JSON.stringify({ t: 'r', c: cols, r: rows }) + '\n');
    } else {
      session.proc.kill('SIGWINCH');
    }
  } catch {
    // shell went away
  }
}

export function handleTerminalKill(terminalId: string): void {
  const session = terminals.get(terminalId);
  if (!session) return;
  try {
    session.proc.kill('SIGTERM');
  } catch {
    // already gone
  }
  terminals.delete(terminalId);
}
