import { promises as fs } from 'node:fs';
import { basename, dirname, isAbsolute, join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { createHash } from 'node:crypto';
import { WorkspaceError } from './security';
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
      if (expectedRevision === null) { await fs.link(tmp, path); await fs.unlink(tmp); }
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
  const source = hostPath(from), target = hostPath(to);
  if (source === target) return { path: target };
  // File-only rename uses link/unlink for no-clobber semantics on Linux.
  const info = await fs.lstat(source);
  if (!info.isFile() || info.isSymbolicLink()) throw new WorkspaceError('UNSUPPORTED', 'Rename currently supports regular files only.');
  await fs.link(source, target); await fs.unlink(source); invalidateDirectory(source); invalidateDirectory(target); return { path: target };
}
export async function gitChanges(raw: string) {
  const cwd = hostPath(raw);
  const proc = Bun.spawn(['git', '-C', cwd, 'status', '--porcelain=v1', '-z', '--untracked-files=normal'], { stdout: 'pipe', stderr: 'pipe' });
  const [text, error, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
  if (code !== 0) throw new WorkspaceError('INVALID_ARGUMENT', error.trim() || 'Not a Git repository.');
  const root = Bun.spawn(['git','-C',cwd,'rev-parse','--show-toplevel'], { stdout:'pipe', stderr:'ignore' });
  const repository = (await new Response(root.stdout).text()).trim(); await root.exited;
  const parts = text.split('\0'); const files: any[] = [];
  for (let i=0; i<parts.length; i++) { const row = parts[i]; if (!row) continue; const status=row.slice(0,2), path=row.slice(3); const from = /[RC]/.test(status) ? parts[++i] : undefined; files.push({ path, absolutePath: join(repository,path), status, from, staged: status[0] !== ' ' && status[0] !== '?', unstaged: status[1] !== ' ', untracked: status === '??' }); }
  return { cwd: repository, files };
}
export async function gitDiff(raw: string, path: string, staged: boolean) {
  const cwd = hostPath(raw);
  const proc = Bun.spawn(['git','-C',cwd,'diff','--no-ext-diff','--no-textconv',...(staged ? ['--cached'] : []),'--',path], { stdout:'pipe', stderr:'pipe' });
  let text=''; let truncated=false;
  const decoder=new TextDecoder();
  const errors = new Response(proc.stderr).text();
  for await (const chunk of proc.stdout) { if (text.length < EDIT_BYTES) text += decoder.decode(chunk, { stream:true }); else { truncated=true; proc.kill(); break; } }
  const code = await proc.exited;
  if (code !== 0 && !truncated) throw new WorkspaceError('INVALID_ARGUMENT', (await errors).slice(0,1000));
  return { text: text.slice(0,EDIT_BYTES), truncated, binary: text.startsWith('Binary files ') || text.includes('\nBinary files ') };
}
