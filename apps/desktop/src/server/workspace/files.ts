import { promises as fs, constants as fsConstants, type Stats } from 'node:fs';
import { basename, dirname, isAbsolute, join, resolve, sep } from 'node:path';
import { homedir } from 'node:os';
import { createHash, randomBytes } from 'node:crypto';
import { WorkspaceError, dataDirectory } from './security';
export const EDIT_BYTES = 1024 * 1024;
export function hostPath(raw: string): string {
  if (!raw || raw.includes('\0')) throw new WorkspaceError('INVALID_ARGUMENT', 'A file path is required.');
  const p = raw === '~' ? homedir() : raw.startsWith('~/') ? join(homedir(), raw.slice(2)) : raw;
  if (!isAbsolute(p)) throw new WorkspaceError('INVALID_ARGUMENT', 'Use an absolute PC path.');
  return resolve(p);
}
const revision = (bytes: Uint8Array) => createHash('sha256').update(bytes).digest('hex');
const locks = new Map<string, Promise<unknown>>();
export async function withFileLock<T>(path: string, action: () => Promise<T>): Promise<T> {
  const previous = locks.get(path) || Promise.resolve();
  const current = previous.catch(() => {}).then(action);
  locks.set(path, current);
  try { return await current; } finally { if (locks.get(path) === current) locks.delete(path); }
}
export async function readText(raw: string) {
  const requested = hostPath(raw);
  const link = await fs.lstat(requested);
  const path = await fs.realpath(requested);
  const stat = await fs.stat(path);
  if (!stat.isFile()) throw new WorkspaceError('INVALID_ARGUMENT', 'This path is not a regular file.');
  const handle = await fs.open(path, 'r');
  let bytes: Buffer;
  try {
    const buffer = Buffer.alloc(Math.min(stat.size, EDIT_BYTES + 1));
    let offset = 0;
    while (offset < buffer.length) { const r = await handle.read(buffer, offset, buffer.length - offset, offset); if (!r.bytesRead) break; offset += r.bytesRead; }
    bytes = buffer.subarray(0, offset);
  } finally { await handle.close(); }
  const oversized = stat.size > EDIT_BYTES;
  let content = ''; let binary = bytes.includes(0);
  const bom = bytes.length >= 3 && bytes[0] === 239 && bytes[1] === 187 && bytes[2] === 191;
  try {
    const source=bom ? bytes.subarray(3) : bytes;
    try { content=new TextDecoder('utf-8',{fatal:true}).decode(source); }
    catch(error) {
      if(!oversized)throw error;
      let decoded=false;
      for(let trim=1;trim<=3 && trim<source.length;trim++) {
        try { content=new TextDecoder('utf-8',{fatal:true}).decode(source.subarray(0,source.length-trim));decoded=true;break; } catch {}
      }
      if(!decoded)throw error;
    }
  } catch { binary = true; }
  const crlf = (content.match(/\r\n/g) || []).length;
  const lf = (content.match(/(?<!\r)\n/g) || []).length;
  const mixed = (crlf > 0 && lf > 0) || /\r(?!\n)/.test(content);
  let writable = true;
  try { await fs.access(path, 2); } catch { writable = false; }
  const lines = content.split('\n').length;
  const reason = binary ? 'Binary or invalid UTF-8 file' : oversized || lines > 20000 ? 'File exceeds the editing limit' : mixed ? 'Mixed line endings' : link.isSymbolicLink() ? 'Open the resolved target to edit this symbolic link' : stat.nlink > 1 ? 'Hard-linked files are read-only' : !writable ? 'Permission denied' : null;
  return { path, requestedPath: requested, content: binary ? '' : content, bytes: stat.size,
    revision: oversized ? null : revision(bytes), modifiedAt: stat.mtime.toISOString(), bom,
    lineEnding: mixed ? 'mixed' : crlf ? 'crlf' : 'lf', writable: !reason, readOnlyReason: reason,
    truncated: oversized, binary, mode: stat.mode };
}
export async function writeText(raw: string, content: string, expectedRevision: string | null, bom = false) {
  const path = hostPath(raw);
  const bytes = Buffer.concat([bom ? Buffer.from([239,187,191]) : Buffer.alloc(0), Buffer.from(content)]);
  if (bytes.length > EDIT_BYTES || content.split('\n').length > 20000 || content.includes('\0')) throw new WorkspaceError('INVALID_ARGUMENT', 'File exceeds the text editing limits.');
  return withFileLock(path, async () => {
    let old: Awaited<ReturnType<typeof readText>> | undefined;
    try { old = await readText(path); } catch (e: any) { if (e.code !== 'ENOENT') throw e; }
    if ((old?.revision ?? null) !== expectedRevision) throw new WorkspaceError('REVISION_CONFLICT', 'The file changed on the PC. Compare or reload before saving.');
    if (old && !old.writable) throw new WorkspaceError('PERMISSION_DENIED', old.readOnlyReason!);
    const tmp = join(dirname(path), `.${basename(path)}.nexuslink-${crypto.randomUUID()}`);
    try {
      const file = await fs.open(tmp, 'wx', old ? old.mode & 0o777 : 0o644);
      try { await file.writeFile(bytes); await file.sync(); } finally { await file.close(); }
      let current: string | null = null;
      try { const st = await fs.lstat(path); if (st.isSymbolicLink() || st.nlink > 1) throw new WorkspaceError('REVISION_CONFLICT', 'File identity changed.'); current = revision(await fs.readFile(path)); } catch (e: any) { if (e.code !== 'ENOENT') throw e; }
      if (current !== expectedRevision) throw new WorkspaceError('REVISION_CONFLICT', 'The file changed while saving.');
      if (expectedRevision === null) await publishNoClobber(tmp, path);
      else await fs.rename(tmp, path);
      invalidateDirectory(path);
      return await readText(path);
    } finally { await fs.rm(tmp, { force: true }); }
  });
}
const directoryCache = new Map<string,{until:number;entries:any[]}>();
export function invalidateDirectory(raw:string) {
  const parent=dirname(hostPath(raw));
  for(const key of directoryCache.keys()) if(key.startsWith(`${parent}\0`)) directoryCache.delete(key);
}
export async function listPage(raw: string, options: { cursor?: string; limit?: number; hidden?: boolean; query?: string; sort?: string } = {}) {
  const path = await fs.realpath(hostPath(raw));
  const cacheKey=`${path}\0${options.hidden?'1':'0'}\0${options.query||''}\0${options.sort||'name'}`;
  let cached=directoryCache.get(cacheKey);
  if(!cached || cached.until<Date.now()) {
    const entries = (await fs.readdir(path, { withFileTypes: true })).filter(e => (options.hidden || !e.name.startsWith('.')) && (!options.query || e.name.toLowerCase().includes(options.query.toLowerCase())));
    const output: any[] = [];
    let index = 0;
    await Promise.all(Array.from({ length: Math.min(16, entries.length) }, async () => {
    while (index < entries.length) {
      const entry = entries[index++]; const full = join(path, entry.name);
      try { const st = await fs.stat(full); output.push({ name: entry.name, path: full, isDirectory: st.isDirectory(), isSymlink: entry.isSymbolicLink(), size: st.size, modifiedAt: st.mtime.toISOString(), mimeType: st.isDirectory() ? 'directory' : Bun.file(full).type }); }
      catch (e: any) { output.push({ name: entry.name, path: full, isDirectory: false, size: 0, modifiedAt: '', mimeType: '', error: e.code, isSymlink: entry.isSymbolicLink() }); }
    }
  }));
    output.sort((a,b) => Number(b.isDirectory) - Number(a.isDirectory) || (options.sort === 'date' ? b.modifiedAt.localeCompare(a.modifiedAt) : options.sort === 'size' ? b.size - a.size : a.name.localeCompare(b.name, undefined, { numeric: true })) || a.name.localeCompare(b.name));
    cached={until:Date.now()+3000,entries:output};
    directoryCache.set(cacheKey,cached);
    while(directoryCache.size>8)directoryCache.delete(directoryCache.keys().next().value!);
  }
  const output=cached.entries;
  const start = Number(options.cursor || 0); const limit = Math.min(200, Math.max(1, options.limit || 200));
  if (!Number.isInteger(start) || start < 0) throw new WorkspaceError('INVALID_ARGUMENT', 'Invalid directory cursor.');
  return { path, entries: output.slice(start, start + limit), nextCursor: start + limit < output.length ? String(start + limit) : null, total: output.length };
}
export async function renameFile(from: string, to: string) {
  // No-clobber, works for folders, link-free filesystems (FAT/exFAT) and across mounts.
  return moveEntry(from, to);
}

