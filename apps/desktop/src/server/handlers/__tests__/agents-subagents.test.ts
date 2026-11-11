// Code Agent sub-agents and Ultra Code: fixtures are trimmed real stream-json
// captures from `claude` 2.1.319 (see docs/AGENT-SUBAGENT-EVENTS.md).

import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { delimiter, join } from 'node:path';
import type { AgentEvent, AgentSessionInfo, WsMessage } from '@nexuslink/rpc-types';
import {
  agentHistory,
  buildAgyArgv,
  buildCodexArgv,
  buildCursorArgv,
  buildOpencodeArgv,
  cancelAgent,
  claudeSpawnArgs,
  claudeTaskStatus,
  ClaudeSubagentTracker,
  closeAgentSession,
  closeDanglingAgents,
  createAgentSession,
  cursorModelFlag,
  isResultWhileAgentsRun,
  listAgents,
  normalizeThinkingForAgent,
  promptAgent,
  resolveAgentPermission,
  runningAgentEvents,
  setAgentBroadcast,
  thinkingToEffort,
  translateClaudeEvent,
} from '../agents';

const FIXTURES = join(import.meta.dir, 'fixtures', 'claude-subagents');
type Line = Record<string, unknown>;
const fixture = (name: string): Line[] =>
  readFileSync(join(FIXTURES, name), 'utf8').split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l));

function translate(lines: Line[]) {
  const tracker = new ClaudeSubagentTracker();
  const out = lines.flatMap((l) => translateClaudeEvent(l, tracker));
  return { out, tracker };
}

const kinds = (events: Array<{ kind: string; agentId?: string }>) =>
  events.map((e) => (e.agentId ? `${e.kind}@${e.agentId}` : e.kind));

