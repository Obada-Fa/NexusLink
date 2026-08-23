import { describe, expect, test } from 'bun:test';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  utimesSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  isChromiumFamily,
  resolveChromiumBin,
  buildChromiumArgv,
  findBrowserBinForAppId,
  chromiumLayout,
  CHROME_MIN_DIP_WIDTH,
  browserKindFromBin,
  hostUserDataCandidates,
  findHostUserDataDir,
  persistentProfileDir,
  prepareChromiumProfile,
  seedChromiumProfile,
  copyEssentialProfile,
  checkoutSessionProfile,
  shouldSkipProfileEntry,
  pickBinForHostProfiles,
} from '../app-profiles';

describe('chromium-family detection', () => {
  test('recognizes Brave / Chrome / Chromium / Edge app ids', () => {
    expect(isChromiumFamily('brave-browser')).toBe(true);
    expect(isChromiumFamily('com.brave.Browser')).toBe(true);
    expect(isChromiumFamily('google-chrome')).toBe(true);
    expect(isChromiumFamily('chromium')).toBe(true);
    expect(isChromiumFamily('microsoft-edge')).toBe(true);
    expect(isChromiumFamily('org.gnome.Calculator')).toBe(false);
    expect(isChromiumFamily('debian-xterm')).toBe(false);
  });

  test('recognizes a Brave Exec line even with field codes', () => {
    expect(isChromiumFamily('some-id', '/usr/bin/brave-browser-stable %U')).toBe(true);
    expect(isChromiumFamily('calc', '/usr/bin/gnome-calculator')).toBe(false);
  });

  test('does not treat a non-browser app as chromium just because chrome is installed', () => {
    expect(resolveChromiumBin('org.gnome.Nautilus', '/usr/bin/nautilus --new-window')).toBeNull();
    expect(findBrowserBinForAppId('org.gnome.Calculator')).toBeNull();
  });
});

describe('chromiumLayout', () => {
  test('keeps DIP width at least Chrome min so a phone DSF cannot letterbox', () => {
    const layout = chromiumLayout({
      width: 780,
      height: 1688,
      dpr: 2,
      sessionDir: '/tmp/x',
    });
    expect(layout.dipW).toBeGreaterThanOrEqual(CHROME_MIN_DIP_WIDTH);
    expect(layout.dipH).toBeGreaterThan(layout.dipW);
    expect(Math.abs(layout.dipW * layout.dsf - 780)).toBeLessThan(3);
  });

  test('does not raise DSF above the session dpr', () => {
    const layout = chromiumLayout({
      width: 1200,
      height: 2592,
      dpr: 2,
      sessionDir: '/tmp/x',
    });
    expect(layout.dsf).toBeLessThanOrEqual(2);
    expect(layout.dipW).toBeGreaterThanOrEqual(CHROME_MIN_DIP_WIDTH);
  });
});

describe('buildChromiumArgv', () => {
  test('falls back to the session dir when no persistent profile is set', () => {
    const argv = buildChromiumArgv('/usr/bin/brave-browser', {
      width: 780,
      height: 1688,
      dpr: 2,
      sessionDir: '/tmp/nexus-sess',
    });
    expect(argv[0]).toBe('/usr/bin/brave-browser');
    expect(argv).toContain('--user-data-dir=/tmp/nexus-sess/chrome-profile');
    expect(argv.some((a) => a.startsWith('--user-agent='))).toBe(true);
    expect(argv).toContain('--touch-events=enabled');
    expect(argv).toContain('--start-fullscreen');
    expect(argv.some((a) => a.startsWith('--window-size='))).toBe(true);
    const size = argv.find((a) => a.startsWith('--window-size='))!.slice('--window-size='.length);
    const [w, h] = size.split(',').map(Number);
    expect(w).toBeGreaterThanOrEqual(CHROME_MIN_DIP_WIDTH);
    expect(h).toBeGreaterThan(w!);
  });

  test('uses the persistent host-seeded profile dir when provided', () => {
    const argv = buildChromiumArgv('/usr/bin/brave-browser', {
      width: 780,
      height: 1688,
      dpr: 2,
      sessionDir: '/tmp/nexus-sess',
      profileDir: '/home/user/.config/nexuslink/browser-profiles/brave',
    });
    expect(argv).toContain(
      '--user-data-dir=/home/user/.config/nexuslink/browser-profiles/brave',
    );
    expect(argv).not.toContain('--user-data-dir=/tmp/nexus-sess/chrome-profile');
  });
});

