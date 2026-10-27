import { Database } from 'bun:sqlite';
import { mkdirSync, chmodSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { randomBytes, randomInt, createHash } from 'node:crypto';

export class WorkspaceError extends Error {
  constructor(public code: string, message: string, public details?: unknown) { super(message); }
}
export const dataDirectory = () => process.env.NEXUSLINK_DATA_DIR || join(homedir(), '.local', 'share', 'nexuslink');
let database: Database;
function db() {
  if (database) return database;
  mkdirSync(dataDirectory(), { recursive: true, mode: 0o700 });
  database = new Database(join(dataDirectory(), 'devices.sqlite'), { create: true });
  chmodSync(join(dataDirectory(), 'devices.sqlite'), 0o600);
  database.exec(`PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, name TEXT, hash TEXT UNIQUE, created INTEGER);
    CREATE TABLE IF NOT EXISTS enrollment (id INTEGER PRIMARY KEY CHECK(id=1), hash TEXT, expires INTEGER, attempts INTEGER);`);
  database.query('INSERT OR IGNORE INTO settings VALUES (?, ?)').run('hostId', crypto.randomUUID());
  return database;
}
const hash = (s: string) => createHash('sha256').update(s).digest('hex');
export function hostId(): string { return (db().query('SELECT value FROM settings WHERE key=?').get('hostId') as any).value; }
export function closeSecurityStore() { database?.close(); database = undefined as any; tokens.clear(); }
export function enableEnrollment(): string {
  const code = String(randomInt(10000000, 100000000));
  db().query('INSERT OR REPLACE INTO enrollment VALUES (1, ?, ?, 0)').run(hash(code), Date.now() + 300000);
  return code;
}
export function enroll(code: string, name: string) {
  const row = db().query('SELECT * FROM enrollment WHERE id=1').get() as any;
  if (!row || row.expires < Date.now() || row.attempts >= 5) throw new WorkspaceError('UNAUTHENTICATED', 'Enable pairing on the PC with bun run host:pair.');
  db().query('UPDATE enrollment SET attempts=attempts+1 WHERE id=1').run();
  if (row.hash !== hash(code)) throw new WorkspaceError('UNAUTHENTICATED', 'Incorrect pairing code.');
  const credential = randomBytes(32).toString('base64url');
  const deviceId = crypto.randomUUID();
  db().transaction(() => {
    db().query('INSERT INTO devices VALUES (?, ?, ?, ?)').run(deviceId, name.slice(0, 100), hash(credential), Date.now());
    db().query('DELETE FROM enrollment').run();
  })();
  return { credential, ...resume(credential) };
}
export function listDevices() { return db().query('SELECT id, name, created FROM devices').all(); }
export function revokeDevice(id: string) { db().query('DELETE FROM devices WHERE id=?').run(id); }
type Access = { deviceId: string; expires: number; path?: string; role: 'control' | 'monitor' | 'download' };
const tokens = new Map<string, Access>();
export function resume(credential: string, role: 'control' | 'monitor' = 'control') {
  const device = db().query('SELECT id FROM devices WHERE hash=?').get(hash(credential)) as any;
  if (!device) throw new WorkspaceError('UNAUTHENTICATED', 'Pair this device with the PC again.');
  const token = randomBytes(32).toString('base64url');
  const expires = Date.now() + 60 * 60 * 1000;
  for (const [key, access] of tokens) if (access.expires < Date.now()) tokens.delete(key);
  tokens.set(token, { deviceId: device.id, expires, role });
  return { token, expires, hostId: hostId(), deviceId: device.id };
}
export function accessToken(token?: string): Access | undefined {
  const access = token ? tokens.get(token) : undefined;
  if (!access || access.expires < Date.now() || !db().query('SELECT id FROM devices WHERE id=?').get(access.deviceId)) return;
  return access;
}
export function downloadToken(deviceId: string, path: string) {
  // Download tokens live 24 h; purge expired ones here too, not only on resume().
  for (const [key, access] of tokens) if (access.expires < Date.now()) tokens.delete(key);
  const token = randomBytes(32).toString('base64url');
  const expires = Date.now() + 24 * 60 * 60 * 1000;
  tokens.set(token, { deviceId, path, expires, role: 'download' });
  return { token, expires };
}
export function authorizeHttp(req: Request, path: string) {
  const access = accessToken(req.headers.get('authorization')?.replace(/^Bearer /i, ''));
  if (!access || access.role === 'monitor' || (access.role === 'download' && (access.path !== path || !['GET', 'HEAD'].includes(req.method)))) {
    throw new WorkspaceError('UNAUTHENTICATED', 'A valid file transfer authorization is required.');
  }
  return access;
}
// The advanced LAN listener serves plain HTTP/WebSocket. Never expose paired
// credentials on a public peer through that listener; use a TLS reverse proxy
// terminating on loopback for non-tailnet remote access.
export function isPrivatePeer(address?: string): boolean {
  if (!address) return false;
  const ip = address.replace(/^::ffff:/, '');
  if (ip === '::1' || ip === '127.0.0.1') return true;
  const octets = ip.split('.').map(Number);
  if (octets.length === 4 && octets.every(n => Number.isInteger(n) && n >= 0 && n <= 255)) {
    return octets[0] === 10 ||
      (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
      (octets[0] === 192 && octets[1] === 168) ||
      (octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127) ||
      (octets[0] === 169 && octets[1] === 254) ||
      octets[0] === 127;
  }
  return /^(fc|fd|fe[89ab])/i.test(ip);
}
export function stringParam(params: Record<string, unknown>, key: string, optional = false): string {
  const value = params[key];
  if (optional && value === undefined) return '';
  if (typeof value !== 'string' || (!optional && !value.length) || value.includes('\0')) throw new WorkspaceError('INVALID_ARGUMENT', `Invalid ${key}.`);
  return value;
}
export function intParam(params: Record<string, unknown>, key: string, fallback: number, min: number, max: number) {
  const value = params[key] ?? fallback;
  if (!Number.isInteger(value) || Number(value) < min || Number(value) > max) throw new WorkspaceError('INVALID_ARGUMENT', `Invalid ${key}.`);
  return Number(value);
}
