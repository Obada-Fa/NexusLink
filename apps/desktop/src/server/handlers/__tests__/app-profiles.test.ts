import { describe, expect, test } from 'bun:test';
import {
  isChromiumFamily,
  resolveChromiumBin,
  buildChromiumArgv,
  findBrowserBinForAppId,
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

describe('buildChromiumArgv', () => {
  test('uses an isolated profile so desktop Brave is not reused', () => {
    const argv = buildChromiumArgv('/usr/bin/brave-browser', {
      width: 390,
      height: 844,
      dpr: 2,
      sessionDir: '/tmp/nexus-sess',
    });
    expect(argv[0]).toBe('/usr/bin/brave-browser');
    expect(argv).toContain('--user-data-dir=/tmp/nexus-sess/chrome-profile');
    expect(argv.some((a) => a.startsWith('--user-agent='))).toBe(true);
    expect(argv).toContain('--force-device-scale-factor=2.00');
    expect(argv).toContain('--touch-events=enabled');
  });
});