describe('browser profile family', () => {
  test('classifies binaries', () => {
    expect(browserKindFromBin('/usr/bin/brave-browser-stable')).toBe('brave');
    expect(browserKindFromBin('/opt/brave.com/brave/brave')).toBe('brave');
    expect(browserKindFromBin('/usr/bin/google-chrome-stable')).toBe('chrome');
    expect(browserKindFromBin('/usr/bin/chromium')).toBe('chromium');
    expect(browserKindFromBin('/usr/bin/microsoft-edge')).toBe('edge');
  });

  test('lists Brave / Chrome host user-data-dir candidates', () => {
    const brave = hostUserDataCandidates('brave', '/home/ada');
    expect(brave).toContain('/home/ada/.config/BraveSoftware/Brave-Browser');
    expect(brave.some((p) => p.includes('com.brave.Browser'))).toBe(true);
    const chrome = hostUserDataCandidates('chrome', '/home/ada');
    expect(chrome).toContain('/home/ada/.config/google-chrome');
  });

  test('persistent phone profile lives outside the temp session dir', () => {
    expect(persistentProfileDir('brave', '/home/ada')).toBe(
      '/home/ada/.config/nexuslink/browser-profiles/brave',
    );
  });

  test('picks the browser whose host profile was used most recently', () => {
    const home = mkdtempSync(join(tmpdir(), 'nl-home-'));
    const brave = join(home, '.config/BraveSoftware/Brave-Browser/Default');
    const chrome = join(home, '.config/google-chrome/Default');
    mkdirSync(brave, { recursive: true });
    mkdirSync(chrome, { recursive: true });
    writeFileSync(join(home, '.config/google-chrome/Local State'), '{}');
    writeFileSync(join(chrome, 'Cookies'), 'chrome');
    writeFileSync(join(home, '.config/BraveSoftware/Brave-Browser/Local State'), '{}');
    writeFileSync(join(brave, 'Cookies'), 'brave');
    const past = new Date(Date.now() - 120_000);
    const now = new Date();
    utimesSync(join(home, '.config/google-chrome/Local State'), past, past);
    utimesSync(join(home, '.config/BraveSoftware/Brave-Browser/Local State'), now, now);

    const picked = pickBinForHostProfiles(
      ['/usr/bin/google-chrome', '/usr/bin/brave-browser'],
      home,
    );
    expect(picked).toBe('/usr/bin/brave-browser');
    rmSync(home, { recursive: true, force: true });
  });
});

