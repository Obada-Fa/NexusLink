// Virtual app sessions (Tier 1): each launched app gets its own headless X
// server (Xvfb) sized exactly to the phone's screen, with a minimal WM
// (openbox) that strips decorations and maximizes everything. The host's real
// desktop is never touched; capture and input bind to the session's DISPLAY
// and map 1:1 to the phone — no adopt/crop/letterbox math anywhere.

import { mkdirSync, existsSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import type { AppSessionInfo, WsMessage } from '@nexuslink/rpc-types';
import {
  getProfile, listProfiles, resolveChromiumBin, buildChromiumArgv,
  type LaunchContext,
} from './app-profiles';
import { getDesktopEntry, resolveIconPublic } from './windows';

type SpawnOpts = Parameters<typeof Bun.spawn>[1];
type Proc = ReturnType<typeof Bun.spawn>;

/** Display numbers reserved for NexusLink virtual screens. */
const DISPLAY_BASE = 50;
const DISPLAY_MAX = 99;

/**
 * Cap on session pixels: streaming/encoding cost grows with area, and phones
 * with 3x+ DPRs would otherwise ask for 1440x3120 surfaces. ~2.2MP keeps a
 * portrait session around 1000x2160 — crisp on the phone, cheap to encode.
 */
const MAX_SESSION_PIXELS = 2_200_000;

/** How long an exited session's tombstone stays visible in appSession.list. */
const EXITED_TTL_MS = 60_000;

interface AppSession {
  info: AppSessionInfo;
  displayNum: number;
  xvfb: Proc;
  wm: Proc | null;
  app: Proc | null;
  sessionDir: string;
  /** PulseAudio null-sink module id, if audio was set up. */
  pulseModule: number | null;
  /** Name of the pulse sink whose .monitor the WebRTC pipeline captures. */
  pulseSink: string | null;
  /** Keep re-fitting Chrome after it remaps (first paint often undoes size). */
  fitTimer: ReturnType<typeof setInterval> | null;
}

const sessions = new Map<string, AppSession>();

type BroadcastFn = (msg: WsMessage) => void;
let broadcast: BroadcastFn = () => {};

export function setSessionBroadcast(fn: BroadcastFn): void {
  broadcast = fn;
}

function run(cmd: string[], env?: Record<string, string>): { ok: boolean; stdout: string } {
  try {
    const out = Bun.spawnSync(cmd, {
      env: { ...process.env, ...env },
      stderr: 'ignore',
    } as unknown as SpawnOpts);
    return { ok: out.exitCode === 0, stdout: out.stdout?.toString() ?? '' };
  } catch {
    return { ok: false, stdout: '' };
  }
}

function findFreeDisplay(): number {
  for (let n = DISPLAY_BASE; n <= DISPLAY_MAX; n++) {
    const taken =
      existsSync(`/tmp/.X${n}-lock`) || existsSync(`/tmp/.X11-unix/X${n}`) ||
      [...sessions.values()].some((s) => s.displayNum === n);
    if (!taken) return n;
  }
  throw new Error('no free virtual display slots');
}

async function waitForX(display: string, timeoutMs = 6000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (run(['xdpyinfo', '-display', display]).ok) return;
    await Bun.sleep(100);
  }
  throw new Error(`virtual display ${display} did not come up`);
}

/** Openbox config: no decorations, everything maximized — apps fill the phone. */
const OPENBOX_RC = `<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <applications>
    <application type="normal">
      <decor>no</decor>
      <maximized>yes</maximized>
    </application>
    <application class="*">
      <decor>no</decor>
      <maximized>yes</maximized>
    </application>
  </applications>
</openbox_config>
`;

/** Phone-OS sessions are always portrait; landscape rotation letterboxes on the client. */
export function ensurePortrait(width: number, height: number): { width: number; height: number } {
  const w = Math.max(1, Math.round(width));
  const h = Math.max(1, Math.round(height));
  return w <= h ? { width: w, height: h } : { width: h, height: w };
}

