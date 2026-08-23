import type { FileEntry, GitWorkingTree, ProjectInfo } from '@nexuslink/rpc-types';
import fs from 'fs/promises';
import { homedir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { existsSync, realpathSync, statSync } from 'node:fs';

export function toPosixPath(p: string): string {
  return p.replace(/\\/g, '/');
}

/** Phone sends Unix-style paths; Windows hosts still understand them via Node. */
export function expandHostPath(rawPath: string): string {
  let p = (rawPath || '').trim();
  if (p.startsWith('file://')) {
    p = decodeURIComponent(p.replace(/^file:\/\//, ''));
    p = p.replace(/^\/([A-Za-z]:)/, '$1');
  }
  const home = homedir();
  if (!p || p === '~') return home;
  if (process.platform === 'win32' && p === '/') return home;
  if (p.startsWith('~/') || p.startsWith('~\\')) return join(home, p.slice(2));
  if (process.platform === 'win32' && (p.startsWith('/home/') || p === '/home')) return home;
  if (/^[A-Za-z]:$/.test(p)) return `${p}\\`;
  return p;
}

export function canonicalDir(dir: string): string {
  try {
    return realpathSync(dir);
  } catch {
    return dir;
  }
}

/** Walk up directory tree to find top-level Git repository root if inside a repo. */
export function findGitRoot(startDir: string): string {
  if (!startDir || !startDir.trim()) return startDir;
  let cur = canonicalDir(expandHostPath(startDir));
  while (cur && cur !== '/' && !/^[A-Za-z]:[\\/]?$/.test(cur)) {
    if (existsSync(join(cur, '.git'))) return toPosixPath(cur);
    const parent = dirname(cur);
    if (parent === cur) break;
    cur = parent;
  }
  return toPosixPath(startDir);
}

export async function handleFsRead(rawPath: string): Promise<string> {
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

export async function handleFsMkdir(rawPath: string): Promise<{ path: string; name: string }> {
  const p = expandHostPath(rawPath);
  await fs.mkdir(p, { recursive: true });
  return { path: toPosixPath(p), name: basename(p) };
}

export function getWindowsDrives(): FileEntry[] {
  const drives: FileEntry[] = [];
  for (let i = 65; i <= 90; i++) {
    const letter = String.fromCharCode(i);
    const drivePath = `${letter}:\\`;
    try {
      if (existsSync(drivePath)) {
        drives.push({
          name: `${letter}:`,
          path: `${letter}:/`,
          size: 0,
          isDirectory: true,
          modifiedAt: new Date().toISOString(),
          mimeType: 'directory',
        });
      }
    } catch {
      // Skip inaccessible drives
    }
  }
  return drives;
}

export async function handleFsList(path: string, showHidden = false): Promise<FileEntry[]> {
  const trimmed = (path || '').trim();
  if (process.platform === 'win32' && (trimmed === '/' || trimmed === '' || trimmed.toLowerCase() === 'this pc')) {
    return getWindowsDrives();
  }
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
      const stat = await fs.stat(fullPath);
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

/** Working-directory picker for agent chats: git roots under common folders. */
export async function listProjects(): Promise<ProjectInfo[]> {
  const home = homedir();
  const roots = [
    home,
    join(home, 'Projects'),
    join(home, 'projects'),
    join(home, 'Documents'),
    join(home, 'Desktop'),
    join(home, 'code'),
    join(home, 'dev'),
    join(home, 'src'),
    join(home, 'work'),
    '/mnt/shared',
    '/mnt/shared/projects',
    'D:\\projects',
    'C:\\projects',
  ];
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

  for (const root of roots) {
    if (!existsSync(root)) continue;
    await consider(root, basename(root));
    await walk(root, 2);
  }
  out.sort((a, b) => a.name.localeCompare(b.name));
  return out.slice(0, 40);
}

/** Parse `git status -sb --porcelain=v1` (first line is `## branch`). */
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
