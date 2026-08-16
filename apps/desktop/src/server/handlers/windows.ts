// Window orchestration + app catalog for the X11 LAN path (architecture.md Module B,
// PhysicalBackend). Running windows are enumerated with wmctrl/xprop, shaped into a
// portrait "phone viewport" with wmctrl -e, and matched to .desktop entries so the
// mobile launcher can show real names and icons. No Rust sidecar required.

import { readdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join, basename } from 'node:path';
import { homedir } from 'node:os';
import type { WindowInfo, AppInfo, CaptureRegion } from '@nexuslink/rpc-types';
import { getScreenMetadata, getPrimaryMonitor } from './capture';
import { listProfiles } from './app-profiles';

const DISPLAY = process.env.DISPLAY || ':0';

type SpawnOpts = Parameters<typeof Bun.spawn>[1];

function run(cmd: string[]): string {
  try {
    const out = Bun.spawnSync(cmd, {
      env: { ...process.env, DISPLAY },
      stderr: 'ignore',
    } as unknown as SpawnOpts);
    return out.stdout?.toString() ?? '';
  } catch {
    return '';
  }
}

// ---------------------------------------------------------------------------
// .desktop application catalog
// ---------------------------------------------------------------------------

const APP_DIRS = [
  '/usr/share/applications',
  '/usr/local/share/applications',
  join(homedir(), '.local/share/applications'),
  '/var/lib/snapd/desktop/applications',
  '/var/lib/flatpak/exports/share/applications',
  join(homedir(), '.local/share/flatpak/exports/share/applications'),
];

const ICON_SIZES = ['64x64', '48x48', '96x96', '128x128', '256x256', 'scalable', '32x32'];
const MAX_ICON_BYTES = 200_000;

interface DesktopEntry {
  appId: string;
  path: string;
  name: string;
  iconName?: string;
  exec?: string;
  wmClass?: string;
  noDisplay: boolean;
}

interface AppCatalog {
  apps: DesktopEntry[];
  /** lowercase match key (wmClass / appId fragments) → entry */
  byClass: Map<string, DesktopEntry>;
}

/** Collapse a class/app id for fuzzy matching: "org.gnome.Calculator" → "orggnomecalculator". */
export function normClass(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9]/g, '');
}

let catalogCache: { at: number; catalog: AppCatalog } | null = null;
const iconCache = new Map<string, string | null>(); // iconName → data URI (null = unresolvable)

function parseDesktopFile(path: string, content: string): DesktopEntry | null {
  // Only the [Desktop Entry] group matters; actions/other groups are ignored.
  const lines = content.split('\n');
  let inMain = false;
  const kv: Record<string, string> = {};
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.startsWith('[')) {
      inMain = trimmed === '[Desktop Entry]';
      continue;
    }
    if (!inMain || !trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq < 0) continue;
    const key = trimmed.slice(0, eq).trim();
    if (!(key in kv)) kv[key] = trimmed.slice(eq + 1).trim();
  }
  if ((kv['Type'] ?? 'Application') !== 'Application') return null;
  const name = kv['Name'];
  if (!name) return null;
  return {
    appId: basename(path).replace(/\.desktop$/, ''),
    path,
    name,
    iconName: kv['Icon'],
    exec: kv['Exec'],
    wmClass: kv['StartupWMClass'],
    noDisplay: kv['NoDisplay'] === 'true' || kv['Hidden'] === 'true',
  };
}

async function buildCatalog(): Promise<AppCatalog> {
  const apps: DesktopEntry[] = [];
  const seen = new Set<string>();
  for (const dir of APP_DIRS) {
    let files: string[] = [];
    try {
      files = await readdir(dir);
    } catch {
      continue;
    }
    for (const f of files) {
      if (!f.endsWith('.desktop')) continue;
      const id = f.replace(/\.desktop$/, '');
      if (seen.has(id)) continue;
      try {
        const content = await Bun.file(join(dir, f)).text();
        const entry = parseDesktopFile(join(dir, f), content);
        if (entry) {
          apps.push(entry);
          seen.add(id);
        }
      } catch {
        // unreadable entry — skip
      }
    }
  }

  const byClass = new Map<string, DesktopEntry>();
  for (const app of apps) {
    const keys = new Set<string>();
    if (app.wmClass) {
      keys.add(app.wmClass.toLowerCase());
      keys.add(normClass(app.wmClass));
    }
    keys.add(app.appId.toLowerCase());
    // Reverse-DNS ids also match their last segment, and dashes/dots are
    // interchangeable in the wild (org.gnome.Calculator ↔ gnome-calculator).
    keys.add(normClass(app.appId));
    const last = app.appId.split('.').pop();
    if (last) {
      keys.add(last.toLowerCase());
      keys.add(normClass(last));
    }
    for (const k of keys) {
      if (k && !byClass.has(k)) byClass.set(k, app);
    }
  }
  return { apps, byClass };
}

