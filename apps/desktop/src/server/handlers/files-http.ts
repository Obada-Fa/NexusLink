import { basename, dirname, join } from 'node:path';
import { promises as fs } from 'node:fs';
import { authorizeHttp, WorkspaceError } from '../workspace/security';
import { hostPath, withFileLock, invalidateDirectory } from '../workspace/files';
export async function handleFileDownload(url: URL, req = new Request(url)): Promise<Response> {
  try {
    const path = hostPath(url.searchParams.get('path') || ''); authorizeHttp(req, path);
    const info = await fs.stat(path);
    if (!info.isFile()) throw new WorkspaceError('INVALID_ARGUMENT', 'Not a regular file.');
    const etag = `"${info.dev}-${info.ino}-${info.size}-${info.mtimeMs}-${info.ctimeMs}"`;
    const headers = new Headers({ 'content-type': Bun.file(path).type || 'application/octet-stream', 'accept-ranges':'bytes', etag,
      'content-disposition': `attachment; filename*=UTF-8''${encodeURIComponent(basename(path))}`, 'content-length': String(info.size), 'cache-control':'private, no-store' });
    let start = 0, end = info.size - 1, status = 200;
    const range = req.headers.get('range');
    if (range) {
      const match = /^bytes=(\d*)-(\d*)$/.exec(range);
      if (!match || (!match[1] && !match[2])) return new Response(null, { status:416, headers:{'content-range':`bytes */${info.size}`} });
      const condition = req.headers.get('if-range') || req.headers.get('if-match');
      if (!condition || condition !== etag) return new Response('Remote file changed; restart the download.', { status:412 });
      start = match[1] ? Number(match[1]) : Math.max(0, info.size - Number(match[2]));
      end = match[1] && match[2] ? Math.min(Number(match[2]), end) : end;
      if (start > end || start >= info.size || start < 0) return new Response(null,{status:416,headers:{'content-range':`bytes */${info.size}`}});
      status=206; headers.set('content-range',`bytes ${start}-${end}/${info.size}`); headers.set('content-length',String(end-start+1));
    }
    return new Response(req.method === 'HEAD' ? null : Bun.file(path).slice(start, end+1), { status, headers });
  } catch (e) { return fileError(e); }
}
export async function handleFileUpload(url: URL, req: Request): Promise<Response> {
  let tmp: string | undefined;
  try {
    const path = hostPath(url.searchParams.get('path') || ''); authorizeHttp(req, path);
    if (!req.body) throw new WorkspaceError('INVALID_ARGUMENT','Empty upload.');
    return await withFileLock(path, async () => {
      let existing: import('node:fs').Stats | undefined;
      try { existing=await fs.lstat(path); } catch(e:any) { if(e.code!=='ENOENT') throw e; }
      if(existing && url.searchParams.get('overwrite')!=='1') return Response.json({error:'File exists',code:'EXISTS'},{status:409});
      if(existing && (!existing.isFile() || existing.isSymbolicLink() || existing.nlink>1)) throw new WorkspaceError('INVALID_ARGUMENT','Cannot replace this file type.');
      tmp=join(dirname(path),`.${basename(path)}.upload-${crypto.randomUUID()}`);
      const file=await fs.open(tmp,'wx',existing ? existing.mode & 0o777 : 0o644);
      const limit=Number(process.env.NEXUSLINK_MAX_UPLOAD_BYTES || 1024*1024*1024);
      let written=0;
      try {
        for await(const chunk of req.body as any) { written+=chunk.byteLength; if(written>limit) throw new WorkspaceError('TOO_LARGE','Upload exceeds the host limit.'); await file.writeFile(chunk); }
        await file.sync();
      } finally { await file.close(); }
      if(existing) {
        const current=await fs.lstat(path);
        if(current.ino!==existing.ino || current.mtimeMs!==existing.mtimeMs || current.size!==existing.size) throw new WorkspaceError('REVISION_CONFLICT','File changed during upload.');
        await fs.rename(tmp,path);
      } else { await fs.link(tmp,path); await fs.unlink(tmp); }
      invalidateDirectory(path);
      return Response.json({ok:true,bytes:written});
    });
  } catch(e) { return fileError(e); }
  finally { if(tmp) await fs.rm(tmp,{force:true}).catch(()=>{}); }
}
function fileError(e:any) {
  const code=e.code || 'IO_ERROR';
  const status=code==='UNAUTHENTICATED'?401:code==='ENOENT'?404:['EACCES','EPERM','PERMISSION_DENIED'].includes(code)?403:code==='REVISION_CONFLICT'?409:code==='TOO_LARGE'?413:code==='INVALID_ARGUMENT'?400:500;
  return Response.json({error:e.message || 'File transfer failed',code},{status});
}
