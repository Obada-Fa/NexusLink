import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import type { RemoteServiceHealth } from '@nexuslink/rpc-types';
import { sampleProcesses, commandLine, processEnv } from './proc-sampler';
import { tailscaleIpv4FromCli } from '../launch-banner';

/**
 * Health of the ways the owner reaches this PC (RustDesk, Tailscale, NexusLink), plus a
 * RustDesk watchdog. Observed failure: at boot rustdesk.service binds its user --server to
 * a transient display (DISPLAY=:1, "cannot open display") and stays broken until a manual
 * `systemctl restart rustdesk`. The watchdog detects that and repairs it.
 */
type Repair = { at: number; reason: string };
let lastRepair: Repair | null = null;
let failingSince: number | null = null;
let repairs: number[] = [];
let cache: { at: number; value: RemoteServiceHealth[] } | null = null;
const startedAt = Date.now();

function run(cmd: string[], timeout = 2500) {
  try {
    const out = Bun.spawnSync(cmd, { stdout: 'pipe', stderr: 'pipe', timeout } as any);
    return { code: out.exitCode ?? -1, out: out.stdout?.toString().trim() || '', err: out.stderr?.toString().trim() || '' };
  } catch (error) { return { code: -1, out: '', err: error instanceof Error ? error.message : 'failed' }; }
}

/** The user's real X display: the socket in /tmp/.X11-unix owned by this uid, else $DISPLAY. */
function sessionDisplay() {
  const uid = process.getuid?.() ?? -1;
  try {
    for (const name of readdirSync('/tmp/.X11-unix')) {
      if (/^X\d+$/.test(name) && statSync(`/tmp/.X11-unix/${name}`).uid === uid) return `:${name.slice(1)}`;
    }
  } catch {}
  return process.env.DISPLAY || ':0';
}

function listening(port: number) {
  try {
    const hex = port.toString(16).toUpperCase().padStart(4, '0');
    for (const file of ['/proc/net/tcp6', '/proc/net/tcp']) {
      const text = existsSync(file) ? readFileSync(file, 'utf8') : '';
      if (text.split('\n').some(l => { const f = l.trim().split(/\s+/); return f[1]?.endsWith(`:${hex}`) && f[3] === '0A'; })) return true;
    }
  } catch {}
  return false;
}

function rustdeskLogTail() {
  const dir = join(homedir(), '.local/share/logs/RustDesk/server');
  try {
    const text = readFileSync(join(dir, 'rustdesk_rCURRENT.log'), 'utf8');
    return text.slice(-6000);
  } catch { return ''; }
}

export function rustdeskHealth(): RemoteServiceHealth {
  const installed = existsSync('/usr/share/rustdesk/rustdesk.bin') || existsSync('/usr/bin/rustdesk');
  const base: RemoteServiceHealth = { id: 'rustdesk', name: 'RustDesk', installed, state: 'unknown', summary: '', issues: [], details: {},
    actions: [], lastRepairAt: lastRepair?.at ?? null, lastRepairReason: lastRepair?.reason ?? null };
  if (!installed) return { ...base, state: 'unknown', summary: 'Not installed on this PC.' };
  const service = run(['systemctl', 'is-active', 'rustdesk.service']).out || 'unknown';
  const uid = process.getuid?.() ?? -1;
  const servers = sampleProcesses().filter(p => p.uid === uid && /rustdesk/.test(p.comm) && commandLine(p).includes('--server') && p.state !== 'Z');
  const server = servers[0];
  const expected = sessionDisplay();
  const display = server ? processEnv(server.pid, 'DISPLAY') : null;
  const port = listening(21118);
  const flatpak = existsSync('/var/lib/flatpak/app/com.rustdesk.RustDesk') || existsSync(join(homedir(), '.local/share/flatpak/app/com.rustdesk.RustDesk'));
  const log = rustdeskLogTail();
  const rendezvousError = /rendezvous mediator error/.test(log.split('\n').slice(-30).join('\n')) && !/Latency of/.test(log.split('\n').slice(-30).join('\n'));
  const issues: string[] = [];
  if (service !== 'active') issues.push(`RustDesk service is ${service}.`);
  if (!server) issues.push('RustDesk is not serving this desktop (no --server process).');
  if (server && display && display !== expected) issues.push(`RustDesk is attached to display ${display}, but your desktop is ${expected}.`);
  if (server && !port) issues.push('Direct connections (port 21118) are not listening.');
  if (rendezvousError) issues.push('RustDesk cannot reach its ID server yet.');
  if (flatpak) issues.push('A second RustDesk (Flatpak) is installed and can steal the connection. Run packaging/rustdesk/install.sh once.');
  const blocking = issues.filter(i => !i.includes('Flatpak') && !i.includes('ID server'));
  const state: RemoteServiceHealth['state'] = blocking.length ? (server ? 'degraded' : 'down') : issues.length ? 'degraded' : 'healthy';
  const polkit = existsSync('/etc/polkit-1/rules.d/50-nexuslink-rustdesk.rules');
  return { ...base, state, issues,
    summary: state === 'healthy' ? `Ready on display ${display || expected}${port ? ' · direct port open' : ''}.` : blocking[0] || issues[0],
    details: { service, serverPid: server?.pid ?? null, display, expectedDisplay: expected, directPort: port, flatpakDuplicate: flatpak,
      passwordlessRestart: polkit, serverStartedAt: server?.startedAt ?? null },
    actions: ['restart', 'repair'] };
}

