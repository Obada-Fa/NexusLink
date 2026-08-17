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
  buildOpenCodeArgs,
  buildAntigravityArgs,
  parseCursorToolCall,
  classifyCursorAssistant,
} from '../agents';

function installFakeBin(name: string, script: string): { dir: string; argvFile: string; restore: () => void } {
  const dir = join(tmpdir(), `nl-agent-${crypto.randomUUID()}`);
  mkdirSync(dir, { recursive: true });
  const bin = join(dir, name);
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
    expect(ids).toContain('opencode');
    expect(ids).toContain('antigravity');
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
    expect(argv).toContain('--stream-partial-output');
    expect(argv).toContain('--workspace');
    expect(argv).toContain('/home/me/proj');
    expect(argv).toContain('--resume');
    expect(argv).toContain('abc');
    expect(argv.at(-1)).toBe('hello');
  });

  test('classifies Cursor assistant events for complete vs streamed output', () => {
    const complete = { type: 'assistant', message: { content: [{ type: 'text', text: 'Hi' }] } };
    expect(classifyCursorAssistant(complete, { streamedDeltas: false })).toBe('text');
    expect(classifyCursorAssistant(complete, { streamedDeltas: true })).toBe('skip');

    const delta = { type: 'assistant', timestamp_ms: 1, message: { content: [{ type: 'text', text: 'H' }] } };
    expect(classifyCursorAssistant(delta, { streamedDeltas: false })).toBe('text-delta');

    const flush = {
      type: 'assistant',
      timestamp_ms: 2,
      model_call_id: 'm1',
      message: { content: [{ type: 'text', text: 'Hi' }] },
    };
    expect(classifyCursorAssistant(flush, { streamedDeltas: true })).toBe('skip');
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
    const fake = installFakeBin('cursor-agent',`#!/usr/bin/env bash
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

  test('second Cursor CLI prompt resumes the same session', async () => {
    const fake = installFakeBin('cursor-agent',`#!/usr/bin/env bash
printf '%s\\n' "$@" > "\${0}.argv"
echo '{"type":"system","subtype":"init","session_id":"sess-1"}'
echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"pong"}]}}'
echo '{"type":"result","subtype":"success","is_error":false,"result":"pong","session_id":"sess-1"}'
`);
    const pushed: AgentEvent[] = [];
    setAgentBroadcast((msg: WsMessage) => {
      if (msg.type === 'agent-event') pushed.push(msg.event);
    });
    try {
      const info = createAgentSession('cursor', fake.dir, 'Cursor CLI');
      promptAgent(info.agentSessionId, 'hello');
      await waitFor(pushed, 'text');
      pushed.length = 0;
      promptAgent(info.agentSessionId, 'what system am i using');
      await waitFor(pushed, 'text');
      const argv = readFileSync(fake.argvFile, 'utf8');
      expect(argv).toContain('--resume');
      expect(argv).toContain('sess-1');
      expect(argv).toContain('what system am i using');
      expect(pushed.some((e) => e.kind === 'user' && e.text === 'what system am i using')).toBe(true);
      expect(pushed.some((e) => e.kind === 'text' && e.text?.includes('pong'))).toBe(true);
      closeAgentSession(info.agentSessionId);
    } finally {
      fake.restore();
      setAgentBroadcast(() => {});
    }
  });

  test('cursor adapter surfaces stderr when the CLI exits with no JSON', async () => {
    const fake = installFakeBin('cursor-agent',`#!/usr/bin/env bash
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

  test('cursor adapter streams token deltas and keeps later complete messages', async () => {
    const fake = installFakeBin('cursor-agent', `#!/usr/bin/env bash
echo '{"type":"system","subtype":"init","session_id":"sess-d"}'
echo '{"type":"assistant","timestamp_ms":1,"message":{"role":"assistant","content":[{"type":"text","text":"Hel"}]}}'
echo '{"type":"assistant","timestamp_ms":2,"message":{"role":"assistant","content":[{"type":"text","text":"lo"}]}}'
echo '{"type":"assistant","model_call_id":"m1","timestamp_ms":3,"message":{"role":"assistant","content":[{"type":"text","text":"Hello"}]}}'
echo '{"type":"tool_call","subtype":"started","call_id":"t1","tool_call":{"readToolCall":{"args":{"path":"a.txt"}}}}'
echo '{"type":"tool_call","subtype":"completed","call_id":"t1","tool_call":{"readToolCall":{"args":{"path":"a.txt"},"result":{"success":{"content":"ok"}}}}}'
echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":" Done."}]}}'
echo '{"type":"result","subtype":"success","is_error":false,"result":"Hello Done.","session_id":"sess-d"}'
`);
    const pushed: AgentEvent[] = [];
    setAgentBroadcast((msg: WsMessage) => {
      if (msg.type === 'agent-event') pushed.push(msg.event);
    });
    try {
      const info = createAgentSession('cursor', fake.dir, 'Cursor CLI');
      promptAgent(info.agentSessionId, 'hi');
      await waitFor(pushed, 'result');
      const deltas = pushed.filter((e) => e.kind === 'text-delta').map((e) => e.text).join('');
      expect(deltas).toBe('Hello');
      expect(pushed.some((e) => e.kind === 'text' && e.text === ' Done.')).toBe(true);
      closeAgentSession(info.agentSessionId);
    } finally {
      fake.restore();
      setAgentBroadcast(() => {});
    }
  });

  test('cursor adapter errors when the CLI stays silent', async () => {
    const prev = process.env.NEXUS_AGENT_SILENCE_MS;
    process.env.NEXUS_AGENT_SILENCE_MS = '200';
    const fake = installFakeBin('cursor-agent', `#!/usr/bin/env bash
sleep 8
`);
    const pushed: AgentEvent[] = [];
    setAgentBroadcast((msg: WsMessage) => {
      if (msg.type === 'agent-event') pushed.push(msg.event);
    });
    try {
      const info = createAgentSession('cursor', fake.dir, 'Cursor CLI');
      promptAgent(info.agentSessionId, 'hello');
      await waitFor(pushed, 'error', 3000);
      expect(pushed.find((e) => e.kind === 'error')?.text ?? '').toMatch(/did not respond/i);
      closeAgentSession(info.agentSessionId);
    } finally {
      if (prev === undefined) delete process.env.NEXUS_AGENT_SILENCE_MS;
      else process.env.NEXUS_AGENT_SILENCE_MS = prev;
      fake.restore();
      setAgentBroadcast(() => {});
    }
  });

  test('headless OpenCode argv uses run --format json --auto', () => {
    const argv = buildOpenCodeArgs('/tmp/opencode', 'hello', {
      cwd: '/home/me/proj',
      sessionId: 'ses_abc',
    });
    expect(argv.slice(0, 6)).toEqual(['/tmp/opencode', 'run', '--format', 'json', '--auto', '--dir']);
    expect(argv).toContain('/home/me/proj');
    expect(argv).toContain('--session');
    expect(argv).toContain('ses_abc');
    expect(argv.at(-1)).toBe('hello');
  });

  test('headless Antigravity argv uses print stream-json', () => {
    const argv = buildAntigravityArgs('/tmp/agy', 'hello', {
      cwd: '/tmp',
      sessionId: 'conv-1',
    });
    expect(argv).toContain('--print');
    expect(argv).toContain('stream-json');
    expect(argv).toContain('--dangerously-skip-permissions');
    expect(argv).toContain('--conversation');
    expect(argv).toContain('conv-1');
    expect(argv.at(-1)).toBe('hello');
  });

  test('opencode adapter streams assistant text from a fake CLI', async () => {
    const fake = installFakeBin('opencode', `#!/usr/bin/env bash
printf '%s\\n' "$@" > "\${0}.argv"
echo '{"type":"step_start","sessionID":"ses_1"}'
echo '{"type":"text","sessionID":"ses_1","part":{"type":"text","text":"OpenCode here."}}'
echo '{"type":"tool_use","sessionID":"ses_1","part":{"callID":"c1","tool":"bash","state":{"status":"completed","input":{"command":"uname"},"output":"Linux\\n"}}}'
echo '{"type":"step_finish","sessionID":"ses_1","part":{"type":"step-finish","reason":"stop"}}'
`);
    const pushed: AgentEvent[] = [];
    setAgentBroadcast((msg: WsMessage) => {
      if (msg.type === 'agent-event') pushed.push(msg.event);
    });
    try {
      expect(listAgents().find((a) => a.id === 'opencode')!.available).toBe(true);
      const info = createAgentSession('opencode', fake.dir, 'OpenCode');
      promptAgent(info.agentSessionId, 'hello');
      await waitFor(pushed, 'text');
      await waitFor(pushed, 'result');
      const argv = readFileSync(fake.argvFile, 'utf8');
      expect(argv).toContain('run');
      expect(argv).toContain('--format');
      expect(argv).toContain('json');
      expect(argv).toContain('--auto');
      expect(pushed.some((e) => e.kind === 'text' && e.text?.includes('OpenCode'))).toBe(true);
      expect(pushed.find((e) => e.kind === 'tool-start')?.toolName).toBe('bash');
      closeAgentSession(info.agentSessionId);
    } finally {
      fake.restore();
      setAgentBroadcast(() => {});
    }
  });

  test('antigravity adapter streams assistant text from a fake CLI', async () => {
    const fake = installFakeBin('agy', `#!/usr/bin/env bash
printf '%s\\n' "$@" > "\${0}.argv"
echo '{"event":"init","conversation_id":"conv-9","init":{"cwd":"/tmp","permission_mode":"always-proceed"}}'
echo '{"event":"step_update","step_update":{"conversation_id":"conv-9","step_index":3,"state":"DONE","step_type":"agent_response","text_delta":"Antigravity on this PC."}}'
echo '{"event":"step_update","step_update":{"conversation_id":"conv-9","step_index":4,"state":"DONE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"uname"},"output":"Linux"}}}'
echo '{"event":"result","result":{"conversation_id":"conv-9","status":"SUCCESS","response":"Antigravity on this PC."}}'
`);
    const pushed: AgentEvent[] = [];
    setAgentBroadcast((msg: WsMessage) => {
      if (msg.type === 'agent-event') pushed.push(msg.event);
    });
    try {
      expect(listAgents().find((a) => a.id === 'antigravity')!.available).toBe(true);
      const info = createAgentSession('antigravity', fake.dir, 'Antigravity');
      promptAgent(info.agentSessionId, 'hello');
      await waitFor(pushed, 'text');
      await waitFor(pushed, 'result');
      const argv = readFileSync(fake.argvFile, 'utf8');
      expect(argv).toContain('--print');
      expect(argv).toContain('stream-json');
      expect(pushed.some((e) => e.kind === 'text' && e.text?.includes('Antigravity'))).toBe(true);
      expect(pushed.find((e) => e.kind === 'tool-end')?.toolName).toBe('run_command');
      closeAgentSession(info.agentSessionId);
    } finally {
      fake.restore();
      setAgentBroadcast(() => {});
    }
  });

  test('second OpenCode prompt resumes with --session', async () => {
    const fake = installFakeBin('opencode', `#!/usr/bin/env bash
printf '%s\\n' "$@" > "\${0}.argv"
echo '{"type":"text","sessionID":"ses_1","part":{"text":"pong"}}'
echo '{"type":"step_finish","sessionID":"ses_1","part":{"reason":"stop"}}'
`);
    const pushed: AgentEvent[] = [];
    setAgentBroadcast((msg: WsMessage) => {
      if (msg.type === 'agent-event') pushed.push(msg.event);
    });
    try {
      const info = createAgentSession('opencode', fake.dir, 'OpenCode');
      promptAgent(info.agentSessionId, 'hello');
      await waitFor(pushed, 'text');
      pushed.length = 0;
      promptAgent(info.agentSessionId, 'again');
      await waitFor(pushed, 'text');
      const argv = readFileSync(fake.argvFile, 'utf8');
      expect(argv).toContain('--session');
      expect(argv).toContain('ses_1');
      closeAgentSession(info.agentSessionId);
    } finally {
      fake.restore();
      setAgentBroadcast(() => {});
    }
  });

  test('second Antigravity prompt resumes with --conversation', async () => {
    const fake = installFakeBin('agy', `#!/usr/bin/env bash
printf '%s\\n' "$@" > "\${0}.argv"
echo '{"event":"init","conversation_id":"conv-9"}'
echo '{"event":"step_update","step_update":{"conversation_id":"conv-9","state":"DONE","step_type":"agent_response","text_delta":"pong"}}'
echo '{"event":"result","result":{"conversation_id":"conv-9","status":"SUCCESS","response":"pong"}}'
`);
    const pushed: AgentEvent[] = [];
    setAgentBroadcast((msg: WsMessage) => {
      if (msg.type === 'agent-event') pushed.push(msg.event);
    });
    try {
      const info = createAgentSession('antigravity', fake.dir, 'Antigravity');
      promptAgent(info.agentSessionId, 'hello');
      await waitFor(pushed, 'text');
      pushed.length = 0;
      promptAgent(info.agentSessionId, 'again');
      await waitFor(pushed, 'text');
      const argv = readFileSync(fake.argvFile, 'utf8');
      expect(argv).toContain('--conversation');
      expect(argv).toContain('conv-9');
      closeAgentSession(info.agentSessionId);
    } finally {
      fake.restore();
      setAgentBroadcast(() => {});
    }
  });
});
