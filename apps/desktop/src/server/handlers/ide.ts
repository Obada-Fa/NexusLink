// Tier 3: VS Code on the phone via code-server / openvscode-server.
// The editor UI is a real web app (touch-capable); only the backend runs on the PC.
// The phone loads it in a full-screen WebView using the already-paired host.
//
// Security: the editor is a shell on this PC, so it is never reachable without
// a per-start random token and never bound to 0.0.0.0.
//  - code-server has no URL-token login, so it listens on a 0600 unix socket and
//    a tiny token gate (below) owns the TCP port: `/?tkn=<token>` sets an
//    HttpOnly cookie, everything else without that cookie gets 401.
//  - openvscode-server uses its native --connection-token-file (same `?tkn=` URL).
// Clients load `http://<host>:<port><path>` where `path` comes from ide.start.

import { existsSync, lstatSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import type { Socket, TCPSocketListener } from 'bun';
import { tailscaleIpv4FromCli } from '../launch-banner';
import { isPrivatePeer } from '../workspace/security';

type SpawnOpts = Parameters<typeof Bun.spawn>[1];
type Proc = ReturnType<typeof Bun.spawn>;

const IDE_PORT = Number(process.env.NEXUSLINK_IDE_PORT) || 45780;
export const IDE_COOKIE = 'nl_ide_tkn';

export type IdeFlavor = 'code-server' | 'openvscode';

export interface IdeInfo {
  available: boolean;
  running: boolean;
  port?: number;
  cwd?: string;
  reason?: string;
  /** Interface the editor listens on (Tailscale IP or 127.0.0.1, never 0.0.0.0). */
  host?: string;
  /** Path + query carrying the access token; load `http://<host>:<port><path>`. */
  path?: string;
  /** Absolute tokenized URL using `host`. */
  url?: string;
}

interface IdeProc {
  proc: Proc;
  bin: string;
  cwd: string;
  port: number;
  host: string;
  token: string;
  gate?: IdeGate;
  runtimeDir: string;
}

let running: IdeProc | null = null;

function which(bin: string): string | null {
  for (const dir of (process.env.PATH ?? '').split(':')) {
    const p = `${dir}/${bin}`;
    if (dir && existsSync(p)) return p;
  }
  return null;
}

export function findIdeBin(): { bin: string; flavor: IdeFlavor } | null {
  const cs = which('code-server');
  if (cs) return { bin: cs, flavor: 'code-server' };
  const ov = which('openvscode-server');
  if (ov) return { bin: ov, flavor: 'openvscode' };
  return null;
}

const WILDCARD_HOSTS = new Set(['', '0.0.0.0', '::', '[::]', '*', '::0']);

/**
 * Where the editor listens: an explicitly configured specific host, else the
 * Tailscale IPv4 (how the owner's phone connects), else loopback. Never a wildcard.
 */
export function ideBindHost(
  env: Record<string, string | undefined> = process.env,
  tailscale: () => string[] = () => tailscaleIpv4FromCli(),
): string {
  const configured = (env.NEXUSLINK_HOST || env.HOST || '').trim();
  if (!WILDCARD_HOSTS.has(configured)) return configured;
  const ts = tailscale();
  return ts[0] ?? '127.0.0.1';
}

/** 0700 directory for the socket / token file; refuses a pre-planted symlink or foreign dir. */
function ideRuntimeDir(): string {
  const base = process.env.XDG_RUNTIME_DIR && existsSync(process.env.XDG_RUNTIME_DIR)
    ? process.env.XDG_RUNTIME_DIR
    : join('/tmp', `nexuslink-${process.getuid?.() ?? 'user'}`);
  const dir = join(base, 'nexuslink-ide');
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const st = lstatSync(dir);
  if (!st.isDirectory() || st.isSymbolicLink() || (process.getuid && st.uid !== process.getuid()) || (st.mode & 0o077) !== 0) {
    throw new Error(`Unsafe IDE runtime directory ${dir}`);
  }
  return dir;
}

/** argv for the editor backend. Exported for tests: must never contain an unauthenticated public bind. */
export function buildIdeArgv(
  flavor: IdeFlavor,
  bin: string,
  opts: { host: string; port: number; socketPath: string; tokenFile: string; folder?: string },
): string[] {
  if (flavor === 'code-server') {
    return [
      bin,
      '--socket', opts.socketPath,
      '--socket-mode', '600',
      // Auth is enforced by the token gate in front of the socket.
      '--auth', 'none',
      '--disable-telemetry',
      '--disable-update-check',
      ...(opts.folder ? [opts.folder] : []),
    ];
  }
  return [
    bin,
    '--host', opts.host,
    '--port', String(opts.port),
    '--connection-token-file', opts.tokenFile,
    ...(opts.folder ? ['--default-folder', opts.folder] : []),
  ];
}

function info(r: IdeProc): IdeInfo {
  const path = `/?tkn=${encodeURIComponent(r.token)}`;
  const hostPart = r.host.includes(':') ? `[${r.host}]` : r.host;
  return { available: true, running: true, port: r.port, cwd: r.cwd, host: r.host, path, url: `http://${hostPart}:${r.port}${path}` };
}

export function ideStatus(): IdeInfo {
  const found = findIdeBin();
  if (!found) {
    return {
      available: false,
      running: false,
      reason:
        'Install code-server (https://code-server.dev) or openvscode-server on the PC, then tap VS Code again.',
    };
  }
  if (running && running.proc.exitCode === null && !running.proc.killed) return info(running);
  return { available: true, running: false };
}

/** Child env without credentials code-server would otherwise pick up. */
function ideEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) if (v !== undefined && k !== 'PASSWORD' && k !== 'HASHED_PASSWORD') env[k] = v;
  return env;
}

