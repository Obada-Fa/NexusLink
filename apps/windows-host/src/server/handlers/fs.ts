import type { FileEntry, GitWorkingTree, ProjectInfo } from '@nexuslink/rpc-types';
import fs from 'fs/promises';
import { homedir } from 'node:os';
import { basename, join, win32 } from 'node:path';
import { existsSync, realpathSync, statSync } from 'node:fs';
import { dlopen, FFIType, ptr } from 'bun:ffi';

export function toPosixPath(p: string): string {
  return p.replace(/\\/g, '/');
}

export function posixify(raw: string): string {
  return (raw || '').trim().replace(/\\/g, '/');
}

/** `/` is This PC (drive list), not the user profile. */
export function isThisPcPath(rawPath: string): boolean {
  const p = posixify(rawPath).replace(/\/+$/, '') || '/';
  return p === '/' || p.toLowerCase() === 'this pc';
}

const DRIVE_ROOT = /^[A-Za-z]:$/;
const DRIVE_PATH = /^[A-Za-z]:[\\/]/;

export function listDriveLetters(): string[] {
  try {
    const kernel32 = dlopen('kernel32.dll', {
      GetLogicalDriveStringsW: {
        args: [FFIType.u32, FFIType.ptr],
        returns: FFIType.u32,
      },
    });
    const buf = new Uint16Array(512);
    const nChars = kernel32.symbols.GetLogicalDriveStringsW(buf.length, ptr(buf));
    if (!nChars) return fallbackDriveLetters();
    const letters: string[] = [];
    let i = 0;
    const limit = Math.min(nChars, buf.length);
    while (i < limit) {
      if (buf[i] === 0) {
        i++;
        continue;
      }
      const letter = String.fromCharCode(buf[i]!).toUpperCase();
      if (/^[A-Z]$/.test(letter) && !letters.includes(letter)) letters.push(letter);
      while (i < limit && buf[i] !== 0) i++;
      i++;
    }
    return letters.length > 0 ? letters : fallbackDriveLetters();
  } catch {
    return fallbackDriveLetters();
  }
}

function fallbackDriveLetters(): string[] {
  const found: string[] = [];
  for (let code = 67; code <= 90; code++) {
    const letter = String.fromCharCode(code);
    try {
      if (existsSync(`${letter}:\\`)) found.push(letter);
    } catch {
      // removable / inaccessible
    }
  }
  return found.length > 0 ? found : ['C'];
}

export function listDriveEntries(): FileEntry[] {
  const now = new Date().toISOString();
  return listDriveLetters().map((letter) => ({
    name: `${letter}:`,
    path: `${letter}:/`,
    size: 0,
    isDirectory: true,
    modifiedAt: now,
    mimeType: 'directory',
  }));
}

/**
 * Phone file UI speaks POSIX. Map that onto a real Windows path without
 * pretending this machine is Linux. `/` is This PC and is not a filesystem path.
 */