function tailscaleHealth(): RemoteServiceHealth {
  const installed = existsSync('/usr/bin/tailscale') || existsSync('/usr/sbin/tailscaled');
  const ips = installed ? tailscaleIpv4FromCli() : [];
  const status = installed ? run(['tailscale', 'status', '--json'], 2500) : { code: -1, out: '', err: '' };
  let backend = 'unknown'; let peers = 0; let online = 0; let name: string | null = null;
  try { const j = JSON.parse(status.out); backend = j.BackendState; name = j.Self?.HostName ?? null; const list = Object.values(j.Peer || {}) as any[]; peers = list.length; online = list.filter(p => p.Online).length; } catch {}
  const ok = backend === 'Running' && ips.length > 0;
  return { id: 'tailscale', name: 'Tailscale', installed, state: !installed ? 'unknown' : ok ? 'healthy' : 'down',
    summary: !installed ? 'Not installed.' : ok ? `${ips[0]} · ${online}/${peers} devices online` : `Tailscale is ${backend}.`,
    issues: ok || !installed ? [] : [`Tailscale is ${backend}; the phone can only reach this PC on the local network.`],
    details: { ip: ips[0] ?? null, backend, hostName: name, peers, peersOnline: online }, actions: [], lastRepairAt: null, lastRepairReason: null };
}

function nexuslinkHealth(): RemoteServiceHealth {
  const mem = (() => { try { return Number(readFileSync('/proc/self/status', 'utf8').match(/^VmRSS:\s+(\d+)/m)?.[1] ?? 0) * 1024; } catch { return 0; } })();
  return { id: 'nexuslink', name: 'NexusLink host', installed: true, state: 'healthy',
    summary: `Up ${formatAge(Date.now() - startedAt)} · ${Math.round(mem / 1048576)} MB`, issues: [],
    details: { pid: process.pid, startedAt, rssBytes: mem, bun: Bun.version }, actions: [], lastRepairAt: null, lastRepairReason: null };
}

function formatAge(ms: number) { const m = Math.floor(ms / 60000); return m < 60 ? `${m} min` : `${Math.floor(m / 60)} h ${m % 60} min`; }

export function remoteHealth(force = false): RemoteServiceHealth[] {
  if (!force && cache && Date.now() - cache.at < 8000) return cache.value;
  const value = [rustdeskHealth(), tailscaleHealth(), nexuslinkHealth()];
  cache = { at: Date.now(), value };
  return value;
}

/** soft: kill the user --server (the root service respawns it with fresh session detection); hard: restart the service. */
export async function restartRustdesk(reason: string, mode: 'auto' | 'hard' | 'soft' = 'auto'): Promise<{ ok: boolean; message: string }> {
  repairs = repairs.filter(t => Date.now() - t < 30 * 60_000);
  repairs.push(Date.now());
  lastRepair = { at: Date.now(), reason };
  cache = null;
  if (mode !== 'soft') {
    const hard = run(['systemctl', '--no-ask-password', 'restart', 'rustdesk.service'], 15000);
    if (hard.code === 0) { console.log(`[remote] restarted rustdesk.service (${reason})`); return { ok: true, message: 'RustDesk restarted. It takes about 10 seconds to accept connections.' }; }
    if (mode === 'hard') return { ok: false, message: 'This PC needs a one-time setup to let NexusLink restart RustDesk: run `sudo bash packaging/rustdesk/install.sh` in the NexusLink folder.' };
  }
  const uid = process.getuid?.() ?? -1;
  const servers = sampleProcesses().filter(p => p.uid === uid && /rustdesk/.test(p.comm) && commandLine(p).includes('--server'));
  if (!servers.length) return { ok: false, message: 'RustDesk’s service is not running and NexusLink can’t start it without the one-time setup (packaging/rustdesk/install.sh).' };
  for (const p of servers) { try { process.kill(p.pid, 'SIGTERM'); } catch {} }
  console.log(`[remote] restarted rustdesk --server (${reason})`);
  return { ok: true, message: 'Restarted RustDesk’s screen server; the RustDesk service brings it back in a few seconds.' };
}

/** Every 30 s: repair RustDesk when it has been unusable for > 45 s (max 4 repairs / 30 min). */
export function startRemoteWatchdog() {
  const timer = setInterval(async () => {
    if (process.env.NEXUSLINK_DISABLE_WATCHDOG === '1') return;
    const health = rustdeskHealth();
    if (!health.installed) return;
    const broken = health.issues.some(i => /not serving|attached to display|not listening|service is/.test(i)) && health.details.service !== 'inactive';
    if (!broken) { failingSince = null; return; }
    failingSince ??= Date.now();
    // Give a fresh boot or a respawn time to settle before acting.
    if (Date.now() - failingSince < 45_000 || Date.now() - startedAt < 60_000) return;
    if (repairs.filter(t => Date.now() - t < 30 * 60_000).length >= 4) return;
    if (lastRepair && Date.now() - lastRepair.at < 120_000) return;
    failingSince = null;
    await restartRustdesk(`watchdog: ${health.issues[0]}`);
  }, 30_000);
  timer.unref();
  return () => clearInterval(timer);
}
