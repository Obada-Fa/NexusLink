import { describe, expect, test } from 'bun:test';
import {
  isChromiumFamily,
  resolveChromiumBin,
  buildChromiumArgv,
  findBrowserBinForAppId,
  chromiumLayout,
  CHROME_MIN_DIP_WIDTH,
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
  test('uses an isolated profile so desktop Brave is not reused', () => {
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
});
