import { existsSync, mkdirSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import type { AppSessionInfo, WsMessage } from '@nexuslink/rpc-types';
import { resolveAppPath, launchApp } from './wm';
import { u32, idToHwnd, windowPid, enumTopLevelWindows, hwndToId, windowTitle, SWP_SHOWWINDOW, HWND_TOP } from './win32';
import { getPrimaryMonitor } from './capture';

const MOBILE_UA =
  'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

type SpawnOpts = Parameters<typeof Bun.spawn>[1];

interface Session {
  info: AppSessionInfo;
  proc: ReturnType<typeof Bun.spawn> | null;
  hwnd?: string;
  sessionDir: string;
}

const sessions = new Map<string, Session>();
let broadcast: (msg: WsMessage) => void = () => {};

export function setSessionBroadcast(fn: (msg: WsMessage) => void): void {
  broadcast = fn;
}

function ensurePortrait(width: number, height: number): { width: number; height: number } {
  const w = Math.max(1, Math.round(width));
  const h = Math.max(1, Math.round(height));
  return w <= h ? { width: w, height: h } : { width: h, height: w };
}

function browserBin(): string | null {
  return resolveAppPath('msedge') || resolveAppPath('chrome') || resolveAppPath('brave');
}

function chromiumArgv(bin: string, ctx: { width: number; height: number; dpr: number; sessionDir: string }): string[] {
  const dsf = Math.max(1, ctx.dpr || 2);
  const dipW = Math.max(1, Math.round(ctx.width / dsf));
  const dipH = Math.max(1, Math.round(ctx.height / dsf));
  const dataDir = join(ctx.sessionDir, 'profile');
  const primary = getPrimaryMonitor();
  const x = Math.max(0, primary.width - ctx.width);
  return [
    bin,
    `--user-data-dir=${dataDir}`,
    `--user-agent=${MOBILE_UA}`,
    `--force-device-scale-factor=${dsf.toFixed(2)}`,
    `--window-size=${dipW},${dipH}`,
    `--window-position=${x},0`,
    '--new-window',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-session-crashed-bubble',
    '--touch-events=enabled',
    'https://www.google.com',
  ];
}

async function waitForPidWindow(pid: number, timeoutMs = 10000): Promise<string | undefined> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    for (const hwnd of enumTopLevelWindows()) {
      if (windowPid(hwnd) === pid && u32.IsWindowVisible(hwnd as never) && windowTitle(hwnd)) {
        return hwndToId(hwnd);
      }
    }
    await Bun.sleep(200);
  }
  return undefined;
}

export async function createAppSession(
  appId: string,
  width: number,
  height: number,
  dpr?: number,
): Promise<AppSessionInfo> {
  const size = ensurePortrait(width, height);
  const id = crypto.randomUUID();
  const sessionDir = join(tmpdir(), 'nexuslink-sessions', id);
  mkdirSync(sessionDir, { recursive: true });

  const info: AppSessionInfo = {
    sessionId: id,
    appId,
    name: appId === 'nexus.chrome-mobile' ? 'Browser' : appId,
    display: 'win32',
    width: size.width,
    height: size.height,
    dpr: dpr || 2,
    createdAt: Date.now(),
    status: 'starting',
  };

  const session: Session = { info, proc: null, sessionDir };
  sessions.set(id, session);
  broadcast({ type: 'app-session-update', session: info });

  const isBrowser = appId === 'nexus.chrome-mobile' || appId === 'msedge' || appId === 'chrome' || appId === 'brave';
  if (isBrowser) {
    const bin = browserBin();
    if (!bin) throw new Error('No Edge/Chrome/Brave found on this PC');
    const argv = chromiumArgv(bin, { ...size, dpr: info.dpr, sessionDir });
    session.proc = Bun.spawn(argv, {
      stdout: 'ignore',
      stderr: 'ignore',
    } as unknown as SpawnOpts);
    const pid = session.proc.pid;
    session.hwnd = pid ? await waitForPidWindow(pid) : undefined;
    if (session.hwnd) {
      u32.SetWindowPos(
        idToHwnd(session.hwnd) as never,
        HWND_TOP as never,
        Math.max(0, getPrimaryMonitor().width - size.width),
        0,
        size.width,
        size.height,
        SWP_SHOWWINDOW,
      );
    }
  } else {
    launchApp(appId);
  }

  info.status = 'running';
  session.proc?.exited.then(() => {
    info.status = 'exited';
    broadcast({ type: 'app-session-update', session: info });
    setTimeout(() => sessions.delete(id), 60_000);
  }).catch(() => {});

  broadcast({ type: 'app-session-update', session: info });
  broadcast({ type: 'app-session-ready', sessionId: id });
  return info;
}

export function listAppSessions(): AppSessionInfo[] {
  return [...sessions.values()].map((s) => s.info);
}

export function getAppSession(sessionId: string): Session | undefined {
  return sessions.get(sessionId);
}

export function resizeAppSession(sessionId: string, width: number, height: number): AppSessionInfo {
  const session = sessions.get(sessionId);
  if (!session) throw new Error('unknown app session');
  const size = ensurePortrait(width, height);
  session.info.width = size.width;
  session.info.height = size.height;
  if (session.hwnd) {
    u32.SetWindowPos(
      idToHwnd(session.hwnd) as never,
      HWND_TOP as never,
      Math.max(0, getPrimaryMonitor().width - size.width),
      0,
      size.width,
      size.height,
      SWP_SHOWWINDOW,
    );
  }
  broadcast({ type: 'app-session-update', session: session.info });
  return session.info;
}

export function closeAppSession(sessionId: string): void {
  const session = sessions.get(sessionId);
  if (!session) throw new Error('unknown app session');
  try {
    session.proc?.kill();
  } catch {
    // already gone
  }
  sessions.delete(sessionId);
}

export function iddDriverInstalled(): boolean {
  const infHint = join(homedir(), '..', '..');
  const sys = 'C:\\Windows\\System32\\drivers';
  return existsSync(join(sys, 'NexusLinkIdd.sys'))
    || existsSync(join(process.env.ProgramFiles || 'C:\\Program Files', 'NexusLink', 'idd', 'NexusLinkIdd.dll'));
}
