// Agent gateway: session lifecycle, CLI stream parsers, and the mock adapter.

import { describe, expect, test } from 'bun:test';
import { homedir } from 'node:os';
import { realpathSync } from 'node:fs';
import type { AgentEvent, WsMessage } from '@nexuslink/rpc-types';
import {
  listAgents,
  createAgentSession,
  listAgentSessions,
  promptAgent,
  agentHistory,
  closeAgentSession,
  resolveAgentPermission,
  openHostChat,
  setAgentSessionCwd,
  resolveAgentCwd,
  setAgentBroadcast,
  finishCliTurn,
  parseCursorStreamEvent,
  withoutDuplicateResult,
  parseOpencodeStreamEvent,
  parseAgyStreamEvent,
  describeCursorToolCall,
  formatCursorToolInput,
  formatCursorToolOutput,
  sessionIdFromEvent,
  looksLikeAgentLogin,
  parseEnvApiKey,
  extractAuthUrl,
  isCliAuthError,
  rewriteCliAuthError,
  cursorModelFlag,
  withImageMentions,
  materializeAgentImages,
  buildCursorArgv,
  buildOpencodeArgv,
  buildAgyArgv,
  claudeSpawnArgs,
  claudeUserContent,
  thinkingToEffort,
  parseAgentModelList,
  matchAgentModel,
  listAgentModels,
  modelFamilyId,
  collapseModelFamilies,
  pickModelVariant,
  agyEffortFlag,
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
    const cursor = agents.find((a) => a.id === 'cursor')!;
    expect(cursor.capabilities.modes).toEqual(['agent', 'plan', 'ask']);
    expect(cursor.capabilities.images).toBe(true);
    expect(cursor.capabilities.thinkingLevels).toContain('extra-high');
    expect(cursor.capabilities.models.some((m) => m.id === 'auto')).toBe(true);
    const oc = agents.find((a) => a.id === 'opencode')!;
    expect(oc.capabilities.images).toBe(true);
    expect(oc.capabilities.models.some((m) => m.id.includes('mimo'))).toBe(true);
    expect(listAgentModels('mock').some((m) => m.id === 'demo')).toBe(true);
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

  test('openHostChat attaches a mock conversation and seeds a status line', () => {
    const info = openHostChat({ agent: 'mock', hostChatId: 'host-1', title: 'Old chat' });
    expect(info.hostChatId).toBe('host-1');
    expect(info.title).toBe('Old chat');
    const history = agentHistory(info.agentSessionId);
    expect(history.some((e) => e.kind === 'status')).toBe(true);
    expect(openHostChat({ agent: 'mock', hostChatId: 'host-1' }).agentSessionId).toBe(info.agentSessionId);
    closeAgentSession(info.agentSessionId);
  });

  test('openHostChat and setAgentSessionCwd keep the folder the user picked', () => {
    const info = openHostChat({
      agent: 'mock',
      hostChatId: 'host-cwd',
      cwd: '/tmp',
      title: 'Project chat',
    });
    expect(info.cwd).toBe(resolveAgentCwd('/tmp'));
    const moved = openHostChat({
      agent: 'mock',
      hostChatId: 'host-cwd',
      cwd: homedir(),
    });
    expect(moved.agentSessionId).toBe(info.agentSessionId);
    expect(moved.cwd).toBe(resolveAgentCwd(homedir()));
    const again = setAgentSessionCwd(info.agentSessionId, '/tmp');
    expect(again.cwd).toBe(resolveAgentCwd('/tmp'));
    const kept = openHostChat({ agent: 'mock', hostChatId: 'host-cwd' });
    expect(kept.agentSessionId).toBe(info.agentSessionId);
    expect(kept.cwd).toBe(resolveAgentCwd('/tmp'));
    closeAgentSession(info.agentSessionId);
  });

  test('rejects unknown agents and empty prompts', () => {
    expect(() => createAgentSession('nope')).toThrow();
    const info = createAgentSession('mock');
    expect(promptAgent(info.agentSessionId, '   ').ok).toBe(false);
    expect(promptAgent('missing-session', 'hi').ok).toBe(false);
    closeAgentSession(info.agentSessionId);
  });

  test('resolves ~ and rejects missing working directories', () => {
    expect(resolveAgentCwd('~')).toBe(homedir());
    expect(resolveAgentCwd()).toBe(homedir());
    expect(resolveAgentCwd('/tmp')).toBe(realpathSync('/tmp'));
    expect(() => resolveAgentCwd('/this/path-does-not-exist-nexuslink')).toThrow(/directory not found/);
    expect(resolveAgentCwd('/this-path-does-not-exist-nexuslink', { fallbackHome: true })).toBe(homedir());
  });
});