/** Link-free filesystems (FAT/exFAT, some FUSE/SMB mounts) report one of these for link(2). */
const LINK_UNSUPPORTED = new Set(['EPERM', 'ENOTSUP', 'EOPNOTSUPP', 'ENOSYS', 'EXDEV', 'EMLINK']);

/**
 * Move a finished temp file to `path` without ever replacing a file that
 * already exists there. Uses link+unlink where hard links work; otherwise
 * reserves the name with O_EXCL and renames over that empty placeholder; if
 * even rename is impossible (EXDEV), copies with COPYFILE_EXCL.
 */
export async function publishNoClobber(
  tmp: string,
  path: string,
  ops: { link?: typeof fs.link; rename?: typeof fs.rename; onExdev?: 'copy' | 'throw' } = {},
): Promise<void> {
  const link = ops.link ?? fs.link;
  const rename = ops.rename ?? fs.rename;
  try {
    await link(tmp, path);
    await fs.unlink(tmp);
    return;
  } catch (e: any) {
    if (e?.code === 'EEXIST') throw new WorkspaceError('EXISTS', 'File exists');
    if (e?.code === 'EXDEV' && ops.onExdev === 'throw') throw e;
    if (!LINK_UNSUPPORTED.has(e?.code)) throw e;
  }
  let placeholder: Stats;
  try {
    const handle = await fs.open(path, 'wx', 0o600);
    try { placeholder = await handle.stat(); } finally { await handle.close(); }
  } catch (e: any) {
    if (e?.code === 'EEXIST') throw new WorkspaceError('EXISTS', 'File exists');
    throw e;
  }
  try {
    await rename(tmp, path);
  } catch (e: any) {
    // Remove only our own still-empty placeholder, never someone else's file.
    try { const cur = await fs.lstat(path); if (cur.ino === placeholder.ino && cur.size === 0) await fs.unlink(path); } catch { /* gone */ }
    if (e?.code !== 'EXDEV' || ops.onExdev === 'throw') throw e;
    await fs.copyFile(tmp, path, fsConstants.COPYFILE_EXCL);
    await fs.unlink(tmp);
  }
}

