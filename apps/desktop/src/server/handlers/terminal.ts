import type { WsMessage } from '@nexuslink/rpc-types';

interface TerminalSession {
  proc: ReturnType<typeof Bun.spawn>;
  ws: WebSocket;
  cols: number;
  rows: number;
}

type SendFn = (ws: WebSocket, msg: WsMessage) => void;

const terminals = new Map<string, TerminalSession>();
let sendFn: SendFn;

export function setSend(fn: SendFn) {
  sendFn = fn;
}

function streamOutput(id: string, session: TerminalSession, stream: ReadableStream<Uint8Array> | null) {
  if (!stream) return;
  const decoder = new TextDecoder();
  (async () => {
    for await (const chunk of stream) {
      const data = decoder.decode(chunk);
      if (sendFn && session.ws) {
        sendFn(session.ws, { type: 'terminal-output', terminalId: id, data });
      }
    }
  })().catch(() => {});
}

export function handleTerminalCreate(
  cols: number,
  rows: number,
  options?: { shell?: string; command?: string; args?: string[]; cwd?: string },
  ws?: WebSocket,
): { terminalId: string } {
  const id = crypto.randomUUID();
  const cwd = options?.cwd || process.env.HOME || process.cwd();
  const env = {
    ...process.env,
    TERM: 'xterm-256color',
    COLORTERM: 'truecolor',
    COLUMNS: String(cols),
    LINES: String(rows),
  };

  let proc: ReturnType<typeof Bun.spawn>;
  if (options?.command) {
    proc = Bun.spawn([options.command, ...(options.args ?? [])], {
      cwd,
      stdin: 'pipe',
      stdout: 'pipe',
      stderr: 'pipe',
      env,
    });
  } else {
    const cmd = options?.shell || process.env.SHELL || '/bin/bash';
    proc = Bun.spawn([cmd], {
      cwd,
      stdin: 'pipe',
      stdout: 'pipe',
      stderr: 'pipe',
      env,
    });
  }

  const session: TerminalSession = { proc, ws: ws!, cols, rows };
  terminals.set(id, session);

  streamOutput(id, session, proc.stdout);
  streamOutput(id, session, proc.stderr);

  return { terminalId: id };
}

export function handleTerminalInput(terminalId: string, data: string): void {
  const session = terminals.get(terminalId);
  if (!session) return;
  session.proc.stdin.write(new TextEncoder().encode(data));
}

export function handleTerminalResize(terminalId: string, cols: number, rows: number): void {
  const session = terminals.get(terminalId);
  if (!session) return;
  session.cols = cols;
  session.rows = rows;
  try {
    session.proc.kill('SIGWINCH');
  } catch {
    /* ignore */
  }
}

export function handleTerminalKill(terminalId: string): void {
  const session = terminals.get(terminalId);
  if (!session) return;
  try {
    session.proc.kill('SIGTERM');
  } catch {
    /* ignore */
  }
  terminals.delete(terminalId);
}
