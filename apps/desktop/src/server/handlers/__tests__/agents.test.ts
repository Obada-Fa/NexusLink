// Agent gateway: session lifecycle, CLI stream parsers, and the mock adapter.

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
  finishCliTurn,
  parseCursorStreamEvent,
  parseOpencodeStreamEvent,
  parseAgyStreamEvent,
  describeCursorToolCall,
  sessionIdFromEvent,
  looksLikeAgentLogin,
  parseEnvApiKey,
  extractAuthUrl,
  isCliAuthError,
  rewriteCliAuthError,
} from '../agents';

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
});

describe('CLI stream parsers', () => {
  test('surfaces Cursor auth failure instead of an empty result', () => {
    const fail = finishCliTurn({
      sawResult: false,
      exitCode: 1,
      stderr:
        "Error: Authentication required. Please run 'agent login' first, or set CURSOR_API_KEY environment variable.",
    });
    expect(fail).toEqual({
      kind: 'error',
      text: "Error: Authentication required. Please run 'agent login' first, or set CURSOR_API_KEY environment variable.",
    });
    expect(finishCliTurn({ sawResult: true, exitCode: 0, stderr: '' })).toBeNull();
    expect(finishCliTurn({ sawResult: false, exitCode: 1, stderr: '' })?.text).toContain(
      'exited without a reply',
    );
  });

  test('parses Cursor stream-json assistant, nested tool_call, and result', () => {
    const sid = sessionIdFromEvent({
      type: 'system',
      subtype: 'init',
      session_id: 'c6b62c6f-7ead-4fd6-9922-e952131177ff',
    });
    expect(sid).toBe('c6b62c6f-7ead-4fd6-9922-e952131177ff');

    expect(
      parseCursorStreamEvent({
        type: 'assistant',
        message: { role: 'assistant', content: [{ type: 'text', text: "I'll read README.md" }] },
      }),
    ).toEqual([{ kind: 'text', text: "I'll read README.md" }]);

    const started = parseCursorStreamEvent({
      type: 'tool_call',
      subtype: 'started',
      call_id: 'toolu_1',
      tool_call: { readToolCall: { args: { path: 'README.md' } } },
    });
    expect(started[0]).toMatchObject({
      kind: 'tool-start',
      toolName: 'read',
      refId: 'toolu_1',
    });
    expect(started[0]!.toolInput).toContain('README.md');

    const done = parseCursorStreamEvent({
      type: 'tool_call',
      subtype: 'completed',
      call_id: 'toolu_1',
      tool_call: {
        readToolCall: {
          args: { path: 'README.md' },
          result: { success: { content: '# Project', totalLines: 1 } },
        },
      },
    });
    expect(done[0]).toMatchObject({ kind: 'tool-end', toolName: 'read', refId: 'toolu_1' });

    expect(
      parseCursorStreamEvent({
        type: 'result',
        subtype: 'success',
        is_error: false,
        result: "I'll read README.mdDone.",
      }),
    ).toEqual([{ kind: 'result', text: "I'll read README.mdDone." }]);

    expect(
      parseCursorStreamEvent({
        type: 'result',
        subtype: 'error',
        is_error: true,
        result: 'rate limited',
      }),
    ).toEqual([{ kind: 'error', text: 'rate limited' }]);

    expect(describeCursorToolCall({ writeToolCall: { args: { path: 'a.txt' } } }).name).toBe(
      'write',
    );
  });

  test('parses OpenCode run --format json text and tools', () => {
    const events = [
      parseOpencodeStreamEvent({
        type: 'step_start',
        sessionID: 'ses_fef972ec7ffeshLKs0Mnrk3erD',
        part: { type: 'step-start' },
      }),
      parseOpencodeStreamEvent({
        type: 'text',
        sessionID: 'ses_fef972ec7ffeshLKs0Mnrk3erD',
        part: { type: 'text', text: 'Hello! How can I help you today?' },
      }),
      parseOpencodeStreamEvent({
        type: 'tool_use',
        sessionID: 'ses_fef972ec7ffeshLKs0Mnrk3erD',
        part: {
          callID: 'call_1',
          tool: 'bash',
          state: { status: 'completed', input: { command: 'echo hi' }, output: 'hi\n' },
        },
      }),
      parseOpencodeStreamEvent({
        type: 'step_finish',
        sessionID: 'ses_fef972ec7ffeshLKs0Mnrk3erD',
        part: { type: 'step-finish', reason: 'stop' },
      }),
    ].flat();

    expect(sessionIdFromEvent({ type: 'text', sessionID: 'ses_abc' })).toBe('ses_abc');
    expect(events.filter((e) => e.kind === 'text')).toEqual([
      { kind: 'text', text: 'Hello! How can I help you today?' },
    ]);
    expect(events.some((e) => e.kind === 'tool-start' && e.toolName === 'bash')).toBe(true);
    expect(events.some((e) => e.kind === 'tool-end' && e.toolOutput?.includes('hi'))).toBe(true);
    expect(events[events.length - 1]).toEqual({ kind: 'result', text: '' });
  });

  test('parses Antigravity stream-json init, text, tools, and result', () => {
    expect(
      sessionIdFromEvent({
        event: 'init',
        conversation_id: 'c3b66b04-872b-4fbe-a3a4-058a026ef20a',
        init: { cwd: '/tmp' },
      }),
    ).toBe('c3b66b04-872b-4fbe-a3a4-058a026ef20a');

    expect(parseAgyStreamEvent({ event: 'init', init: { cwd: '/tmp' } })).toEqual([]);

    expect(
      parseAgyStreamEvent({
        event: 'step_update',
        step_update: {
          conversation_id: 'c3b66b04-872b-4fbe-a3a4-058a026ef20a',
          step_index: 3,
          state: 'DONE',
          step_type: 'agent_response',
          text_delta: 'Git rebase rewrites history.\n',
        },
      }),
    ).toEqual([{ kind: 'text-delta', text: 'Git rebase rewrites history.\n' }]);

    expect(
      parseAgyStreamEvent({
        event: 'step_update',
        step_update: {
          step_index: 4,
          state: 'DONE',
          step_type: 'tool',
          tool_name: 'run_command',
          tool_info: {
            name: 'run_command',
            parameters: { CommandLine: 'echo hello' },
            output: 'hello\n',
          },
        },
      }),
    ).toEqual([{
      kind: 'tool-end',
      toolName: 'run_command',
      toolOutput: 'hello\n',
      refId: '4',
    }]);

    expect(
      parseAgyStreamEvent({
        event: 'result',
        result: {
          conversation_id: 'c3b66b04-872b-4fbe-a3a4-058a026ef20a',
          status: 'SUCCESS',
          response: 'done\n',
        },
      }),
    ).toEqual([{ kind: 'result', text: 'done\n' }]);

    expect(
      parseAgyStreamEvent({
        event: 'result',
        result: { status: 'ERROR', error: 'authentication required', response: '' },
      }),
    ).toEqual([{ kind: 'error', text: 'authentication required' }]);
  });
});