describe('composer flags and attachments', () => {
  test('parses CLI model lists and fuzzy-matches /model queries', () => {
    const oc = parseAgentModelList(
      'opencode/deepseek-v4-flash-free\nopencode/mimo-v2.5-free\n',
    );
    expect(oc).toEqual([
      { id: 'opencode/deepseek-v4-flash-free', name: 'deepseek-v4-flash-free' },
      { id: 'opencode/mimo-v2.5-free', name: 'mimo-v2.5-free' },
    ]);
    expect(matchAgentModel('mimo 2.5', oc)?.id).toBe('opencode/mimo-v2.5-free');
    expect(matchAgentModel('deepseek', oc)?.id).toContain('deepseek');

    const cursor = parseAgentModelList(
      'Available models\nauto - Auto (current, default)\ncomposer-2.5 - Composer 2.5\n',
    );
    expect(cursor.map((m) => m.id)).toEqual(['auto', 'composer-2.5']);
    expect(cursor[0]!.name).toBe('Auto');

    const agy = parseAgentModelList(
      'gemini-3.7-flash-high\tGemini 3.7 Flash (High)\nclaude-sonnet-4-6\tClaude Sonnet 4.6\n',
    );
    expect(agy).toEqual([
      { id: 'gemini-3.7-flash-high', name: 'Gemini 3.7 Flash (High)' },
      { id: 'claude-sonnet-4-6', name: 'Claude Sonnet 4.6' },
    ]);
  });

  test('collapses thinking variants into a family and picks one at prompt time', () => {
    expect(modelFamilyId('claude-opus-5-thinking-high')).toBe('claude-opus-5');
    expect(modelFamilyId('gemini-3.7-flash-high')).toBe('gemini-3.7-flash');
    expect(modelFamilyId('cursor-grok-4.6-xhigh-fast')).toBe('cursor-grok-4.6');
    expect(modelFamilyId('opencode/mimo-v2.5-free')).toBe('opencode/mimo-v2.5-free');

    const catalog = [
      { id: 'claude-opus-5', name: 'Claude Opus 5' },
      { id: 'claude-opus-5-thinking-high', name: 'Claude Opus 5 High' },
      { id: 'gemini-3.7-flash-low', name: 'Gemini 3.7 Flash (Low)' },
      { id: 'gemini-3.7-flash-medium', name: 'Gemini 3.7 Flash (Medium)' },
      { id: 'gemini-3.7-flash-high', name: 'Gemini 3.7 Flash (High)' },
      { id: 'cursor-grok-4.6', name: 'Grok 4.6' },
      { id: 'cursor-grok-4.6-xhigh', name: 'Grok 4.6 Extra High' },
      { id: 'cursor-grok-4.6-xhigh-fast', name: 'Grok 4.6 Extra High Fast' },
    ];
    expect(collapseModelFamilies(catalog).map((m) => m.id)).toEqual([
      'claude-opus-5',
      'gemini-3.7-flash',
      'cursor-grok-4.6',
    ]);
    expect(pickModelVariant('claude-opus-5', 'high', catalog)).toBe(
      'claude-opus-5-thinking-high',
    );
    expect(pickModelVariant('gemini-3.7-flash', 'high', catalog)).toBe(
      'gemini-3.7-flash-high',
    );
    expect(pickModelVariant('gemini-3.7-flash', 'medium', catalog)).toBe(
      'gemini-3.7-flash-medium',
    );
    expect(pickModelVariant('cursor-grok-4.6', 'extra-high', catalog)).toBe(
      'cursor-grok-4.6-xhigh',
    );
  });
  test('maps thinking levels onto Cursor --model effort brackets', () => {
    expect(thinkingToEffort('extra-high')).toBe('high');
    expect(cursorModelFlag('auto', 'high')).toBeUndefined();
    expect(cursorModelFlag('gpt-5', 'medium')).toBe('gpt-5');
    expect(cursorModelFlag('claude-opus-4-8', 'high')).toBe('claude-opus-4-8[effort=high]');
    expect(cursorModelFlag('gpt-5', 'extra-high')).toBe('gpt-5[effort=high,fast=false]');
  });

  test('builds Cursor / OpenCode / Claude / Antigravity argv from composer opts', () => {
    const cursor = buildCursorArgv({
      bin: 'cursor-agent',
      cwd: '/tmp/proj',
      chatId: 'abc',
      text: 'fix the bug',
      model: 'gpt-5',
      mode: 'plan',
      thinking: 'high',
      imagePaths: ['/tmp/shot.jpg'],
    });
    expect(cursor).toContain('--mode');
    expect(cursor).toContain('plan');
    expect(cursor).toContain('--model');
    expect(cursor).toContain('gpt-5[effort=high]');
    expect(cursor).toContain('--resume');
    expect(cursor.at(-1)).toContain('@/tmp/shot.jpg');

    const oc = buildOpencodeArgv({
      bin: 'opencode',
      cwd: '/tmp/proj',
      text: 'hi',
      mode: 'plan',
      thinking: 'max',
      imagePaths: ['/tmp/a.png'],
    });
    expect(oc).toContain('--agent');
    expect(oc).toContain('--variant');
    expect(oc).toContain('max');
    expect(oc).toContain('--file');
    expect(oc).toContain('/tmp/a.png');

    const agy = buildAgyArgv({
      bin: 'agy',
      cwd: '/tmp/proj',
      text: 'plan this',
      mode: 'plan',
      thinking: 'low',
      newProject: true,
    });
    expect(agy).toContain('--mode');
    expect(agy).toContain('--effort');
    expect(agy).toContain('low');
    expect(agy).toContain('--add-dir');
    expect(agy).toContain('/tmp/proj');
    expect(agy).toContain('--new-project');
    expect(agy).not.toContain('--conversation');

    const agyResume = buildAgyArgv({
      bin: 'agy',
      cwd: '/tmp/proj',
      conversationId: 'conv-1',
      projectId: 'proj-9',
      newProject: true,
      text: 'continue',
    });
    expect(agyResume).toContain('--conversation');
    expect(agyResume).toContain('conv-1');
    expect(agyResume).toContain('--project');
    expect(agyResume).toContain('proj-9');
    expect(agyResume).not.toContain('--new-project');

    const agyClaude = buildAgyArgv({
      bin: 'agy',
      cwd: '/tmp/proj',
      text: 'hi',
      model: 'claude-sonnet-4-6',
      thinking: 'high',
    });
    expect(agyClaude).toContain('--model');
    expect(agyClaude).not.toContain('--effort');
    expect(agyEffortFlag('claude-sonnet-4-6', 'high')).toBeUndefined();
    expect(agyEffortFlag('gemini-3.7-flash', 'high')).toBe('high');

    const cursorResolved = buildCursorArgv({
      bin: 'cursor-agent',
      cwd: '/tmp/proj',
      text: 'hi',
      model: 'claude-opus-5',
      thinking: 'high',
      catalog: [
        { id: 'claude-opus-5', name: 'Opus 5' },
        { id: 'claude-opus-5-thinking-high', name: 'Opus 5 High' },
      ],
    });
    expect(cursorResolved).toContain('claude-opus-5-thinking-high');
    expect(cursorResolved.some((a) => a.includes('[effort='))).toBe(false);

    const agyResolved = buildAgyArgv({
      bin: 'agy',
      text: 'hi',
      model: 'gemini-3.7-flash',
      thinking: 'high',
      catalog: [
        { id: 'gemini-3.7-flash-medium', name: 'Flash Medium' },
        { id: 'gemini-3.7-flash-high', name: 'Flash High' },
      ],
    });
    expect(agyResolved).toContain('gemini-3.7-flash-high');
    expect(agyResolved).toContain('--effort');
    expect(agyResolved).toContain('high');

    const claude = claudeSpawnArgs({ bin: 'claude', mode: 'plan', model: 'opus', thinking: 'high' });
    expect(claude).toContain('--permission-mode');
    expect(claude).toContain('plan');
    expect(claude).toContain('--model');
    expect(claude).toContain('opus');
    expect(claude).toContain('--effort');
    expect(claudeUserContent('look', [{ mime: 'image/jpeg', data: 'abc' }])).toEqual([
      { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: 'abc' } },
      { type: 'text', text: 'look' },
    ]);
    expect(withImageMentions('hi', ['/a.jpg'])).toBe('hi\n\n@/a.jpg');
  });

  test('writes phone photos to a host inbox and forwards them to the mock agent', async () => {
    const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xd9]).toString('base64');
    const staged = materializeAgentImages('test-session', [
      { name: 'shot.jpg', mime: 'image/jpeg', data: jpeg },
    ]);
    expect(staged.paths).toHaveLength(1);
    expect(staged.files[0]!.name).toBe('shot.jpg');
    expect(await Bun.file(staged.paths[0]!).exists()).toBe(true);

    const pushed: AgentEvent[] = [];
    setAgentBroadcast((msg: WsMessage) => {
      if (msg.type === 'agent-event') pushed.push(msg.event);
    });
    const info = createAgentSession('mock', '/tmp', 'Photos');
    expect(promptAgent(info.agentSessionId, '  ', {}).ok).toBe(false);
    expect(promptAgent(info.agentSessionId, '', {
      mode: 'plan',
      thinking: 'high',
      model: 'demo',
      images: [{ name: 'shot.jpg', mime: 'image/jpeg', data: jpeg }],
    }).ok).toBe(true);

    const deadline = Date.now() + 5000;
    while (!pushed.some((e) => e.kind === 'permission-request') && Date.now() < deadline) {
      await Bun.sleep(50);
    }
    expect(pushed[0]?.kind).toBe('user');
    expect(pushed[0]?.images).toEqual(['shot.jpg']);
    expect(resolveAgentPermission(info.agentSessionId, 'mock-perm', true).ok).toBe(true);
    while (!pushed.some((e) => e.kind === 'result') && Date.now() < deadline) {
      await Bun.sleep(50);
    }
    const reply = pushed.find((e) => e.kind === 'text')?.text ?? '';
    expect(reply).toContain('mode=plan');
    expect(reply).toContain('thinking=high');
    expect(reply).toContain('1 photo(s)');
    closeAgentSession(info.agentSessionId);
    setAgentBroadcast(() => {});
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

    expect(
      parseCursorStreamEvent({
        type: 'tool_call',
        subtype: 'started',
        call_id: 'call-1\nfc_abc',
        tool_call: { readToolCall: { args: { path: 'a.ts' } } },
      })[0],
    ).toMatchObject({ kind: 'tool-start', refId: 'call-1fc_abc' });
    expect(
      parseCursorStreamEvent({
        type: 'system',
        subtype: 'turn_complete',
      }),
    ).toEqual([{ kind: 'result', text: '' }]);

    expect(describeCursorToolCall({ writeToolCall: { args: { path: 'a.txt' } } }).name).toBe(
      'write',
    );

    expect(formatCursorToolInput('shell', { command: 'dart analyze lib/' })).toBe(
      'dart analyze lib/',
    );
    expect(formatCursorToolInput('readLints', { paths: ['/a/page.tsx', '/b/lib.ts'] })).toBe(
      'page.tsx, lib.ts',
    );
    expect(formatCursorToolOutput('shell', { command: 'echo hi', exitCode: 0 })).toBe('');
    expect(formatCursorToolOutput('readLints', { totalDiagnostics: 0, fileDiagnostics: [] })).toBe(
      '',
    );
    expect(formatCursorToolOutput('shell', { success: { stdout: 'ok\n', exitCode: 0 } })).toBe(
      'ok',
    );

    expect(
      withoutDuplicateResult({ kind: 'result', text: "I'll read README.mdDone." }, true),
    ).toEqual({ kind: 'result', text: '' });
    expect(
      withoutDuplicateResult({ kind: 'result', text: 'only in the result event' }, false),
    ).toEqual({ kind: 'result', text: 'only in the result event' });
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
    expect(isCliAuthError('authentication failed or timed out')).toBe(true);
    expect(isCliAuthError('You are not logged into Antigravity.')).toBe(true);
    expect(isCliAuthError('Print mode: auth timed out')).toBe(true);
    const rewritten = rewriteCliAuthError(
      "Error: Authentication required. Please run 'agent login' first.",
      'Cursor CLI',
    );
    expect(rewritten).toContain("isn't signed in");
    expect(rewritten).toContain('CURSOR_API_KEY');
    expect(rewriteCliAuthError('authentication failed or timed out', 'Antigravity'))
      .toContain("isn't signed in");
  });
});