export function expandHostPath(rawPath: string): string {
  let p = (rawPath || '').trim();
  const home = homedir();

  if (p.startsWith('file://')) {
    p = decodeURIComponent(p.replace(/^file:\/\//, ''));
    p = p.replace(/^\/([A-Za-z]:)/, '$1');
  }

  if (!p || p === '~') return home;
  if (p.startsWith('~/') || p.startsWith('~\\')) return join(home, p.slice(2));

  // Phone root listing uses Unix home layout; land on this user's profile.
  if (p === '/home' || p.startsWith('/home/')) return home;

  if (isThisPcPath(p)) {
    throw new Error('This PC is not a filesystem folder');
  }

  if (DRIVE_ROOT.test(p)) return `${p}\\`;
  if (DRIVE_PATH.test(p)) return win32.normalize(p.replace(/\//g, '\\'));

  return p;
}

export async function handleFsRead(rawPath: string): Promise<string> {
  if (isThisPcPath(rawPath)) {
    throw new Error('Cannot read This PC');
  }
  const p = expandHostPath(rawPath);
  const stat = await fs.stat(p);
  if (stat.isDirectory()) {
    throw new Error(`Cannot read directory: ${p}`);
  }
  const MAX_READ_BYTES = 5 * 1024 * 1024;
  if (stat.size > MAX_READ_BYTES) {
    throw new Error(`File is too large (${stat.size} bytes, max ${MAX_READ_BYTES} bytes)`);
  }
  return await fs.readFile(p, 'utf-8');
}

export async function handleFsList(path: string, showHidden = false): Promise<FileEntry[]> {
  if (isThisPcPath(path)) return listDriveEntries();

  const dir = expandHostPath(path);
  const entries = await fs.readdir(dir, { withFileTypes: true, recursive: false });
  const out: FileEntry[] = [];
  for (const entry of entries) {
    const name = entry.name;
    if (!showHidden && name.startsWith('.')) continue;
    const fullPath = toPosixPath(join(dir, name));
    let size = 0;
    let modifiedAt = '';
    try {
      const stat = await fs.stat(join(dir, name));
      size = entry.isFile() ? Number(stat.size) : 0;
      modifiedAt = new Date(stat.mtimeMs).toISOString();
    } catch {
      modifiedAt = new Date().toISOString();
    }
    out.push({
      name,
      path: fullPath,
      size,
      isDirectory: entry.isDirectory(),
      modifiedAt,
      mimeType: entry.isDirectory() ? 'directory' : 'application/octet-stream',
    });
  }
  return out.sort((a, b) => {
    if (a.isDirectory !== b.isDirectory) {
      return a.isDirectory ? -1 : 1;
    }
    return a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' });
  });
}

function canonicalDir(dir: string): string {
  try {
    return realpathSync(dir);
  } catch {
    return dir;
  }
}

function projectScanRoots(): string[] {
  const home = homedir();
  const roots = [
    home,
    join(home, 'Projects'),
    join(home, 'projects'),
    join(home, 'Documents'),
    join(home, 'Desktop'),
    join(home, 'source'),
    join(home, 'src'),
    join(home, 'dev'),
    join(home, 'work'),
  ];
  for (const letter of listDriveLetters()) {
    roots.push(`${letter}:\\projects`);
    roots.push(`${letter}:\\Projects`);
    roots.push(`${letter}:\\code`);
    roots.push(`${letter}:\\dev`);
    roots.push(`${letter}:\\src`);
    roots.push(`${letter}:\\work`);
  }
  return roots;
}

export async function listProjects(): Promise<ProjectInfo[]> {
  const skip = new Set(['node_modules', 'dist', 'out', 'build', 'target']);
  const seen = new Set<string>();
  const out: ProjectInfo[] = [];

  async function consider(dir: string, name: string): Promise<void> {
    const real = canonicalDir(dir);
    if (seen.has(real) || !existsSync(join(dir, '.git'))) return;
    seen.add(real);
    out.push({ name, path: toPosixPath(real) });
  }

  async function walk(root: string, remaining: number): Promise<void> {
    if (remaining < 0 || !existsSync(root)) return;
    let entries: string[] = [];
    try {
      entries = await fs.readdir(root);
    } catch {
      return;
    }
    for (const name of entries) {
      if (name.startsWith('.') || skip.has(name)) continue;
      const child = join(root, name);
      await consider(child, name);
      if (remaining > 0) {
        try {
          if (statSync(child).isDirectory()) await walk(child, remaining - 1);
        } catch {
          // unreadable
        }
      }
    }
  }

  for (const root of projectScanRoots()) {
    if (!existsSync(root)) continue;
    await consider(root, basename(root));
    await walk(root, 2);
  }
  out.sort((a, b) => a.name.localeCompare(b.name));
  return out.slice(0, 40);
}

export function parseGitStatusPorcelain(output: string): Omit<GitWorkingTree, 'cwd'> | null {
  const lines = output
    .split('\n')
    .map((l) => l.replace(/\r$/, ''))
    .filter((l) => l.length > 0);
  if (!lines[0]?.startsWith('## ')) return null;
  const header = lines[0].slice(3);
  const branch = (header.split('...')[0] ?? header).split(' ')[0] || 'HEAD';
  const ahead = Number(header.match(/ahead (\d+)/)?.[1] ?? 0);
  const behind = Number(header.match(/behind (\d+)/)?.[1] ?? 0);
  const fileLines = lines.slice(1);
  const files = fileLines
    .map((l) => (l.length >= 3 ? l.slice(3) : l).trim().split(' -> ').pop() ?? '')
    .filter(Boolean)
    .slice(0, 8);
  return { branch, ahead, behind, changed: fileLines.length, files };
}

export async function gitWorkingTree(cwd: string): Promise<GitWorkingTree | null> {
  if (isThisPcPath(cwd)) return null;
  const dir = expandHostPath(cwd);
  if (!dir || !existsSync(dir)) return null;
  try {
    const proc = Bun.spawnSync(['git', '-C', dir, 'status', '-sb', '--porcelain=v1'], {
      stdout: 'pipe',
      stderr: 'pipe',
      timeout: 4000,
    });
    if (proc.exitCode !== 0) return null;
    const text = proc.stdout?.toString() ?? '';
    const parsed = parseGitStatusPorcelain(text);
    if (!parsed) return null;
    return { cwd: toPosixPath(dir), ...parsed };
  } catch {
    return null;
  }
}
