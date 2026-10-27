import { readdirSync, readFileSync, readlinkSync, statSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { cpus } from 'node:os';

/** One /proc scan shared by vitals and the agent-app monitor; sampled at most every 1.5 s. */
export interface ProcSample {
  pid: number;
  ppid: number;
  comm: string;
  state: string;
  uid: number;
  /** Share of the whole machine (0-100), not of one core. */
  cpuPercent: number;
  rssBytes: number;
  startedAt: number;
}

const CLK_TCK = 100;
const PAGE = 4096;
const BOOT = bootTime();
let last: { at: number; ticks: Map<number, number>; list: ProcSample[] } | null = null;
const cmdlines = new Map<number, { start: number; argv: string[] }>();

function bootTime() {
  try { const hit = readFileSync('/proc/stat', 'utf8').match(/^btime (\d+)/m); return hit ? Number(hit[1]) * 1000 : 0; } catch { return 0; }
}

export function sampleProcesses(): ProcSample[] {
  const now = Date.now();
  if (last && now - last.at < 1500) return last.list;
  if (process.platform !== 'linux') return [];
  const ticks = new Map<number, number>();
  const list: ProcSample[] = [];
  const elapsed = last ? (now - last.at) / 1000 : 0;
  const cores = Math.max(1, cpus().length);
  let names: string[] = [];
  try { names = readdirSync('/proc'); } catch { return []; }
  for (const name of names) {
    const pid = Number(name);
    if (!Number.isInteger(pid) || pid <= 0) continue;
    let stat: string;
    try { stat = readFileSync(`/proc/${pid}/stat`, 'utf8'); } catch { continue; }
    const close = stat.lastIndexOf(')');
    if (close < 0) continue;
    const comm = stat.slice(stat.indexOf('(') + 1, close);
    const rest = stat.slice(close + 2).split(' ');
    const used = Number(rest[11]) + Number(rest[12]);
    ticks.set(pid, used);
    const before = last?.ticks.get(pid);
    const cpu = elapsed > 0 && before !== undefined ? ((used - before) / CLK_TCK / elapsed / cores) * 100 : 0;
    let uid = -1;
    try { uid = statSync(`/proc/${pid}`).uid; } catch {}
    list.push({ pid, ppid: Number(rest[1]), comm, state: rest[0], uid, cpuPercent: Math.max(0, Math.round(cpu * 10) / 10),
      rssBytes: Number(rest[21]) * PAGE, startedAt: BOOT + (Number(rest[19]) / CLK_TCK) * 1000 });
  }
  last = { at: now, ticks, list };
  for (const pid of cmdlines.keys()) if (!ticks.has(pid)) cmdlines.delete(pid);
  return list;
}

/** argv of a process, cached per pid+start so reused pids never return stale commands. */
export function commandLine(proc: Pick<ProcSample, 'pid' | 'startedAt'>): string[] {
  const hit = cmdlines.get(proc.pid);
  if (hit && hit.start === proc.startedAt) return hit.argv;
  let argv: string[] = [];
  try { argv = readFileSync(`/proc/${proc.pid}/cmdline`, 'utf8').split('\0').filter(Boolean); } catch {}
  // Chromium/Electron children rewrite their title into one space-joined string.
  if (argv.length === 1 && argv[0].includes(' --')) argv = argv[0].split(' ').filter(Boolean);
  cmdlines.set(proc.pid, { start: proc.startedAt, argv });
  return argv;
}

export function processCwd(pid: number): string | null {
  try { return readlinkSync(`/proc/${pid}/cwd`); } catch { return null; }
}

export function processEnv(pid: number, key: string): string | null {
  try {
    const prefix = `${key}=`;
    return readFileSync(`/proc/${pid}/environ`, 'utf8').split('\0').find(v => v.startsWith(prefix))?.slice(prefix.length) ?? null;
  } catch { return null; }
}

export function childrenOf(list: ProcSample[]) {
  const map = new Map<number, ProcSample[]>();
  for (const p of list) { const kids = map.get(p.ppid); kids ? kids.push(p) : map.set(p.ppid, [p]); }
  return map;
}

/** Every pid in the subtree rooted at `root` (inclusive). */
export function subtree(root: number, children: Map<number, ProcSample[]>): number[] {
  const out: number[] = [];
  const stack = [root];
  while (stack.length) { const pid = stack.pop()!; out.push(pid); for (const kid of children.get(pid) || []) stack.push(kid.pid); }
  return out;
}

/**
 * RSS double-counts Electron's shared pages (Claude/Codex apps read ~40% high), so app
 * memory uses PSS. smaps_rollup is slow (~2 ms each), so it refreshes off-thread.
 */
const pss = new Map<number, { start: number; bytes: number }>();
let pssAt = 0;
let pssRunning = false;
export function memoryBytes(p: ProcSample) { const hit = pss.get(p.pid); return hit && hit.start === p.startedAt ? hit.bytes : p.rssBytes; }
export function refreshPss(list: ProcSample[], maxAgeMs = 15000) {
  if (pssRunning || Date.now() - pssAt < maxAgeMs) return;
  pssRunning = true; pssAt = Date.now();
  void (async () => {
    for (let i = 0; i < list.length; i += 6) {
      await Promise.all(list.slice(i, i + 6).map(async p => {
        try { const m = (await readFile(`/proc/${p.pid}/smaps_rollup`, 'utf8')).match(/^Pss:\s+(\d+)/m); if (m) pss.set(p.pid, { start: p.startedAt, bytes: Number(m[1]) * 1024 }); } catch {}
      }));
    }
    const live = new Set(list.map(p => p.pid));
    for (const pid of pss.keys()) if (!live.has(pid)) pss.delete(pid);
  })().finally(() => { pssRunning = false; });
}