async function getCatalog(): Promise<AppCatalog> {
  if (catalogCache && Date.now() - catalogCache.at < 60_000) return catalogCache.catalog;
  const catalog = await buildCatalog();
  catalogCache = { at: Date.now(), catalog };
  return catalog;
}

async function fileToDataUri(path: string): Promise<string | null> {
  try {
    const file = Bun.file(path);
    if (!(await file.exists())) return null;
    if (file.size > MAX_ICON_BYTES || file.size === 0) return null;
    const mime = path.endsWith('.svg') ? 'image/svg+xml' : 'image/png';
    if (path.endsWith('.xpm')) return null;
    const buf = Buffer.from(await file.arrayBuffer());
    return `data:${mime};base64,${buf.toString('base64')}`;
  } catch {
    return null;
  }
}

function iconPathRank(path: string): number {
  if (path.includes('64x64')) return 0;
  if (path.includes('48x48')) return 1;
  if (path.includes('96x96')) return 2;
  if (path.includes('128x128')) return 3;
  if (path.endsWith('.svg')) return 4;
  return 5;
}

/** Resolve a freedesktop icon name (or absolute path) to a data: URI. Cached. */
async function resolveIcon(iconName: string | undefined): Promise<string | undefined> {
  if (!iconName) return undefined;
  const cached = iconCache.get(iconName);
  if (cached !== undefined) return cached ?? undefined;

  let uri: string | null = null;
  if (iconName.startsWith('/')) {
    uri = await fileToDataUri(iconName);
  } else {
    const iconRoots = [
      '/usr/share/icons',
      '/var/lib/flatpak/exports/share/icons',
      join(homedir(), '.local/share/flatpak/exports/share/icons'),
      join(homedir(), '.local/share/icons'),
    ];
    const candidates: string[] = [];
    for (const root of iconRoots) {
      for (const size of ICON_SIZES) {
        for (const ext of ['png', 'svg']) {
          candidates.push(`${root}/hicolor/${size}/apps/${iconName}.${ext}`);
        }
      }
    }
    for (const ext of ['png', 'svg']) {
      candidates.push(`/usr/share/pixmaps/${iconName}.${ext}`);
    }
    for (const c of candidates) {
      uri = await fileToDataUri(c);
      if (uri) break;
    }
    if (!uri) {
      // Last resort: one find(1) sweep across icon themes (cached, so it runs once
      // per unique icon name per server lifetime).
      const found = run([
        'find', ...iconRoots.filter((r) => existsSync(r)),
        '-name', `${iconName}.png`, '-o', '-name', `${iconName}.svg`,
      ])
        .split('\n')
        .filter(Boolean)
        // Prefer mid-size rasters (crisp at launcher size, small on the wire).
        .sort((a, b) => Number(iconPathRank(a)) - Number(iconPathRank(b)));
      for (const f of found) {
        uri = await fileToDataUri(f);
        if (uri) break;
      }
    }
  }
  iconCache.set(iconName, uri);
  return uri ?? undefined;
}

export async function listApps(): Promise<AppInfo[]> {
  const catalog = await getCatalog();
  const visible = catalog.apps.filter((a) => !a.noDisplay && a.exec);
  const out: AppInfo[] = [];
  for (const app of visible) {
    out.push({
      appId: app.appId,
      name: app.name,
      icon: await resolveIcon(app.iconName),
      wmClass: app.wmClass ?? app.appId,
    });
  }
  // Built-in virtual-session profiles (e.g. the mobile browser) appear as
  // first-class launcher apps alongside the .desktop catalog.
  for (const p of listProfiles()) {
    if (out.some((a) => a.appId === p.appId)) continue;
    out.push({
      appId: p.appId,
      name: p.name,
      icon: await resolveIcon(p.iconName),
      wmClass: p.appId,
    });
  }
  out.sort((a, b) => a.name.localeCompare(b.name));
  return out;
}

/** Catalog lookup for the virtual-session launcher (app-sessions.ts). */
export async function getDesktopEntry(
  appId: string,
): Promise<{ exec?: string; name: string; iconName?: string } | null> {
  const catalog = await getCatalog();
  const app = catalog.apps.find((a) => a.appId === appId);
  return app ? { exec: app.exec, name: app.name, iconName: app.iconName } : null;
}

