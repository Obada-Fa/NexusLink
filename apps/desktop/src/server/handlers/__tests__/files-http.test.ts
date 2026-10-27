// HTTP file transfer edge cases: plain Range requests, conditional ranges,
// early 413/507 rejections and the no-clobber publish on link-free filesystems.
import { afterAll, describe, expect, test } from 'bun:test';
import { mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { enableEnrollment, enroll } from '../../workspace/security';
import { handleFileDownload, handleFileUpload, planRange, publishNoClobber } from '../files-http';

const directory = await mkdtemp(join(tmpdir(), 'nexuslink-files-http-'));
afterAll(() => rm(directory, { recursive: true, force: true }));
const auth = () => ({ authorization: `Bearer ${enroll(enableEnrollment(), 'files-http test').token}` });
const fileUrl = (path: string, extra: Record<string, string> = {}) => {
  const url = new URL('http://localhost/files');
  url.searchParams.set('path', path);
  for (const [k, v] of Object.entries(extra)) url.searchParams.set(k, v);
  return url;
};
const linkUnsupported = async () => { throw Object.assign(new Error('Operation not permitted'), { code: 'EPERM' }); };

describe('download ranges', () => {
  test('a plain Range request (no If-Range/If-Match) gets 206', async () => {
    const path = join(directory, 'plain.txt');
    await writeFile(path, '0123456789');
    const url = fileUrl(path);
    const res = await handleFileDownload(url, new Request(url, { headers: { ...auth(), range: 'bytes=3-6' } }));
    expect(res.status).toBe(206);
    expect(res.headers.get('content-range')).toBe('bytes 3-6/10');
    expect(res.headers.get('content-length')).toBe('4');
    expect(await res.text()).toBe('3456');
    const suffix = await handleFileDownload(url, new Request(url, { headers: { ...auth(), range: 'bytes=-3' } }));
    expect(suffix.status).toBe(206);
    expect(await suffix.text()).toBe('789');
  });

  test('planRange follows RFC 9110 conditional and edge semantics', () => {
    const etag = '"1-2-10-3-4"';
    const lm = 'Tue, 20 Oct 2026 10:00:00 GMT';
    const h = (o: Record<string, string>) => new Headers(o);
    expect(planRange(h({ range: 'bytes=0-' }), 10, etag, lm)).toEqual({ status: 206, start: 0, end: 9 });
    expect(planRange(h({ range: 'bytes=2-', 'if-range': etag }), 10, etag, lm).status).toBe(206);
    expect(planRange(h({ range: 'bytes=2-', 'if-range': '"other"' }), 10, etag, lm).status).toBe(200);
    expect(planRange(h({ range: 'bytes=2-', 'if-range': lm }), 10, etag, lm).status).toBe(206);
    expect(planRange(h({ range: 'bytes=2-', 'if-match': '"other"' }), 10, etag, lm).status).toBe(412);
    expect(planRange(h({ range: 'bytes=2-', 'if-match': `"x", ${etag}` }), 10, etag, lm).status).toBe(206);
    expect(planRange(h({ range: 'bytes=0-1,4-5' }), 10, etag, lm).status).toBe(200);
    expect(planRange(h({ range: 'bytes=10-' }), 10, etag, lm).status).toBe(416);
    expect(planRange(h({ range: 'bytes=-0' }), 10, etag, lm).status).toBe(416);
    expect(planRange(h({ range: 'items=1-2' }), 10, etag, lm).status).toBe(416);
  });
});

describe('uploads', () => {
  test('rejects an oversized Content-Length with 413 before touching the disk', async () => {
    const path = join(directory, 'too-big.bin');
    const url = fileUrl(path);
    const previous = process.env.NEXUSLINK_MAX_UPLOAD_BYTES;
    process.env.NEXUSLINK_MAX_UPLOAD_BYTES = '8';
    try {
      const res = await handleFileUpload(url, new Request(url, { method: 'POST', headers: { ...auth(), 'content-length': '64' }, body: 'x'.repeat(64) }));
      expect(res.status).toBe(413);
      expect((await res.json()).code).toBe('TOO_LARGE');
      expect((await readdir(directory)).some((n) => n.includes('too-big'))).toBe(false);
    } finally {
      if (previous === undefined) delete process.env.NEXUSLINK_MAX_UPLOAD_BYTES;
      else process.env.NEXUSLINK_MAX_UPLOAD_BYTES = previous;
    }
  });

  test('rejects an upload larger than the free space with 507', async () => {
    const path = join(directory, 'no-space.bin');
    const url = fileUrl(path);
    const previous = process.env.NEXUSLINK_MAX_UPLOAD_BYTES;
    process.env.NEXUSLINK_MAX_UPLOAD_BYTES = String(Number.MAX_SAFE_INTEGER);
    try {
      const res = await handleFileUpload(url, new Request(url, { method: 'POST', headers: { ...auth(), 'content-length': String(2 ** 52) }, body: 'tiny' }));
      expect(res.status).toBe(507);
      expect((await res.json()).code).toBe('NO_SPACE');
    } finally {
      if (previous === undefined) delete process.env.NEXUSLINK_MAX_UPLOAD_BYTES;
      else process.env.NEXUSLINK_MAX_UPLOAD_BYTES = previous;
    }
  });

  test('long file names upload (temp name stays under NAME_MAX)', async () => {
    const path = join(directory, `${'n'.repeat(240)}.txt`);
    const url = fileUrl(path);
    const res = await handleFileUpload(url, new Request(url, { method: 'POST', headers: auth(), body: 'long' }));
    expect(res.status).toBe(200);
    expect(await readFile(path, 'utf8')).toBe('long');
  });
});

describe('publishNoClobber on link-free filesystems (FAT/exFAT)', () => {
  test('falls back to reserve-then-rename when link() is unsupported', async () => {
    const tmp = join(directory, '.fat.tmp');
    const target = join(directory, 'fat-target.txt');
    await writeFile(tmp, 'payload');
    await publishNoClobber(tmp, target, { link: linkUnsupported as any });
    expect(await readFile(target, 'utf8')).toBe('payload');
    expect((await readdir(directory)).includes('.fat.tmp')).toBe(false);
  });

  test('never replaces an existing file, even on the fallback path', async () => {
    const tmp = join(directory, '.fat2.tmp');
    const target = join(directory, 'fat-existing.txt');
    await writeFile(tmp, 'new');
    await writeFile(target, 'original');
    await expect(publishNoClobber(tmp, target, { link: linkUnsupported as any })).rejects.toMatchObject({ code: 'EXISTS' });
    await expect(publishNoClobber(tmp, target)).rejects.toMatchObject({ code: 'EXISTS' });
    expect(await readFile(target, 'utf8')).toBe('original');
  });

  test('copies (exclusively) when even rename crosses filesystems', async () => {
    const tmp = join(directory, '.xdev.tmp');
    const target = join(directory, 'xdev-target.txt');
    await writeFile(tmp, 'copied');
    const exdev = async () => { throw Object.assign(new Error('cross-device'), { code: 'EXDEV' }); };
    await publishNoClobber(tmp, target, { link: exdev as any, rename: exdev as any });
    expect(await readFile(target, 'utf8')).toBe('copied');
    expect((await readdir(directory)).includes('.xdev.tmp')).toBe(false);
  });

  test('an upload over HTTP still returns 409 when the target exists', async () => {
    const path = join(directory, 'exists.txt');
    await writeFile(path, 'keep');
    const url = fileUrl(path);
    const res = await handleFileUpload(url, new Request(url, { method: 'POST', headers: auth(), body: 'replace' }));
    expect(res.status).toBe(409);
    expect(await readFile(path, 'utf8')).toBe('keep');
  });
});
