import { basename, dirname, join } from 'node:path';
import { promises as fs } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { authorizeHttp, WorkspaceError } from '../workspace/security';
import { hostPath, withFileLock, invalidateDirectory, publishNoClobber } from '../workspace/files';

export { publishNoClobber };

/** Free space an upload must leave on the target filesystem. */
const UPLOAD_RESERVE_BYTES = 64 * 1024 * 1024;
const uploadLimit = () => Number(process.env.NEXUSLINK_MAX_UPLOAD_BYTES || 1024 * 1024 * 1024);

/** RFC 9110 strong comparison against a comma-separated entity-tag list (or "*"). */
export function etagListMatches(header: string, etag: string): boolean {
  return header.split(',').map((t) => t.trim()).some((t) => t === '*' || (!t.startsWith('W/') && t === etag));
}

/**
 * Decide how to answer a Range request (RFC 9110 §13-14):
 * - If-Match that does not match → 412 (Android DownloadManager resumes with it).
 * - If-Range that does not match → ignore Range, send the full file (200).
 * - Plain Range → 206. Multi-range is ignored (200); malformed/unsatisfiable → 416.
 */
export function planRange(
  headers: Headers,
  size: number,
  etag: string,
  lastModified: string,
): { status: 200 | 206 | 412 | 416; start: number; end: number } {
  const full = { status: 200 as const, start: 0, end: size - 1 };
  const ifMatch = headers.get('if-match');
  if (ifMatch && !etagListMatches(ifMatch, etag)) return { status: 412, start: 0, end: -1 };
  const range = headers.get('range');
  if (!range) return full;
  const ifRange = headers.get('if-range')?.trim();
  if (ifRange) {
    const fresh = ifRange.startsWith('"') || ifRange.startsWith('W/') ? ifRange === etag : ifRange === lastModified;
    if (!fresh) return full;
  }
  if (/^bytes=[^,]*,/.test(range)) return full;
  const match = /^bytes=(\d*)-(\d*)$/.exec(range.trim());
  if (!match || (!match[1] && !match[2])) return { status: 416, start: 0, end: -1 };
  let start: number;
  let end = size - 1;
  if (match[1]) {
    start = Number(match[1]);
    if (match[2]) end = Math.min(Number(match[2]), size - 1);
  } else {
    // bytes=-N is the last N bytes; bytes=-0 is unsatisfiable.
    start = Number(match[2]) === 0 ? size : Math.max(0, size - Number(match[2]));
  }
  if (!Number.isSafeInteger(start) || start > end || start >= size || start < 0) return { status: 416, start: 0, end: -1 };
  return { status: 206, start, end };
}

export async function handleFileDownload(url: URL, req = new Request(url)): Promise<Response> {
  try {
    const path = hostPath(url.searchParams.get('path') || ''); authorizeHttp(req, path);
    const info = await fs.stat(path);
    if (!info.isFile()) throw new WorkspaceError('INVALID_ARGUMENT', 'Not a regular file.');
    const etag = `"${info.dev}-${info.ino}-${info.size}-${info.mtimeMs}-${info.ctimeMs}"`;
    const lastModified = info.mtime.toUTCString();
    const headers = new Headers({ 'content-type': Bun.file(path).type || 'application/octet-stream', 'accept-ranges':'bytes', etag,
      'last-modified': lastModified,
      'content-disposition': `attachment; filename*=UTF-8''${encodeURIComponent(basename(path))}`, 'content-length': String(info.size), 'cache-control':'private, no-store' });
    const plan = planRange(req.headers, info.size, etag, lastModified);
    if (plan.status === 412) return new Response('Remote file changed; restart the download.', { status: 412, headers: { etag } });
    if (plan.status === 416) return new Response(null, { status: 416, headers: { 'content-range': `bytes */${info.size}` } });
    if (plan.status === 206) {
      headers.set('content-range', `bytes ${plan.start}-${plan.end}/${info.size}`);
      headers.set('content-length', String(plan.end - plan.start + 1));
    }
    const body = req.method === 'HEAD' ? null : plan.status === 206 ? Bun.file(path).slice(plan.start, plan.end + 1) : Bun.file(path);
    return new Response(body, { status: plan.status, headers });
  } catch (e) { return fileError(e); }
}

