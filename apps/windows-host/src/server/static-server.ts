import { existsSync } from 'fs';
import { dirname, join, resolve, extname } from 'path';

function resolveStaticDir(): string {
  if (process.env.NEXUSLINK_STATIC_DIR) return process.env.NEXUSLINK_STATIC_DIR;
  const candidates = [
    join(dirname(process.execPath), 'www'),
    resolve(import.meta.dir, '../../../mobile-client/out'),
  ];
  for (const dir of candidates) {
    if (existsSync(join(dir, 'index.html'))) return dir;
  }
  return candidates[0]!;
}

const STATIC_DIR = resolveStaticDir();

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

function sanitize(pathname: string): string {
  const noQuery = pathname.split('?')[0]!.split('#')[0]!;
  return noQuery.replace(/\.\.+/g, '.').replace(/\/{2,}/g, '/');
}

function cacheHeaders(pathname: string): HeadersInit {
  return pathname.startsWith('/_next/static/')
    ? { 'Cache-Control': 'public, max-age=31536000, immutable' }
    : { 'Cache-Control': 'no-cache' };
}

export async function serveStatic(pathname: string): Promise<Response | null> {
  if (!(await staticAvailable())) return null;

  const clean = sanitize(pathname);
  const rel = clean === '/' ? 'index.html' : clean.replace(/^\//, '');
  const headers = cacheHeaders(clean);

  const candidates =
    clean === '/'
      ? ['index.html']
      : [rel, `${rel}.html`, join(rel, 'index.html')];

  for (const c of candidates) {
    const full = join(STATIC_DIR, c);
    const file = Bun.file(full);
    if (await file.exists()) {
      return new Response(file as unknown as BodyInit, { headers });
    }
  }

  if (extname(clean) === '') {
    const shell = Bun.file(join(STATIC_DIR, 'index.html'));
    if (await shell.exists()) {
      return new Response(shell as unknown as BodyInit, { headers: cacheHeaders('/') });
    }
  }
  return new Response('Not found', { status: 404 });
}
