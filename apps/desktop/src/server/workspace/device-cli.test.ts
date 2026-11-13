import { expect, test } from 'bun:test';
import { mkdtempSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { Database } from 'bun:sqlite';

const cli = join(import.meta.dir, 'device-cli.ts');
const root = '/tmp/nexus-utilities-build/nexuslink';
mkdirSync(root, { recursive: true });
const run = (dir: string, ...a: string[]) => {
  const p = Bun.spawnSync([process.execPath, cli, ...a], { env: { ...process.env, NEXUSLINK_DATA_DIR: dir } });
  const stdout = p.stdout.toString();
  return { code: p.exitCode, stdout, stderr: p.stderr.toString(), json: (() => { try { return JSON.parse(stdout); } catch { return null; } })() };
};
const scratch = () => mkdtempSync(join(root, 't-'));

test('status, invite, devices, revoke JSON contract', () => {
  const d = scratch();
  const s = run(d, 'status', '--json');
  expect(s.code).toBe(0);
  expect(s.json).toMatchObject({ contract: 1, utility: 'nexuslink', devices: 0, fingerprint: null });
  expect(typeof s.json.hostId).toBe('string');
  const before = Date.now();
  const i = run(d, 'invite', '--ttl', '120', '--label', 'Pixel', '--json');
  expect(i.code).toBe(0);
  expect(i.json.secret).toMatch(/^\d{8}$/);
  expect(i.json.fingerprint).toBeNull();
  expect(i.json.expiresAt).toBeGreaterThanOrEqual(before + 119000);
  expect(i.json.hostId).toBe(s.json.hostId);
  expect(run(d, 'devices', '--json').json).toEqual({ contract: 1, devices: [] });
  expect(i.stderr).not.toContain(i.json.secret);
});

test('errors are JSON with non-zero exit', () => {
  const d = scratch();
  for (const a of [['invite', '--ttl', '10'], ['invite', '--ttl', '5000'], ['invite', '--ttl', 'x'], ['invite', '--label', 'x'.repeat(101)], ['bogus'], ['revoke']]) {
    const r = run(d, ...a, '--json');
    expect(r.code).not.toBe(0);
    expect(r.json.error.code).toBe('BAD_ARGS');
  }
  const r = run(d, 'revoke', 'nope', '--json');
  expect(r.code).not.toBe(0);
  expect(r.json).toEqual({ contract: 1, error: { code: 'NOT_FOUND', message: expect.any(String) } });
});

test('enroll records inviteId; revoke removes device; human commands unchanged', async () => {
  const d = scratch();
  process.env.NEXUSLINK_DATA_DIR = d;
  const sec = await import('./security');
  sec.closeSecurityStore();
  const inv = run(d, 'invite', '--ttl', '60', '--json').json;
  const dev = sec.enroll(inv.secret, 'Test phone');
  const list = run(d, 'devices', '--json').json.devices;
  expect(list).toHaveLength(1);
  expect(list[0]).toMatchObject({ id: dev.deviceId, name: 'Test phone', inviteId: inv.inviteId, lastSeenAt: null });
  expect(sec.accessToken(dev.token)).toBeDefined();
  expect(sec.accessToken(dev.token)).toBeDefined();
  expect(Date.now() - run(d, 'devices', '--json').json.devices[0].lastSeenAt).toBeLessThan(5000);
  expect(run(d, 'status', '--json').json.devices).toBe(1);
  // human-readable
  expect(run(d, 'list').stdout).toContain(dev.deviceId);
  expect(run(d, 'pair').stdout).toContain('NexusLink pairing code:');
  expect(run(d, 'revoke', dev.deviceId, '--json').json).toEqual({ contract: 1, revoked: true });
  expect(sec.isRevokedToken(dev.token)).toBe(true);
  expect(sec.accessToken(dev.token)).toBeUndefined();
  expect(run(d, 'devices', '--json').json.devices).toEqual([]);
  sec.closeSecurityStore();
});

test('migration on old-schema DB keeps old positional inserts working', () => {
  const d = scratch();
  const old = new Database(join(d, 'devices.sqlite'), { create: true });
  old.exec(`CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE devices (id TEXT PRIMARY KEY, name TEXT, hash TEXT UNIQUE, created INTEGER);
    CREATE TABLE enrollment (id INTEGER PRIMARY KEY CHECK(id=1), hash TEXT, expires INTEGER, attempts INTEGER);
    INSERT INTO devices VALUES ('old1','Old phone','h',1000);`);
  old.close();
  const r = run(d, 'devices', '--json').json;
  expect(r.devices).toEqual([{ id: 'old1', name: 'Old phone', createdAt: 1000, lastSeenAt: null, inviteId: null }]);
  const again = new Database(join(d, 'devices.sqlite'));
  again.query('INSERT INTO devices VALUES (?,?,?,?)').run('old2', 'x', 'h2', 2); // old service code path
  again.query('INSERT OR REPLACE INTO enrollment VALUES (1, ?, ?, 0)').run('h', 1);
  again.close();
});
