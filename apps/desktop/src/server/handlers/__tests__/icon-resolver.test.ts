import { describe, it, expect } from 'bun:test';
import {
  getThemeChain,
  getIconIndex,
  findIconFile,
  fileToPngDataUri,
  resolveAppIcon,
  invalidateIconCache,
} from '../icon-resolver';
import { listApps, refreshApps, setAppsBroadcast } from '../windows';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { unlink } from 'node:fs/promises';

describe('FreeDesktop icon resolver', () => {
  it('detects theme hierarchy with standard fallback', async () => {
    const chain = await getThemeChain();
    expect(chain.length).toBeGreaterThanOrEqual(1);
    expect(chain).toContain('hicolor');
  });

  it('indexes desktop icons across system and user roots', async () => {
    const index = await getIconIndex();
    expect(index.size).toBeGreaterThan(100);
  });

  it('resolves real system application icons', async () => {
    const chrome = await findIconFile('google-chrome');
    const calc = await findIconFile('org.gnome.Calculator');
    expect(chrome || calc).toBeTruthy();
  });

  it('converts icon files to valid PNG base64 data URIs', async () => {
    const calc = await findIconFile('org.gnome.Calculator');
    if (calc) {
      const uri = await fileToPngDataUri(calc);
      expect(uri).toMatch(/^data:image\/(png|jpeg|webp);base64,/);
    }
  });

  it('resolves icons for all visible installed apps with listApps', async () => {
    const apps = await listApps();
    expect(apps.length).toBeGreaterThan(0);
    const withIcon = apps.filter((a) => a.icon != null);
    // At least 95%+ of apps on system must resolve real icons
    expect(withIcon.length / apps.length).toBeGreaterThan(0.95);
  });

  it('supports live app addition and refresh', async () => {
    let receivedUpdate = false;
    setAppsBroadcast((msg) => {
      if (msg.type === 'apps-update') {
        const found = msg.apps.find((a) => a.appId === 'test-dynamic-app');
        if (found) receivedUpdate = true;
      }
    });

    const testAppPath = join(homedir(), '.local/share/applications/test-dynamic-app.desktop');
    try {
      await Bun.write(
        testAppPath,
        `[Desktop Entry]\nType=Application\nName=Test Dynamic App\nExec=echo test\nIcon=utilities-terminal\n`,
      );

      const refreshed = await refreshApps();
      const match = refreshed.find((a) => a.appId === 'test-dynamic-app');
      expect(match).toBeDefined();
      expect(match?.name).toBe('Test Dynamic App');
      expect(match?.icon).toMatch(/^data:image\//);
      expect(receivedUpdate).toBe(true);
    } finally {
      try {
        await unlink(testAppPath);
        await refreshApps();
      } catch {}
    }
  });
});