/**
 * Paths the phone may never delete or move: /, top-level system folders,
 * $HOME and its ancestors, and NexusLink's own data directory (+ ancestors).
 */
export function assertMutablePath(path: string, action: 'delete' | 'move'): void {
  const p = resolve(path);
  const home = resolve(homedir());
  const data = resolve(dataDirectory());
  const isSameOrAncestor = (protectedPath: string) => protectedPath === p || protectedPath.startsWith(p.endsWith(sep) ? p : p + sep);
  const depth = p.split(sep).filter(Boolean).length;
  if (depth < 2 || isSameOrAncestor(home) || isSameOrAncestor(data)) {
    throw new WorkspaceError('PERMISSION_DENIED', `Refusing to ${action} ${p}: it is a protected folder.`);
  }
}

const tmpSibling = (target: string, tag: string) => join(dirname(target), `.${basename(target).slice(0, 48)}.${tag}-${randomBytes(6).toString('hex')}`);

/** Lock several paths in a stable order (no deadlock between opposite moves). */
async function withFileLocks<T>(paths: string[], action: () => Promise<T>): Promise<T> {
  const [first, ...rest] = [...new Set(paths)].sort();
  if (!first) return action();
  return withFileLock(first, () => withFileLocks(rest, action));
}

/** Rename a directory without replacing anything: claim the name with mkdir, then rename onto the empty placeholder. */
async function renameDirNoClobber(source: string, target: string): Promise<void> {
  try { await fs.mkdir(target); } catch (e: any) {
    if (e?.code === 'EEXIST') throw new WorkspaceError('EXISTS', 'A file or folder with that name already exists.');
    throw e;
  }
  try { await fs.rename(source, target); } catch (e) {
    await fs.rmdir(target).catch(() => {});
    throw e;
  }
}

