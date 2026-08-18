// FreeDesktop icon resolver and rasterizer for NexusLink.
// Finds real app icons across themes, desktop entries, pixmaps, flatpak, snap, and Steam,
// and rasterizes SVGs / converts images into crisp 128x128 PNG data URIs cached to disk and memory.

import { readdir, stat, mkdir } from 'node:fs/promises';
import { join, basename, extname } from 'node:path';
import { homedir } from 'node:os';
import { existsSync } from 'node:fs';
import { createHash } from 'node:crypto';

type SpawnOpts = Parameters<typeof Bun.spawn>[1];

const DISPLAY = process.env.DISPLAY || ':0';
const CACHE_DIR = join(homedir(), '.cache/nexuslink/icons');

const ICON_ROOTS = [
  join(homedir(), '.local/share/icons'),
  join(homedir(), '.icons'),
  '/usr/share/icons',
  '/usr/local/share/icons',
  '/var/lib/flatpak/exports/share/icons',
  join(homedir(), '.local/share/flatpak/exports/share/icons'),
  '/var/lib/snapd/desktop/share/icons',
  '/snap',
  '/usr/share/pixmaps',
  join(homedir(), '.local/share/pixmaps'),
  join(homedir(), '.steam/steam/appcache/stats/icon'),
  join(homedir(), '.steam/root/appcache/stats/icon'),
  join(homedir(), '.steam/debian-installation/appcache/stats/icon'),
];

let themeChainCache: { at: number; chain: string[] } | null = null;
let themePromise: Promise<string[]> | null = null;

let iconIndexCache: { at: number; index: Map<string, string[]> } | null = null;
let indexingPromise: Promise<Map<string, string[]>> | null = null;

const memoryDataUriCache = new Map<string, string | null>(); // iconName/path -> data URI
const inflightResolutions = new Map<string, Promise<string | undefined>>();

class Semaphore {
  private count: number;
  private queue: (() => void)[] = [];

  constructor(count: number) {
    this.count = count;
  }

  async acquire(): Promise<void> {
    if (this.count > 0) {
      this.count--;
      return;
    }
    return new Promise<void>((resolve) => {
      this.queue.push(resolve);
    });
  }

  release(): void {
    if (this.queue.length > 0) {
      const next = this.queue.shift();
      next?.();
    } else {
      this.count++;
    }
  }
}

const conversionSemaphore = new Semaphore(16);

async function convertAsync(srcPath: string, destPath: string): Promise<boolean> {
  await conversionSemaphore.acquire();
  try {
    const proc = Bun.spawn(['convert', '-background', 'none', '-resize', '128x128', srcPath, destPath], {
      stdout: 'ignore',
      stderr: 'ignore',
    } as unknown as SpawnOpts);
    const exitCode = await proc.exited;
    return exitCode === 0;
  } catch {
    return false;
  } finally {
    conversionSemaphore.release();
  }
}

