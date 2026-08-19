import { basename, dirname, isAbsolute, normalize } from 'path';
import { mkdir, stat } from 'node:fs/promises';
import { expandHostPath, isThisPcPath } from './handlers/fs';

function badRequest(msg: string): Response {
  return new Response(JSON.stringify({ error: msg }), {
    status: 400,
    headers: { 'content-type': 'application/json' },
  });
}

function sanePath(raw: string | null): string | null {
  if (!raw) return null;
  if (isThisPcPath(raw)) return null;
  try {
    const expanded = expandHostPath(raw);
    const p = normalize(expanded);
    if (!isAbsolute(p)) return null;
    return p;
  } catch {
    return null;
  }
}

export async function handleFileDownload(url: URL): Promise<Response> {
  const path = sanePath(url.searchParams.get('path'));
  if (!path) return badRequest('missing or unsafe path');

  try {
    const info = await stat(path);
    if (info.isDirectory()) return badRequest('path is a directory');
    const file = Bun.file(path);
    return new Response(file as unknown as BodyInit, {
      headers: {
        'content-length': String(info.size),
        'content-type': file.type || 'application/octet-stream',
        'content-disposition': `attachment; filename="${encodeURIComponent(basename(path))}"`,
      },
    });
  } catch {
    return new Response(JSON.stringify({ error: 'not found' }), {
      status: 404,
      headers: { 'content-type': 'application/json' },
    });
  }
}

export async function handleFileUpload(url: URL, req: Request): Promise<Response> {
  const path = sanePath(url.searchParams.get('path'));
  if (!path) return badRequest('missing or unsafe path');
  if (!req.body) return badRequest('empty body');

  try {
    await mkdir(dirname(path), { recursive: true });
    if (url.searchParams.get('overwrite') !== '1') {
      if (await Bun.file(path).exists()) {
        return new Response(JSON.stringify({ error: 'exists' }), {
          status: 409,
          headers: { 'content-type': 'application/json' },
        });
      }
    }
    const body = await req.arrayBuffer();
    const written = await Bun.write(path, body);
    return new Response(JSON.stringify({ ok: true, bytes: written }), {
      headers: { 'content-type': 'application/json' },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { 'content-type': 'application/json' },
    });
  }
}
