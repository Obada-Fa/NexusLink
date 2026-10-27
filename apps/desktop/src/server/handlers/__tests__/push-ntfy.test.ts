// ntfy pushes with non-ASCII titles ("…", emoji) used to throw inside fetch()
// (invalid header value) and were silently lost.
import { afterAll, describe, expect, test } from 'bun:test';
import { ntfyHeaderRequest, ntfyJsonRequest, ntfyTopicUrl, rfc2047, sendNtfyPushForTests, type PushTokenRecord } from '../push';

const seen: Array<{ path: string; title: string | null; type: string | null; body: string }> = [];
let rejectJson = false;
const server = Bun.serve({
  hostname: '127.0.0.1',
  port: 0,
  async fetch(req) {
    const url = new URL(req.url);
    const body = await req.text();
    seen.push({ path: url.pathname + url.search, title: req.headers.get('title'), type: req.headers.get('content-type'), body });
    if (rejectJson && req.headers.get('content-type')?.includes('json')) return new Response('nope', { status: 404 });
    return Response.json({ id: 'x' });
  },
});
afterAll(() => server.stop(true));
const record = (endpoint: string): PushTokenRecord => ({ token: 't', provider: 'ntfy', endpoint, createdAt: 0, lastSeenAt: 0 });
const payload = { title: 'Codex finished “refactor” … ✓', body: 'Résumé ready' };

describe('ntfy publishing', () => {
  test('publishes a non-ASCII title as UTF-8 JSON to the server root', async () => {
    seen.length = 0;
    rejectJson = false;
    const ok = await sendNtfyPushForTests(record(`http://127.0.0.1:${server.port}/base/my-topic?auth=abc`), payload, fetch);
    expect(ok).toBe(true);
    expect(seen).toHaveLength(1);
    expect(seen[0]!.path).toBe('/base/?auth=abc');
    const json = JSON.parse(seen[0]!.body);
    expect(json).toMatchObject({ topic: 'my-topic', title: payload.title, message: payload.body });
  });

  test('falls back to header publishing with an RFC 2047 title', async () => {
    seen.length = 0;
    rejectJson = true;
    const ok = await sendNtfyPushForTests(record(`http://127.0.0.1:${server.port}/my-topic`), payload, fetch);
    expect(ok).toBe(true);
    expect(seen).toHaveLength(2);
    expect(seen[1]!.path).toBe('/my-topic');
    expect(seen[1]!.title).toBe(rfc2047(payload.title));
    const b64 = seen[1]!.title!.match(/^=\?UTF-8\?B\?(.+)\?=$/)![1]!;
    expect(Buffer.from(b64, 'base64').toString('utf8')).toBe(payload.title);
    expect(seen[1]!.body).toBe(payload.body);
  });

  test('request builders', () => {
    expect(rfc2047('plain ascii')).toBe('plain ascii');
    expect(ntfyTopicUrl({ token: 'abc def' })).toBe('https://ntfy.sh/abc%20def');
    expect(ntfyJsonRequest('https://ntfy.sh/abc%20def', payload)!.url).toBe('https://ntfy.sh/');
    expect(JSON.parse(String(ntfyJsonRequest('https://ntfy.sh/abc%20def', payload)!.init.body)).topic).toBe('abc def');
    expect(ntfyJsonRequest('https://ntfy.sh/', payload)).toBeNull();
    // The header variant must be constructible by fetch (no invalid header values).
    expect(() => new Headers(ntfyHeaderRequest('https://ntfy.sh/x', payload).init.headers)).not.toThrow();
  });
});
