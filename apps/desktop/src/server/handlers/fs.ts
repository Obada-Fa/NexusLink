import type { FileEntry, GitWorkingTree, ProjectInfo } from '@nexuslink/rpc-types';
import fs from 'fs/promises';
import { homedir } from 'node:os';
import { basename, join } from 'node:path';
import { existsSync, realpathSync, statSync } from 'node:fs';

export async function handleFsList(path: string, showHidden = false): Promise<FileEntry[]> {
  const entries = await fs.readdir(path, { withFileTypes: true, recursive: false });
  const out: FileEntry[] = [];
  for (const entry of entries) {
    const name = entry.name;
    if (!showHidden && name.startsWith('.')) continue;
    const fullPath = `${path.replace(/\/$/, '')}/${name}`;
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

function canonicalDir(dir: string): string {
  try {
    return realpathSync(dir);
  } catch {
    return dir;
  }
}

/** Working-directory picker for agent chats: git roots under common folders. */
export async function listProjects(): Promise<ProjectInfo[]> {
  const home = homedir();
  const roots = [
    home,
    join(home, 'Projects'),
    join(home, 'projects'),
    join(home, 'code'),
    join(home, 'dev'),
    join(home, 'src'),
    join(home, 'work'),
  ];
  const skip = new Set(['node_modules', 'dist', 'out', 'build', 'target']);
  const seen = new Set<string>();
  const out: ProjectInfo[] = [];

  async function consider(dir: string, name: string): Promise<void> {
    const real = canonicalDir(dir);
    if (seen.has(real) || !existsSync(join(dir, '.git'))) return;
    seen.add(real);
    out.push({ name, path: real });
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
  const dir = cwd.trim();
  if (!dir || !existsSync(dir)) return null;
  try {
    const proc = Bun.spawnSync(['git', '-C', dir, 'status', '-sb', '--porcelain=v1'], {
      stdout: 'pipe',
      stderr: 'pipe',
      timeout: 4000,
    });
    if (proc.exitCode !== 0) return null;
    const text = new TextDecoder().decode(proc.stdout ?? new Uint8Array());
    const parsed = parseGitStatusPorcelain(text);
    if (!parsed) return null;
    return { cwd: dir, ...parsed };
  } catch {
    return null;
  }
}
