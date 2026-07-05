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

export function handleTerminalCreate(cols: number, rows: number, shell?: string, ws?: WebSocket): { terminalId: string } {
  const id = crypto.randomUUID();
  const cmd = shell || process.env.SHELL || '/bin/bash';

  const proc = Bun.spawn([cmd], {
    stdin: 'pipe',
    stdout: 'pipe',
    stderr: 'pipe',
    env: { ...process.env, TERM: 'xterm-256color', COLUMNS: String(cols), LINES: String(rows) },
  });

  const session: TerminalSession = { proc, ws: ws!, cols, rows };
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
  }
}

export function handleTerminalKill(terminalId: string): void {
  const session = terminals.get(terminalId);
  if (!session) return;
  try {
    session.proc.kill('SIGTERM');
  } catch {
  }
  terminals.delete(terminalId);
}
