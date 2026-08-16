// Brave (Chromium) "native mobile" session helper.
//
// Portrait-resizing a desktop browser leaves desktop UA/layout and usually
// letterboxes on the phone (min-width + chrome). For Brave we launch a dedicated
// profile with remote debugging and drive Chrome DevTools Protocol:
//   - mobile user-agent
//   - device metrics = phone CSS viewport
//   - touch emulation
// so sites render as they would on a real phone. Expandable later to Chrome/Edge.

import { existsSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const DISPLAY = process.env.DISPLAY || ':0';

/** Android Chrome UA — widely accepted for mobile site variants. */
export const MOBILE_UA =
  'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

export interface MobileViewport {
  width: number;
  height: number;
  /** Device pixel ratio from the phone (default 2). */
  dpr?: number;
}

export interface BraveMobileSession {
  port: number;
  pid: number;
  userDataDir: string;
}

type SpawnOpts = Parameters<typeof Bun.spawn>[1];

let session: BraveMobileSession | null = null;

export function isBraveWmClass(wmClass: string | undefined | null): boolean {
  if (!wmClass) return false;
  const n = wmClass.toLowerCase().replace(/[^a-z0-9]/g, '');
  return n.includes('brave');
}

export function isBraveAppId(appId: string | undefined | null): boolean {
  if (!appId) return false;
  const n = appId.toLowerCase().replace(/[^a-z0-9]/g, '');
  return n.includes('brave');
}

/** Resolve a Brave/Chromium binary suitable for a dedicated mobile profile. */
export function resolveBraveBinary(): string | null {
  const candidates = [
    process.env.NEXUSLINK_BRAVE_BIN,
    'brave-browser',
    'brave-browser-stable',
    'brave',
    '/usr/bin/brave-browser',
    '/usr/bin/brave-browser-stable',
    '/usr/bin/brave',
    '/snap/bin/brave',
    // Dev/CI fallback — Chromium speaks the same CDP surface.
    'google-chrome-stable',
    'google-chrome',
    'chromium-browser',
    'chromium',
    '/usr/bin/google-chrome-stable',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium-browser',
    '/usr/bin/chromium',
  ].filter(Boolean) as string[];

  for (const c of candidates) {
    if (c.includes('/')) {
      if (existsSync(c)) return c;
      continue;
    }
    try {
      const out = Bun.spawnSync(['which', c], { stdout: 'pipe', stderr: 'ignore' });
      if (out.exitCode === 0) {
        const p = out.stdout.toString().trim();
        if (p) return p;
      }
    } catch {
      // keep looking
    }
  }
  return null;
}

function userDataDir(): string {
  const dir =
    process.env.NEXUSLINK_BRAVE_USER_DATA ||
    join(homedir(), '.config', 'nexuslink', 'brave-mobile');
  mkdirSync(dir, { recursive: true });
  return dir;
}

async function pickDebugPort(): Promise<number> {
  // Ephemeral bind to learn a free port, then release it for Brave.
  const srv = Bun.serve({ port: 0, fetch: () => new Response('ok') });
  const port = srv.port;
  srv.stop(true);
  // Brief gap so the kernel reclaims the port before Brave binds it.
  await Bun.sleep(50);
  return port;
}

async function waitForCdp(port: number, timeoutMs = 15000): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/json/version`, {
        signal: AbortSignal.timeout(500),
      });
      if (res.ok) return true;
    } catch {
      // not up yet
    }
    await Bun.sleep(200);
  }
  return false;
}

/** List page targets on a CDP endpoint. */
export async function listCdpTargets(
  port: number,
): Promise<Array<{ id: string; type: string; url: string; webSocketDebuggerUrl?: string }>> {
  try {
    const res = await fetch(`http://127.0.0.1:${port}/json/list`, {
      signal: AbortSignal.timeout(2000),
    });
    if (!res.ok) return [];
    return (await res.json()) as Array<{
      id: string;
      type: string;
      url: string;
      webSocketDebuggerUrl?: string;
    }>;
  } catch {
    return [];
  }
}

/**
 * Send one CDP command and wait for its response (id-matched).
 * Used by tests with a mock socket; production uses applyMobileEmulation.
 */
export function buildMobileEmulationCommands(vp: MobileViewport): object[] {
  const width = Math.max(320, Math.round(vp.width));
  const height = Math.max(480, Math.round(vp.height));
  const dpr = Math.min(3.5, Math.max(1, vp.dpr ?? 2));
  return [
    {
      method: 'Emulation.setUserAgentOverride',
      params: {
        userAgent: MOBILE_UA,
        acceptLanguage: 'en-US,en',
        platform: 'Linux armv8l',
        userAgentMetadata: {
          brands: [
            { brand: 'Chromium', version: '131' },
            { brand: 'Brave', version: '131' },
            { brand: 'Not_A Brand', version: '24' },
          ],
          fullVersion: '131.0.0.0',
          platform: 'Android',
          platformVersion: '14.0.0',
          architecture: '',
          model: 'Pixel 8',
          mobile: true,
        },
      },
    },
    {
      method: 'Emulation.setTouchEmulationEnabled',
      params: { enabled: true, maxTouchPoints: 5 },
    },
    {
      method: 'Emulation.setDeviceMetricsOverride',
      params: {
        width,
        height,
        deviceScaleFactor: dpr,
        mobile: true,
        screenWidth: width,
        screenHeight: height,
        // Keep the visible size = window client area so CDP does not paint
        // DevTools-style letterbox bars inside the captured frame.
        dontSetVisibleSize: true,
      },
    },
    {
      method: 'Emulation.setEmitTouchEventsForMouse',
      params: { enabled: true, configuration: 'mobile' },
    },
  ];
}

