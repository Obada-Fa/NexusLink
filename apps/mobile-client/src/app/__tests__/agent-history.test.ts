import { describe, expect, it } from 'bun:test';
import { mergeAgentHistory } from '@/lib/agent-history';

describe('mergeAgentHistory', () => {
  it('keeps live events that arrived after the host snapshot', () => {
    const history = [
      { seq: 1, text: 'a' },
      { seq: 2, text: 'b' },
      { seq: 3, text: 'c' },
    ];
    const live = [
      { seq: 1, text: 'stale' },
      { seq: 3, text: 'c' },
      { seq: 4, text: 'live' },
    ];
    const merged = mergeAgentHistory(history, live);
    expect(merged.map((e) => e.seq)).toEqual([1, 2, 3, 4]);
    expect(merged.at(-1)?.text).toBe('live');
    expect(merged[0]?.text).toBe('a');
  });

  it('replaces an empty snapshot with the live transcript', () => {
    expect(mergeAgentHistory([], [{ seq: 1, text: 'only' }])).toEqual([
      { seq: 1, text: 'only' },
    ]);
  });
});
