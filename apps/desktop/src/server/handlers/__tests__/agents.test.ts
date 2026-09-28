// Agent gateway: session lifecycle, CLI stream parsers, and the mock adapter.

import { describe, expect, test } from 'bun:test';
import { homedir, tmpdir } from 'node:os';
import { existsSync, realpathSync } from 'node:fs';
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
  isInternalCliNoise,
  sanitizeCliError,
  sanitizeAgentHistory,
  closeDanglingToolStarts,
  unmatchedToolStarts,
  isRedundantToolStart,
  cursorModelFlag,
  withImageMentions,
  materializeAgentImages,
  buildCursorArgv,
  buildOpencodeArgv,
  buildAgyArgv,
  claudeSpawnArgs,
  claudeUserContent,
  thinkingToEffort,
  isSafeAgentToolCall,
  parseAgentModelList,
  matchAgentModel,
  listAgentModels,
  modelFamilyId,
  collapseModelFamilies,
  pickModelVariant,
  agyEffortFlag,
  isModelEffortSupported,
  getAgentApprovalMode,
  setAgentApprovalMode,
  resolveAgentIcon,
  resolveBin,
  spawnArgv,
} from '../agents';

const sessionCwd = existsSync('/tmp') ? '/tmp' : tmpdir();

describe('agent gateway', () => {
  test('unifies agent icons and does not scrape inconsistent host desktop icons', async () => {
    const antigravityIcon = await resolveAgentIcon('antigravity');
    expect(antigravityIcon).toBeUndefined();

    const cursorIcon = await resolveAgentIcon('cursor');
    expect(cursorIcon).toBeUndefined();

    const agents = listAgents();
    const agy = agents.find((a) => a.id === 'antigravity');
    expect(agy?.icon).toBeUndefined();
  });

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

    const info = createAgentSession('mock', sessionCwd, 'Test chat');
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
      cwd: sessionCwd,
      title: 'Project chat',
    });
    expect(info.cwd).toBe(resolveAgentCwd(sessionCwd));
    const moved = openHostChat({
      agent: 'mock',
      hostChatId: 'host-cwd',
      cwd: homedir(),
    });
    expect(moved.agentSessionId).toBe(info.agentSessionId);
    expect(moved.cwd).toBe(resolveAgentCwd(homedir()));
    const again = setAgentSessionCwd(info.agentSessionId, sessionCwd);
    expect(again.cwd).toBe(resolveAgentCwd(sessionCwd));
    const kept = openHostChat({ agent: 'mock', hostChatId: 'host-cwd' });
    expect(kept.agentSessionId).toBe(info.agentSessionId);
    expect(kept.cwd).toBe(resolveAgentCwd(sessionCwd));
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
    const home = realpathSync(homedir()).replace(/\\/g, '/');
    expect(resolveAgentCwd('~')).toBe(home);
    expect(resolveAgentCwd()).toBe(home);
    expect(resolveAgentCwd(sessionCwd)).toBe(realpathSync(sessionCwd).replace(/\\/g, '/'));
    expect(() => resolveAgentCwd('/this/path-does-not-exist-nexuslink')).toThrow(/directory not found/);
    expect(resolveAgentCwd('/this-path-does-not-exist-nexuslink', { fallbackHome: true })).toBe(homedir().replace(/\\/g, '/'));
  });

  test('resolves CLI names with PATH delimiters and Windows script wrappers', () => {
    expect(spawnArgv(['claude', '-p'])).toEqual(['claude', '-p']);
    if (process.platform === 'win32') {
      const wrapped = spawnArgv(['C:\\tools\\cursor-agent.cmd', 'login']);
      expect(wrapped[0]).toBe('cmd.exe');
      expect(wrapped).toContain('C:\\tools\\cursor-agent.cmd');
      expect(resolveBin('cursor-agent')).toBeTruthy();
      const agyHome = process.env.LOCALAPPDATA;
      if (agyHome && existsSync(`${agyHome}\\agy\\bin\\agy.exe`)) {
        expect(resolveBin('agy')).toMatch(/agy\.exe$/i);
      }
    }
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

  test('resolves Grok 4.6 to a concrete CLI slug, never bare family id', () => {
    const liveLike = [
      { id: 'cursor-grok-4.6-low', name: 'Grok 4.6 Low' },
      { id: 'cursor-grok-4.6-medium', name: 'Grok 4.6 Medium' },
      { id: 'cursor-grok-4.6-high', name: 'Grok 4.6 High' },
      { id: 'cursor-grok-4.6-xhigh', name: 'Grok 4.6 Extra High' },
    ];
    expect(pickModelVariant('cursor-grok-4.6', 'medium', liveLike)).toBe(
      'cursor-grok-4.6-medium',
    );
    const argv = buildCursorArgv({
      bin: 'cursor-agent',
      cwd: '/tmp/proj',
      text: 'hi',
      model: 'cursor-grok-4.6',
      thinking: 'medium',
      catalog: liveLike,
    });
    expect(argv).toContain('cursor-grok-4.6-medium');
    expect(argv).not.toContain('cursor-grok-4.6');
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
    expect(agy).toContain('--dangerously-skip-permissions');
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

    const claudeOpus = claudeSpawnArgs({ bin: 'claude', mode: 'plan', model: 'opus', thinking: 'high' });
    expect(claudeOpus).toContain('--permission-mode');
    expect(claudeOpus).toContain('plan');
    expect(claudeOpus).toContain('--model');
    expect(claudeOpus).toContain('opus');
    expect(claudeOpus).not.toContain('--effort');

    const claudeSonnet = claudeSpawnArgs({ bin: 'claude', mode: 'agent', model: 'sonnet', thinking: 'high' });
    expect(claudeSonnet).toContain('--model');
    expect(claudeSonnet).toContain('sonnet');
    expect(claudeSonnet).toContain('--effort');
    expect(claudeSonnet).toContain('high');

    expect(isModelEffortSupported('antigravity', 'gemini-3.7-flash')).toBe(true);
    expect(isModelEffortSupported('antigravity', 'claude-sonnet-4-6')).toBe(false);
    expect(isModelEffortSupported('claude', 'sonnet')).toBe(true);
    expect(isModelEffortSupported('claude', 'opus')).toBe(false);
    expect(isModelEffortSupported('cursor', 'auto')).toBe(false);
    expect(isModelEffortSupported('cursor', 'composer-2.5')).toBe(true);

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
    const info = createAgentSession('mock', sessionCwd, 'Photos');
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
    expect(formatCursorToolInput('createPlan', { plan: '# Implementation Plan\n\n1. Step 1' })).toBe(
      'Implementation Plan',
    );
    expect(formatCursorToolInput('createPlan', { path: '/tmp/PLAN.md' })).toBe('/tmp/PLAN.md');
    expect(formatCursorToolOutput('createPlan', { plan: '# Done plan' })).toBe('# Done plan');

    const planEvent = parseCursorStreamEvent({
      type: 'tool_call',
      subtype: 'started',
      call_id: 'tool_plan_1',
      tool_call: { createPlanToolCall: { args: { plan: '# Voice Mode Plan' } } },
    });
    expect(planEvent[0]).toMatchObject({
      kind: 'tool-start',
      toolName: 'createPlan',
      refId: 'tool_plan_1',
    });
    expect(planEvent[0]!.toolInput).toContain('Voice Mode Plan');

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
          state: 'ACTIVE',
          step_type: 'tool',
          tool_name: 'task',
          tool_info: {
            name: 'task',
            parameters: { CommandLine: 'git checkout v1.0.30+36' },
          },
        },
      }),
    ).toEqual([{
      kind: 'tool-start',
      toolName: 'task',
      toolInput: JSON.stringify({ CommandLine: 'git checkout v1.0.30+36' }, null, 2).slice(0, 4000),
      refId: '4',
    }]);

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
    ).toEqual([{ kind: 'error', text: rewriteCliAuthError('authentication required', 'Antigravity') }]);

    // Thinking and planner response
    expect(
      parseAgyStreamEvent({
        event: 'step_update',
        step_update: {
          step_type: 'thinking',
          thinking: 'Analyzing the repository architecture...',
        },
      }),
    ).toEqual([{ kind: 'thinking', text: 'Analyzing the repository architecture...' }]);

    expect(
      parseAgyStreamEvent({
        event: 'step_update',
        step_update: {
          step_type: 'planner_response',
          thinking: 'Need to run git status first',
          content: 'I will inspect the git status.',
        },
      }),
    ).toEqual([
      { kind: 'thinking', text: 'Need to run git status first' },
      { kind: 'text', text: 'I will inspect the git status.' },
    ]);

    // Permission request from agy
    expect(
      parseAgyStreamEvent({
        event: 'control_request',
        request_id: 'perm-1',
        tool_name: 'task',
        tool_input: { CommandLine: 'rm -rf node_modules' },
        reason: 'Dangerous deletion requested',
      }),
    ).toEqual([{
      kind: 'permission-request',
      toolName: 'task',
      toolInput: JSON.stringify({ CommandLine: 'rm -rf node_modules' }, null, 2),
      refId: 'perm-1',
      text: 'Dangerous deletion requested',
    }]);

    // isSafeAgentToolCall with stringified input and 'task' command tool
    const taskSafety = isSafeAgentToolCall(
      'task',
      JSON.stringify({ CommandLine: 'git push origin main' }),
      sessionCwd,
    );
    expect(taskSafety.safe).toBe(false);
    expect(taskSafety.reason).toContain('Git action requested');
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

  test('detects and cleans internal CLI / cortex tool noise', () => {
    const cortexNoise =
      'declaring permissions: cortex tool write_to_file: convert tool call for permissions: model output error: invalid tool call error (invalid_args) /path/to/file.dart is not a valid artifact path; artifacts must be in /home/user/.gemini/antigravity-cli/brain/abc/';
    expect(isInternalCliNoise(cortexNoise)).toBe(true);
    expect(isInternalCliNoise('Real syntax error in code')).toBe(false);

    expect(sanitizeCliError(cortexNoise, 'Antigravity')).toBe(
      '/path/to/file.dart is not a valid artifact path; artifacts must be in /home/user/.gemini/antigravity-cli/brain/abc/',
    );

    const history: AgentEvent[] = [
      { seq: 1, ts: 1000, kind: 'user', text: 'hi' },
      { seq: 2, ts: 1001, kind: 'text', text: 'hello' },
      { seq: 3, ts: 1002, kind: 'error', text: cortexNoise },
      { seq: 4, ts: 1003, kind: 'result', text: '' },
    ];
    expect(sanitizeAgentHistory(history)).toEqual([
      { seq: 1, ts: 1000, kind: 'user', text: 'hi' },
      { seq: 2, ts: 1001, kind: 'text', text: 'hello' },
      { seq: 4, ts: 1003, kind: 'result', text: '' },
    ]);
  });

  test('closeDanglingToolStarts ends a tool-start left open after host restart', () => {
    const history: AgentEvent[] = [
      { seq: 1, ts: 1, kind: 'tool-start', toolName: 'shell', toolInput: 'kill', refId: 't1' },
    ];
    const settled = closeDanglingToolStarts(history, 'Interrupted — host restarted.');
    expect(settled).toHaveLength(2);
    expect(settled[1]).toMatchObject({
      kind: 'tool-end',
      refId: 't1',
      toolOutput: 'Interrupted — host restarted.',
    });
  });

  test('closeDanglingToolStarts ends every duplicate-ref start', () => {
    const history: AgentEvent[] = [
      { seq: 1, ts: 1, kind: 'tool-start', toolName: 'task', refId: 'task' },
      { seq: 2, ts: 2, kind: 'tool-start', toolName: 'task', refId: 'task' },
      { seq: 3, ts: 3, kind: 'tool-start', toolName: 'task', refId: 'task' },
    ];
    expect(unmatchedToolStarts(history)).toHaveLength(3);
    const settled = closeDanglingToolStarts(history, 'Stopped.');
    expect(unmatchedToolStarts(settled)).toHaveLength(0);
    expect(settled.filter((e) => e.kind === 'tool-end')).toHaveLength(3);
  });

  test('isRedundantToolStart skips a second ACTIVE for an in-flight ref', () => {
    const history: AgentEvent[] = [
      { seq: 1, ts: 1, kind: 'tool-start', toolName: 'task', refId: '4' },
    ];
    expect(isRedundantToolStart(history, { kind: 'tool-start', refId: '4' })).toBe(true);
    expect(isRedundantToolStart(history, { kind: 'tool-start', refId: '5' })).toBe(false);
    expect(isRedundantToolStart(history, { kind: 'tool-end', refId: '4' })).toBe(false);
  });

  test('withoutDuplicateResult blanks result if text was streamed, but preserves errors', () => {
    expect(withoutDuplicateResult({ kind: 'result', text: 'full text' }, true)).toEqual({
      kind: 'result',
      text: '',
    });
    expect(withoutDuplicateResult({ kind: 'error', text: 'exit 1' }, true)).toEqual({
      kind: 'error',
      text: 'exit 1',
    });
    expect(withoutDuplicateResult({ kind: 'error', text: 'fatal error' }, false)).toEqual({
      kind: 'error',
      text: 'fatal error',
    });
  });

  describe('isSafeAgentToolCall security filter', () => {
    const cwd = '/home/user/project';

    test('auto-allows safe in-directory file tools', () => {
      expect(isSafeAgentToolCall('view_file', { AbsolutePath: '/home/user/project/src/index.ts' }, cwd).safe).toBe(true);
      expect(isSafeAgentToolCall('replace_file_content', { TargetFile: '/home/user/project/src/index.ts' }, cwd).safe).toBe(true);
      expect(isSafeAgentToolCall('grep_search', { SearchPath: '/home/user/project/src' }, cwd).safe).toBe(true);
      expect(isSafeAgentToolCall('list_dir', { DirectoryPath: '/home/user/project' }, cwd).safe).toBe(true);
      expect(isSafeAgentToolCall('ask_question', { questions: [] }, cwd).safe).toBe(true);
    });

    test('flags commands/tools targeting paths outside assigned cwd', () => {
      const out1 = isSafeAgentToolCall('view_file', { AbsolutePath: '/etc/passwd' }, cwd);
      expect(out1.safe).toBe(false);
      expect(out1.reason).toContain('outside the assigned directory');

      const out2 = isSafeAgentToolCall('write_to_file', { TargetFile: '/home/user/.ssh/id_rsa' }, cwd);
      expect(out2.safe).toBe(false);
      expect(out2.reason).toContain('outside the assigned directory');

      const out3 = isSafeAgentToolCall('run_command', { CommandLine: 'cd ../.. && ls' }, cwd);
      expect(out3.safe).toBe(false);
      expect(out3.reason).toContain('navigate outside assigned directory');
    });

    test('flags mutating git actions for permission approval while allowing read-only queries', () => {
      const git1 = isSafeAgentToolCall('run_command', { CommandLine: 'git push origin main' }, cwd);
      expect(git1.safe).toBe(false);
      expect(git1.reason).toContain('Git action requested');

      const git2 = isSafeAgentToolCall('bash', { command: 'git commit -m "update"' }, cwd);
      expect(git2.safe).toBe(false);
      expect(git2.reason).toContain('Git action requested');

      const git3 = isSafeAgentToolCall('shell', { command: 'git reset --hard HEAD' }, cwd);
      expect(git3.safe).toBe(false);

      const gitReadOnly = isSafeAgentToolCall('run_command', { CommandLine: 'git status && git log -n 10 --oneline && git branch -a' }, cwd);
      expect(gitReadOnly.safe).toBe(true);

      const gitDiff = isSafeAgentToolCall('run_command', { CommandLine: 'git diff' }, cwd);
      expect(gitDiff.safe).toBe(true);
    });

    test('flags database actions and migrations for permission approval', () => {
      const db1 = isSafeAgentToolCall('run_command', { CommandLine: 'psql -U postgres -d mydb' }, cwd);
      expect(db1.safe).toBe(false);
      expect(db1.reason).toContain('Database operation requested');

      const db2 = isSafeAgentToolCall('run_command', { CommandLine: 'npx prisma migrate dev' }, cwd);
      expect(db2.safe).toBe(false);
      expect(db2.reason).toContain('Database operation requested');

      const db3 = isSafeAgentToolCall('bash', { command: 'mysql -u root -p database' }, cwd);
      expect(db3.safe).toBe(false);

      const db4 = isSafeAgentToolCall('run_command', { CommandLine: 'redis-cli flushall' }, cwd);
      expect(db4.safe).toBe(false);
    });

    test('flags destructive commands for permission approval', () => {
      const rm = isSafeAgentToolCall('run_command', { CommandLine: 'rm -rf ./dist' }, cwd);
      expect(rm.safe).toBe(false);
      expect(rm.reason).toContain('Potentially dangerous system command');

      const sudo = isSafeAgentToolCall('run_command', { CommandLine: 'sudo apt install foo' }, cwd);
      expect(sudo.safe).toBe(false);

      const kill = isSafeAgentToolCall('bash', { command: 'kill -9 1234' }, cwd);
      expect(kill.safe).toBe(false);
    });

    test('allows harmless developer commands inside cwd', () => {
      expect(isSafeAgentToolCall('run_command', { CommandLine: 'bun test' }, cwd).safe).toBe(true);
      expect(isSafeAgentToolCall('run_command', { CommandLine: 'npm run build' }, cwd).safe).toBe(true);
      expect(isSafeAgentToolCall('run_command', { CommandLine: 'ls -la' }, cwd).safe).toBe(true);
      expect(isSafeAgentToolCall('run_command', { CommandLine: 'echo "hello"' }, cwd).safe).toBe(true);
    });
  });
});