/** Icon resolution for callers outside this module. */
export async function resolveIconPublic(iconName: string | undefined): Promise<string | undefined> {
  return resolveIcon(iconName);
}

export async function launchApp(appId: string): Promise<{ ok: boolean; wmClass?: string }> {
  const catalog = await getCatalog();
  const app = catalog.apps.find((a) => a.appId === appId);
  if (!app) return { ok: false };

  // gio launch handles Exec field codes, DBusActivatable, working dirs, etc.
  try {
    Bun.spawn(['gio', 'launch', app.path], {
      stdout: 'ignore',
      stderr: 'ignore',
      env: { ...process.env, DISPLAY },
    } as unknown as SpawnOpts);
    return { ok: true, wmClass: app.wmClass ?? app.appId };
  } catch {
    // Fallback: strip field codes and run Exec directly.
    const exec = (app.exec ?? '').replace(/%[fFuUdDnNickvm]/g, '').trim();
    if (!exec) return { ok: false };
    try {
      Bun.spawn(['sh', '-c', `setsid ${exec} >/dev/null 2>&1 &`], {
        env: { ...process.env, DISPLAY },
      } as unknown as SpawnOpts);
      return { ok: true, wmClass: app.wmClass ?? app.appId };
    } catch {
      return { ok: false };
    }
  }
}

// ---------------------------------------------------------------------------
// Running-window enumeration
// ---------------------------------------------------------------------------

/** Window types/states that must never appear in the phone launcher. */
function isNormalWindow(windowId: string): boolean {
  const props = run(['xprop', '-id', windowId, '_NET_WM_WINDOW_TYPE', '_NET_WM_STATE']);
  if (props.includes('_NET_WM_WINDOW_TYPE') && !props.includes('not found')) {
    if (
      props.includes('_NET_WM_WINDOW_TYPE_DESKTOP') ||
      props.includes('_NET_WM_WINDOW_TYPE_DOCK') ||
      props.includes('_NET_WM_WINDOW_TYPE_TOOLBAR') ||
      props.includes('_NET_WM_WINDOW_TYPE_MENU') ||
      props.includes('_NET_WM_WINDOW_TYPE_SPLASH') ||
      props.includes('_NET_WM_WINDOW_TYPE_NOTIFICATION') ||
      props.includes('_NET_WM_WINDOW_TYPE_TOOLTIP')
    ) {
      return false;
    }
  }
  if (props.includes('_NET_WM_STATE_SKIP_TASKBAR')) return false;
  return true;
}

export async function listWindows(): Promise<WindowInfo[]> {
  const raw = run(['wmctrl', '-lx']);
  const catalog = await getCatalog();
  const out: WindowInfo[] = [];

  for (const line of raw.split('\n')) {
    if (!line.trim()) continue;
    // 0x03400004  0 brave-browser.Brave-browser  host  Title with spaces
    const m = line.match(/^(0x[0-9a-f]+)\s+(-?\d+)\s+(\S+)\s+(\S+)\s+(.*)$/);
    if (!m) continue;
    const [, windowId, desktopStr, wmClass, , title] = m;
    const desktop = parseInt(desktopStr!, 10);
    if (!isNormalWindow(windowId!)) continue;

    // Match the window to a .desktop entry via WM_CLASS for name/icon.
    const classParts = wmClass!.toLowerCase().split('.');
    let entry: DesktopEntry | undefined;
    for (const part of [classParts[1], classParts[0], wmClass!.toLowerCase()]) {
      if (!part) continue;
      entry = catalog.byClass.get(part) ?? catalog.byClass.get(normClass(part));
      if (entry) break;
    }
    if (!entry) {
      // Fuzzy fallback: normalized containment either way (gnome-calculator ⊂
      // org.gnome.Calculator). Longest match wins to avoid generic collisions.
      const nParts = [normClass(classParts[1] ?? ''), normClass(classParts[0] ?? '')].filter(
        (p) => p.length >= 4,
      );
      let best: { entry: DesktopEntry; len: number } | null = null;
      for (const app of catalog.apps) {
        const nApp = normClass(app.wmClass ?? app.appId);
        if (nApp.length < 4) continue;
        for (const p of nParts) {
          if (nApp.includes(p) || p.includes(nApp)) {
            const len = Math.min(nApp.length, p.length);
            if (!best || len > best.len) best = { entry: app, len };
          }
        }
      }
      entry = best?.entry;
    }

    out.push({
      windowId: windowId!,
      title: title ?? '',
      wmClass: wmClass!,
      desktop,
      icon: entry ? await resolveIcon(entry.iconName) : undefined,
      appId: entry?.appId,
    });
  }
  return out;
}

