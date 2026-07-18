// HTTP file transfer endpoints for the mobile clients. Large transfers do not
// belong on the RPC WebSocket (head-of-line blocking against input events), so
// download/upload run over plain HTTP with streaming and Content-Length —
// which also gives the Flutter client progress reporting for free.
//
// Auth note: LAN trust level matches the WS RPC surface today; the M3 pairing
// token becomes a required query param here when Module D lands.

import { normalize, isAbsolute, basename, dirname } from 'path';
import { stat, mkdir } from 'node:fs/promises';

function badRequest(msg: string): Response {
  return new Response(JSON.stringify({ error: msg }), {
    status: 400,
    headers: { 'content-type': 'application/json' },
  });
}

/** Reject relative paths and any traversal remnants after normalization. */
function sanePath(raw: string | null): string | null {
  if (!raw) return null;
  const p = normalize(raw);
  if (!isAbsolute(p) || p.includes('..')) return null;
  return p;
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
    // Never silently clobber: caller must pass overwrite=1 to replace a file.
    if (url.searchParams.get('overwrite') !== '1') {
      if (await Bun.file(path).exists()) {
        return new Response(JSON.stringify({ error: 'exists' }), {
          status: 409,
          headers: { 'content-type': 'application/json' },
        });
      }
    }
    // Buffer the body before writing — Bun.write from a live request stream
    // stalls (observed on Bun 1.3.14), and phone-sized uploads fit in memory.
    // Revisit with chunked writes if multi-GB uploads become a use case.
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
