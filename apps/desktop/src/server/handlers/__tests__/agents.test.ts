// Agent gateway: session lifecycle and the normalized event stream, exercised
// end-to-end through the mock adapter (no CLI required).

import { chmodSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, test } from 'bun:test';
import type { AgentEvent, WsMessage } from '@nexuslink/rpc-types';
import {
  listAgents,
  createAgentSession,
  listAgentSessions,
  promptAgent,
  agentHistory,
  closeAgentSession,
  resolveAgentPermission,
  setAgentBroadcast,
  buildCursorCliArgs,
  parseCursorToolCall,
} from '../agents';

function installFakeCursor(script: string): { dir: string; argvFile: string; restore: () => void } {
  const dir = join(tmpdir(), `nl-cursor-${crypto.randomUUID()}`);
  mkdirSync(dir, { recursive: true });
  const bin = join(dir, 'cursor-agent');
  writeFileSync(bin, script);
  chmodSync(bin, 0o755);
  const prev = process.env.PATH;
  process.env.PATH = `${dir}:${prev ?? ''}`;
  return {
    dir,
    argvFile: `${bin}.argv`,
    restore() {
      process.env.PATH = prev;
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

async function waitFor(pushed: AgentEvent[], kind: AgentEvent['kind'], ms = 4000): Promise<void> {
  const deadline = Date.now() + ms;
  while (!pushed.some((e) => e.kind === kind) && Date.now() < deadline) {
    await Bun.sleep(25);
  }
}

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
    while (!pushed.some((e) => e.kind === 'permission-request') && Date.now() < deadline) {
      await Bun.sleep(50);
    }
    expect(pushed.some((e) => e.kind === 'permission-request')).toBe(true);
    expect(resolveAgentPermission(info.agentSessionId, 'mock-perm', true).ok).toBe(true);

    while (!pushed.some((e) => e.kind === 'result') && Date.now() < deadline) {
      await Bun.sleep(50);
    }

    const kinds = pushed.map((e) => e.kind);
    expect(kinds[0]).toBe('user');
    expect(kinds).toContain('thinking');
    expect(kinds).toContain('permission-request');
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

  test('headless Cursor CLI argv includes --trust and --force', () => {
    const argv = buildCursorCliArgs('/tmp/cursor-agent', 'hello', {
      cwd: '/home/me/proj',
      sessionId: 'abc',
    });
    expect(argv).toContain('--print');
    expect(argv).toContain('--trust');
    expect(argv).toContain('--force');
    expect(argv).toContain('--approve-mcps');
    expect(argv).toContain('--workspace');
    expect(argv).toContain('/home/me/proj');
    expect(argv).toContain('--resume');
    expect(argv).toContain('abc');
    expect(argv.at(-1)).toBe('hello');
  });

  test('parses nested Cursor tool_call payloads', () => {
    const started = parseCursorToolCall({
      type: 'tool_call',
      subtype: 'started',
      call_id: 't1',
      tool_call: { readToolCall: { args: { path: '/etc/os-release' } } },
    });
    expect(started.name).toBe('read');
    expect((started.args as { path: string }).path).toBe('/etc/os-release');

    const done = parseCursorToolCall({
      type: 'tool_call',
      subtype: 'completed',
      call_id: 't1',
      tool_call: {
        readToolCall: {
          args: { path: '/etc/os-release' },
          result: { success: { content: 'ID=linux' } },
        },
      },
    });
    expect((done.result as { success: { content: string } }).success.content).toBe('ID=linux');
  });

  test('cursor adapter streams assistant text from a fake CLI', async () => {
    const fake = installFakeCursor(`#!/usr/bin/env bash
printf '%s\\n' "$@" > "\${0}.argv"
echo '{"type":"system","subtype":"init","session_id":"sess-1"}'
echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"You are on Linux."}]}}'
echo '{"type":"tool_call","subtype":"started","call_id":"t1","tool_call":{"readToolCall":{"args":{"path":"/etc/os-release"}}}}'
echo '{"type":"tool_call","subtype":"completed","call_id":"t1","tool_call":{"readToolCall":{"args":{"path":"/etc/os-release"},"result":{"success":{"content":"ID=linux"}}}}}'
echo '{"type":"result","subtype":"success","is_error":false,"result":"You are on Linux.","session_id":"sess-1"}'
`);
    const pushed: AgentEvent[] = [];
    setAgentBroadcast((msg: WsMessage) => {
      if (msg.type === 'agent-event') pushed.push(msg.event);
    });
    try {
      expect(listAgents().find((a) => a.id === 'cursor')!.available).toBe(true);
      const info = createAgentSession('cursor', fake.dir, 'Cursor CLI');
      expect(promptAgent(info.agentSessionId, 'what system am i using').ok).toBe(true);
      await waitFor(pushed, 'text');
      await waitFor(pushed, 'tool-end');
      const argv = readFileSync(fake.argvFile, 'utf8');
      expect(argv).toContain('--trust');
      expect(argv).toContain('--force');
      expect(argv).toContain('--print');
      expect(argv).toContain('what system am i using');
      expect(pushed.some((e) => e.kind === 'text' && e.text?.includes('Linux'))).toBe(true);
      expect(pushed.find((e) => e.kind === 'tool-start')?.toolName).toBe('read');
      // Duplicate full result text is not re-emitted as a second bubble.
      expect(pushed.filter((e) => e.kind === 'text').length).toBe(1);
      closeAgentSession(info.agentSessionId);
    } finally {
      fake.restore();
      setAgentBroadcast(() => {});
    }
  });

  test('cursor adapter surfaces stderr when the CLI exits with no JSON', async () => {
    const fake = installFakeCursor(`#!/usr/bin/env bash
echo 'Authentication required. Run cursor-agent login.' >&2
exit 1
`);
    const pushed: AgentEvent[] = [];
    setAgentBroadcast((msg: WsMessage) => {
      if (msg.type === 'agent-event') pushed.push(msg.event);
    });
    try {
      const info = createAgentSession('cursor', fake.dir, 'Cursor CLI');
      promptAgent(info.agentSessionId, 'hello');
      await waitFor(pushed, 'error');
      const err = pushed.find((e) => e.kind === 'error');
      expect(err?.text ?? '').toMatch(/login|Authentication/i);
      closeAgentSession(info.agentSessionId);
    } finally {
      fake.restore();
      setAgentBroadcast(() => {});
    }
  });
});