export function startIde(cwd?: string): IdeInfo {
  const found = findIdeBin();
  if (!found) return ideStatus();
  if (running && running.proc.exitCode === null && !running.proc.killed) return info(running);
  if (running) stopIde();

  const folder = cwd && existsSync(cwd) ? cwd : undefined;
  const workdir = folder ?? homedir();
  const host = ideBindHost();
  const token = randomBytes(32).toString('base64url');
  let runtimeDir: string;
  try {
    runtimeDir = ideRuntimeDir();
  } catch (e) {
    return { available: true, running: false, reason: e instanceof Error ? e.message : 'IDE runtime directory unavailable' };
  }
  const socketPath = join(runtimeDir, 'code-server.sock');
  const tokenFile = join(runtimeDir, 'connection-token');
  rmSync(socketPath, { force: true });

  let gate: IdeGate | undefined;
  if (found.flavor === 'code-server') {
    // Claim the public port first: if it is taken we must not leave an editor running.
    try {
      gate = startIdeGate({ hostname: host, port: IDE_PORT, token, upstreamSocket: socketPath });
    } catch (e: any) {
      return { available: true, running: false, reason: `Port ${IDE_PORT} on ${host} is unavailable (${e?.code ?? e?.message ?? 'error'}). Stop whatever is using it and try again.` };
    }
  } else {
    writeFileSync(tokenFile, token, { mode: 0o600 });
  }

  const argv = buildIdeArgv(found.flavor, found.bin, { host, port: IDE_PORT, socketPath, tokenFile, folder });
  let proc: Proc;
  try {
    proc = Bun.spawn(argv, {
      cwd: workdir,
      stdin: 'ignore',
      stdout: 'ignore',
      stderr: 'ignore',
      env: ideEnv(),
    } as unknown as SpawnOpts);
  } catch (e) {
    gate?.stop();
    return { available: true, running: false, reason: e instanceof Error ? e.message : 'Could not start the editor' };
  }
  const entry: IdeProc = { proc, bin: found.bin, cwd: workdir, port: IDE_PORT, host, token, gate, runtimeDir };
  running = entry;
  proc.exited.then(() => {
    entry.gate?.stop();
    rmSync(found.flavor === 'code-server' ? socketPath : tokenFile, { force: true });
    if (running === entry) running = null;
  }).catch(() => {});
  return info(entry);
}