describe('approval mode', () => {
  test('defaults to ask and rejects unknown modes', () => {
    expect(getAgentApprovalMode('claude-nonexistent-agent')).toBe('ask');
    expect(setAgentApprovalMode('claude-nonexistent-agent', 'yolo')).toEqual({ ok: false });
    // A rejected write must not change the stored value.
    expect(getAgentApprovalMode('claude-nonexistent-agent')).toBe('ask');
  });

  test('round-trips ask and auto per agent', () => {
    const agent = 'claude-nonexistent-agent';
    expect(setAgentApprovalMode(agent, 'auto')).toEqual({ ok: true, mode: 'auto' });
    expect(getAgentApprovalMode(agent)).toBe('auto');
    expect(setAgentApprovalMode(agent, 'ask')).toEqual({ ok: true, mode: 'ask' });
    expect(getAgentApprovalMode(agent)).toBe('ask');
  });

  test('is reported on agent.list so the phone can render the toggle', () => {
    try {
      // agent.list only includes known agents, so assert via a real one instead.
      const claude = listAgents().find((a) => a.id === 'claude');
      expect(claude).toBeDefined();
      expect(claude!.capabilities.approvalMode).toBe('ask');

      setAgentApprovalMode('claude', 'auto');
      const after = listAgents().find((a) => a.id === 'claude');
      expect(after!.capabilities.approvalMode).toBe('auto');
    } finally {
      setAgentApprovalMode('claude', 'ask');
    }
  });
});