function listSessionWindowIds(display: string): string[] {
  const env = { DISPLAY: display };
  const wm = run(['wmctrl', '-l'], env);
  if (wm.ok && wm.stdout.trim()) {
    return wm.stdout.split('\n').flatMap((line) => {
      const m = line.match(/^(0x[0-9a-f]+)/i);
      return m ? [m[1]!] : [];
    });
  }
  const xd = run(['xdotool', 'search', '--onlyvisible'], env);
  return xd.stdout.split('\n').map((s) => s.trim()).filter(Boolean);
}

function fitWindowsOnce(
  display: string,
  width: number,
  height: number,
  mode: 'maximize' | 'fullscreen',
): number {
  const env = { DISPLAY: display };
  const ids = listSessionWindowIds(display);
  for (const id of ids) {
    run(['wmctrl', '-i', '-r', id, '-e', `0,0,0,${width},${height}`], env);
    run(['xdotool', 'windowmove', id, '0', '0'], env);
    run(['xdotool', 'windowsize', id, String(width), String(height)], env);
    if (mode === 'fullscreen') {
      run(['wmctrl', '-i', '-r', id, '-b', 'add,fullscreen'], env);
    } else {
      run(['wmctrl', '-i', '-r', id, '-b', 'add,maximized_vert,maximized_horz'], env);
    }
  }
  return ids.length;
}

async function fillSessionWindows(
  display: string,
  width: number,
  height: number,
  mode: 'maximize' | 'fullscreen',
  timeoutMs = 3000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (fitWindowsOnce(display, width, height, mode) > 0) return;
    await Bun.sleep(150);
  }
}

function scheduleRefit(
  session: AppSession,
  width: number,
  height: number,
  mode: 'maximize' | 'fullscreen',
): void {
  if (session.fitTimer) clearInterval(session.fitTimer);
  const started = Date.now();
  session.fitTimer = setInterval(() => {
    if (!sessions.has(session.info.sessionId) || Date.now() - started > 8000) {
      if (session.fitTimer) clearInterval(session.fitTimer);
      session.fitTimer = null;
      return;
    }
    fitWindowsOnce(session.info.display, width, height, mode);
  }, 400);
}

/**
 * Effective render scale: honor the phone's DPR but clamp total pixels so the
 * encode/stream stays cheap. Aspect ratio is always preserved exactly.
 */
export function computeSessionGeometry(
  logicalW: number,
  logicalH: number,
  dpr: number,
): { width: number; height: number; dpr: number } {
  const wantDpr = Math.max(1, Math.min(4, dpr || 1));
  const area = logicalW * logicalH * wantDpr * wantDpr;
  const scale = area > MAX_SESSION_PIXELS ? Math.sqrt(MAX_SESSION_PIXELS / (logicalW * logicalH)) : wantDpr;
  // Even-align for the video pipeline (x264/x11grab want mod-2 dimensions).
  const width = Math.max(200, Math.round(logicalW * scale)) & ~1;
  const height = Math.max(200, Math.round(logicalH * scale)) & ~1;
  return { width, height, dpr: Math.round((width / logicalW) * 100) / 100 };
}

function sessionEnv(session: AppSession, extra?: Record<string, string>): Record<string, string> {
  const { dpr } = session.info;
  const intScale = String(Math.max(1, Math.round(dpr)));
  const env: Record<string, string> = {
    ...process.env as Record<string, string>,
    DISPLAY: session.info.display,
    // Finger-sized UI for toolkit apps. Chrome overrides these via its profile.
    GDK_SCALE: intScale,
    GDK_DPI_SCALE: '1',
    QT_AUTO_SCREEN_SCALE_FACTOR: '0',
    QT_SCALE_FACTOR: intScale,
    XCURSOR_SIZE: String(24 * Math.max(1, Math.round(dpr))),
    XFT_DPI: String(Math.round(96 * dpr)),
    // Never leak the host's real session bus targets into virtual apps.
    ...(extra ?? {}),
  };
  if (session.pulseSink) env.PULSE_SINK = session.pulseSink;
  return env;
}

