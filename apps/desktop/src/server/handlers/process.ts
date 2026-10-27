// Process list + guarded termination for the phone's task manager.
// CPU is the share since the previous /proc sample (not ps's lifetime average),
// shared with vitals/agent monitors through proc-sampler's 1.5 s cache.

import { readFileSync } from 'node:fs';
import { basename } from 'node:path';
import { commandLine, sampleProcesses } from './proc-sampler';

export type ProcessEntry = {
  pid: number;
  /** Executable name (full, not /proc's 15-char comm) */
  name: string;
  /** Share of the whole machine since the previous sample, 0-100. */
  cpuPercent: number;
  memMb: number;
  rssBytes: number;
  ppid: number;
  uid: number;
  /** Owned by the host's user, i.e. killProcess may act on it. */
  own: boolean;
  state: string;
  /** Command line, truncated to 300 chars ('' for kernel threads). */
  command: string;
  startedAt: number;
};

const MAX_COMMAND = 300;
let warmed = false;

/** Prefer argv[0]'s basename when /proc truncated comm to 15 chars. */
export function displayName(comm: string, argv: string[]): string {
  const exe = argv[0] ? basename(argv[0]) : '';
  return exe && comm.length >= 15 && exe.startsWith(comm) ? exe : comm;
}

export async function listProcesses(opts: { limit?: number } = {}): Promise<ProcessEntry[]> {
  const limit = Math.max(1, Math.min(1000, Math.floor(Number(opts.limit) || 200)));
  let list = sampleProcesses();
  // The very first sample has no previous tick counts, so every CPU reads 0;
  // take a second one once instead of shipping a list of zeros.
  if (!warmed) {
    warmed = true;
    if (list.length && list.every((p) => p.cpuPercent === 0)) {
      await new Promise((r) => setTimeout(r, 1600));
      list = sampleProcesses();
    }
  }
  const uid = process.getuid?.() ?? -1;
  return [...list]
    .sort((a, b) => b.cpuPercent - a.cpuPercent || b.rssBytes - a.rssBytes || a.pid - b.pid)
    .slice(0, limit)
    .map((p) => {
      const argv = commandLine(p);
      const command = argv.join(' ');
      return {
        pid: p.pid,
        name: displayName(p.comm, argv),
        cpuPercent: p.cpuPercent,
        memMb: Math.round((p.rssBytes / 1048576) * 10) / 10,
        rssBytes: p.rssBytes,
        ppid: p.ppid,
        uid: p.uid,
        own: p.uid === uid,
        state: p.state,
        command: command.length > MAX_COMMAND ? `${command.slice(0, MAX_COMMAND - 1)}…` : command,
        startedAt: p.startedAt,
      };
    });
}

/** Desktop-session processes whose death logs the user out or kills the host's display. */
const SESSION_CRITICAL = new Set(['systemd', 'Xorg', 'Xwayland', 'gnome-shell', 'gnome-session-b', 'dbus-daemon', 'dbus-broker', 'plasmashell', 'kwin_x11', 'kwin_wayland', 'xfce4-session', 'cinnamon']);

interface ProcIdentity { ppid: number; comm: string; state: string; start: string; ruid: number; euid: number }

/** Read identity from /proc (start ticks guard against pid reuse). */
function readIdentity(pid: number): ProcIdentity | null {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, 'utf8');
    const close = stat.lastIndexOf(')');
    const comm = stat.slice(stat.indexOf('(') + 1, close);
    const rest = stat.slice(close + 2).split(' ');
    const uids = /^Uid:\s+(\d+)\s+(\d+)/m.exec(readFileSync(`/proc/${pid}/status`, 'utf8'));
    return { comm, state: rest[0]!, ppid: Number(rest[1]), start: rest[19]!, ruid: uids ? Number(uids[1]) : -1, euid: uids ? Number(uids[2]) : -1 };
  } catch {
    return null;
  }
}

/** The host process and every ancestor up to init. */
function protectedPids(): Set<number> {
  const out = new Set<number>([1, process.pid]);
  let pid = process.pid;
  for (let i = 0; i < 64 && pid > 1; i++) {
    const id = readIdentity(pid);
    if (!id) break;
    out.add(id.ppid);
    pid = id.ppid;
  }
  if (process.ppid) out.add(process.ppid);
  return out;
}

const alive = (pid: number, start: string) => {
  const id = readIdentity(pid);
  return !!id && id.start === start && id.state !== 'Z' && id.state !== 'X';
};

export type KillResult = { ok: boolean; message: string; signal?: 'SIGTERM' | 'SIGKILL'; exited?: boolean };

/**
 * Terminate one of the host user's processes: SIGTERM, then (force) SIGKILL if
 * it is still the same process after `graceMs`. Refuses pid 1, the host and
 * its ancestors, other users' processes, kernel threads and session-critical
 * desktop processes. Never throws.
 */
export async function killProcess(pid: number, force = false, opts: { graceMs?: number } = {}): Promise<KillResult> {
  if (process.platform !== 'linux') return { ok: false, message: 'Process termination is only supported on Linux hosts.' };
  if (!Number.isSafeInteger(pid) || pid <= 1) return { ok: false, message: 'Invalid process id.' };
  if (protectedPids().has(pid)) return { ok: false, message: 'Refusing to stop NexusLink itself or one of its parent processes.' };
  const id = readIdentity(pid);
  if (!id || id.state === 'Z') return { ok: false, message: 'No such process.' };
  const uid = process.getuid?.() ?? -1;
  if (id.ruid !== uid || id.euid !== uid) return { ok: false, message: `Process ${pid} (${id.comm}) belongs to another user.` };
  if (id.ppid === 2 || id.ppid === 0) return { ok: false, message: 'Kernel threads cannot be stopped.' };
  if (SESSION_CRITICAL.has(id.comm)) return { ok: false, message: `${id.comm} is part of the desktop session; stopping it would log you out.` };
  const grace = Math.max(0, Math.min(10_000, opts.graceMs ?? 3000));
  try {
    process.kill(pid, 'SIGTERM');
  } catch (e: any) {
    return { ok: false, message: e?.code === 'ESRCH' ? 'No such process.' : e?.code === 'EPERM' ? 'Permission denied.' : 'Could not signal the process.' };
  }
  const deadline = Date.now() + grace;
  while (Date.now() < deadline && alive(pid, id.start)) await new Promise((r) => setTimeout(r, 100));
  if (!alive(pid, id.start)) return { ok: true, message: `${id.comm} (${pid}) exited.`, signal: 'SIGTERM', exited: true };
  if (!force) return { ok: true, message: `Sent SIGTERM to ${id.comm} (${pid}); it is still running.`, signal: 'SIGTERM', exited: false };
  try {
    // Same start time → still the process we were asked about, not a reused pid.
    if (alive(pid, id.start)) process.kill(pid, 'SIGKILL');
  } catch (e: any) {
    if (e?.code !== 'ESRCH') return { ok: false, message: 'Could not force-stop the process.', signal: 'SIGTERM' };
  }
  for (let i = 0; i < 20 && alive(pid, id.start); i++) await new Promise((r) => setTimeout(r, 50));
  const exited = !alive(pid, id.start);
  return { ok: exited, message: exited ? `${id.comm} (${pid}) was force-stopped.` : `${id.comm} (${pid}) did not exit.`, signal: 'SIGKILL', exited };
}

