import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

export function appDataDir(): string {
  if (process.env.NEXUSLINK_DATA_DIR) return process.env.NEXUSLINK_DATA_DIR;
  return process.env.APPDATA
    ? join(process.env.APPDATA, 'NexusLink')
    : join(homedir(), 'AppData', 'Roaming', 'NexusLink');
}

export function persistentHostId(): string {
  const path = join(appDataDir(), 'host-id');
  mkdirSync(appDataDir(), { recursive: true });
  if (!existsSync(path)) writeFileSync(path, crypto.randomUUID(), { flag: 'wx' });
  const id = readFileSync(path, 'utf8').trim();
  if (!/^[a-f0-9-]{36}$/i.test(id)) throw new Error('Invalid saved NexusLink host identity.');
  return id;
}

function tokensPath(): string {
  return join(appDataDir(), 'session-tokens.json');
}

interface StoredToken {
  token: string;
  expires: number;
}

function loadStored(): StoredToken[] {
  try {
    if (!existsSync(tokensPath())) return [];
    const raw = JSON.parse(readFileSync(tokensPath(), 'utf-8')) as { tokens?: StoredToken[] };
    const now = Date.now();
    return (raw.tokens ?? []).filter((t) => t.token && t.expires > now);
  } catch {
    return [];
  }
}

function saveStored(tokens: StoredToken[]): void {
  mkdirSync(appDataDir(), { recursive: true });
  writeFileSync(tokensPath(), JSON.stringify({ tokens }, null, 2));
}

const memory = new Map<string, StoredToken>();

export function hydratePersistedTokens(): void {
  for (const t of loadStored()) memory.set(t.token, t);
}

export function persistToken(token: string, expires: number): void {
  memory.set(token, { token, expires });
  saveStored([...memory.values()].filter((t) => t.expires > Date.now()));
}

export function persistedTokenValid(token: string): boolean {
  const entry = memory.get(token);
  if (!entry) return false;
  if (Date.now() > entry.expires) {
    memory.delete(token);
    saveStored([...memory.values()]);
    return false;
  }
  return true;
}

export function forgetToken(token: string): void {
  memory.delete(token);
  saveStored([...memory.values()]);
}