// ---------------------------------------------------------------------------
// Portrait adoption (PhysicalBackend)
// ---------------------------------------------------------------------------

/** Original geometry per adopted window, restored on release. */
const savedGeometry = new Map<string, CaptureRegion & { maximized: boolean }>();

function getWindowGeometry(windowId: string): CaptureRegion | null {
  // xwininfo reports the client area's absolute position — exactly what x11grab needs.
  const info = run(['xwininfo', '-id', windowId]);
  const x = info.match(/Absolute upper-left X:\s*(-?\d+)/)?.[1];
  const y = info.match(/Absolute upper-left Y:\s*(-?\d+)/)?.[1];
  const w = info.match(/Width:\s*(\d+)/)?.[1];
  const h = info.match(/Height:\s*(\d+)/)?.[1];
  if (x === undefined || y === undefined || !w || !h) return null;
  return { x: parseInt(x, 10), y: parseInt(y, 10), width: parseInt(w, 10), height: parseInt(h, 10) };
}

export { getWindowGeometry };

function isMaximized(windowId: string): boolean {
  const props = run(['xprop', '-id', windowId, '_NET_WM_STATE']);
  return props.includes('MAXIMIZED_VERT') || props.includes('MAXIMIZED_HORZ');
}

/**
 * Shape a window into a portrait phone viewport (right-anchored, height-fit) and
 * focus it. Returns the resulting on-screen region for capture + input mapping.
 */
export async function adoptWindow(
  windowId: string,
  viewportW = 390,
  viewportH = 844,
): Promise<{ region: CaptureRegion }> {
  const screen = getScreenMetadata();
  // Anchor inside the PRIMARY monitor — on multi-monitor hosts the WM fights
  // placements on other outputs, and the user's attention is here anyway.
  const mon = getPrimaryMonitor();

  if (!savedGeometry.has(windowId)) {
    const orig = getWindowGeometry(windowId);
    if (orig) savedGeometry.set(windowId, { ...orig, maximized: isMaximized(windowId) });
  }

  run(['wmctrl', '-i', '-r', windowId, '-b', 'remove,maximized_vert,maximized_horz']);
  run(['wmctrl', '-i', '-r', windowId, '-b', 'remove,fullscreen']);
  run(['wmctrl', '-i', '-r', windowId, '-b', 'remove,hidden']);

  // Height-fit portrait rect with margins for panels/decorations; right-anchored so
  // the desktop stays usable on the left.
  const marginTop = 48;
  const marginBottom = 16;
  const height = mon.height - marginTop - marginBottom;
  const aspect = viewportW > 0 && viewportH > 0 ? viewportW / viewportH : 390 / 844;
  const width = Math.min(mon.width - 32, Math.round(height * aspect));
  const x = mon.x + mon.width - width - 16;
  const y = mon.y + marginTop;

  run(['wmctrl', '-i', '-r', windowId, '-e', `0,${x},${y},${width},${height}`]);
  run(['wmctrl', '-i', '-a', windowId]);

  // Read back what the WM actually granted (decorations can shift the rect, and
  // some WMs re-place the window a beat later).
  await Bun.sleep(300);
  const actual = getWindowGeometry(windowId);
  const region = actual ?? { x, y, width, height };

  // Clamp into screen bounds and even-align for the capture pipeline.
  const rx = Math.max(0, region.x);
  const ry = Math.max(0, region.y);
  const rw = Math.min(screen.width - rx, region.width) & ~1;
  const rh = Math.min(screen.height - ry, region.height) & ~1;

  return { region: { x: rx, y: ry, width: rw, height: rh } };
}

/** Restore a previously adopted window to its original geometry. */
export function releaseWindow(windowId: string): { ok: boolean } {
  const saved = savedGeometry.get(windowId);
  savedGeometry.delete(windowId);
  if (!saved) return { ok: true };
  run(['wmctrl', '-i', '-r', windowId, '-e', `0,${saved.x},${saved.y},${saved.width},${saved.height}`]);
  if (saved.maximized) {
    run(['wmctrl', '-i', '-r', windowId, '-b', 'add,maximized_vert,maximized_horz']);
  }
  return { ok: true };
}

export function activateWindow(windowId: string): { ok: boolean } {
  run(['wmctrl', '-i', '-a', windowId]);
  return { ok: true };
}