function setupAudio(session: AppSession): void {
  const sinkName = `nexuslink_${session.displayNum}`;
  const res = run([
    'pactl', 'load-module', 'module-null-sink',
    `sink_name=${sinkName}`,
    `sink_properties=device.description=NexusLink-${session.displayNum}`,
  ]);
  if (res.ok) {
    const moduleId = parseInt(res.stdout.trim(), 10);
    session.pulseModule = Number.isFinite(moduleId) ? moduleId : null;
    session.pulseSink = sinkName;
  }
}

export async function createAppSession(
  appId: string,
  logicalW: number,
  logicalH: number,
  dpr = 1,
): Promise<AppSessionInfo> {
  const portrait = ensurePortrait(logicalW, logicalH);
  const geo = computeSessionGeometry(portrait.width, portrait.height, dpr);
  const displayNum = findFreeDisplay();
  const display = `:${displayNum}`;
  const sessionId = crypto.randomUUID();
  const sessionDir = join(tmpdir(), 'nexuslink-sessions', sessionId);
  mkdirSync(sessionDir, { recursive: true });

  // Resolve what to launch BEFORE paying for an X server.
  const profile = getProfile(appId);
  const desktopEntry = profile ? null : await getDesktopEntry(appId);
  if (!profile && !desktopEntry?.exec) {
    rmSync(sessionDir, { recursive: true, force: true });
    throw new Error(`unknown app: ${appId}`);
  }

  const name = profile?.name ?? desktopEntry?.name ?? appId;
  const icon = await resolveIconPublic(profile?.iconName ?? desktopEntry?.iconName);

  const xvfb = Bun.spawn(
    [
      'Xvfb', display,
      '-screen', '0', `${geo.width}x${geo.height}x24`,
      '-dpi', String(Math.round(96 * geo.dpr)),
      '-nolisten', 'tcp',
      '+extension', 'RANDR',
    ],
    { stdout: 'ignore', stderr: 'ignore' } as unknown as SpawnOpts,
  );

  const info: AppSessionInfo = {
    sessionId,
    appId,
    name,
    icon,
    display,
    width: geo.width,
    height: geo.height,
    dpr: geo.dpr,
    createdAt: Date.now(),
    status: 'starting',
  };
  const session: AppSession = {
    info, displayNum, xvfb, wm: null, app: null, sessionDir,
    pulseModule: null, pulseSink: null, fitTimer: null,
  };
  sessions.set(sessionId, session);

  try {
    await waitForX(display);

    const resources = `Xft.dpi: ${Math.round(96 * geo.dpr)}\n`;
    const resPath = join(sessionDir, '.Xresources');
    await Bun.write(resPath, resources);
    run(['xrdb', '-merge', resPath], { DISPLAY: display });

    const rcPath = join(sessionDir, 'openbox-rc.xml');
    await Bun.write(rcPath, OPENBOX_RC);
    session.wm = Bun.spawn(['openbox', '--config-file', rcPath], {
      stdout: 'ignore',
      stderr: 'ignore',
      env: { ...process.env, DISPLAY: display },
    } as unknown as SpawnOpts);

    setupAudio(session);

    const ctx: LaunchContext = { width: geo.width, height: geo.height, dpr: geo.dpr, sessionDir };
    let argv: string[];
    let extraEnv: Record<string, string> | undefined;
    const chromiumBin = profile ? null : resolveChromiumBin(appId, desktopEntry?.exec);
    if (profile) {
      argv = profile.buildArgv(ctx);
      extraEnv = profile.buildEnv?.(ctx);
    } else if (chromiumBin) {
      // Brave/Chrome/Chromium .desktop Exec reuses the desktop profile and
      // exits if that browser is already open. Give the virtual session its
      // own user-data-dir plus mobile UA/scale so it actually appears.
      argv = buildChromiumArgv(chromiumBin, ctx);
      extraEnv = { GDK_SCALE: '1', QT_SCALE_FACTOR: '1' };
    } else {
      // .desktop Exec with field codes stripped, run through sh for quoting.
      const exec = (desktopEntry!.exec ?? '').replace(/%[fFuUdDnNickvm]/g, '').trim();
      argv = ['sh', '-c', exec];
    }

    session.app = Bun.spawn(argv, {
      stdout: 'ignore',
      stderr: 'ignore',
      cwd: sessionDir,
      env: sessionEnv(session, extraEnv),
    } as unknown as SpawnOpts);

    session.app.exited.then(() => {
      if (!sessions.has(sessionId) || info.status === 'exited') return;
      markExited(sessionId);
    }).catch(() => {});

    const fillMode = profile || chromiumBin ? 'fullscreen' : 'maximize';
    await fillSessionWindows(
      display,
      geo.width,
      geo.height,
      fillMode,
      fillMode === 'fullscreen' ? 5000 : 2500,
    );
    scheduleRefit(session, geo.width, geo.height, fillMode);

    info.status = 'running';
    broadcast({ type: 'app-session-update', session: { ...info } });
    return { ...info };
  } catch (err) {
    teardown(session);
    sessions.delete(sessionId);
    throw err;
  }
}

