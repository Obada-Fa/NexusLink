import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, basename } from 'node:path';
import { readdir } from 'node:fs/promises';
import type { AppInfo, WindowInfo } from '@nexuslink/rpc-types';
import {
  enumTopLevelWindows, isNullPtr, u32, sh32, wideBuffer, ptr,
  windowTitle, windowClass, windowPid, processImagePath, idToHwnd, hwndToId,
  GWL_EXSTYLE, WS_EX_TOOLWINDOW, SW_RESTORE, SW_SHOW, SWP_SHOWWINDOW, HWND_TOP,
} from './win32';

export function listWindows(): WindowInfo[] {
  const out: WindowInfo[] = [];
  for (const hwnd of enumTopLevelWindows()) {
    if (!u32.IsWindowVisible(hwnd as never)) continue;
    const title = windowTitle(hwnd);
    if (!title.trim()) continue;
    const ex = Number(u32.GetWindowLongPtrW(hwnd as never, GWL_EXSTYLE));
    if (ex & WS_EX_TOOLWINDOW) continue;
    const cls = windowClass(hwnd);
    const pid = windowPid(hwnd);
    const image = processImagePath(pid);
    out.push({
      windowId: hwndToId(hwnd),
      title,
      wmClass: cls || basename(image).replace(/\.exe$/i, ''),
      desktop: 0,
      appId: image ? basename(image).replace(/\.exe$/i, '').toLowerCase() : undefined,
    });
  }
  return out.slice(0, 80);
}

export function activateWindow(windowId: string): { ok: boolean } {
  const hwnd = idToHwnd(windowId);
  if (!u32.IsWindow(hwnd as never)) return { ok: false };
  u32.ShowWindow(hwnd as never, SW_RESTORE);
  u32.SetForegroundWindow(hwnd as never);
  return { ok: true };
}

export function adoptWindow(
  windowId: string,
  viewportW?: number,
  viewportH?: number,
): { ok: boolean; region?: { x: number; y: number; width: number; height: number } } {
  const hwnd = idToHwnd(windowId);
  if (!u32.IsWindow(hwnd as never)) return { ok: false };
  const w = Math.max(320, Math.round(viewportW || 400));
  const h = Math.max(480, Math.round(viewportH || 800));
  const primaryW = u32.GetSystemMetrics(0) || 1920;
  const x = Math.max(0, primaryW - w);
  u32.SetWindowPos(hwnd as never, HWND_TOP as never, x, 0, w, h, SWP_SHOWWINDOW);
  u32.SetForegroundWindow(hwnd as never);
  return { ok: true, region: { x, y: 0, width: w, height: h } };
}

export function releaseWindow(windowId: string): { ok: boolean } {
  const hwnd = idToHwnd(windowId);
  if (!u32.IsWindow(hwnd as never)) return { ok: false };
  u32.ShowWindow(hwnd as never, SW_SHOW);
  return { ok: true };
}

const KNOWN_APPS: { appId: string; name: string; paths: string[] }[] = [
  {
    appId: 'msedge',
    name: 'Microsoft Edge',
    paths: [
      'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
      'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
    ],
  },
  {
    appId: 'chrome',
    name: 'Google Chrome',
    paths: [
      'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
      'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
      join(homedir(), 'AppData\\Local\\Google\\Chrome\\Application\\chrome.exe'),
    ],
  },
  {
    appId: 'brave',
    name: 'Brave',
    paths: [
      'C:\\Program Files\\BraveSoftware\\Brave-Browser\\Application\\brave.exe',
      join(homedir(), 'AppData\\Local\\BraveSoftware\\Brave-Browser\\Application\\brave.exe'),
    ],
  },
  {
    appId: 'firefox',
    name: 'Firefox',
    paths: [
      'C:\\Program Files\\Mozilla Firefox\\firefox.exe',
      'C:\\Program Files (x86)\\Mozilla Firefox\\firefox.exe',
    ],
  },
  {
    appId: 'notepad',
    name: 'Notepad',
    paths: ['C:\\Windows\\System32\\notepad.exe'],
  },
  {
    appId: 'calc',
    name: 'Calculator',
    paths: ['C:\\Windows\\System32\\calc.exe'],
  },
  {
    appId: 'cmd',
    name: 'Command Prompt',
    paths: ['C:\\Windows\\System32\\cmd.exe'],
  },
  {
    appId: 'powershell',
    name: 'PowerShell',
    paths: [
      'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
      'C:\\Program Files\\PowerShell\\7\\pwsh.exe',
    ],
  },
];

