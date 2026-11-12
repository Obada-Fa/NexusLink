import { describe, expect, test } from 'bun:test';
import { defaultAppIds } from '../windows';

const installed = ['org.gnome.Terminal', 'kitty', 'org.gnome.Nautilus', 'org.kde.dolphin'];

function probe(files: Record<string, string>, commands: Record<string, string> = {}, desktop = 'zorin:GNOME') {
  return {
    home: '/home/me',
    env: { XDG_CURRENT_DESKTOP: desktop },
    read: async (path: string) => files[path],
    run: async (argv: string[]) => commands[argv.join(' ')],
  };
}

describe('default terminal and file manager', () => {
  test('xdg-terminals.list wins, desktop-specific first, comments skipped', async () => {
    const r = await defaultAppIds(installed, probe({
      '/home/me/.config/xdg-terminals.list': '# mine\norg.gnome.Terminal.desktop\n',
      '/home/me/.config/gnome-xdg-terminals.list': 'kitty.desktop:new-window\n',
    }, { 'xdg-mime query default inode/directory': 'org.gnome.Nautilus.desktop' }));
    expect(r).toEqual({ terminal: 'kitty', files: 'org.gnome.Nautilus' });
  });

  test('falls back to the GNOME setting, then known terminals', async () => {
    const gsettings = 'gsettings get org.gnome.desktop.default-applications.terminal exec';
    expect((await defaultAppIds(installed, probe({}, { [gsettings]: "'kitty'" }))).terminal).toBe('kitty');
    expect((await defaultAppIds(installed, probe({}))).terminal).toBe('org.gnome.Terminal');
    expect((await defaultAppIds(['org.gnome.Nautilus'], probe({}))).terminal).toBeUndefined();
  });

  test('ignores defaults that are not installed apps', async () => {
    const r = await defaultAppIds(installed, probe(
      { '/home/me/.config/xdg-terminals.list': 'ghost.desktop\n' },
      { 'xdg-mime query default inode/directory': 'missing.desktop' },
    ));
    expect(r).toEqual({ terminal: 'org.gnome.Terminal', files: undefined });
  });
});