describe('claude stream: sub-agent translation (real fixtures)', () => {
  test('foreground agent: start, end on task_notification, then the spawning tool-end', () => {
    const { out, tracker } = translate(fixture('foreground.jsonl'));
    const id = 'a981023569ae6ebcf';
    expect(kinds(out)).toEqual([
      'tool-start', // main agent's Agent call
      `agent-start@${id}`,
      `agent-end@${id}`,
      'tool-end', // the spawning card ends after the agent
      'text',
    ]);
    const start = out[1]!;
    expect(start).toMatchObject({
      kind: 'agent-start', agentId: id, refId: 'toolu_017FWpGsGfNFM2DJV8N95h3S', agentName: 'Reply with pong',
      agentType: 'general-purpose', agentDepth: 1, agentBackground: false, agentStatus: 'running',
    });
    expect(start.agentPrompt).toContain('pong');
    expect(out[2]).toMatchObject({ kind: 'agent-end', agentStatus: 'completed', text: 'pong', refId: start.refId });
    expect(out[3]!.refId).toBe(start.refId);
    expect(out[4]!.agentId).toBeUndefined();
    expect(tracker.runningCount).toBe(0);
  });

  test('background agent: its tools and text carry agentId and it outlives the first result', () => {
    const lines = fixture('background.jsonl');
    const id = 'a28e4ce2f264da5bb';
    const firstResult = lines.findIndex((l) => l.type === 'result');
    const round1 = translate(lines.slice(0, firstResult + 1));
    expect(round1.tracker.runningCount).toBe(1);
    const { out, tracker } = translate(lines);
    expect(kinds(out)).toEqual([
      'thinking',
      'tool-start',
      `agent-start@${id}`,
      'tool-end', // "Async agent launched" — the card ends, the agent runs on
      'text', // "launched"
      `tool-start@${id}`, // sub-agent's Bash
      `agent-update@${id}`,
      `tool-end@${id}`,
      `text@${id}`,
      `agent-end@${id}`,
      'thinking', // second round, started by the CLI
      'text',
    ]);
    expect(out[2]).toMatchObject({ agentBackground: true, agentDepth: 1 });
    expect(out[6]).toMatchObject({ kind: 'agent-update', text: 'Running Sleep 6 seconds then echo bg-done', toolName: 'Bash', agentStatus: 'running' });
    expect(out[9]).toMatchObject({ kind: 'agent-end', agentStatus: 'completed' });
    expect(out[9]!.text).toContain('finished');
    // The sub-agent's own background shell (task_type local_bash) is not an agent.
    expect(out.filter((e) => e.kind === 'agent-start')).toHaveLength(1);
    expect(tracker.runningCount).toBe(0);
  });

  test('Ultra Code run produces the same event shapes', () => {
    const { out } = translate(fixture('ultracode-background.jsonl'));
    const agentKinds = out.filter((e) => e.kind.startsWith('agent-')).map((e) => e.kind);
    expect(agentKinds).toEqual(['agent-start', 'agent-update', 'agent-end']);
    expect(out.filter((e) => e.kind === 'text' && !e.agentId)).toHaveLength(2);
  });

  test('nested agents: depth 2 names its parent and ends first', () => {
    const { out } = translate(fixture('nested-permission.jsonl'));
    const outer = 'a5e3038f0d177146a';
    const inner = 'a9462576fd733b1e6';
    const agentEvents = out.filter((e) => e.kind.startsWith('agent-'));
    expect(kinds(agentEvents)).toEqual([
      `agent-start@${outer}`, `agent-update@${outer}`, `agent-start@${inner}`, `agent-update@${inner}`,
      `agent-end@${inner}`, `agent-end@${outer}`,
    ]);
    expect(agentEvents[2]).toMatchObject({ agentDepth: 2, agentParentId: outer, refId: 'toolu_013MBeHPxxAyXR2uRGHSdHT5' });
    // The outer agent's Agent call is a tool card of the outer agent.
    expect(out.find((e) => e.kind === 'tool-start' && e.agentId === outer)?.refId).toBe('toolu_013MBeHPxxAyXR2uRGHSdHT5');
  });

  test('a message from an unannounced agent synthesizes the start; task_started then only updates', () => {
    const tracker = new ClaudeSubagentTracker();
    const msg = {
      type: 'assistant', parent_tool_use_id: 'tu-x', agent_id: 'task-x', subagent_type: 'Explore', task_description: 'Look around',
      message: { content: [{ type: 'text', text: 'hi from the agent' }] },
    };
    const first = translateClaudeEvent(msg, tracker);
    expect(kinds(first)).toEqual(['agent-start@task-x', 'text@task-x']);
    expect(first[0]).toMatchObject({ refId: 'tu-x', agentType: 'Explore', agentName: 'Look around' });
    const started = translateClaudeEvent({
      type: 'system', subtype: 'task_started', task_id: 'task-x', tool_use_id: 'tu-x', description: 'Look around',
      subagent_type: 'Explore', is_backgrounded: true, spawn_depth: 1, task_type: 'local_agent',
    }, tracker);
    expect(kinds(started)).toEqual(['agent-update@task-x']);
    expect(started[0]!.agentBackground).toBe(true);
  });

  test('an agent continued after it ended starts again under the same agentId', () => {
    const tracker = new ClaudeSubagentTracker();
    const start = (tool: string) => ({ type: 'system', subtype: 'task_started', task_id: 'a1', tool_use_id: tool, description: 'Job', task_type: 'local_agent', spawn_depth: 1 });
    expect(kinds(translateClaudeEvent(start('tu-1'), tracker))).toEqual(['agent-start@a1']);
    expect(kinds(translateClaudeEvent({ type: 'system', subtype: 'task_notification', task_id: 'a1', status: 'completed', summary: 'done' }, tracker))).toEqual(['agent-end@a1']);
    // Late progress for an ended agent is dropped.
    expect(translateClaudeEvent({ type: 'system', subtype: 'task_progress', task_id: 'a1', description: 'late' }, tracker)).toEqual([]);
    const again = translateClaudeEvent(start('tu-2'), tracker);
    expect(kinds(again)).toEqual(['agent-start@a1']);
    expect(again[0]!.refId).toBe('tu-2');
  });

  test('task status mapping and endAll', () => {
    expect(claudeTaskStatus('completed')).toBe('completed');
    expect(claudeTaskStatus('failed')).toBe('failed');
    expect(claudeTaskStatus('error')).toBe('failed');
    expect(claudeTaskStatus('killed')).toBe('stopped');
    expect(claudeTaskStatus('stopped')).toBe('stopped');
    const { tracker } = translate(fixture('nested-permission.jsonl').slice(0, 12));
    expect(tracker.runningCount).toBe(2);
    const ends = tracker.endAll('stopped', 'Stopped.');
    expect(ends.map((e) => [e.agentDepth, e.agentStatus, e.text])).toEqual([[2, 'stopped', 'Stopped.'], [1, 'stopped', 'Stopped.']]);
    expect(tracker.runningCount).toBe(0);
  });

  test('main-agent events stay exactly as before (no agentId key)', () => {
    const { out } = translate(fixture('foreground.jsonl'));
    expect(Object.keys(out[0]!).sort()).toEqual(['kind', 'refId', 'toolInput', 'toolName']);
    expect(Object.keys(out[4]!).sort()).toEqual(['kind', 'text']);
  });
});

