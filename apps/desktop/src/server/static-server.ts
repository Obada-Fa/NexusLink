// Serves the exported mobile PWA (apps/mobile-client/out) from the same Bun server
// that hosts the RPC WebSocket — so the whole app lives on one port / one origin.
// If the export hasn't been built, everything here is a no-op and the two-server
// dev flow (separate `next dev`) still works via origin-derived auto-connect.

import { join, resolve, extname } from 'path';

const STATIC_DIR =
  process.env.NEXUSLINK_STATIC_DIR || resolve(import.meta.dir, '../../../mobile-client/out');

let available: boolean | null = null;

export function staticDir(): string {
  return STATIC_DIR;
}

export async function staticAvailable(): Promise<boolean> {
  if (available === null) {
    available = await Bun.file(join(STATIC_DIR, 'index.html')).exists();
  }
  return available;
}

/** Strip query/hash and collapse any `..` segments to prevent path traversal. */
function sanitize(pathname: string): string {
  const noQuery = pathname.split('?')[0]!.split('#')[0]!;
  return noQuery.replace(/\.\.+/g, '.').replace(/\/{2,}/g, '/');
}

/**
 * Resolve a request path to a Response backed by a file in the export, or null if
 * this request should not be handled statically. Non-asset misses fall back to
 * index.html so client-side routes (/mirror, /files, …) deep-link correctly.
 */
export async function serveStatic(pathname: string): Promise<Response | null> {
  if (!(await staticAvailable())) return null;

  const clean = sanitize(pathname);
  const rel = clean === '/' ? 'index.html' : clean.replace(/^\//, '');

  const candidates =
    clean === '/'
      ? ['index.html']
      : [rel, `${rel}.html`, join(rel, 'index.html')];

  for (const c of candidates) {
    const full = join(STATIC_DIR, c);
    const file = Bun.file(full);
    if (await file.exists()) {
      return new Response(file as unknown as BodyInit);
    }
  }

  // SPA fallback: extension-less misses (routes) serve the shell; asset misses 404.
  if (extname(clean) === '') {
    const shell = Bun.file(join(STATIC_DIR, 'index.html'));
    if (await shell.exists()) return new Response(shell as unknown as BodyInit);
  }
  return new Response('Not found', { status: 404 });
}
