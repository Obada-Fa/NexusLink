// Tier 3: VS Code on the phone via code-server / openvscode-server.
// The editor UI is a real web app (touch-capable); only the backend runs on the PC.
// The phone loads it in a full-screen WebView using the already-paired host.

import { existsSync } from 'node:fs';
import { homedir } from 'node:os';

type SpawnOpts = Parameters<typeof Bun.spawn>[1];
type Proc = ReturnType<typeof Bun.spawn>;

const IDE_PORT = 45780;

interface IdeProc {
  proc: Proc;
  bin: string;
  cwd: string;
  port: number;
}

let running: IdeProc | null = null;

function which(bin: string): string | null {
  for (const dir of (process.env.PATH ?? '').split(':')) {
    const p = `${dir}/${bin}`;
    if (dir && existsSync(p)) return p;
  }
  return null;
}

export function findIdeBin(): { bin: string; flavor: 'code-server' | 'openvscode' } | null {
  const cs = which('code-server');
  if (cs) return { bin: cs, flavor: 'code-server' };
  const ov = which('openvscode-server');
  if (ov) return { bin: ov, flavor: 'openvscode' };
  return null;
}

export function ideStatus(): {
  available: boolean;
  running: boolean;
  port?: number;
  cwd?: string;
  reason?: string;
} {
  const found = findIdeBin();
  if (!found) {
    return {
      available: false,
      running: false,
      reason:
        'Install code-server (https://code-server.dev) or openvscode-server on the PC, then tap VS Code again.',
    };
  }
  return {
    available: true,
    running: running !== null,
    port: running?.port,
    cwd: running?.cwd,
  };
}

export function startIde(cwd?: string): {
  available: boolean;
  running: boolean;
  port?: number;
  cwd?: string;
  reason?: string;
} {
  const found = findIdeBin();
  if (!found) return ideStatus();
  if (running && running.proc.exitCode === null && !running.proc.killed) {
    return { available: true, running: true, port: running.port, cwd: running.cwd };
  }

  const workdir = cwd && existsSync(cwd) ? cwd : homedir();
  const argv =
    found.flavor === 'code-server'
      ? [
          found.bin,
          '--bind-addr', `0.0.0.0:${IDE_PORT}`,
          '--auth', 'none',
          '--disable-telemetry',
          '--disable-update-check',
        ]
      : [
          found.bin,
          '--host', '0.0.0.0',
          '--port', String(IDE_PORT),
          '--without-connection-token',
        ];

  const proc = Bun.spawn(argv, {
    cwd: workdir,
    stdout: 'ignore',
    stderr: 'ignore',
  } as unknown as SpawnOpts);
  running = { proc, bin: found.bin, cwd: workdir, port: IDE_PORT };
  proc.exited.then(() => {
    if (running?.proc === proc) running = null;
  }).catch(() => {});
  return { available: true, running: true, port: IDE_PORT, cwd: workdir };
}

export function stopIde(): { ok: boolean } {
  if (!running) return { ok: false };
  try {
    running.proc.kill();
  } catch {
    // already gone
  }
  running = null;
  return { ok: true };
}
