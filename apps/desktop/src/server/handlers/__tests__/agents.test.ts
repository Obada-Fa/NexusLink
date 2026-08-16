// Agent gateway: session lifecycle and the normalized event stream, exercised
// end-to-end through the mock adapter (no CLI required).

import { describe, expect, test } from 'bun:test';
import type { AgentEvent, WsMessage } from '@nexuslink/rpc-types';
import {
  listAgents,
  createAgentSession,
  listAgentSessions,
  promptAgent,
  agentHistory,
  closeAgentSession,
  setAgentBroadcast,
} from '../agents';

describe('agent gateway', () => {
  test('lists known agents with availability flags', () => {
    const agents = listAgents();
    const ids = agents.map((a) => a.id);
    expect(ids).toContain('claude');
    expect(ids).toContain('cursor');
    expect(ids).toContain('mock');
    expect(agents.find((a) => a.id === 'mock')!.available).toBe(true);
  });

  test('mock conversation streams normalized events and keeps history', async () => {
    const pushed: AgentEvent[] = [];
    setAgentBroadcast((msg: WsMessage) => {
      if (msg.type === 'agent-event') pushed.push(msg.event);
    });

    const info = createAgentSession('mock', '/tmp', 'Test chat');
    expect(info.status).toBe('running');
    expect(listAgentSessions().some((s) => s.agentSessionId === info.agentSessionId)).toBe(true);

    const res = promptAgent(info.agentSessionId, 'hello agent');
    expect(res.ok).toBe(true);

    const deadline = Date.now() + 5000;
    while (!pushed.some((e) => e.kind === 'result') && Date.now() < deadline) {
      await Bun.sleep(50);
    }

    const kinds = pushed.map((e) => e.kind);
    expect(kinds[0]).toBe('user');
    expect(kinds).toContain('thinking');
    expect(kinds).toContain('tool-start');
    expect(kinds).toContain('tool-end');
    expect(kinds).toContain('text');
    expect(kinds[kinds.length - 1]).toBe('result');

    // Tool start/end correlate through refId.
    const start = pushed.find((e) => e.kind === 'tool-start')!;
    const end = pushed.find((e) => e.kind === 'tool-end')!;
    expect(start.refId).toBe(end.refId!);

    // History replays the same events (for reconnecting phones).
    const history = agentHistory(info.agentSessionId);
    expect(history.map((e) => e.kind)).toEqual(kinds);
    expect(history.every((e, i) => i === 0 || e.seq > history[i - 1]!.seq)).toBe(true);

    expect(closeAgentSession(info.agentSessionId).ok).toBe(true);
    expect(listAgentSessions().some((s) => s.agentSessionId === info.agentSessionId)).toBe(false);
    setAgentBroadcast(() => {});
  });

  test('rejects unknown agents and empty prompts', () => {
    expect(() => createAgentSession('nope')).toThrow();
    const info = createAgentSession('mock');
    expect(promptAgent(info.agentSessionId, '   ').ok).toBe(false);
    expect(promptAgent('missing-session', 'hi').ok).toBe(false);
    closeAgentSession(info.agentSessionId);
  });
});