describe('replay helpers', () => {
  const base = { seq: 0, ts: 1 } as const;
  test('closeDanglingAgents ends running agents with stopped, deepest first', () => {
    const history: AgentEvent[] = [
      { ...base, seq: 1, kind: 'agent-start', agentId: 'a', refId: 'r1', agentDepth: 1, agentBackground: true, agentStatus: 'running', turnId: 't' },
      { ...base, seq: 2, kind: 'agent-start', agentId: 'b', refId: 'r2', agentDepth: 2, agentParentId: 'a', agentStatus: 'running' },
      { ...base, seq: 3, kind: 'agent-update', agentId: 'a', refId: 'r1', agentDepth: 1, agentBackground: true, agentStatus: 'running', text: 'busy' },
      { ...base, seq: 4, kind: 'agent-start', agentId: 'c', refId: 'r3', agentDepth: 1, agentStatus: 'running' },
      { ...base, seq: 5, kind: 'agent-end', agentId: 'c', refId: 'r3', agentDepth: 1, agentStatus: 'completed' },
    ];
    expect(runningAgentEvents(history).map((e) => e.agentId).sort()).toEqual(['a', 'b']);
    const closed = closeDanglingAgents(history);
    const extra = closed.slice(history.length);
    expect(extra.map((e) => [e.seq, e.kind, e.agentId, e.agentStatus])).toEqual([[6, 'agent-end', 'b', 'stopped'], [7, 'agent-end', 'a', 'stopped']]);
    expect(extra[1]).toMatchObject({ refId: 'r1', agentBackground: true, text: 'Interrupted — host restarted.', turnId: 't' });
    expect(closeDanglingAgents(closed)).toBe(closed);
  });

  test('a restarted host replays stopped agents and closed sub-agent tools from storage', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'nexuslink-replay-'));
    try {
      const events = [
        { seq: 1, ts: 1, kind: 'user', text: 'go', turnId: 't1' },
        { seq: 2, ts: 2, kind: 'tool-start', toolName: 'Agent', refId: 'tu1', turnId: 't1' },
        { seq: 3, ts: 3, kind: 'agent-start', agentId: 'a1', refId: 'tu1', agentName: 'Bg job', agentType: 'general-purpose', agentDepth: 1, agentBackground: true, agentStatus: 'running', turnId: 't1' },
        { seq: 4, ts: 4, kind: 'tool-end', refId: 'tu1', toolOutput: 'launched', turnId: 't1' },
        { seq: 5, ts: 5, kind: 'tool-start', toolName: 'Bash', refId: 'tu2', agentId: 'a1', turnId: 't1' },
        { seq: 6, ts: 6, kind: 'result', text: '', turnId: 't1' },
      ];
      const proc = Bun.spawn([process.execPath, join(import.meta.dir, 'fixtures', 'restart-replay.ts')], {
        env: { ...process.env, NEXUSLINK_DATA_DIR: dir, NEXUSLINK_DISABLE_PUSH: '1', NEXUSLINK_DISABLE_CHAT_DISCOVERY: '1', NODE_ENV: 'test', REPLAY_EVENTS: JSON.stringify(events) },
        stdout: 'pipe', stderr: 'pipe',
      });
      const [code, stdout, stderr] = await Promise.all([proc.exited, new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
      expect({ code, stderr: code ? stderr : '' }).toEqual({ code: 0, stderr: '' });
      const result = JSON.parse(stdout.trim().split('\n').at(-1)!) as { sessions: AgentSessionInfo[]; stored: AgentEvent[]; memory: AgentEvent[] };
      expect(result.sessions[0]!.runningAgents).toBe(0);
      for (const history of [result.stored, result.memory]) {
        expect(history.find((e) => e.seq === 3)).toMatchObject({ kind: 'agent-start', agentId: 'a1', agentBackground: true, agentDepth: 1, agentType: 'general-purpose' });
        expect(history.find((e) => e.seq === 5)?.agentId).toBe('a1');
        const tail = history.filter((e) => e.seq > 6);
        expect(tail.map((e) => [e.kind, e.refId, e.agentId ?? null, e.agentStatus ?? null])).toEqual([
          ['tool-end', 'tu2', null, null],
          ['agent-end', 'tu1', 'a1', 'stopped'],
        ]);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 20000);
});

describe('Ultra Code', () => {
  test('claude passes --effort ultracode for every Code Agent model', () => {
    const effortOf = (argv: string[]) => (argv.includes('--effort') ? argv[argv.indexOf('--effort') + 1] : undefined);
    for (const model of ['sonnet', 'opus', 'haiku', 'default', undefined]) {
      expect(effortOf(claudeSpawnArgs({ bin: 'claude', model, thinking: 'ultracode' }))).toBe('ultracode');
    }
    // Opus and Haiku used to get no --effort at all; now low/high reach them too.
    expect(effortOf(claudeSpawnArgs({ bin: 'claude', model: 'opus', thinking: 'low' }))).toBe('low');
    expect(effortOf(claudeSpawnArgs({ bin: 'claude', model: 'haiku', thinking: 'high' }))).toBe('high');
    expect(effortOf(claudeSpawnArgs({ bin: 'claude', model: 'opus', thinking: 'medium' }))).toBeUndefined();
    // Unchanged: other levels (xhigh/max still collapse to high for claude).
    expect(claudeSpawnArgs({ bin: 'claude', model: 'sonnet', thinking: 'max' })).toContain('high');
    expect(claudeSpawnArgs({ bin: 'claude', model: 'sonnet', thinking: 'medium' })).not.toContain('--effort');
  });

  test('other providers get their own highest level, never "ultracode"', () => {
    expect(normalizeThinkingForAgent('claude', 'ultracode')).toBe('ultracode');
    expect(normalizeThinkingForAgent('claude', 'high')).toBe('high');
    expect(normalizeThinkingForAgent('cursor', 'ultracode')).toBe('max');
    expect(normalizeThinkingForAgent('opencode', 'ultracode')).toBe('max');
    expect(normalizeThinkingForAgent('antigravity', 'ultracode')).toBe('high');
    expect(normalizeThinkingForAgent('codex', 'ultracode')).toBe('high');
    expect(normalizeThinkingForAgent('mock', 'ultracode')).toBe('extra-high');
    expect(normalizeThinkingForAgent('cursor', 'low')).toBe('low');
    expect(normalizeThinkingForAgent('cursor', undefined)).toBeUndefined();
    // Builders called directly with the raw value still never pass it on.
    expect(thinkingToEffort('ultracode')).toBe('high');
    expect(cursorModelFlag('composer-2.5', 'ultracode')).toBe(cursorModelFlag('composer-2.5', 'max'));
    const oc = buildOpencodeArgv({ bin: 'opencode', cwd: '/tmp', text: 'x', thinking: 'ultracode' });
    expect(oc.slice(oc.indexOf('--variant'), oc.indexOf('--variant') + 2)).toEqual(['--variant', 'max']);
    const agy = buildAgyArgv({ bin: 'agy', text: 'x', model: 'gemini-3.1-pro', thinking: 'ultracode' });
    expect(agy.slice(agy.indexOf('--effort'), agy.indexOf('--effort') + 2)).toEqual(['--effort', 'high']);
    expect(buildCodexArgv({ bin: 'codex', cwd: '/tmp', text: 'x', thinking: 'ultracode' })).toContain('model_reasoning_effort="high"');
    const cursor = buildCursorArgv({ bin: 'cursor-agent', cwd: '/tmp', text: 'x', model: 'composer-2.5', thinking: 'ultracode' });
    expect(cursor.join(' ')).not.toContain('ultracode');
    // Existing values are unchanged.
    expect(['low', 'minimal', 'medium', 'high', 'extra-high', 'max', 'xhigh', 'off'].map((t) => thinkingToEffort(t)))
      .toEqual(['low', 'low', 'medium', 'high', 'high', 'high', 'high', undefined]);
  });

  test('advertised per Code Agent model, not in the agent-wide levels', () => {
    const agents = listAgents();
    const claude = agents.find((a) => a.id === 'claude')!;
    expect(claude.capabilities.thinkingLevels).toEqual(['low', 'medium', 'high']);
    const levels = Object.fromEntries(claude.capabilities.models.map((m) => [m.id, m.thinkingLevels]));
    expect(levels.default).toEqual(['low', 'medium', 'high', 'ultracode']);
    expect(levels.sonnet).toEqual(['low', 'medium', 'high', 'ultracode']);
    expect(levels.opus).toEqual(['low', 'medium', 'high', 'ultracode']);
    expect(levels.haiku).toEqual(['low', 'medium', 'high', 'ultracode']);
    expect(claude.capabilities.models.every((m) => m.supportsEffort === true)).toBe(true);
    for (const agent of agents.filter((a) => a.id !== 'claude')) {
      expect(agent.capabilities.thinkingLevels).not.toContain('ultracode');
      expect(agent.capabilities.models.every((m) => m.thinkingLevels === undefined)).toBe(true);
    }
  });
});

test('push: a result while agents run is not "done"', () => {
  expect(isResultWhileAgentsRun({ kind: 'result' }, { runningAgents: 1 })).toBe(true);
  expect(isResultWhileAgentsRun({ kind: 'result' }, { runningAgents: 0 })).toBe(false);
  expect(isResultWhileAgentsRun({ kind: 'result' }, {})).toBe(false);
  expect(isResultWhileAgentsRun({ kind: 'permission-request' }, { runningAgents: 2 })).toBe(false);
});

// ---------------------------------------------------------------------------
// The real ClaudeAdapter against a fake `claude` that replays the fixtures.
// ---------------------------------------------------------------------------

describe('ClaudeAdapter with sub-agents (fake claude binary)', () => {
  const root = mkdtempSync(join(tmpdir(), 'nexuslink-fake-claude-'));
  const binDir = join(root, 'bin');
  const work = join(root, 'work');
  const oldPath = process.env.PATH;
  let messages: WsMessage[] = [];
  const opened: string[] = [];

  beforeAll(() => {
    Bun.spawnSync(['mkdir', '-p', binDir, work]);
    const wrapper = join(binDir, 'claude');
    writeFileSync(wrapper, `#!/bin/sh\nexec "${process.execPath}" "${join(import.meta.dir, 'fixtures', 'fake-claude.ts')}" "$@"\n`);
    chmodSync(wrapper, 0o755);
    process.env.PATH = `${binDir}${delimiter}${oldPath ?? ''}`;
  });

  afterAll(() => {
    for (const id of opened) closeAgentSession(id);
    process.env.PATH = oldPath;
    delete process.env.FAKE_CLAUDE_SCRIPT;
    delete process.env.FAKE_CLAUDE_ARGV;
    delete process.env.FAKE_CLAUDE_STDIN;
    setAgentBroadcast(() => {});
    rmSync(root, { recursive: true, force: true });
  });

  function start(name: string, script: Line[]): string {
    const file = join(root, `${name}.jsonl`);
    writeFileSync(file, script.map((l) => JSON.stringify(l)).join('\n') + '\n');
    process.env.FAKE_CLAUDE_SCRIPT = file;
    process.env.FAKE_CLAUDE_ARGV = join(root, `${name}.argv.json`);
    process.env.FAKE_CLAUDE_STDIN = join(root, `${name}.stdin.jsonl`);
    messages = [];
    setAgentBroadcast((m) => messages.push(m));
    const info = createAgentSession('claude', work, name);
    opened.push(info.agentSessionId);
    return info.agentSessionId;
  }

  const events = (id: string) => messages
    .filter((m): m is Extract<WsMessage, { type: 'agent-event' }> => m.type === 'agent-event' && m.agentSessionId === id)
    .map((m) => m.event);
  const updates = (id: string) => messages
    .filter((m): m is Extract<WsMessage, { type: 'agent-session-update' }> => m.type === 'agent-session-update' && m.session.agentSessionId === id)
    .map((m) => m.session);
  const lastInfo = (id: string) => updates(id).at(-1)!;

  async function waitFor(what: string, check: () => boolean, ms = 8000): Promise<void> {
    const until = Date.now() + ms;
    while (!check()) {
      if (Date.now() > until) throw new Error(`timed out waiting for ${what}`);
      await Bun.sleep(10);
    }
  }
  const count = (id: string, kind: string) => events(id).filter((e) => e.kind === kind).length;
  const splitAfterFirstResult = (lines: Line[]) => {
    const i = lines.findIndex((l) => l.type === 'result');
    return [lines.slice(0, i + 1), lines.slice(i + 1)] as const;
  };

  test('foreground agent end to end', async () => {
    const id = start('fg', fixture('foreground.jsonl'));
    expect(promptAgent(id, 'spawn one agent').ok).toBe(true);
    await waitFor('result', () => count(id, 'result') === 1);
    await Bun.sleep(30);
    const seen = events(id);
    expect(kinds(seen)).toEqual([
      'user', 'status', 'tool-start', 'agent-start@a981023569ae6ebcf', 'agent-end@a981023569ae6ebcf', 'tool-end', 'text', 'result',
    ]);
    expect(lastInfo(id)).toMatchObject({ busy: false, runningAgents: 0 });
    // agent-start / agent-end each push a session update with the count.
    const counts = updates(id).map((s) => s.runningAgents).filter((n) => n !== undefined);
    expect(counts).toContain(1);
    expect(agentHistory(id).filter((e) => e.agentId).map((e) => e.kind)).toEqual(['agent-start', 'agent-end']);
  });

  test('background agent: phone can send after the first result; second round arrives normally', async () => {
    const [round1, rest] = splitAfterFirstResult(fixture('background.jsonl'));
    const id = start('bg', [...round1, { __fake: 'wait_stdin' }, ...rest]);
    promptAgent(id, 'start a background agent');
    await waitFor('first result', () => count(id, 'result') === 1);
    await Bun.sleep(30);
    expect(lastInfo(id)).toMatchObject({ busy: false, runningAgents: 1, taskState: 'completed' });
    // Its Bash tool is still open, and a history read must not close it.
    expect(agentHistory(id).some((e) => e.kind === 'tool-end' && e.toolOutput === 'Interrupted — host restarted.')).toBe(false);
    // A new message is allowed while the background agent works.
    expect(promptAgent(id, 'how is it going?').ok).toBe(true);
    await waitFor('second result', () => count(id, 'result') === 2);
    await Bun.sleep(30);
    const seen = events(id);
    const agentId = 'a28e4ce2f264da5bb';
    const end = seen.findIndex((e) => e.kind === 'agent-end');
    const secondResult = seen.findLastIndex((e) => e.kind === 'result');
    expect(end).toBeGreaterThan(-1);
    expect(end).toBeLessThan(secondResult);
    expect(seen[end]).toMatchObject({ agentId, agentStatus: 'completed', agentBackground: true });
    // Round two's text is a main-agent event; the duplicate result text is dropped.
    const roundTwoText = seen.slice(end).find((e) => e.kind === 'text');
    expect(roundTwoText?.agentId).toBeUndefined();
    expect(roundTwoText?.text).toContain('bg-done');
    expect(seen[secondResult]!.text).toBe('');
    expect(seen.filter((e) => e.agentId === agentId).map((e) => e.kind)).toEqual([
      'agent-start', 'tool-start', 'agent-update', 'tool-end', 'text', 'agent-end',
    ]);
    expect(lastInfo(id)).toMatchObject({ busy: false, runningAgents: 0 });
  });

  test('background round started by the CLI never marks the session busy', async () => {
    const [round1, rest] = splitAfterFirstResult(fixture('background.jsonl'));
    const id = start('bg-idle', [...round1, { __fake: 'sleep', ms: 100 }, ...rest]);
    promptAgent(id, 'start a background agent');
    await waitFor('first result', () => count(id, 'result') === 1);
    const mark = updates(id).length;
    await waitFor('second result', () => count(id, 'result') === 2);
    await Bun.sleep(30);
    expect(updates(id).slice(mark).every((s) => s.busy === false)).toBe(true);
    expect(lastInfo(id).runningAgents).toBe(0);
  });

  test('cancel while a background agent runs stops it and closes its tools', async () => {
    const [round1] = splitAfterFirstResult(fixture('background.jsonl'));
    const id = start('bg-cancel', [...round1, { __fake: 'wait_stdin' }]);
    promptAgent(id, 'start a background agent');
    await waitFor('first result', () => count(id, 'result') === 1);
    await Bun.sleep(30);
    expect(cancelAgent(id).ok).toBe(true);
    await Bun.sleep(50);
    const seen = events(id);
    expect(seen.filter((e) => e.kind === 'agent-end')).toEqual([
      expect.objectContaining({ agentId: 'a28e4ce2f264da5bb', agentStatus: 'stopped', text: 'Stopped.' }),
    ]);
    expect(lastInfo(id)).toMatchObject({ busy: false, runningAgents: 0 });
    const history = agentHistory(id);
    expect(history.some((e) => e.kind === 'tool-end' && e.refId === 'toolu_01GndPCmDvVL8kARwxEVhnB7')).toBe(true);
    expect(runningAgentEvents(history)).toEqual([]);
  });

  test('process exit after the result ends running agents without an error', async () => {
    const [round1] = splitAfterFirstResult(fixture('background.jsonl'));
    const id = start('bg-exit', [...round1, { __fake: 'sleep', ms: 30 }, { __fake: 'exit', code: 1 }]);
    promptAgent(id, 'start a background agent');
    await waitFor('agent-end', () => count(id, 'agent-end') === 1);
    await Bun.sleep(50);
    expect(events(id).find((e) => e.kind === 'agent-end')).toMatchObject({ agentStatus: 'stopped', text: 'The agent process ended.' });
    expect(count(id, 'error')).toBe(0);
    expect(lastInfo(id)).toMatchObject({ busy: false, runningAgents: 0 });
  });

  test('process exit during a foreground agent: agent stopped, then the turn error', async () => {
    const lines = fixture('foreground.jsonl');
    const cut = lines.findIndex((l) => l.subtype === 'task_started');
    const id = start('fg-exit', [...lines.slice(0, cut + 1), { __fake: 'exit', code: 3 }]);
    promptAgent(id, 'spawn one agent');
    await waitFor('error', () => count(id, 'error') === 1);
    await Bun.sleep(30);
    const tail = kinds(events(id)).slice(-2);
    expect(tail).toEqual(['agent-end@a981023569ae6ebcf', 'error']);
    expect(lastInfo(id)).toMatchObject({ busy: false, runningAgents: 0 });
  });

  test('a sub-agent permission request carries its agentId and is answered over stdin', async () => {
    const lines = fixture('nested-permission.jsonl').map((l) => {
      if (l.type !== 'control_request') return l;
      const request = l.request as Record<string, unknown>;
      return { ...l, request: { ...request, input: { command: 'rm -rf build', description: 'clean' } } };
    });
    const at = lines.findIndex((l) => l.type === 'control_request');
    const id = start('nested', [...lines.slice(0, at + 1), { __fake: 'wait_stdin' }, ...lines.slice(at + 1)]);
    promptAgent(id, 'nested agents');
    await waitFor('permission', () => count(id, 'permission-request') === 1);
    const request = events(id).find((e) => e.kind === 'permission-request')!;
    expect(request).toMatchObject({ agentId: 'a9462576fd733b1e6', toolName: 'Bash', refId: '237436a0-0e7c-46c9-abec-6aedd49d8fe5' });
    expect(resolveAgentPermission(id, request.refId!, true).ok).toBe(true);
    await waitFor('result', () => count(id, 'result') === 1);
    const stdin = readFileSync(process.env.FAKE_CLAUDE_STDIN!, 'utf8');
    expect(stdin).toContain('"request_id":"237436a0-0e7c-46c9-abec-6aedd49d8fe5"');
    expect(stdin).toContain('"behavior":"allow"');
    const agentEvents = events(id).filter((e) => e.kind.startsWith('agent-'));
    expect(agentEvents.find((e) => e.agentId === 'a9462576fd733b1e6' && e.kind === 'agent-start')).toMatchObject({ agentDepth: 2, agentParentId: 'a5e3038f0d177146a' });
    expect(lastInfo(id).runningAgents).toBe(0);
  });

  test('Ultra Code reaches the CLI and is part of the spawn key', async () => {
    const script = fixture('foreground.jsonl');
    const id = start('ultra', [...script, { __fake: 'wait_stdin' }, ...script.slice(1)]);
    promptAgent(id, 'first', { model: 'sonnet', thinking: 'high' });
    await waitFor('result', () => count(id, 'result') === 1);
    const argvFile = process.env.FAKE_CLAUDE_ARGV!;
    expect(JSON.parse(readFileSync(argvFile, 'utf8'))).toEqual(expect.arrayContaining(['--effort', 'high']));
    rmSync(argvFile);
    promptAgent(id, 'second', { model: 'sonnet', thinking: 'ultracode' });
    await waitFor('respawn', () => existsSync(argvFile));
    const argv = JSON.parse(readFileSync(argvFile, 'utf8')) as string[];
    expect(argv.slice(argv.indexOf('--effort'), argv.indexOf('--effort') + 2)).toEqual(['--effort', 'ultracode']);
    expect(argv).toContain('--resume');
  });

  test('changing effort while a background agent runs keeps the process (and the agent)', async () => {
    const [round1, rest] = splitAfterFirstResult(fixture('background.jsonl'));
    const id = start('keep', [...round1, { __fake: 'wait_stdin' }, ...rest]);
    promptAgent(id, 'start a background agent', { model: 'sonnet', thinking: 'medium' });
    await waitFor('first result', () => count(id, 'result') === 1);
    const argvFile = process.env.FAKE_CLAUDE_ARGV!;
    rmSync(argvFile);
    promptAgent(id, 'now think harder', { model: 'sonnet', thinking: 'ultracode' });
    await waitFor('second result', () => count(id, 'result') === 2);
    expect(existsSync(argvFile)).toBe(false);
    expect(events(id).some((e) => e.kind === 'status' && /Sub-agents are still running/.test(e.text ?? ''))).toBe(true);
    expect(events(id).find((e) => e.kind === 'agent-end')?.agentStatus).toBe('completed');
  });
});
