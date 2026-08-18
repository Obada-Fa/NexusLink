import { describe, expect, it } from 'bun:test';
import {
  mergeRecentAgentCwd,
  parseStoredRecentCwds,
  RECENT_AGENT_CWD_CAP,
} from '@/lib/last-cwd';

describe('recent agent directories', () => {
  it('puts the newest path first and drops duplicates', () => {
    expect(mergeRecentAgentCwd('/tmp/b', ['/tmp/a', '/tmp/b'])).toEqual([
      '/tmp/b',
      '/tmp/a',
    ]);
  });

  it('caps the list', () => {
    const many = Array.from({ length: RECENT_AGENT_CWD_CAP }, (_, i) => `/p${i}`);
    expect(mergeRecentAgentCwd('/new', many)).toHaveLength(RECENT_AGENT_CWD_CAP);
    expect(mergeRecentAgentCwd('/new', many)[0]).toBe('/new');
  });

  it('reads a JSON list and falls back to the old single path', () => {
    expect(parseStoredRecentCwds(JSON.stringify(['/a', '/b']), '/legacy')).toEqual([
      '/a',
      '/b',
    ]);
    expect(parseStoredRecentCwds(null, '/legacy')).toEqual(['/legacy']);
    expect(parseStoredRecentCwds('not-json', null)).toEqual([]);
  });
});