/**
 * Move/rename a file, symlink or folder. Never overwrites the destination,
 * refuses protected paths and moving a folder into itself, and works across
 * filesystems (copy, verify, then remove the source).
 */
export async function moveEntry(from: string, to: string): Promise<{ path: string }> {
  const source = hostPath(from), target = hostPath(to);
  if (source === target) return { path: target };
  assertMutablePath(source, 'move');
  if (target.startsWith(source + sep)) throw new WorkspaceError('INVALID_ARGUMENT', 'Cannot move a folder into itself.');
  return withFileLocks([source, target], async () => {
    const info = await fs.lstat(source);
    try { await fs.lstat(target); throw new WorkspaceError('EXISTS', 'A file or folder with that name already exists.'); }
    catch (e: any) { if (e?.code !== 'ENOENT') throw e; }
    const targetDev = (await fs.stat(dirname(target))).dev;
    try {
      if (targetDev !== info.dev) throw Object.assign(new Error('cross-device move'), { code: 'EXDEV' });
      if (info.isDirectory()) await renameDirNoClobber(source, target);
      else await publishNoClobber(source, target, { onExdev: 'throw' });
    } catch (e: any) {
      // Bind mounts share st_dev but still refuse rename(2) with EXDEV.
      if (e?.code !== 'EXDEV') throw e;
      await copyAcrossFilesystems(source, target, info);
    }
    invalidateDirectory(source); invalidateDirectory(target);
    return { path: target };
  });
}

async function copyAcrossFilesystems(source: string, target: string, info: Stats): Promise<void> {
  const staging = tmpSibling(target, 'nlmove');
  try {
    if (info.isDirectory()) {
      await fs.cp(source, staging, { recursive: true, errorOnExist: true, force: false, preserveTimestamps: true, verbatimSymlinks: true });
      await renameDirNoClobber(staging, target);
    } else if (info.isSymbolicLink()) {
      await fs.symlink(await fs.readlink(source), staging);
      await publishNoClobber(staging, target);
    } else {
      await fs.copyFile(source, staging, fsConstants.COPYFILE_EXCL);
      await fs.chmod(staging, info.mode & 0o7777).catch(() => {});
      await fs.utimes(staging, info.atime, info.mtime).catch(() => {});
      await publishNoClobber(staging, target);
    }
  } catch (e) {
    await fs.rm(staging, { recursive: true, force: true }).catch(() => {});
    throw e;
  }
  // The copy is complete and published; only now remove the original.
  await fs.rm(source, { recursive: true, force: false });
}

type TrashRunner = (path: string) => Promise<boolean>;
const TRASH_TIMEOUT_MS = 15_000;

/** `gio trash` (freedesktop Trash, restorable from the file manager). False when unavailable/failed. */
const gioTrash: TrashRunner = async (path) => {
  if (!Bun.which('gio')) return false;
  try {
    const proc = Bun.spawn(['gio', 'trash', '--', path], { stdin: 'ignore', stdout: 'ignore', stderr: 'ignore' });
    const timer = setTimeout(() => { try { proc.kill('SIGKILL'); } catch { /* gone */ } }, TRASH_TIMEOUT_MS);
    try { return (await proc.exited) === 0; } finally { clearTimeout(timer); }
  } catch { return false; }
};
let trashRunner: TrashRunner = gioTrash;

/** Test hook: replace the trash implementation (null restores gio). */
export function setTrashRunnerForTests(fn: TrashRunner | null): void { trashRunner = fn ?? gioTrash; }

/**
 * Delete a file, symlink or folder from the phone. Prefers the desktop Trash
 * (recoverable). Without a usable Trash only files/symlinks and empty folders
 * are removed; a non-empty folder is never rm -rf'd. Folders with contents
 * need `recursive: true` even when trashing.
 */