describe('seedChromiumProfile', () => {
  function scratch(): string {
    return mkdtempSync(join(tmpdir(), 'nl-profile-'));
  }

  test('copies cookies, logins, bookmarks and Local State from the host profile', () => {
    const root = scratch();
    const src = join(root, 'host');
    const dest = join(root, 'phone');
    mkdirSync(join(src, 'Default', 'Network'), { recursive: true });
    writeFileSync(join(src, 'Local State'), '{"os_crypt":{"encrypted_key":"abc"}}');
    writeFileSync(join(src, 'Default', 'Cookies'), 'cookie-db');
    writeFileSync(join(src, 'Default', 'Network', 'Cookies'), 'network-cookies');
    writeFileSync(join(src, 'Default', 'Login Data'), 'logins');
    writeFileSync(join(src, 'Default', 'Bookmarks'), '{"roots":{}}');
    writeFileSync(join(src, 'SingletonLock'), 'pid');
    mkdirSync(join(src, 'Default', 'Cache'), { recursive: true });
    writeFileSync(join(src, 'Default', 'Cache', 'big'), 'cache-blob');

    const { copied, skipped } = seedChromiumProfile(src, dest);

    expect(copied).toBeGreaterThanOrEqual(5);
    expect(skipped).toBeGreaterThanOrEqual(2);
    expect(readFileSync(join(dest, 'Local State'), 'utf8')).toContain('encrypted_key');
    expect(readFileSync(join(dest, 'Default', 'Cookies'), 'utf8')).toBe('cookie-db');
    expect(readFileSync(join(dest, 'Default', 'Network', 'Cookies'), 'utf8')).toBe(
      'network-cookies',
    );
    expect(readFileSync(join(dest, 'Default', 'Login Data'), 'utf8')).toBe('logins');
    expect(readFileSync(join(dest, 'Default', 'Bookmarks'), 'utf8')).toContain('roots');
    expect(existsSync(join(dest, 'SingletonLock'))).toBe(false);
    expect(existsSync(join(dest, 'Default', 'Cache', 'big'))).toBe(false);

    rmSync(root, { recursive: true, force: true });
  });

  test('does not clobber a newer phone file with an older desktop copy', () => {
    const root = scratch();
    const src = join(root, 'host');
    const dest = join(root, 'phone');
    mkdirSync(join(src, 'Default'), { recursive: true });
    mkdirSync(join(dest, 'Default'), { recursive: true });
    writeFileSync(join(src, 'Default', 'Cookies'), 'desktop-old');
    writeFileSync(join(dest, 'Default', 'Cookies'), 'phone-new');
    const past = new Date(Date.now() - 60_000);
    const now = new Date();
    utimesSync(join(src, 'Default', 'Cookies'), past, past);
    utimesSync(join(dest, 'Default', 'Cookies'), now, now);

    seedChromiumProfile(src, dest);
    expect(readFileSync(join(dest, 'Default', 'Cookies'), 'utf8')).toBe('phone-new');

    rmSync(root, { recursive: true, force: true });
  });

  test('refreshes an older phone file when the desktop copy is newer', () => {
    const root = scratch();
    const src = join(root, 'host');
    const dest = join(root, 'phone');
    mkdirSync(join(src, 'Default'), { recursive: true });
    mkdirSync(join(dest, 'Default'), { recursive: true });
    writeFileSync(join(dest, 'Default', 'Cookies'), 'phone-stale');
    writeFileSync(join(src, 'Default', 'Cookies'), 'desktop-fresh');
    const past = new Date(Date.now() - 60_000);
    const now = new Date();
    utimesSync(join(dest, 'Default', 'Cookies'), past, past);
    utimesSync(join(src, 'Default', 'Cookies'), now, now);

    seedChromiumProfile(src, dest);
    expect(readFileSync(join(dest, 'Default', 'Cookies'), 'utf8')).toBe('desktop-fresh');

    rmSync(root, { recursive: true, force: true });
  });

  test('skips lock and cache entry names', () => {
    expect(shouldSkipProfileEntry('SingletonLock')).toBe(true);
    expect(shouldSkipProfileEntry('Cache')).toBe(true);
    expect(shouldSkipProfileEntry('Cookies')).toBe(false);
    expect(shouldSkipProfileEntry('Local State')).toBe(false);
  });

  test('prepareChromiumProfile seeds from NEXUSLINK_HOST_USER_DATA_DIR', () => {
    const root = scratch();
    const host = join(root, 'BraveSoftware', 'Brave-Browser');
    const profiles = join(root, 'phone-profiles');
    mkdirSync(join(host, 'Default'), { recursive: true });
    writeFileSync(join(host, 'Local State'), '{}');
    writeFileSync(join(host, 'Default', 'Cookies'), 'host-cookies');

    const prevHost = process.env.NEXUSLINK_HOST_USER_DATA_DIR;
    const prevProfiles = process.env.NEXUSLINK_BROWSER_PROFILES;
    process.env.NEXUSLINK_HOST_USER_DATA_DIR = host;
    process.env.NEXUSLINK_BROWSER_PROFILES = profiles;
    try {
      expect(findHostUserDataDir('brave', root)).toBe(host);
      const result = prepareChromiumProfile('/usr/bin/brave-browser', root);
      expect(result.sourceDir).toBe(host);
      expect(result.destDir).toBe(join(profiles, 'brave'));
      expect(result.copied).toBeGreaterThanOrEqual(2);
      expect(readFileSync(join(result.destDir, 'Default', 'Cookies'), 'utf8')).toBe(
        'host-cookies',
      );
    } finally {
      if (prevHost === undefined) delete process.env.NEXUSLINK_HOST_USER_DATA_DIR;
      else process.env.NEXUSLINK_HOST_USER_DATA_DIR = prevHost;
      if (prevProfiles === undefined) delete process.env.NEXUSLINK_BROWSER_PROFILES;
      else process.env.NEXUSLINK_BROWSER_PROFILES = prevProfiles;
      rmSync(root, { recursive: true, force: true });
    }
  });

  test('copyEssentialProfile skips caches and lock files', () => {
    const root = scratch();
    const src = join(root, 'host');
    const dest = join(root, 'phone');
    mkdirSync(join(src, 'Default', 'Cache'), { recursive: true });
    writeFileSync(join(src, 'Local State'), '{}');
    writeFileSync(join(src, 'Default', 'Cookies'), 'cookies');
    writeFileSync(join(src, 'Default', 'Cache', 'big'), 'nope');
    writeFileSync(join(src, 'SingletonLock'), 'pid');
    const n = copyEssentialProfile(src, dest);
    expect(n).toBeGreaterThanOrEqual(2);
    expect(existsSync(join(dest, 'Default', 'Cache', 'big'))).toBe(false);
    expect(existsSync(join(dest, 'SingletonLock'))).toBe(false);
    expect(readFileSync(join(dest, 'Default', 'Cookies'), 'utf8')).toBe('cookies');
    rmSync(root, { recursive: true, force: true });
  });

  test('checkoutSessionProfile gives each session its own profile dir', () => {
    const root = scratch();
    const host = join(root, 'BraveSoftware', 'Brave-Browser');
    const profiles = join(root, 'phone-profiles');
    mkdirSync(join(host, 'Default'), { recursive: true });
    writeFileSync(join(host, 'Local State'), '{}');
    writeFileSync(join(host, 'Default', 'Cookies'), 'host-cookies');
    writeFileSync(join(host, 'SingletonLock'), 'desktop-lock');

    const prevHost = process.env.NEXUSLINK_HOST_USER_DATA_DIR;
    const prevProfiles = process.env.NEXUSLINK_BROWSER_PROFILES;
    process.env.NEXUSLINK_HOST_USER_DATA_DIR = host;
    process.env.NEXUSLINK_BROWSER_PROFILES = profiles;
    try {
      const a = join(root, 'sess-a');
      const b = join(root, 'sess-b');
      const dirA = checkoutSessionProfile('/usr/bin/brave-browser', a, root);
      const dirB = checkoutSessionProfile('/usr/bin/brave-browser', b, root);
      expect(dirA).not.toBe(dirB);
      expect(dirA).toBe(join(a, 'chrome-profile'));
      expect(readFileSync(join(dirA, 'Default', 'Cookies'), 'utf8')).toBe('host-cookies');
      expect(existsSync(join(dirA, 'SingletonLock'))).toBe(false);
      expect(existsSync(join(dirB, 'SingletonLock'))).toBe(false);
    } finally {
      if (prevHost === undefined) delete process.env.NEXUSLINK_HOST_USER_DATA_DIR;
      else process.env.NEXUSLINK_HOST_USER_DATA_DIR = prevHost;
      if (prevProfiles === undefined) delete process.env.NEXUSLINK_BROWSER_PROFILES;
      else process.env.NEXUSLINK_BROWSER_PROFILES = prevProfiles;
      rmSync(root, { recursive: true, force: true });
    }
  });
});