describe('CLI login helpers', () => {
  test('treats chat login phrases as login, not prompts', () => {
    expect(looksLikeAgentLogin('agent login')).toBe(true);
    expect(looksLikeAgentLogin('/agent login')).toBe(true);
    expect(looksLikeAgentLogin('login')).toBe(true);
    expect(looksLikeAgentLogin('create test txt file')).toBe(false);
  });

  test('parses pasted API keys without treating normal prompts as keys', () => {
    expect(parseEnvApiKey('CURSOR_API_KEY=sk-test-123', ['CURSOR_API_KEY'])).toEqual({
      name: 'CURSOR_API_KEY',
      value: 'sk-test-123',
    });
    expect(parseEnvApiKey('export GEMINI_API_KEY=abc', ['GEMINI_API_KEY'])).toEqual({
      name: 'GEMINI_API_KEY',
      value: 'abc',
    });
    expect(parseEnvApiKey('create a file', ['CURSOR_API_KEY'])).toBeUndefined();
  });

  test('extracts a sign-in URL and rewrites Cursor auth errors', () => {
    expect(extractAuthUrl('Visit https://cursor.com/loginCli?token=abc to continue.')).toBe(
      'https://cursor.com/loginCli?token=abc',
    );
    expect(isCliAuthError(
      "Error: Authentication required. Please run 'agent login' first, or set CURSOR_API_KEY environment variable.",
    )).toBe(true);
    const rewritten = rewriteCliAuthError(
      "Error: Authentication required. Please run 'agent login' first.",
      'Cursor CLI',
    );
    expect(rewritten).toContain("isn't signed in");
    expect(rewritten).toContain('CURSOR_API_KEY');
  });
});
