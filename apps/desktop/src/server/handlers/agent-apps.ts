import { existsSync, readFileSync } from 'node:fs';
import { cpus, homedir } from 'node:os';
import { join } from 'node:path';
import type { AgentAppInstance, AgentAppLauncher, AgentAppAction } from '@nexuslink/rpc-types';
import { sampleProcesses, commandLine, processCwd, childrenOf, subtree, memoryBytes, refreshPss, type ProcSample } from './proc-sampler';

/**
 * Agent apps running on the PC: desktop agent IDEs/apps and agent CLIs, each with its
 * whole process tree's CPU/RAM, windows and a restart that survives NexusLink restarts.
 */
interface AppDef {
  appId: string; name: string; provider: string; kind: 'desktop' | 'cli';
  match(argv: string[], comm: string): boolean;
  desktopFiles?: string[]; fallbackExec?: string[];
}
const base = (s: string | undefined) => (s || '').split('/').pop() || '';
const has = (argv: string[], re: RegExp) => argv.some(a => re.test(a));
const DEFS: AppDef[] = [
  { appId: 'antigravity', name: 'Antigravity', provider: 'antigravity', kind: 'desktop', desktopFiles: ['antigravity.desktop'],
    fallbackExec: [join(homedir(), 'Applications/Antigravity/antigravity')], match: argv => /\/antigravity$/i.test(argv[0] || '') },
  { appId: 'codex-desktop', name: 'Codex', provider: 'codex', kind: 'desktop', desktopFiles: ['chatgpt.desktop', 'codex.desktop'],
    fallbackExec: ['/usr/lib/chatgpt/ChatGPT'], match: argv => /\/chatgpt\/ChatGPT$|\/Codex$/.test(argv[0] || '') },
  { appId: 'claude-desktop', name: 'Claude', provider: 'claude', kind: 'desktop', desktopFiles: ['claude.desktop', 'claude-desktop.desktop'],
    fallbackExec: ['/usr/lib/claude-desktop/claude-desktop'], match: argv => /claude-desktop$/.test(argv[0] || '') },
  { appId: 'cursor', name: 'Cursor', provider: 'cursor', kind: 'desktop', desktopFiles: ['cursor.desktop'],
    match: argv => /\/cursor$/i.test(argv[0] || '') && !has(argv, /cursor-agent/) },
  { appId: 'windsurf', name: 'Windsurf', provider: 'windsurf', kind: 'desktop', desktopFiles: ['windsurf.desktop'], match: argv => /\/windsurf$/i.test(argv[0] || '') },
  { appId: 'vscode', name: 'VS Code', provider: 'vscode', kind: 'desktop', desktopFiles: ['code.desktop'], match: argv => /\/(code|code-insiders)$/.test(argv[0] || '') && has(argv, /\/(share|lib)\/code/) },
  { appId: 'claude-code', name: 'Claude Code', provider: 'claude', kind: 'cli',
    match: (argv, comm) => comm === 'claude' || (base(argv[0]) === 'claude') || has(argv, /@anthropic-ai\/claude-code|claude-code\/cli\.js/) },
  { appId: 'codex-cli', name: 'Codex CLI', provider: 'codex', kind: 'cli',
    match: (argv, comm) => (comm === 'codex' || base(argv[0]) === 'codex' || has(argv, /@openai\/codex/)) && !/\/usr\/lib\/chatgpt\//.test(argv[0] || '') },
  { appId: 'gemini-cli', name: 'Gemini CLI', provider: 'gemini', kind: 'cli', match: (argv, comm) => comm === 'gemini' || has(argv, /@google\/gemini-cli|\/gemini-cli\//) },
  { appId: 'opencode', name: 'OpenCode', provider: 'opencode', kind: 'cli', match: (argv, comm) => comm === 'opencode' || comm === '.opencode' || base(argv[0]) === 'opencode' },
  { appId: 'cursor-agent', name: 'Cursor Agent', provider: 'cursor', kind: 'cli', match: (argv, comm) => comm === 'cursor-agent' || has(argv, /cursor-agent/) },
  { appId: 'aider', name: 'Aider', provider: 'aider', kind: 'cli', match: argv => has(argv, /\/aider$|bin\/aider\b/) },
];

const history = new Map<string, { cpu: number[]; hotSince: number | null }>();
const lastExec = new Map<string, string[]>();
let windowCache: { at: number; list: { id: string; pid: number; title: string }[] } | null = null;
const busyActions = new Map<string, Promise<unknown>>();

function windows() {
  if (windowCache && Date.now() - windowCache.at < 4000) return windowCache.list;
  const out = Bun.spawnSync(['wmctrl', '-lp'], { env: guiEnv(), stderr: 'ignore', timeout: 3000 } as any).stdout?.toString() || '';
  const list = out.split('\n').map(line => line.match(/^(0x[0-9a-f]+)\s+-?\d+\s+(\d+)\s+\S+\s+(.*)$/i)).filter(Boolean)
    .map(m => ({ id: m![1], pid: Number(m![2]), title: m![3] }));
  windowCache = { at: Date.now(), list };
  return list;
}

/** Which agent app a process belongs to, from its argv + comm (pure; exported for tests). */
export function matchAgentApp(argv: string[], comm: string): { appId: string; kind: 'desktop' | 'cli' } | null {
  if (!argv.length) return null;
  const d = DEFS.find(x => x.match(argv, comm));
  return d ? { appId: d.appId, kind: d.kind } : null;
}

function classify(p: ProcSample) {
  const argv = commandLine(p);
  if (!argv.length) return null;
  return DEFS.find(d => d.match(argv, p.comm)) || null;
}

export function listAgentApps(): { apps: AgentAppInstance[]; launchers: AgentAppLauncher[] } {
  const uid = process.getuid?.() ?? -1;
  const procs = sampleProcesses().filter(p => p.uid === uid);
  const byPid = new Map(procs.map(p => [p.pid, p]));
  const kids = childrenOf(procs);
  const defOf = new Map<number, AppDef | null>();
  const def = (p: ProcSample) => { if (!defOf.has(p.pid)) defOf.set(p.pid, classify(p)); return defOf.get(p.pid)!; };
  const cores = Math.max(1, cpus().length);
  const wins = windows();
  const claimed = new Set<number>();
  const apps: AgentAppInstance[] = [];
  const allMembers: ProcSample[] = [];
  // Parents before children: the top-most match owns the whole tree (e.g. Codex app → codex app-server).
  const ordered = [...procs].sort((a, b) => a.startedAt - b.startedAt || a.pid - b.pid);
  for (const p of ordered) {
    if (claimed.has(p.pid)) continue;
    const d = def(p);
    if (!d) continue;
    if (d.kind === 'desktop' && commandLine(p).some(a => a.startsWith('--type='))) continue;
    let ancestor = byPid.get(p.ppid); let nested = false;
    while (ancestor) { const a = def(ancestor); if (a && (a === d || a.kind === 'desktop')) { nested = true; break; } ancestor = byPid.get(ancestor.ppid); }
    if (nested) continue;
    const tree = subtree(p.pid, kids);
    tree.forEach(pid => claimed.add(pid));
    const members = tree.map(pid => byPid.get(pid)).filter(Boolean) as ProcSample[];
    const cpu = Math.round(members.reduce((a, m) => a + m.cpuPercent, 0) * 10) / 10;
    const rss = members.reduce((a, m) => a + memoryBytes(m), 0);
    allMembers.push(...members);
    const id = d.kind === 'desktop' ? d.appId : `${d.appId}:${p.pid}`;
    const h = history.get(id) || { cpu: [], hotSince: null };
    h.cpu.push(cpu); if (h.cpu.length > 40) h.cpu.shift();
    const hottest = Math.max(...members.map(m => m.cpuPercent));
    h.hotSince = hottest * cores / 100 >= 0.95 ? (h.hotSince ?? Date.now()) : null;
    history.set(id, h);
    const recent = h.cpu.slice(-3); const avgCores = (recent.reduce((a, b) => a + b, 0) / recent.length) * cores / 100;
    const state: AgentAppInstance['state'] = d.kind === 'desktop' && h.hotSince && Date.now() - h.hotSince > 90_000 ? 'stuck'
      : avgCores > 0.5 ? 'busy' : avgCores > 0.04 ? 'active' : 'idle';
    const treeSet = new Set(tree);
    const appWindows = wins.filter(w => treeSet.has(w.pid)).map(w => ({ id: w.id, title: w.title }));
    if (d.kind === 'desktop') lastExec.set(d.appId, commandLine(p).slice(0, 1));
    const tty = (() => { try { const n = Number(readFileSync(`/proc/${p.pid}/stat`, 'utf8').split(') ')[1].split(' ')[4]); return n > 0 ? `pts/${n & 0xff}` : null; } catch { return null; } })();
    apps.push({ id, appId: d.appId, name: d.name, provider: d.provider, kind: d.kind, pid: p.pid, processCount: members.length,
      cpuPercent: cpu, rssBytes: rss, startedAt: p.startedAt, cwd: d.kind === 'cli' ? processCwd(p.pid) : null, tty: d.kind === 'cli' ? tty : null,
      state, windows: appWindows, cpuHistory: h.cpu.slice(-24),
      actions: d.kind === 'desktop' ? ['focus', 'restart', 'quit', 'kill'] : ['kill'] });
  }
  refreshPss(allMembers);
  for (const key of history.keys()) if (!apps.some(a => a.id === key)) history.delete(key);
  const running = new Set(apps.map(a => a.appId));
  const launchers = DEFS.filter(d => d.kind === 'desktop' && (running.has(d.appId) || launchTarget(d)))
    .map(d => ({ appId: d.appId, name: d.name, provider: d.provider, kind: d.kind, running: running.has(d.appId) }));
  apps.sort((a, b) => Number(a.kind === 'cli') - Number(b.kind === 'cli') || b.cpuPercent - a.cpuPercent);
  return { apps, launchers };
}

function desktopFile(name: string) {
  for (const dir of [join(homedir(), '.local/share/applications'), '/usr/share/applications', '/usr/local/share/applications',
    '/var/lib/flatpak/exports/share/applications', join(homedir(), '.local/share/flatpak/exports/share/applications')]) {
    const path = join(dir, name); if (existsSync(path)) return path;
  }
  return null;
}
function launchTarget(d: AppDef): { desktop?: string; exec?: string[] } | null {
  for (const name of d.desktopFiles || []) { const path = desktopFile(name); if (path) return { desktop: path }; }
  const exec = lastExec.get(d.appId) || d.fallbackExec;
  return exec && existsSync(exec[0]) ? { exec } : null;
}

/** The real desktop session environment (from gnome-shell), so relaunched apps behave as if clicked on the PC. */
export function guiEnv(): Record<string, string> {
  const env: Record<string, string> = { ...process.env as Record<string, string> };
  const uid = process.getuid?.() ?? 1000;
  const shell = sampleProcesses().find(p => p.uid === uid && ['gnome-shell', 'gnome-session-b', 'plasmashell', 'xfce4-session', 'cinnamon'].includes(p.comm));
  if (shell) {
    try {
      for (const pair of readFileSync(`/proc/${shell.pid}/environ`, 'utf8').split('\0')) {
        const i = pair.indexOf('='); if (i > 0) env[pair.slice(0, i)] = pair.slice(i + 1);
      }
    } catch {}
  }
  env.DISPLAY ||= ':0';
  env.XDG_RUNTIME_DIR ||= `/run/user/${uid}`;
  env.DBUS_SESSION_BUS_ADDRESS ||= `unix:path=/run/user/${uid}/bus`;
  if (!env.XAUTHORITY && existsSync(`/run/user/${uid}/gdm/Xauthority`)) env.XAUTHORITY = `/run/user/${uid}/gdm/Xauthority`;
  return env;
}

/**
 * Launch outside nexuslink.service's cgroup. A plain child would be killed by systemd
 * the next time NexusLink restarts; a transient user scope lives on like a GNOME launch.
 */
export function launchDetached(command: string[], name: string) {
  const unit = `app-nexuslink-${name.replace(/[^a-zA-Z0-9]/g, '')}-${Date.now()}`;
  const scoped = existsSync('/usr/bin/systemd-run') || existsSync('/bin/systemd-run')
    ? ['systemd-run', '--user', '--scope', '--collect', '--quiet', `--unit=${unit}`, '--', ...command] : ['setsid', ...command];
  const child = Bun.spawn(scoped, { env: guiEnv(), stdin: 'ignore', stdout: 'ignore', stderr: 'ignore', cwd: homedir() });
  child.unref();
}

function alive(pid: number) { try { process.kill(pid, 0); return true; } catch { return false; } }
async function waitGone(pids: number[], ms: number) {
  const until = Date.now() + ms;
  while (Date.now() < until) { if (!pids.some(alive)) return true; await Bun.sleep(250); }
  return !pids.some(alive);
}
function treeOf(instance: AgentAppInstance) {
  const procs = sampleProcesses();
  return subtree(instance.pid, childrenOf(procs)).filter(pid => procs.some(p => p.pid === pid));
}
async function stopInstance(instance: AgentAppInstance, graceful: boolean) {
  const pids = treeOf(instance);
  if (graceful && instance.windows.length) {
    for (const w of instance.windows) Bun.spawnSync(['wmctrl', '-i', '-c', w.id], { env: guiEnv(), stderr: 'ignore', timeout: 3000 } as any);
    if (await waitGone([instance.pid], 6000)) return 'closed';
  }
  for (const pid of [instance.pid, ...pids]) { try { process.kill(pid, 'SIGTERM'); } catch {} }
  if (await waitGone(pids, 3000)) return 'terminated';
  for (const pid of pids) { try { process.kill(pid, 'SIGKILL'); } catch {} }
  await waitGone(pids, 1500);
  return 'killed';
}

export async function agentAppAction(params: { instanceId?: string; appId?: string; action: AgentAppAction }): Promise<{ ok: boolean; message: string }> {
  const key = params.instanceId || params.appId || '';
  if (busyActions.has(key)) return { ok: false, message: 'Already working on that app — give it a few seconds.' };
  const run = (async () => {
    const { apps } = listAgentApps();
    const instance = apps.find(a => a.id === params.instanceId) || apps.find(a => a.appId === params.appId);
    const d = DEFS.find(x => x.appId === (instance?.appId || params.appId));
    if (!d) return { ok: false, message: 'Unknown app.' };
    if (params.action === 'launch') {
      if (instance) return { ok: true, message: `${d.name} is already running.` };
      return launch(d);
    }
    if (!instance) return { ok: false, message: `${d.name} is not running.` };
    if (!instance.actions.includes(params.action)) return { ok: false, message: `That action is not available for ${d.name}.` };
    if (params.action === 'focus') {
      const w = instance.windows[0]; if (!w) return { ok: false, message: `${d.name} has no window to focus.` };
      Bun.spawnSync(['wmctrl', '-i', '-a', w.id], { env: guiEnv(), stderr: 'ignore', timeout: 3000 } as any);
      return { ok: true, message: `Brought ${d.name} to the front.` };
    }
    const how = await stopInstance(instance, params.action !== 'kill');
    windowCache = null;
    if (params.action !== 'restart') return { ok: true, message: `${d.name} ${how === 'closed' ? 'closed' : how === 'terminated' ? 'stopped' : 'force-stopped'}.` };
    await Bun.sleep(600);
    const started = launch(d);
    return started.ok ? { ok: true, message: `${d.name} restarted${how === 'killed' ? ' (it had to be force-stopped)' : ''}.` } : started;
  })();
  busyActions.set(key, run);
  try { return await run; } finally { busyActions.delete(key); }
}

function launch(d: AppDef) {
  const target = launchTarget(d);
  if (!target) return { ok: false, message: `Couldn’t find how to start ${d.name} on this PC.` };
  launchDetached(target.desktop ? ['gio', 'launch', target.desktop] : target.exec!, d.appId);
  return { ok: true, message: `Starting ${d.name}…` };
}