async function cdpCall(
  ws: WebSocket,
  id: number,
  method: string,
  params?: object,
): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`CDP timeout: ${method}`)), 8000);
    const onMessage = (ev: MessageEvent) => {
      try {
        const msg = JSON.parse(String(ev.data)) as { id?: number; result?: unknown; error?: unknown };
        if (msg.id !== id) return;
        clearTimeout(timer);
        ws.removeEventListener('message', onMessage);
        if (msg.error) reject(new Error(`CDP ${method}: ${JSON.stringify(msg.error)}`));
        else resolve(msg.result);
      } catch (err) {
        clearTimeout(timer);
        ws.removeEventListener('message', onMessage);
        reject(err);
      }
    };
    ws.addEventListener('message', onMessage);
    ws.send(JSON.stringify({ id, method, params }));
  });
}

async function openCdpSocket(url: string): Promise<WebSocket> {
  const ws = new WebSocket(url);
  await new Promise<void>((resolve, reject) => {
    const t = setTimeout(() => reject(new Error('CDP websocket connect timeout')), 5000);
    ws.addEventListener('open', () => {
      clearTimeout(t);
      resolve();
    });
    ws.addEventListener('error', () => {
      clearTimeout(t);
      reject(new Error('CDP websocket error'));
    });
  });
  return ws;
}

/** Apply mobile emulation to every page target on the debug port. */
export async function applyMobileEmulation(port: number, vp: MobileViewport): Promise<boolean> {
  const targets = await listCdpTargets(port);
  const pages = targets.filter((t) => t.type === 'page' && t.webSocketDebuggerUrl);
  if (pages.length === 0) return false;

  const commands = buildMobileEmulationCommands(vp);
  let ok = false;
  for (const page of pages) {
    const url = page.webSocketDebuggerUrl!;
    let ws: WebSocket | null = null;
    try {
      ws = await openCdpSocket(url);
      let id = 1;
      for (const cmd of commands) {
        const c = cmd as { method: string; params?: object };
        await cdpCall(ws, id++, c.method, c.params);
      }
      ok = true;
    } catch {
      // try next target
    } finally {
      try {
        ws?.close();
      } catch {
        // ignore
      }
    }
  }
  return ok;
}

/**
 * Probe common / known debug ports for an already-running Brave that we can
 * put into mobile emulation (our dedicated session first).
 */
export async function findBraveDebugPort(): Promise<number | null> {
  if (session) {
    if (await waitForCdp(session.port, 1000)) return session.port;
  }
  const extras = [9222, 9229, 9333];
  for (const p of extras) {
    try {
      const res = await fetch(`http://127.0.0.1:${p}/json/version`, {
        signal: AbortSignal.timeout(300),
      });
      if (!res.ok) continue;
      const body = (await res.json()) as { Browser?: string };
      const browser = (body.Browser ?? '').toLowerCase();
      if (browser.includes('brave') || browser.includes('chrome') || browser.includes('chromium')) {
        return p;
      }
    } catch {
      // closed
    }
  }
  return null;
}

export function getBraveMobileSession(): BraveMobileSession | null {
  return session;
}

/**
 * Launch (or reuse) the NexusLink Brave mobile profile with remote debugging.
 * Uses --app so the window is chromeless (no tab strip) — feels like a mobile
 * browser shell once device metrics are applied.
 */
export async function launchBraveMobile(vp?: MobileViewport): Promise<{
  ok: boolean;
  wmClass: string;
  reused: boolean;
  port?: number;
}> {
  const bin = resolveBraveBinary();
  if (!bin) return { ok: false, wmClass: 'brave-browser.Brave-browser', reused: false };

  // Reuse a live session when possible.
  if (session && (await waitForCdp(session.port, 800))) {
    if (vp) await applyMobileEmulation(session.port, vp);
    return {
      ok: true,
      wmClass: 'brave-browser.Brave-browser',
      reused: true,
      port: session.port,
    };
  }

  const port = await pickDebugPort();
  const dir = userDataDir();
  const w = Math.max(320, Math.round(vp?.width ?? 390));
  const h = Math.max(480, Math.round(vp?.height ?? 844));

  const args = [
    `--user-data-dir=${dir}`,
    `--remote-debugging-port=${port}`,
    '--remote-allow-origins=*',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-session-crashed-bubble',
    '--disable-features=TranslateUI',
    `--window-size=${w},${h}`,
    `--user-agent=${MOBILE_UA}`,
    '--force-device-scale-factor=1',
    // App mode: no tab strip / omnibox chrome → content fills the portrait frame.
    '--app=https://www.google.com/',
  ];

  try {
    const proc = Bun.spawn([bin, ...args], {
      stdout: 'ignore',
      stderr: 'ignore',
      env: { ...process.env, DISPLAY },
    } as unknown as SpawnOpts);
    session = { port, pid: proc.pid, userDataDir: dir };
    const up = await waitForCdp(port, 20000);
    if (!up) return { ok: false, wmClass: 'brave-browser.Brave-browser', reused: false, port };
    if (vp) await applyMobileEmulation(port, vp);
    return { ok: true, wmClass: 'brave-browser.Brave-browser', reused: false, port };
  } catch {
    session = null;
    return { ok: false, wmClass: 'brave-browser.Brave-browser', reused: false };
  }
}

/**
 * After the OS window is portrait-shaped, push CDP metrics so layout CSS size
 * matches the phone stage (not the possibly-scaled host window pixels).
 */
export async function adoptBraveMobile(vp: MobileViewport): Promise<boolean> {
  const port = await findBraveDebugPort();
  if (port == null) return false;
  return applyMobileEmulation(port, vp);
}