export async function deleteEntry(raw: string, opts: { recursive?: boolean } = {}): Promise<{ ok: true; path: string; trashed: boolean }> {
  const path = hostPath(raw);
  assertMutablePath(path, 'delete');
  return withFileLock(path, async () => {
    const info = await fs.lstat(path);
    const isDir = info.isDirectory();
    if (isDir && !opts.recursive && (await fs.readdir(path)).length > 0) {
      throw new WorkspaceError('INVALID_ARGUMENT', 'Folder is not empty; confirm deleting it with its contents.');
    }
    let trashed = await trashRunner(path);
    if (trashed) {
      // gio can exit 0 without moving anything on odd mounts; verify.
      try { await fs.lstat(path); trashed = false; } catch (e: any) { if (e?.code !== 'ENOENT') throw e; }
    }
    if (!trashed) {
      if (!isDir) await fs.unlink(path);
      else {
        try { await fs.rmdir(path); } catch (e: any) {
          if (e?.code === 'ENOTEMPTY' || e?.code === 'EEXIST') throw new WorkspaceError('UNSUPPORTED', 'This folder cannot be moved to the Trash here; delete it on the PC.');
          throw e;
        }
      }
    }
    invalidateDirectory(path);
    return { ok: true as const, path, trashed };
  });
}

const GIT_TIMEOUT_MS = 15_000;
/** Read-only git: never take index.lock (would break the user's own git commands) or prompt. */
const gitEnv = () => ({ ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_TERMINAL_PROMPT: '0' });
export async function gitChanges(raw: string) {
  const cwd = hostPath(raw);
  const proc = Bun.spawn(['git', '-C', cwd, 'status', '--porcelain=v1', '-z', '--untracked-files=normal'], { stdout: 'pipe', stderr: 'pipe', env: gitEnv() });
  const timer = setTimeout(() => { try { proc.kill('SIGKILL'); } catch { /* gone */ } }, GIT_TIMEOUT_MS);
  let text: string, error: string, code: number;
  try { [text, error, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]); }
  finally { clearTimeout(timer); }
  if (code !== 0) throw new WorkspaceError('INVALID_ARGUMENT', error.trim() || 'Not a Git repository.');
  const root = Bun.spawn(['git','-C',cwd,'rev-parse','--show-toplevel'], { stdout:'pipe', stderr:'ignore', env: gitEnv() });
  const repository = (await new Response(root.stdout).text()).trim(); await root.exited;
  const parts = text.split('\0'); const files: any[] = [];
  for (let i=0; i<parts.length; i++) { const row = parts[i]; if (!row) continue; const status=row.slice(0,2), path=row.slice(3); const from = /[RC]/.test(status) ? parts[++i] : undefined; files.push({ path, absolutePath: join(repository,path), status, from, staged: status[0] !== ' ' && status[0] !== '?', unstaged: status[1] !== ' ', untracked: status === '??' }); }
  return { cwd: repository, files };
}
export async function gitDiff(raw: string, path: string, staged: boolean) {
  const cwd = hostPath(raw);
  const proc = Bun.spawn(['git','-C',cwd,'diff','--no-ext-diff','--no-textconv',...(staged ? ['--cached'] : []),'--',path], { stdout:'pipe', stderr:'pipe', env: gitEnv() });
  const timer = setTimeout(() => { try { proc.kill('SIGKILL'); } catch { /* gone */ } }, GIT_TIMEOUT_MS);
  let text=''; let truncated=false;
  const decoder=new TextDecoder();
  const errors = new Response(proc.stderr).text();
  for await (const chunk of proc.stdout) { if (text.length < EDIT_BYTES) text += decoder.decode(chunk, { stream:true }); else { truncated=true; proc.kill(); break; } }
  const code = await proc.exited;
  clearTimeout(timer);
  if (code !== 0 && !truncated) throw new WorkspaceError('INVALID_ARGUMENT', (await errors).slice(0,1000));
  return { text: text.slice(0,EDIT_BYTES), truncated, binary: text.startsWith('Binary files ') || text.includes('\nBinary files ') };
}