function markExited(sessionId: string): void {
  const session = sessions.get(sessionId);
  if (!session) return;
  session.info.status = 'exited';
  teardown(session);
  broadcast({ type: 'app-session-update', session: { ...session.info } });
  setTimeout(() => sessions.delete(sessionId), EXITED_TTL_MS);
}

function teardown(session: AppSession): void {
  if (session.fitTimer) {
    clearInterval(session.fitTimer);
    session.fitTimer = null;
  }
  for (const proc of [session.app, session.wm, session.xvfb]) {
    try {
      proc?.kill();
    } catch {
      // already gone
    }
  }
  if (session.pulseModule !== null) {
    run(['pactl', 'unload-module', String(session.pulseModule)]);
    session.pulseModule = null;
  }
  rmSync(session.sessionDir, { recursive: true, force: true });
}

export function listAppSessions(): AppSessionInfo[] {
  return [...sessions.values()].map((s) => ({ ...s.info }));
}

export function getAppSession(sessionId: string): AppSessionInfo | null {
  const s = sessions.get(sessionId);
  return s && s.info.status !== 'exited' ? { ...s.info } : null;
}

/** DISPLAY string for capture/input binding, or null if the session is gone. */
export function getSessionDisplay(sessionId: string): string | null {
  const s = sessions.get(sessionId);
  return s && s.info.status !== 'exited' ? s.info.display : null;
}

/** Pulse monitor source for the session's audio, if audio capture is available. */
export function getSessionAudioSource(sessionId: string): string | null {
  const s = sessions.get(sessionId);
  return s?.pulseSink ? `${s.pulseSink}.monitor` : null;
}

/**
 * Xvfb cannot add RANDR modes after creation. Try `xrandr --fb` anyway (some
 * Xvfb builds honor it); otherwise the client letterboxes on rotation.
 */
export function resizeAppSession(
  sessionId: string,
  width: number,
  height: number,
): { width: number; height: number; resized: boolean } {
  const s = sessions.get(sessionId);
  if (!s) throw new Error('unknown session');
  const w = Math.max(200, Math.round(width)) & ~1;
  const h = Math.max(200, Math.round(height)) & ~1;
  const ok = run(
    ['xrandr', '--fb', `${w}x${h}`],
    { DISPLAY: s.info.display },
  ).ok;
  if (ok) {
    s.info.width = w;
    s.info.height = h;
    broadcast({ type: 'app-session-update', session: { ...s.info } });
    return { width: w, height: h, resized: true };
  }
  return { width: s.info.width, height: s.info.height, resized: false };
}

export function closeAppSession(sessionId: string): { ok: boolean } {
  const session = sessions.get(sessionId);
  if (!session) return { ok: false };
  session.info.status = 'exited';
  teardown(session);
  broadcast({ type: 'app-session-update', session: { ...session.info } });
  sessions.delete(sessionId);
  return { ok: true };
}

/** Kill every session (host shutdown). */
export function closeAllAppSessions(): void {
  for (const id of [...sessions.keys()]) closeAppSession(id);
}

/** Built-in profile apps (e.g. the mobile browser) surfaced in apps.list. */
export function listProfileApps(): { appId: string; name: string; iconName?: string }[] {
  return listProfiles().map((p) => ({ appId: p.appId, name: p.name, iconName: p.iconName }));
}

process.on('exit', closeAllAppSessions);
