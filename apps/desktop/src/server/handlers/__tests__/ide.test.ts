// VS Code on the phone must never be an unauthenticated shell on the tailnet.
// The token gate sits in front of a fake code-server on a unix socket.
import { afterAll, describe, expect, test } from 'bun:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { IDE_COOKIE, buildIdeArgv, gateDecision, ideBindHost, startIdeGate } from '../ide';

const dir = mkdtempSync(join(tmpdir(), 'nl-ide-'));
const sock = join(dir, 'cs.sock');
const token = 'T0k3n_' + 'x'.repeat(37);
const big = 'B'.repeat(6 * 1024 * 1024);
let upstreamHits = 0;
const upstream = Bun.serve({
  unix: sock,
  fetch(req, srv) {
    upstreamHits++;
    const url = new URL(req.url);
    if (url.pathname === '/ws' && srv.upgrade(req)) return;
    if (url.pathname === '/big') return new Response(big);
    return new Response(`editor ${url.pathname}${url.search}`);
  },
  websocket: { message(ws, m) { ws.send(`echo:${m}`); } },
} as any);
const gate = startIdeGate({ hostname: '127.0.0.1', port: 0, token, upstreamSocket: sock });
const base = `http://127.0.0.1:${gate.port}`;
const cookie = `${IDE_COOKIE}=${token}`;
afterAll(() => { gate.stop(); upstream.stop(true); rmSync(dir, { recursive: true, force: true }); });

describe('ide bind host', () => {
  test('never binds a wildcard; prefers configured host, then Tailscale, then loopback', () => {
    expect(ideBindHost({ NEXUSLINK_HOST: '100.101.102.103' }, () => [])).toBe('100.101.102.103');
    expect(ideBindHost({ NEXUSLINK_HOST: '0.0.0.0' }, () => ['100.64.0.9'])).toBe('100.64.0.9');
    expect(ideBindHost({}, () => ['100.64.0.9'])).toBe('100.64.0.9');
    expect(ideBindHost({ HOST: '::' }, () => [])).toBe('127.0.0.1');
    expect(ideBindHost({}, () => [])).toBe('127.0.0.1');
  });

  test('backend argv is authenticated and never public', () => {
    const opts = { host: '100.64.0.9', port: 45780, socketPath: '/run/x/cs.sock', tokenFile: '/run/x/tok' };
    const cs = buildIdeArgv('code-server', 'code-server', opts);
    expect(cs).toContain('--socket');
    expect(cs.join(' ')).not.toContain('--bind-addr');
    expect(cs.join(' ')).not.toContain('0.0.0.0');
    const ov = buildIdeArgv('openvscode', 'openvscode-server', opts);
    expect(ov).toContain('--connection-token-file');
    expect(ov).not.toContain('--without-connection-token');
    expect(ov.join(' ')).not.toContain('0.0.0.0');
  });
});

describe('ide token gate', () => {
  test('gateDecision', () => {
    expect(gateDecision('GET / HTTP/1.1\r\nHost: x', token).kind).toBe('deny');
    expect(gateDecision(`GET /?tkn=wrong HTTP/1.1\r\nHost: x`, token).kind).toBe('deny');
    expect(gateDecision(`GET /?folder=%2Fhome&tkn=${token} HTTP/1.1`, token)).toEqual({ kind: 'redirect', location: '/?folder=%2Fhome' });
    expect(gateDecision(`GET /x HTTP/1.1\r\nCookie: a=b; ${cookie}`, token).kind).toBe('pass');
    expect(gateDecision(`GET /x HTTP/1.1\r\nCookie: ${IDE_COOKIE}=${token}x`, token).kind).toBe('deny');
  });

  test('rejects requests without the token and never reaches the editor', async () => {
    const before = upstreamHits;
    for (const path of ['/', '/?tkn=nope', '/static/x.js']) {
      const res = await fetch(base + path, { redirect: 'manual' });
      expect(res.status).toBe(401);
      await res.text();
    }
    expect(upstreamHits).toBe(before);
  });

  test('the tokenized URL sets an HttpOnly cookie and strips the token', async () => {
    const res = await fetch(`${base}/?tkn=${token}&folder=%2Ftmp`, { redirect: 'manual' });
    expect(res.status).toBe(302);
    expect(res.headers.get('location')).toBe('/?folder=%2Ftmp');
    expect(res.headers.get('set-cookie')).toContain(`${cookie}; Path=/; HttpOnly`);
  });

  test('cookie-authenticated HTTP and large bodies pass through intact', async () => {
    const res = await fetch(`${base}/hello?x=1`, { headers: { cookie } });
    expect(res.status).toBe(200);
    expect(await res.text()).toBe('editor /hello?x=1');
    const bigRes = await fetch(`${base}/big`, { headers: { cookie } });
    const text = await bigRes.text();
    expect(text.length).toBe(big.length);
    expect(text === big).toBe(true);
  });

  test('WebSocket upgrades are piped through', async () => {
    const ws = new WebSocket(`ws://127.0.0.1:${gate.port}/ws`, { headers: { cookie } } as any);
    const reply = await new Promise<string>((resolve, reject) => {
      ws.onopen = () => ws.send('ping');
      ws.onmessage = (e) => resolve(String(e.data));
      ws.onerror = () => reject(new Error('ws error'));
      setTimeout(() => reject(new Error('timeout')), 3000);
    });
    ws.close();
    expect(reply).toBe('echo:ping');
  });

  test('answers 503 with auto-refresh while the editor is still starting', async () => {
    const early = startIdeGate({ hostname: '127.0.0.1', port: 0, token, upstreamSocket: join(dir, 'missing.sock') });
    try {
      const res = await fetch(`http://127.0.0.1:${early.port}/`, { headers: { cookie } });
      expect(res.status).toBe(503);
      expect(await res.text()).toContain('http-equiv="refresh"');
    } finally {
      early.stop();
    }
  });
});