/** Bytes an upload may use on the filesystem holding `dir` (free space minus a safety reserve). */
export async function uploadBudget(dir: string): Promise<number> {
  try {
    const s = await fs.statfs(dir);
    return Number(s.bavail) * Number(s.bsize) - UPLOAD_RESERVE_BYTES;
  } catch {
    return Number.POSITIVE_INFINITY; // statfs unsupported: rely on ENOSPC
  }
}

export async function handleFileUpload(url: URL, req: Request): Promise<Response> {
  let tmp: string | undefined;
  try {
    const path = hostPath(url.searchParams.get('path') || ''); authorizeHttp(req, path);
    if (!req.body) throw new WorkspaceError('INVALID_ARGUMENT','Empty upload.');
    const limit = uploadLimit();
    const declaredRaw = req.headers.get('content-length');
    const declared = declaredRaw !== null && /^\d+$/.test(declaredRaw) ? Number(declaredRaw) : undefined;
    // Refuse before reading a byte: no temp file, no lock, no wasted transfer.
    if (declared !== undefined && declared > limit) throw new WorkspaceError('TOO_LARGE', 'Upload exceeds the host limit.');
    let budget = await uploadBudget(dirname(path));
    if (declared !== undefined && declared > budget) throw new WorkspaceError('NO_SPACE', 'Not enough free space on the PC for this upload.');
    return await withFileLock(path, async () => {
      let existing: import('node:fs').Stats | undefined;
      try { existing=await fs.lstat(path); } catch(e:any) { if(e.code!=='ENOENT') throw e; }
      if(existing && url.searchParams.get('overwrite')!=='1') return Response.json({error:'File exists',code:'EXISTS'},{status:409});
      if(existing && (!existing.isFile() || existing.isSymbolicLink() || existing.nlink>1)) throw new WorkspaceError('INVALID_ARGUMENT','Cannot replace this file type.');
      // Short temp name: `.<long name>.upload-<uuid>` overflowed NAME_MAX for long file names.
      tmp=join(dirname(path),`.${basename(path).slice(0, 48)}.nlup-${randomBytes(6).toString('hex')}`);
      const file=await fs.open(tmp,'wx',existing ? existing.mode & 0o777 : 0o644);
      budget = await uploadBudget(dirname(path));
      let written=0;
      try {
        for await(const chunk of req.body as any) {
          written+=chunk.byteLength;
          if(written>limit) throw new WorkspaceError('TOO_LARGE','Upload exceeds the host limit.');
          if(written>budget) throw new WorkspaceError('NO_SPACE','Not enough free space on the PC for this upload.');
          await file.writeFile(chunk);
        }
        await file.sync();
      } finally { await file.close(); }
      if(existing) {
        const current=await fs.lstat(path);
        if(current.ino!==existing.ino || current.mtimeMs!==existing.mtimeMs || current.size!==existing.size) throw new WorkspaceError('REVISION_CONFLICT','File changed during upload.');
        await fs.rename(tmp,path);
      } else await publishNoClobber(tmp, path);
      tmp = undefined;
      invalidateDirectory(path);
      return Response.json({ok:true,bytes:written});
    });
  } catch(e) { return fileError(e); }
  finally { if(tmp) await fs.rm(tmp,{force:true}).catch(()=>{}); }
}
function fileError(e:any) {
  const code=e.code || 'IO_ERROR';
  const status=code==='UNAUTHENTICATED'?401:code==='ENOENT'?404:['EACCES','EPERM','PERMISSION_DENIED'].includes(code)?403:['REVISION_CONFLICT','EXISTS','EEXIST'].includes(code)?409:code==='TOO_LARGE'?413:['NO_SPACE','ENOSPC','EDQUOT'].includes(code)?507:['INVALID_ARGUMENT','ENAMETOOLONG','EISDIR','ENOTDIR'].includes(code)?400:500;
  return Response.json({error:e.message || 'File transfer failed',code},{status});
}
