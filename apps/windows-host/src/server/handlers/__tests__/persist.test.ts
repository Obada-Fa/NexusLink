import { describe, expect, test } from 'bun:test';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

describe('session token persist', () => {
  test('round-trips a token through %APPDATA% override', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'nexuslink-persist-'));
    const prev = process.env.APPDATA;
    const previousData = process.env.NEXUSLINK_DATA_DIR;
    delete process.env.NEXUSLINK_DATA_DIR;
    process.env.APPDATA = dir;
    try {
      const persist = await import('../../persist');
      persist.hydratePersistedTokens();
      persist.persistToken('tok-1', Date.now() + 60_000);
      expect(persist.persistedTokenValid('tok-1')).toBe(true);
      const raw = readFileSync(join(dir, 'NexusLink', 'session-tokens.json'), 'utf-8');
      expect(raw).toContain('tok-1');
    } finally {
      process.env.APPDATA = prev;
      process.env.NEXUSLINK_DATA_DIR = previousData;
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
