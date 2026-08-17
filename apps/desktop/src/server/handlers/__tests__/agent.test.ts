import { describe, it, expect } from 'bun:test';
import { listAgents } from '../agent';

describe('agent handler', () => {
  it('lists all supported agents with install metadata', async () => {
    const agents = await listAgents();
    expect(agents).toHaveLength(3);
    expect(agents.map((a) => a.id)).toEqual(['cursor', 'opencode', 'antigravity']);
    for (const agent of agents) {
      expect(agent.label.length).toBeGreaterThan(0);
      expect(typeof agent.installed).toBe('boolean');
      expect(agent.installHint).toBeTruthy();
    }
  });
});
