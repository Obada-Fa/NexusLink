// Shell lifetime is independent of views and WebSockets. Output is sequenced
// before delivery so an attach can replay the exact gap after reconnection.
import { fileURLToPath } from 'node:url';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { statSync } from 'node:fs';
import { WorkspaceError } from '../workspace/security';
import type { WsMessage } from '@nexuslink/rpc-types';
const PTY_HOST = join(dirname(fileURLToPath(import.meta.url)), '..', 'pty-host.py');
const BUFFER_BYTES = 2 * 1024 * 1024;
type Chunk = { seq: number; data: string };
interface TerminalSession {
  id: string; proc: ReturnType<typeof Bun.spawn>; clients: Set<WebSocket>;
  cols: number; rows: number; cwd: string; shell: string; taskId?: string;
  seq: number; chunks: Chunk[]; bytes: number; createdAt: number;
  exitCode: number | null; ended: boolean; stderr: string;
}
const terminals = new Map<string, TerminalSession>();
const creations = new Map<string, { terminalId: string }>();
let sendFn: (ws: WebSocket, msg: any) => void = () => {};
export function setSend(fn: (ws: WebSocket, msg: WsMessage) => void) { sendFn = fn; }
let ptyAvailable: boolean | undefined;
export function hasPty(): boolean {
  return ptyAvailable ??= Bun.spawnSync(['python3', '-c', 'import pty, termios, fcntl'], { stdout: 'ignore', stderr: 'ignore' }).exitCode === 0;
}
export function resolveTerminalCwd(raw?: string): string {
  const home = homedir();
  const s = raw?.trim() || '~';
  const path = s === '~' ? home : s.startsWith('~/') ? join(home, s.slice(2)) : isAbsolute(s) ? s : resolve(s);
  try { if (statSync(path).isDirectory()) return path; } catch {}
  throw new WorkspaceError('INVALID_ARGUMENT', `Terminal directory does not exist or is not a directory: ${path}`);
}
function session(id: string) {
  const s = terminals.get(id);
  if (!s) throw new WorkspaceError('NOT_FOUND', 'Terminal session no longer exists. Create a new terminal.');
  return s;
}
function summary(s: TerminalSession) {
  return { terminalId: s.id, cwd: s.cwd, shell: s.shell, taskId: s.taskId, cols: s.cols, rows: s.rows,
    createdAt: s.createdAt, state: s.ended ? 'exited' : 'running', exitCode: s.exitCode, seq: s.seq, error: s.stderr || undefined };
}
export function listTerminals() { return [...terminals.values()].map(summary); }
function output(s: TerminalSession, data: string) {
  if (!data) return;
  const chunk = { seq: ++s.seq, data };
  s.chunks.push(chunk); s.bytes += Buffer.byteLength(data);
  while (s.bytes > BUFFER_BYTES && s.chunks.length > 1) s.bytes -= Buffer.byteLength(s.chunks.shift()!.data);
  for (const ws of s.clients) sendFn(ws, { type: 'terminal-output', terminalId: s.id, ...chunk });
}
export function handleTerminalCreate(cols: number, rows: number, shell?: string, ws?: WebSocket, cwd?: string,
  options?: { operationId?: string; taskId?: string; detached?: boolean }): { terminalId: string } {
  if (options?.operationId && creations.has(options.operationId)) return creations.get(options.operationId)!;
  if ([...terminals.values()].filter(s => !s.ended).length >= 12) throw new WorkspaceError('LIMIT_REACHED', 'Twelve shells are already running. End one before creating another.');
  if (!hasPty()) throw new WorkspaceError('UNSUPPORTED', 'Install Python 3 with PTY support on the PC to use terminals.');
  if (!Number.isInteger(cols) || cols < 1 || cols > 1000 || !Number.isInteger(rows) || rows < 1 || rows > 1000) throw new WorkspaceError('INVALID_ARGUMENT', 'Invalid terminal size.');
  const cmd = shell || process.env.SHELL || '/bin/bash';
  const targetCwd = resolveTerminalCwd(cwd);
  const proc = Bun.spawn(['python3', PTY_HOST, cmd, String(cols), String(rows)], {
    stdin: 'pipe', stdout: 'pipe', stderr: 'pipe', cwd: targetCwd,
    env: { ...process.env, PWD: targetCwd, TERM: 'xterm-256color' },
  });
  const s: TerminalSession = { id: crypto.randomUUID(), proc, cols, rows, cwd: targetCwd, shell: cmd,
    taskId: options?.taskId, clients: new Set(ws && !options?.detached ? [ws] : []), seq: 0, chunks: [], bytes: 0,
    createdAt: Date.now(), ended: false, exitCode: null, stderr: '' };
  terminals.set(s.id, s);
  const result = { terminalId: s.id };
  if (options?.operationId) creations.set(options.operationId, result);
  const pump = (async () => {
    const decoder = new TextDecoder();
    for await (const chunk of proc.stdout) output(s, decoder.decode(chunk, { stream: true }));
    output(s, decoder.decode());
  })();
  const errors = (async () => {
    const decoder = new TextDecoder();
    for await (const chunk of proc.stderr) s.stderr = (s.stderr + decoder.decode(chunk, { stream: true })).slice(-4096);
  })();
  void proc.exited.then(async code => {
    await Promise.allSettled([pump, errors]);
    s.ended = true; s.exitCode = code;
    for (const ws of s.clients) sendFn(ws, { type: 'terminal-exit', ...summary(s) });
    s.clients.clear();
    const ended = [...terminals.values()].filter(s => s.ended);
    for (const old of ended.slice(0, Math.max(0, ended.length - 24))) terminals.delete(old.id);
    while (creations.size > 256) creations.delete(creations.keys().next().value!);
  });
  return result;
}
export function attachTerminal(id: string, ws: WebSocket, afterSeq = 0) {
  const s = session(id);
  const oldest = s.chunks[0]?.seq ?? s.seq + 1;
  const gap = afterSeq < oldest - 1 || afterSeq > s.seq;
  // No await between replay and registering the socket: output cannot interleave.
  if (gap) sendFn(ws, { type: 'terminal-gap', terminalId: id, oldestSeq: oldest });
  for (const chunk of s.chunks) if (gap || chunk.seq > afterSeq) sendFn(ws, { type: 'terminal-output', terminalId: id, ...chunk });
  if (!s.ended) s.clients.add(ws);
  return { ...summary(s), gap, oldestSeq: oldest };
}
export function detachTerminal(id: string, ws: WebSocket) { terminals.get(id)?.clients.delete(ws); }
export function detachTerminalsForSocket(ws: WebSocket) { for (const s of terminals.values()) s.clients.delete(ws); }
function write(s: TerminalSession, message: unknown) {
  if (s.ended) throw new WorkspaceError('SESSION_EXITED', 'This shell has exited.');
  const stdin = s.proc.stdin as import('bun').FileSink;
  stdin.write(JSON.stringify(message) + '\n');
  stdin.flush();
}
export function handleTerminalInput(id: string, data: string) {
  if (Buffer.byteLength(data) > 65536) throw new WorkspaceError('INVALID_ARGUMENT', 'Paste is too large; send at most 64 KiB at a time.');
  write(session(id), { t: 'd', d: Buffer.from(data, 'utf8').toString('base64') });
}
export function handleTerminalResize(id: string, cols: number, rows: number) {
  if (!Number.isInteger(cols) || cols < 1 || cols > 1000 || !Number.isInteger(rows) || rows < 1 || rows > 1000) throw new WorkspaceError('INVALID_ARGUMENT', 'Invalid terminal size.');
  const s = session(id); s.cols = cols; s.rows = rows; write(s, { t: 'r', c: cols, r: rows });
}
export function handleTerminalKill(id: string) {
  const s = session(id);
  if (!s.ended) write(s, { t: 'k' });
}
export function stopAllTerminals() { for (const s of terminals.values()) if (!s.ended) { try { handleTerminalKill(s.id); } catch {} } }
