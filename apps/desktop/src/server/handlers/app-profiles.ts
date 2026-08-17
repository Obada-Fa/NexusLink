// Built-in launch profiles for apps that need special arguments to feel native
// inside a phone-shaped virtual display (Module: app sessions / Tier 1).
//
// A profile turns (appId, session geometry) into an argv + env. Apps without a
// profile fall back to their .desktop Exec line, launched with DISPLAY set to
// the session's virtual X server.

import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  statSync,
} from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

export interface LaunchContext {
  /** Physical pixel size of the virtual display. */
  width: number;
  height: number;
  /** Effective device pixel ratio the session renders at. */
  dpr: number;
  /** Scratch dir for per-session state (openbox config, Xresources, ...). */
  sessionDir: string;
  /**
   * Persistent Chromium user-data-dir for phone sessions. Seeded from the
   * host's real Brave/Chrome profile so cookies and logins survive. Falls
   * back to `sessionDir/chrome-profile` when omitted (tests / unknown bins).
   */
  profileDir?: string;
}

export type BrowserKind = 'brave' | 'chrome' | 'chromium' | 'edge';

export interface SeedResult {
  destDir: string;
  sourceDir: string | null;
  copied: number;
  skipped: number;
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

/**
 * Among candidate binaries, pick the one whose host user-data-dir looks
 * like the daily driver (most recently written Local State / cookies).
 */
export function pickBinForHostProfiles(bins: string[], home: string): string | null {
  let best: { bin: string; mtime: number } | null = null;
  for (const bin of bins) {
    const kind = browserKindFromBin(bin);
    let dir: string | null = null;
    for (const p of hostUserDataCandidates(kind, home)) {
      if (existsSync(join(p, 'Local State')) || existsSync(join(p, 'Default'))) {
        dir = p;
        break;
      }
    }
    if (!dir) continue;
    const cookies =
      existsSync(join(dir, 'Default', 'Network', 'Cookies')) ||
      existsSync(join(dir, 'Default', 'Cookies'));
    const localState = join(dir, 'Local State');
    if (!cookies && !existsSync(localState)) continue;
    let mtime = 0;
    try {
      mtime = statSync(existsSync(localState) ? localState : dir).mtimeMs;
    } catch {
      mtime = 0;
    }
    if (!best || mtime > best.mtime) best = { bin, mtime };
  }
  return best?.bin ?? null;
}

/**
 * Prefer the Chromium-family browser the user actually uses on the PC
 * so the generic "Browser" tile clones logins from Brave if that's their
 * daily driver — not an unused Chrome install.
 */
export function findPreferredBrowserBin(home = homedir()): string | null {
  const bins = [
    firstExisting(BRAVE_BINS),
    firstExisting(CHROME_BINS),
    firstExisting([
      '/usr/bin/chromium',
      '/usr/bin/chromium-browser',
      '/snap/bin/chromium',
    ]),
    firstExisting(EDGE_BINS),
  ].filter((b): b is string => !!b);
  return pickBinForHostProfiles(bins, home) ?? findChromeBin();
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
  if (id.includes('chrome') || id.includes('nexus.chrome')) return findPreferredBrowserBin();
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

/** Map a browser binary path to the on-disk profile family. */
export function browserKindFromBin(bin: string): BrowserKind {
  const n = bin.toLowerCase();
  if (n.includes('brave')) return 'brave';
  if (n.includes('msedge') || n.includes('microsoft-edge')) return 'edge';
  if (n.includes('chromium')) return 'chromium';
  return 'chrome';
}

/** Standard Linux user-data-dir locations, including Flatpak and Snap. */
export function hostUserDataCandidates(kind: BrowserKind, home: string): string[] {
  switch (kind) {
    case 'brave':
      return [
        join(home, '.config/BraveSoftware/Brave-Browser'),
        join(home, '.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser'),
        join(home, 'snap/brave/current/.config/BraveSoftware/Brave-Browser'),
      ];
    case 'chrome':
      return [
        join(home, '.config/google-chrome'),
        join(home, '.var/app/com.google.Chrome/config/google-chrome'),
        join(home, 'snap/google-chrome/current/.config/google-chrome'),
      ];
    case 'chromium':
      return [
        join(home, '.config/chromium'),
        join(home, '.var/app/org.chromium.Chromium/config/chromium'),
        join(home, 'snap/chromium/current/.config/chromium'),
      ];
    case 'edge':
      return [
        join(home, '.config/microsoft-edge'),
        join(home, '.var/app/com.microsoft.Edge/config/microsoft-edge'),
      ];
  }
}

export function findHostUserDataDir(kind: BrowserKind, home = homedir()): string | null {
  const override = process.env.NEXUSLINK_HOST_USER_DATA_DIR;
  if (override && existsSync(override)) return override;
  for (const p of hostUserDataCandidates(kind, home)) {
    if (existsSync(join(p, 'Local State')) || existsSync(join(p, 'Default'))) return p;
  }
  return null;
}

export function persistentProfileDir(kind: BrowserKind, home = homedir()): string {
  const root =
    process.env.NEXUSLINK_BROWSER_PROFILES ||
    join(home, '.config', 'nexuslink', 'browser-profiles');
  return join(root, kind);
}

/**
 * Names that must not be copied into the phone profile.
 * Singleton* would collide with a running desktop browser; caches are huge
 * and regenerable; session-restore files would reopen desktop window layouts
 * inside the kiosk virtual display.
 */
export const PROFILE_SKIP_NAMES = new Set([
  'SingletonLock',
  'SingletonSocket',
  'SingletonCookie',
  'lockfile',
  'RunningChromeVersion',
  'DevToolsActivePort',
  'Cache',
  'Code Cache',
  'GPUCache',
  'GrShaderCache',
  'ShaderCache',
  'GraphiteDawnCache',
  'DawnGraphiteCache',
  'DawnCache',
  'Media Cache',
  'Crash Reports',
  'BrowserMetrics',
  'Safe Browsing',
  'Safe Browsing Cookies',
  'component_crx_cache',
  'extensions_crx_cache',
  'optimization_guide_model_store',
  'optimization_guide_hint_cache',
  'ScreenShotCache',
  'CacheStorage',
  'Sessions',
  'Current Session',
  'Current Tabs',
  'Last Session',
  'Last Tabs',
]);

export function shouldSkipProfileEntry(name: string): boolean {
  return PROFILE_SKIP_NAMES.has(name);
}

/**
 * Overlay-copy a Chromium user-data-dir into `destDir`.
 * Newer dest files win (phone logins are not clobbered by an older desktop
 * copy). Locked/unreadable source files are skipped so a running desktop
 * browser does not block the phone session.
 */
export function seedChromiumProfile(
  sourceDir: string,
  destDir: string,
): { copied: number; skipped: number } {
  const acc = { copied: 0, skipped: 0 };
  if (!existsSync(sourceDir)) return acc;
  mkdirSync(destDir, { recursive: true });
  copyProfileTree(sourceDir, destDir, acc);
  return acc;
}

function copyProfileTree(
  src: string,
  dest: string,
  acc: { copied: number; skipped: number },
): void {
  mkdirSync(dest, { recursive: true });
  let entries: ReturnType<typeof readdirSync>;
  try {
    entries = readdirSync(src, { withFileTypes: true });
  } catch {
    acc.skipped++;
    return;
  }
  for (const entry of entries) {
    if (shouldSkipProfileEntry(entry.name)) {
      acc.skipped++;
      continue;
    }
    const from = join(src, entry.name);
    const to = join(dest, entry.name);
    try {
      if (entry.isSymbolicLink() || entry.isSocket() || entry.isFIFO()) {
        acc.skipped++;
        continue;
      }
      if (entry.isDirectory()) {
        copyProfileTree(from, to, acc);
        continue;
      }
      if (!entry.isFile()) {
        acc.skipped++;
        continue;
      }
      const srcStat = statSync(from);
      try {
        const dstStat = statSync(to);
        // Phone-side edits win when they are newer, even if the size differs
        // (a cookie DB rewrite is not the same byte length as the desktop copy).
        if (dstStat.mtimeMs > srcStat.mtimeMs) continue;
        if (dstStat.mtimeMs === srcStat.mtimeMs && dstStat.size === srcStat.size) continue;
      } catch {
        // dest missing — copy
      }
      copyFileSync(from, to);
      acc.copied++;
    } catch {
      acc.skipped++;
    }
  }
}

/**
 * Persistent phone profile for `bin`, seeded from the matching desktop
 * user-data-dir when one exists. Safe to call on every launch (incremental).
 */
export function prepareChromiumProfile(bin: string, home = homedir()): SeedResult {
  const kind = browserKindFromBin(bin);
  const destDir = persistentProfileDir(kind, home);
  mkdirSync(destDir, { recursive: true });
  const sourceDir = findHostUserDataDir(kind, home);
  if (!sourceDir) return { destDir, sourceDir: null, copied: 0, skipped: 0 };
  const { copied, skipped } = seedChromiumProfile(sourceDir, destDir);
  if (copied > 0) {
    console.log(
      `[nexuslink] seeded ${kind} phone profile from ${sourceDir} (${copied} files)`,
    );
  }
  return { destDir, sourceDir, copied, skipped };
}

/**
 * Desktop Chrome will not create a browser window narrower than ~500 CSS px,
 * so a phone-logical width (360–430) with DSF=2 can never maximize. Drop DSF
 * just enough that the DIP width stays at least this wide, keeping the
 * framebuffer (physical pixels) portrait and full-phone.
 */
export const CHROME_MIN_DIP_WIDTH = 560;

export function chromiumLayout(ctx: LaunchContext): { dsf: number; dipW: number; dipH: number } {
  const wantDsf = Math.max(1, ctx.dpr || 1);
  let dipW = Math.max(1, Math.round(ctx.width / wantDsf));
  let dsf = wantDsf;
  if (dipW < CHROME_MIN_DIP_WIDTH) {
    dipW = Math.min(CHROME_MIN_DIP_WIDTH, ctx.width);
    dsf = ctx.width / dipW;
    if (dsf < 1) {
      dsf = 1;
      dipW = ctx.width;
    }
  }
  const dipH = Math.max(1, Math.round(ctx.height / dsf));
  return { dsf: Math.round(dsf * 100) / 100, dipW, dipH };
}

/**
 * Chromium in "phone browser" trim: its own user-data-dir (so an already-
 * running desktop Brave/Chrome is not reused — Chromium forbids two
 * processes on one profile), but that dir is a persistent clone of the
 * host profile (cookies, logins, bookmarks). Mobile UA + fullscreen so
 * the desktop min-width cannot letterbox a landscape strip.
 */
export function buildChromiumArgv(bin: string, ctx: LaunchContext): string[] {
  const { dsf, dipW, dipH } = chromiumLayout(ctx);
  const dataDir = ctx.profileDir ?? join(ctx.sessionDir, 'chrome-profile');
  return [
    bin,
    `--user-data-dir=${dataDir}`,
    `--user-agent=${MOBILE_UA}`,
    `--force-device-scale-factor=${dsf.toFixed(2)}`,
    `--window-size=${dipW},${dipH}`,
    '--window-position=0,0',
    '--start-fullscreen',
    '--kiosk',
    '--touch-events=enabled',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-session-crashed-bubble',
    '--hide-crash-restore-bubble',
    '--disable-dev-shm-usage',
    '--ozone-platform=x11',
    '--disable-gpu',
    'https://www.google.com',
  ];
}

/** Built-in "Browser" tile — same Chromium argv as tapping Chrome/Brave. */
const chromeMobile: AppProfile = {
  appId: 'nexus.chrome-mobile',
  name: 'Browser',
  iconName: 'google-chrome',
  available: () => findPreferredBrowserBin() !== null,
  buildArgv(ctx) {
    const bin = findPreferredBrowserBin();
    if (!bin) throw new Error('no chromium/chrome binary found');
    const profileDir = ctx.profileDir ?? prepareChromiumProfile(bin).destDir;
    return buildChromiumArgv(bin, { ...ctx, profileDir });
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
