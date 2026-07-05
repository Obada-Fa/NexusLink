import type { FileEntry } from '@nexuslink/rpc-types';
import fs from 'fs/promises';

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
