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
  '/usr/bin/brave-browser',
];

/** Android Chrome UA so sites serve their mobile layouts. */
const MOBILE_UA =
  'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

export function findChromeBin(): string | null {
  for (const bin of CHROME_BINS) {
    if (existsSync(bin)) return bin;
  }
  return null;
}

/**
 * Chromium in "phone browser" trim: mobile UA (sites reflow to their mobile
 * layouts), touch events on, and the device scale factor matched to the phone
 * so text and hit targets are finger-sized. The session's openbox strips the
 * titlebar and maximizes, so the window fills the virtual screen exactly.
 */
const chromeMobile: AppProfile = {
  appId: 'nexus.chrome-mobile',
  name: 'Browser',
  iconName: 'google-chrome',
  available: () => findChromeBin() !== null,
  buildArgv(ctx) {
    const bin = findChromeBin();
    if (!bin) throw new Error('no chromium/chrome binary found');
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
      '--start-maximized',
      '--window-position=0,0',
      'https://www.google.com',
    ];
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
