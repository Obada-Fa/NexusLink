// Built-in launch profiles for apps that need special arguments to feel native
// inside a phone-shaped virtual display (Module: app sessions / Tier 1).
//
// A profile turns (appId, session geometry) into an argv + env. Apps without a
// profile fall back to their .desktop Exec line, launched with DISPLAY set to
// the session's virtual X server.

import { existsSync } from 'node:fs';

export interface LaunchContext {
  /** Physical pixel size of the virtual display. */
  width: number;
  height: number;
  /** Effective device pixel ratio the session renders at. */
  dpr: number;
  /** Scratch dir for per-session state (browser profile, config, ...). */
  sessionDir: string;
}

export interface AppProfile {
  appId: string;
  name: string;
  /** Icon name resolvable through the freedesktop icon lookup, if any. */
  iconName?: string;
  /** Whether the underlying binary exists on this host. */
  available(): boolean;
  buildArgv(ctx: LaunchContext): string[];
  buildEnv?(ctx: LaunchContext): Record<string, string>;
}

const CHROME_BINS = [
  '/usr/local/bin/google-chrome',
  '/usr/bin/google-chrome',
  '/usr/bin/google-chrome-stable',
  '/usr/bin/chromium',
  '/usr/bin/chromium-browser',
  '/snap/bin/chromium',
];

const BRAVE_BINS = [
  '/usr/bin/brave-browser',
  '/usr/bin/brave-browser-stable',
  '/usr/bin/brave',
  '/snap/bin/brave',
  '/opt/brave.com/brave/brave-browser',
  '/opt/brave.com/brave/brave',
];

const EDGE_BINS = [
  '/usr/bin/microsoft-edge',
  '/usr/bin/microsoft-edge-stable',
  '/opt/microsoft/msedge/microsoft-edge',
];

/** Chromium-family app ids / Exec lines (Brave, Chrome, Chromium, Edge). */
const BROWSER_RE = /brave|chrom(e|ium)|msedge|microsoft-edge/i;

/** Android Chrome UA so sites serve their mobile layouts. */
const MOBILE_UA =
  'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

function firstExisting(bins: string[]): string | null {
  for (const bin of bins) {
    if (existsSync(bin)) return bin;
  }
  return null;
}

export function findChromeBin(): string | null {
  return firstExisting(CHROME_BINS) ?? firstExisting(BRAVE_BINS) ?? firstExisting(EDGE_BINS);
}

export function isChromiumFamily(appId: string, exec?: string): boolean {
  return BROWSER_RE.test(appId) || BROWSER_RE.test(exec ?? '');
}

/** Pick the binary the user actually tapped (Brave stays Brave, not Chrome). */
export function findBrowserBinForAppId(appId: string): string | null {
  const id = appId.toLowerCase();
  if (id.includes('brave')) return firstExisting(BRAVE_BINS) ?? findChromeBin();
  if (id.includes('msedge') || id.includes('microsoft-edge')) {
    return firstExisting(EDGE_BINS) ?? findChromeBin();
  }
  if (id.includes('chromium')) {
    return firstExisting([
      '/usr/bin/chromium',
      '/usr/bin/chromium-browser',
      '/snap/bin/chromium',
    ]) ?? findChromeBin();
  }
  if (id.includes('chrome') || id.includes('nexus.chrome')) return findChromeBin();
  return null;
}

/** Absolute browser path from a .desktop Exec line, if that token exists. */
function browserPathFromExec(exec?: string): string | null {
  if (!exec) return null;
  for (const tok of exec.split(/\s+/)) {
    const t = tok.replace(/^["']|["']$/g, '');
    if (t.startsWith('/') && BROWSER_RE.test(t) && existsSync(t)) return t;
  }
  return null;
}

export function resolveChromiumBin(appId: string, exec?: string): string | null {
  if (!isChromiumFamily(appId, exec)) return null;
  return browserPathFromExec(exec) ?? findBrowserBinForAppId(appId) ?? findChromeBin();
}

/**
 * Chromium in "phone browser" trim: isolated profile (so an already-running
 * desktop Brave/Chrome is not reused), mobile UA, touch events, scale matched
 * to the phone. Shared by the built-in Browser tile and .desktop browsers.
 */
export function buildChromiumArgv(bin: string, ctx: LaunchContext): string[] {
  return [
    bin,
    `--user-data-dir=${ctx.sessionDir}/chrome-profile`,
    `--user-agent=${MOBILE_UA}`,
    `--force-device-scale-factor=${ctx.dpr.toFixed(2)}`,
    '--touch-events=enabled',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-session-crashed-bubble',
    '--hide-crash-restore-bubble',
    '--disable-dev-shm-usage',
    '--ozone-platform=x11',
    '--disable-gpu',
    '--start-maximized',
    '--window-position=0,0',
    'https://www.google.com',
  ];
}

/** Built-in "Browser" tile — same Chromium argv as tapping Chrome/Brave. */
const chromeMobile: AppProfile = {
  appId: 'nexus.chrome-mobile',
  name: 'Browser',
  iconName: 'google-chrome',
  available: () => findChromeBin() !== null,
  buildArgv(ctx) {
    const bin = findChromeBin();
    if (!bin) throw new Error('no chromium/chrome binary found');
    return buildChromiumArgv(bin, ctx);
  },
  // Chrome scales itself via --force-device-scale-factor; do not stack
  // GDK/Qt scaling on top of it.
  buildEnv: () => ({ GDK_SCALE: '1', QT_SCALE_FACTOR: '1' }),
};

const PROFILES: AppProfile[] = [chromeMobile];

export function getProfile(appId: string): AppProfile | undefined {
  return PROFILES.find((p) => p.appId === appId);
}

export function listProfiles(): AppProfile[] {
  return PROFILES.filter((p) => p.available());
}