describe('permission resolution honesty', () => {
  test('reports failure for an unknown session instead of pretending it worked', () => {
    const res = resolveAgentPermission('no-such-session', 'req-1', true);
    expect(res.ok).toBe(false);
    expect(res.reason).toBe('unknown session');
  });

  test('reports failure for a request that already expired', async () => {
    const info = createAgentSession('mock', sessionCwd, 'approval expiry test');
    await promptAgent(info.agentSessionId, 'hello');

    const res = resolveAgentPermission(info.agentSessionId, 'never-registered', true);
    expect(res.ok).toBe(false);
    expect(res.reason).toBe('request already expired');

    closeAgentSession(info.agentSessionId);
  });

  test('a second answer to the same request is reported as expired, not accepted', async () => {
    const pushed: AgentEvent[] = [];
    setAgentBroadcast((m: WsMessage) => {
      if (m.type === 'agent-event') pushed.push(m.event as AgentEvent);
    });

    const info = createAgentSession('mock', sessionCwd, 'double answer test');
    await promptAgent(info.agentSessionId, 'hello');

    const deadline = Date.now() + 5000;
    while (!pushed.some((e) => e.kind === 'permission-request') && Date.now() < deadline) {
      await Bun.sleep(50);
    }
    expect(pushed.some((e) => e.kind === 'permission-request')).toBe(true);

    // First answer is delivered to the adapter.
    expect(resolveAgentPermission(info.agentSessionId, 'mock-perm', true).ok).toBe(true);
    // The card can still be on screen; the retry must not look accepted.
    const second = resolveAgentPermission(info.agentSessionId, 'mock-perm', true);
    expect(second.ok).toBe(false);
    expect(second.reason).toBe('request already expired');

    closeAgentSession(info.agentSessionId);
    setAgentBroadcast(null);
  });
});