export function stopIde(): { ok: boolean } {
  if (!running) return { ok: false };
  const r = running;
  running = null;
  r.gate?.stop();
  try {
    r.proc.kill();
  } catch {
    // already gone
  }
  rmSync(join(r.runtimeDir, 'connection-token'), { force: true });
  return { ok: true };
}

// ---------------------------------------------------------------------------
// Token gate: TCP listener → unix-socket backend, authenticated per connection.
// The first request's head decides; afterwards bytes are piped verbatim, so
// keep-alive, streaming and WebSocket upgrades all work unchanged.

export interface IdeGate {
  port: number;
  stop(): void;
}

const MAX_HEAD = 32 * 1024;

type Decision = { kind: 'pass' } | { kind: 'redirect'; location: string } | { kind: 'deny' };

function tokenEquals(a: string | null | undefined, b: string): boolean {
  if (!a) return false;
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

/** Decide on a request head (request line + headers, CRLF separated). */
export function gateDecision(head: string, token: string): Decision {
  const lines = head.split('\r\n');
  const [method = '', target = ''] = (lines[0] ?? '').split(' ');
  for (const line of lines.slice(1)) {
    const idx = line.indexOf(':');
    if (idx < 0 || line.slice(0, idx).trim().toLowerCase() !== 'cookie') continue;
    for (const part of line.slice(idx + 1).split(';')) {
      const eq = part.indexOf('=');
      if (eq > 0 && part.slice(0, eq).trim() === IDE_COOKIE && tokenEquals(part.slice(eq + 1).trim(), token)) return { kind: 'pass' };
    }
  }
  let url: URL;
  try { url = new URL(target, 'http://gate'); } catch { return { kind: 'deny' }; }
  if (!target.startsWith('/') || !tokenEquals(url.searchParams.get('tkn'), token)) return { kind: 'deny' };
  if (method !== 'GET' && method !== 'HEAD') return { kind: 'pass' };
  url.searchParams.delete('tkn');
  return { kind: 'redirect', location: url.pathname + url.search };
}

const REASONS: Record<number, string> = { 302: 'Found', 400: 'Bad Request', 401: 'Unauthorized', 403: 'Forbidden', 431: 'Request Header Fields Too Large', 503: 'Service Unavailable' };

function respond(sock: Socket<ClientState>, status: number, body: string, headers: Record<string, string> = {}): void {
  if (sock.data) sock.data.closed = true;
  const bytes = Buffer.from(body, 'utf8');
  const head = [
    `HTTP/1.1 ${status} ${REASONS[status] ?? 'Error'}`,
    'Content-Type: text/html; charset=utf-8',
    `Content-Length: ${bytes.length}`,
    'Cache-Control: no-store',
    'Connection: close',
    ...Object.entries(headers).map(([k, v]) => `${k}: ${v}`),
    '',
    '',
  ].join('\r\n');
  sock.write(Buffer.concat([Buffer.from(head, 'latin1'), bytes]));
  sock.end();
}

interface ClientState {
  buf: Buffer;
  /** Bytes waiting to be written to the client. */
  out: Uint8Array[];
  up: Socket<UpState> | null;
  connecting: boolean;
  early: Uint8Array[];
  /** Gate answered or the client went away: ignore further input. */
  closed: boolean;
  /** Backend closed while bytes for the client were still queued. */
  endAfterFlush: boolean;
}
interface UpState {
  client: Socket<ClientState>;
  /** Bytes waiting to be written to the backend. */
  out: Uint8Array[];
}

/** Write with backpressure: queue the remainder and pause the source until `dst` drains. */
function pipeWrite(dst: Socket<any>, queue: Uint8Array[], src: Socket<any>, data: Uint8Array): void {
  if (queue.length) {
    queue.push(Buffer.from(data));
    src.pause();
    return;
  }
  const n = dst.write(data);
  if (n < 0) {
    src.end();
    return;
  }
  if (n < data.length) {
    queue.push(Buffer.from(data.subarray(n)));
    src.pause();
  }
}

function flushQueue(dst: Socket<any>, queue: Uint8Array[], src: Socket<any> | null): void {
  while (queue.length) {
    const chunk = queue[0]!;
    const n = dst.write(chunk);
    if (n < 0) return;
    if (n < chunk.length) {
      queue[0] = chunk.subarray(n);
      return;
    }
    queue.shift();
  }
  src?.resume();
}

export function startIdeGate(opts: { hostname: string; port: number; token: string; upstreamSocket: string }): IdeGate {
  const startingPage = '<!doctype html><meta http-equiv="refresh" content="1"><body style="background:#1e1e1e;color:#ccc;font-family:sans-serif">Starting VS Code…</body>';

  const connectUpstream = (client: Socket<ClientState>) => {
    const st = client.data;
    st.connecting = true;
    client.pause();
    let settled = false;
    const fail = () => {
      if (settled) return;
      settled = true;
      st.connecting = false;
      if (!st.closed) respond(client, 503, startingPage, { 'Retry-After': '1' });
    };
    Bun.connect<UpState>({
      unix: opts.upstreamSocket,
      data: { client, out: [] },
      socket: {
        open(up) {
          settled = true;
          if (st.closed) { up.end(); return; }
          st.up = up;
          st.connecting = false;
          const first = Buffer.concat([st.buf, ...st.early]);
          st.buf = Buffer.alloc(0);
          st.early = [];
          pipeWrite(up, up.data.out, client, first);
          if (!up.data.out.length) client.resume();
        },
        data(up, chunk) {
          pipeWrite(up.data.client, up.data.client.data.out, up, chunk);
        },
        drain(up) {
          flushQueue(up, up.data.out, up.data.client);
        },
        close(up) {
          const c = up.data.client;
          // Don't truncate a response still queued for a slow client.
          if (c.data.out.length) c.data.endAfterFlush = true;
          else c.end();
        },
        error(up) {
          up.data.client.end();
        },
        connectError() {
          fail();
        },
      },
    }).catch(fail);
  };

  const listener: TCPSocketListener<ClientState> = Bun.listen<ClientState>({
    hostname: opts.hostname,
    port: opts.port,
    socket: {
      open(client) {
        client.data = { buf: Buffer.alloc(0), out: [], up: null, connecting: false, early: [], closed: false, endAfterFlush: false };
        if (!isPrivatePeer(client.remoteAddress)) respond(client, 403, 'Forbidden');
      },
      data(client, chunk) {
        const st = client.data;
        if (st.up) return pipeWrite(st.up, st.up.data.out, client, chunk);
        if (st.closed) return;
        if (st.connecting) {
          st.early.push(Buffer.from(chunk));
          return;
        }
        st.buf = Buffer.concat([st.buf, chunk]);
        const end = st.buf.indexOf('\r\n\r\n');
        if (end < 0) {
          if (st.buf.length > MAX_HEAD) respond(client, 431, 'Request headers too large');
          return;
        }
        const decision = gateDecision(st.buf.subarray(0, end).toString('latin1'), opts.token);
        if (decision.kind === 'deny') {
          respond(client, 401, 'Open VS Code from the NexusLink app on your phone.');
        } else if (decision.kind === 'redirect') {
          respond(client, 302, '', {
            Location: decision.location,
            'Set-Cookie': `${IDE_COOKIE}=${opts.token}; Path=/; HttpOnly; SameSite=Lax`,
          });
        } else {
          connectUpstream(client);
        }
      },
      drain(client) {
        flushQueue(client, client.data.out, client.data.up);
        if (client.data.endAfterFlush && !client.data.out.length) client.end();
      },
      close(client) {
        client.data.closed = true;
        client.data.out = [];
        client.data.up?.end();
      },
      error(client) {
        client.data.up?.end();
      },
    },
  });

  return {
    port: listener.port,
    stop() {
      try { listener.stop(true); } catch { /* already stopped */ }
    },
  };
}
