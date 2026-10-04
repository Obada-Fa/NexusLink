import { createHash } from 'node:crypto';
import { realpathSync } from 'node:fs';
import { posix, win32 } from 'node:path';

export const identity = (...parts: string[]) => createHash('sha256').update(JSON.stringify(parts)).digest('hex');
export function folderIdentity(recorded: string | undefined, platform = process.platform): { id: string | null; path: string | null; name: string } {
  if (!recorded?.trim() || recorded.includes('\0')) return { id: null, path: null, name: 'No folder' };
  const paths = platform === 'win32' ? win32 : posix;
  if (!paths.isAbsolute(recorded)) return { id: null, path: null, name: 'No folder' };
  let path = paths.normalize(recorded);
  try { path = realpathSync.native(path); } catch { /* Preserve missing recorded folders. */ }
  if (path !== paths.parse(path).root) path = path.replace(/[\\/]$/, '');
  return { id: identity('folder', platform === 'win32' ? path.toLowerCase() : path), path, name: paths.basename(path) || path };
}
