import type { FileEntry, ProjectInfo } from '@nexuslink/rpc-types';
import fs from 'fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { existsSync } from 'node:fs';

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
  return out.sort((a, b) => (a.isDirectory === b.isDirectory ? 0 : a.isDirectory ? -1 : 1));
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
  const seen = new Set<string>();
  const out: ProjectInfo[] = [];

  async function consider(dir: string, name: string): Promise<void> {
    if (seen.has(dir) || !existsSync(join(dir, '.git'))) return;
    seen.add(dir);
    out.push({ name, path: dir });
  }

  await consider(home, 'Home');
  for (const root of roots) {
    if (!existsSync(root)) continue;
    let entries: string[] = [];
    try {
      entries = await fs.readdir(root);
    } catch {
      continue;
    }
    for (const name of entries) {
      if (name.startsWith('.')) continue;
      await consider(join(root, name), name);
    }
  }
  out.sort((a, b) => a.name.localeCompare(b.name));
  return out.slice(0, 40);
}