/** Detect user icon theme and follow its FreeDesktop inheritance hierarchy. */
export async function getThemeChain(): Promise<string[]> {
  if (themeChainCache && Date.now() - themeChainCache.at < 300_000) {
    return themeChainCache.chain;
  }
  if (themePromise) return themePromise;

  themePromise = (async () => {
    const themes = new Set<string>();

    // 1. GNOME / GTK settings via gsettings
    try {
      const res = Bun.spawnSync(['gsettings', 'get', 'org.gnome.desktop.interface', 'icon-theme'], {
        env: { ...process.env, DISPLAY },
        stderr: 'ignore',
      } as unknown as SpawnOpts);
      const t = res.stdout?.toString().trim().replace(/^['"]|['"]$/g, '');
      if (t) themes.add(t);
    } catch {}

    // 2. GTK 3/4 settings file fallback
    try {
      const gtk3 = join(homedir(), '.config/gtk-3.0/settings.ini');
      if (existsSync(gtk3)) {
        const content = await Bun.file(gtk3).text();
        const m = content.match(/gtk-icon-theme-name\s*=\s*(.+)/);
        if (m?.[1]) themes.add(m[1].trim());
      }
    } catch {}

    // 3. Known good fallback themes
    themes.add('WhiteSur-dark');
    themes.add('WhiteSur');
    themes.add('ZorinBlue-Dark');
    themes.add('Zorin');
    themes.add('Yaru');
    themes.add('Adwaita');
    themes.add('hicolor');

    const resolvedChain: string[] = [];
    const visited = new Set<string>();

    for (const theme of themes) {
      if (visited.has(theme)) continue;
      visited.add(theme);
      resolvedChain.push(theme);

      // Read index.theme for Inherits=
      for (const root of ICON_ROOTS) {
        const idxFile = join(root, theme, 'index.theme');
        if (existsSync(idxFile)) {
          try {
            const txt = await Bun.file(idxFile).text();
            const m = txt.match(/Inherits\s*=\s*(.+)/);
            if (m?.[1]) {
              const parents = m[1].split(',').map((s) => s.trim()).filter(Boolean);
              for (const p of parents) {
                if (!visited.has(p)) {
                  visited.add(p);
                  resolvedChain.push(p);
                }
              }
            }
          } catch {}
        }
      }
    }

    if (!visited.has('hicolor')) resolvedChain.push('hicolor');
    themeChainCache = { at: Date.now(), chain: resolvedChain };
    themePromise = null;
    return resolvedChain;
  })();

  return themePromise;
}

/** Recursively scan an icon root and populate the index map. */
async function indexDir(dir: string, index: Map<string, string[]>, depth = 0): Promise<void> {
  if (depth > 6) return;
  try {
    const entries = await readdir(dir, { withFileTypes: true });
    for (const ent of entries) {
      const full = join(dir, ent.name);
      if (ent.isDirectory()) {
        await indexDir(full, index, depth + 1);
      } else if (ent.isFile() || ent.isSymbolicLink()) {
        const ext = extname(ent.name).toLowerCase();
        if (['.png', '.svg', '.jpg', '.jpeg', '.webp', '.ico', '.xpm'].includes(ext)) {
          const name = ent.name.slice(0, -ext.length).toLowerCase();
          let list = index.get(name);
          if (!list) {
            list = [];
            index.set(name, list);
          }
          list.push(full);
        }
      }
    }
  } catch {}
}

/** Build or retrieve cached in-memory icon index map across all roots. */
export async function getIconIndex(forceRefresh = false): Promise<Map<string, string[]>> {
  if (!forceRefresh && iconIndexCache && Date.now() - iconIndexCache.at < 180_000) {
    return iconIndexCache.index;
  }
  if (!forceRefresh && indexingPromise) {
    return indexingPromise;
  }

  indexingPromise = (async () => {
    const index = new Map<string, string[]>();
    for (const root of ICON_ROOTS) {
      if (existsSync(root)) {
        await indexDir(root, index);
      }
    }
    iconIndexCache = { at: Date.now(), index };
    indexingPromise = null;
    return index;
  })();

  return indexingPromise;
}

/** Score candidate icon file path based on active theme, category, and resolution. */
function scorePath(path: string, themeChain: string[]): number {
  let score = 0;
  const pLow = path.toLowerCase();

  // 1. Theme match score (higher index in chain gets lower priority)
  for (let i = 0; i < themeChain.length; i++) {
    const th = themeChain[i].toLowerCase();
    if (pLow.includes(`/${th}/`)) {
      score += (themeChain.length - i) * 1000;
      break;
    }
  }

  // 2. Category score
  if (pLow.includes('/apps/') || pLow.includes('/apps@2x/')) score += 200;
  else if (pLow.includes('/categories/')) score += 100;
  else if (pLow.includes('/places/')) score += 50;

  // 3. Size score (prefer crisp 128/96/64/scalable)
  if (pLow.includes('128x128') || pLow.includes('/128/') || pLow.includes('128@2x')) score += 60;
  else if (pLow.includes('96x96') || pLow.includes('/96/')) score += 55;
  else if (pLow.includes('64x64') || pLow.includes('/64/')) score += 50;
  else if (pLow.includes('scalable/')) score += 45;
  else if (pLow.includes('256x256') || pLow.includes('/256/')) score += 40;
  else if (pLow.includes('48x48') || pLow.includes('/48/')) score += 35;
  else if (pLow.includes('32x32') || pLow.includes('/32/')) score += 25;

  // 4. Format score
  if (pLow.endsWith('.png')) score += 15;
  else if (pLow.endsWith('.svg')) score += 12;
  else if (pLow.endsWith('.jpg') || pLow.endsWith('.jpeg') || pLow.endsWith('.webp')) score += 8;

  return score;
}

/** Find the best icon file path on disk for a given icon name, appId, wmClass, or exec. */
export async function findIconFile(
  iconName: string | undefined,
  appId?: string,
  wmClass?: string,
  exec?: string,
): Promise<string | null> {
  const candidatesToTry: string[] = [];

  if (iconName) {
    // If it is already a direct absolute path
    if (iconName.startsWith('/') && existsSync(iconName)) {
      return iconName;
    }
    candidatesToTry.push(iconName);
    // Try without extension if someone specified foo.png in desktop file
    const ext = extname(iconName);
    if (ext) candidatesToTry.push(iconName.slice(0, -ext.length));
    // Try without -symbolic
    if (iconName.endsWith('-symbolic')) {
      candidatesToTry.push(iconName.replace(/-symbolic$/, ''));
    }
    // Reverse-DNS last segment (e.g. org.gnome.Calculator -> calculator)
    const dotParts = iconName.split('.');
    if (dotParts.length > 1) {
      candidatesToTry.push(dotParts[dotParts.length - 1]);
      candidatesToTry.push(dotParts.slice(-2).join('-'));
    }
  }

  if (appId) {
    candidatesToTry.push(appId);
    const dotParts = appId.split('.');
    if (dotParts.length > 1) {
      candidatesToTry.push(dotParts[dotParts.length - 1]);
      candidatesToTry.push(dotParts.slice(-2).join('-'));
    }
  }

  if (wmClass) {
    candidatesToTry.push(wmClass);
    const parts = wmClass.split('.');
    for (const p of parts) candidatesToTry.push(p);
  }

  // Keyword heuristics from Exec string (e.g. steam, thermal, fan, terminal, browser)
  if (exec) {
    const execLow = exec.toLowerCase();
    if (execLow.includes('steam')) {
      candidatesToTry.push('steam', 'steam-launcher', 'applications-games');
    }
    if (execLow.includes('thermal') || execLow.includes('fan') || execLow.includes('sensor')) {
      candidatesToTry.push('utilities-system-monitor', 'sensors-applet', 'cpu', 'gnome-system-monitor');
    }
    if (execLow.includes('terminal') || execLow.includes('bash') || execLow.includes('zsh')) {
      candidatesToTry.push('utilities-terminal', 'org.gnome.Terminal', 'terminal');
    }
  }

  const [themeChain, index] = await Promise.all([getThemeChain(), getIconIndex()]);

  for (const raw of candidatesToTry) {
    const key = raw.toLowerCase().trim();
    if (!key) continue;

    const matches = index.get(key);
    if (matches && matches.length > 0) {
      return matches.slice().sort((a, b) => scorePath(b, themeChain) - scorePath(a, themeChain))[0];
    }
  }

  // Final fallback candidates for generic apps
  const genericFallbacks = [
    'system-run',
    'application-default-icon',
    'application-x-executable',
    'package-x-generic',
  ];
  for (const fallback of genericFallbacks) {
    const matches = index.get(fallback);
    if (matches && matches.length > 0) {
      return matches.slice().sort((a, b) => scorePath(b, themeChain) - scorePath(a, themeChain))[0];
    }
  }

  return null;
}

/**
 * Convert any icon (SVG, PNG, JPG, WEBP, ICO, XPM) to a crisp 128x128 PNG base64 data URI.
 * Caches rasterized PNGs to ~/.cache/nexuslink/icons/ for instant subsequent retrieval.
 */
export async function fileToPngDataUri(filePath: string): Promise<string | null> {
  try {
    const file = Bun.file(filePath);
    if (!(await file.exists())) return null;
    const st = await stat(filePath);
    if (st.size === 0) return null;

    const ext = extname(filePath).toLowerCase();

    // Fast path: if already a PNG and reasonable size (<= 150KB), encode directly
    if (ext === '.png' && st.size <= 150_000) {
      const buf = Buffer.from(await file.arrayBuffer());
      return `data:image/png;base64,${buf.toString('base64')}`;
    }

    // Ensure cache dir exists
    await mkdir(CACHE_DIR, { recursive: true });

    // Check disk cache
    const cacheKey = createHash('md5').update(`${filePath}:${st.mtimeMs}:128`).digest('hex');
    const cachePath = join(CACHE_DIR, `${cacheKey}.png`);

    if (existsSync(cachePath)) {
      const cachedBuf = Buffer.from(await Bun.file(cachePath).arrayBuffer());
      return `data:image/png;base64,${cachedBuf.toString('base64')}`;
    }

    // Rasterize / convert asynchronously with concurrency limiter
    const ok = await convertAsync(filePath, cachePath);
    if (ok && existsSync(cachePath)) {
      const cachedBuf = Buffer.from(await Bun.file(cachePath).arrayBuffer());
      return `data:image/png;base64,${cachedBuf.toString('base64')}`;
    }

    // Fallback if convert failed (e.g. read raw if png/jpg)
    if (['.png', '.jpg', '.jpeg', '.webp'].includes(ext)) {
      const buf = Buffer.from(await file.arrayBuffer());
      const mime = ext === '.png' ? 'image/png' : ext === '.webp' ? 'image/webp' : 'image/jpeg';
      return `data:${mime};base64,${buf.toString('base64')}`;
    }

    return null;
  } catch {
    return null;
  }
}

/** Resolve an icon to a PNG data URI with full caching. */
export async function resolveAppIcon(
  iconName: string | undefined,
  appId?: string,
  wmClass?: string,
  exec?: string,
): Promise<string | undefined> {
  const cacheKey = `${iconName ?? ''}|${appId ?? ''}|${wmClass ?? ''}|${exec ?? ''}`;
  if (memoryDataUriCache.has(cacheKey)) {
    return memoryDataUriCache.get(cacheKey) ?? undefined;
  }
  if (inflightResolutions.has(cacheKey)) {
    return inflightResolutions.get(cacheKey);
  }

  const promise = (async () => {
    const filePath = await findIconFile(iconName, appId, wmClass, exec);
    if (!filePath) {
      memoryDataUriCache.set(cacheKey, null);
      inflightResolutions.delete(cacheKey);
      return undefined;
    }

    const dataUri = await fileToPngDataUri(filePath);
    memoryDataUriCache.set(cacheKey, dataUri);
    inflightResolutions.delete(cacheKey);
    return dataUri ?? undefined;
  })();

  inflightResolutions.set(cacheKey, promise);
  return promise;
}

/** Invalidate memory caches when themes or icons change. */
export function invalidateIconCache(): void {
  themeChainCache = null;
  themePromise = null;
  iconIndexCache = null;
  indexingPromise = null;
  memoryDataUriCache.clear();
  inflightResolutions.clear();
}