function firstExisting(paths: string[]): string | null {
  for (const p of paths) {
    if (existsSync(p)) return p;
  }
  return null;
}

export function resolveAppPath(appId: string): string | null {
  const known = KNOWN_APPS.find((a) => a.appId === appId);
  if (known) return firstExisting(known.paths);
  if (existsSync(appId)) return appId;
  return null;
}

async function scanStartMenu(): Promise<AppInfo[]> {
  const roots = [
    join(process.env.ProgramData || 'C:\\ProgramData', 'Microsoft\\Windows\\Start Menu\\Programs'),
    join(homedir(), 'AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs'),
  ];
  const skip = new Set(['desktop.ini', 'uninstall']);
  const out: AppInfo[] = [];
  const seen = new Set<string>();

  async function walk(dir: string, depth: number): Promise<void> {
    if (depth < 0 || !existsSync(dir)) return;
    let entries: string[] = [];
    try {
      entries = await readdir(dir);
    } catch {
      return;
    }
    for (const name of entries) {
      if (skip.has(name.toLowerCase())) continue;
      const full = join(dir, name);
      if (name.toLowerCase().endsWith('.lnk') || name.toLowerCase().endsWith('.url')) {
        const id = name.replace(/\.(lnk|url)$/i, '');
        const key = id.toLowerCase();
        if (seen.has(key)) continue;
        seen.add(key);
        out.push({ appId: `startmenu:${full}`, name: id, wmClass: id });
        continue;
      }
      try {
        await walk(full, depth - 1);
      } catch {
        // skip
      }
    }
  }

  for (const root of roots) await walk(root, 3);
  return out;
}

let cachedApps: AppInfo[] | null = null;

export async function listApps(): Promise<AppInfo[]> {
  if (cachedApps) return cachedApps;
  const apps: AppInfo[] = [];
  for (const known of KNOWN_APPS) {
    if (firstExisting(known.paths)) {
      apps.push({ appId: known.appId, name: known.name, wmClass: known.appId });
    }
  }
  apps.push({ appId: 'nexus.chrome-mobile', name: 'Browser', wmClass: 'msedge' });
  const menu = await scanStartMenu();
  for (const a of menu) {
    if (!apps.some((x) => x.name.toLowerCase() === a.name.toLowerCase())) apps.push(a);
  }
  cachedApps = apps.slice(0, 200);
  return cachedApps;
}

export async function refreshApps(): Promise<AppInfo[]> {
  cachedApps = null;
  return listApps();
}

export function launchApp(appId: string): { ok: boolean } {
  let target = resolveAppPath(appId);
  if (!target && appId.startsWith('startmenu:')) target = appId.slice('startmenu:'.length);
  if (appId === 'nexus.chrome-mobile') {
    target = resolveAppPath('msedge') || resolveAppPath('chrome') || resolveAppPath('brave');
  }
  if (!target) throw new Error(`app not found: ${appId}`);
  const verb = wideBuffer('open');
  const file = wideBuffer(target);
  const rc = sh32.ShellExecuteW(
    null as never,
    ptr(verb),
    ptr(file),
    null as never,
    null as never,
    SW_SHOW,
  );
  if (isNullPtr(rc)) throw new Error(`ShellExecute failed for ${target}`);
  return { ok: true };
}

export function waitForWindowByPid(pid: number, timeoutMs = 8000): string | null {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    for (const hwnd of enumTopLevelWindows()) {
      if (windowPid(hwnd) === pid && u32.IsWindowVisible(hwnd as never) && windowTitle(hwnd)) {
        return hwndToId(hwnd);
      }
    }
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 200);
  }
  return null;
}
