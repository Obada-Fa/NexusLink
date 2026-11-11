// How every turn of the Antigravity adapter ends, seen from the phone: busy
// goes false and a terminal event (result or error) is broadcast and stored.
// A fake `agy` replays scripts; no real provider runs.

import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { delimiter, join } from 'node:path';
import type { AgentEvent, AgentSessionInfo, WsMessage } from '@nexuslink/rpc-types';
import {
  agentHistory,
  cancelAgent,
  closeAgentSession,
  createAgentSession,
  promptAgent,
  setAgentBroadcast,
  turnLeftOpen,
} from '../agents';

type Line = Record<string, unknown>;

const init = { event: 'init', conversation_id: 'conv-turn', init: { cwd: '/tmp', tools: [] } };
const text = (t: string): Line => ({
  event: 'step_update',
  step_update: { conversation_id: 'conv-turn', step_type: 'agent_response', state: 'DONE', text: t },
});
const tool = (state: string): Line => ({
  event: 'step_update',
  step_update: { conversation_id: 'conv-turn', step_index: 3, step_type: 'tool', state, tool_name: 'run_command', tool_info: { parameters: { cmd: 'ls' } } },
});
const result = (status: string, response = '', error = ''): Line => ({
  event: 'result',
  result: { conversation_id: 'conv-turn', status, response, error, finished_reason: status },
});
const sleep = (ms: number): Line => ({ __fake: 'sleep', ms });

describe('AntigravityAdapter turn ends (fake agy)', () => {
  const root = mkdtempSync(join(tmpdir(), 'nexuslink-fake-agy-'));
  const binDir = join(root, 'bin');
  const work = join(root, 'work');
  const oldPath = process.env.PATH;
  let messages: WsMessage[] = [];
  const opened: string[] = [];

  beforeAll(() => {
    mkdirSync(binDir, { recursive: true });
    mkdirSync(work, { recursive: true });
    const wrapper = join(binDir, 'agy');
    writeFileSync(wrapper, `#!/bin/sh\nexec "${process.execPath}" "${join(import.meta.dir, 'fixtures', 'fake-agy.ts')}" "$@"\n`);
    chmodSync(wrapper, 0o755);
    process.env.PATH = `${binDir}${delimiter}${oldPath ?? ''}`;
  });

  afterAll(() => {
    for (const id of opened) closeAgentSession(id);
    process.env.PATH = oldPath;
    delete process.env.FAKE_AGY_SCRIPT;
    setAgentBroadcast(() => {});
    rmSync(root, { recursive: true, force: true });
  });

  function start(name: string, script: Line[]): string {
    const file = join(root, `${name}.jsonl`);
    writeFileSync(file, script.map((l) => JSON.stringify(l)).join('\n') + '\n');
    process.env.FAKE_AGY_SCRIPT = file;
    messages = [];
    setAgentBroadcast((m) => messages.push(m));
    const info = createAgentSession('antigravity', work, name);
    opened.push(info.agentSessionId);
    return info.agentSessionId;
  }

  const events = (id: string): AgentEvent[] => messages
    .filter((m): m is Extract<WsMessage, { type: 'agent-event' }> => m.type === 'agent-event' && m.agentSessionId === id)
    .map((m) => m.event);
  const updates = (id: string): AgentSessionInfo[] => messages
    .filter((m): m is Extract<WsMessage, { type: 'agent-session-update' }> => m.type === 'agent-session-update' && m.session.agentSessionId === id)
    .map((m) => m.session);
  const terminal = (id: string) => events(id).filter((e) => e.kind === 'result' || e.kind === 'error');

  async function waitFor(what: string, check: () => boolean, ms = 8000): Promise<void> {
    const until = Date.now() + ms;
    while (!check()) {
      if (Date.now() > until) throw new Error(`timed out waiting for ${what}`);
      await Bun.sleep(10);
    }
  }

  /** One terminal event, busy false everywhere after it, the stored history has it. */
  async function expectEnded(id: string, kind: 'result' | 'error', ms = 8000): Promise<AgentEvent> {
    await waitFor('terminal event', () => terminal(id).length > 0, ms);
    await Bun.sleep(40);
    const ends = terminal(id);
    expect(ends).toHaveLength(1);
    expect(ends[0]!.kind).toBe(kind);
    const last = updates(id).at(-1)!;
    expect(last.busy).toBe(false);
    expect(agentHistory(id).filter((e) => e.kind === 'result' || e.kind === 'error')).toHaveLength(1);
    return ends[0]!;
  }

  test('a normal turn: busy for its whole run, one result at the end', async () => {
    const id = start('ok', [init, tool('ACTIVE'), sleep(60), tool('DONE'), text('all done'), sleep(60), result('SUCCESS', 'all done')]);
    promptAgent(id, 'go');
    await waitFor('first update', () => updates(id).length > 0);
    await expectEnded(id, 'result');
    // busy turns true once, stays true while the process runs, falls once.
    const flags = updates(id).map((s) => s.busy);
    const first = flags.indexOf(true);
    expect(first).toBeGreaterThan(-1);
    expect(flags.slice(first).filter((b, i, a) => i > 0 && b !== a[i - 1])).toHaveLength(1);
  });

  test('clean exit with no result line and no text is "ended unexpectedly", not a silent finish', async () => {
    const id = start('empty-exit', [init]);
    promptAgent(id, 'go');
    const end = await expectEnded(id, 'error');
    expect(end.text).toMatch(/ended unexpectedly|without (a|any) (reply|result)/i);
  });

  test('clean exit with streamed text but no result line still finishes visibly', async () => {
    const id = start('text-exit', [init, text('partial answer')]);
    promptAgent(id, 'go');
    await expectEnded(id, 'result');
  });

  test('non-zero exit with stderr shows the stderr', async () => {
    const id = start('exit-stderr', [init, { __fake: 'stderr', text: 'quota exhausted for today' }, { __fake: 'exit', code: 2 }]);
    promptAgent(id, 'go');
    const end = await expectEnded(id, 'error');
    expect(end.text).toContain('quota exhausted');
  });

  test('non-zero exit without stderr still reports an error with the exit code', async () => {
    const id = start('exit-silent', [init, { __fake: 'exit', code: 7 }]);
    promptAgent(id, 'go');
    const end = await expectEnded(id, 'error');
    expect(end.text).toContain('7');
  });

  test('a killed process (SIGKILL) ends the turn with an error', async () => {
    const id = start('killed', [init, tool('ACTIVE'), { __fake: 'kill_self' }]);
    promptAgent(id, 'go');
    const end = await expectEnded(id, 'error');
    expect(end.text).toMatch(/exited|killed|ended/i);
  });

  test('print timeout (result ERROR, exit 3) is shown with its reason', async () => {
    const id = start('timeout', [
      init,
      result('ERROR', '', 'print timeout after 15m with the turn still in progress; the response is partial'),
      { __fake: 'stderr', text: 'AGY_ERROR: print_timeout' },
      { __fake: 'exit', code: 3 },
    ]);
    promptAgent(id, 'go');
    const end = await expectEnded(id, 'error');
    expect(end.text).toContain('print timeout');
  });

  test('an error the host filters as internal noise is still visible as the end of the turn', async () => {
    const id = start('noise', [
      init,
      result('ERROR', '', 'declaring permissions: cortex tool write_to_file: convert tool call for permissions: model output error: invalid tool call error (invalid_args) /p/f.dart is not a valid artifact path; artifacts must be in /home/u/.gemini/antigravity-cli/brain/abc/'),
      { __fake: 'exit', code: 1 },
    ]);
    promptAgent(id, 'go');
    await expectEnded(id, 'error'); // stored history keeps it (expectEnded checks agentHistory)
    const text = agentHistory(id).find((e) => e.kind === 'error')?.text ?? '';
    expect(text).toContain('stopped');
    // The phone hides this phrase, so the end of a turn must not contain it.
    expect(text).not.toContain('is not a valid artifact path');
  });

  test('exit while a grandchild still holds stdout open does not leave the turn hanging', async () => {
    const id = start('bg-pipe', [init, text('hi'), result('SUCCESS', 'hi'), { __fake: 'spawn_bg', ms: 6000 }, { __fake: 'exit', code: 0 }]);
    promptAgent(id, 'go');
    await expectEnded(id, 'result', 4500);
  });

  test('a result is delivered and the turn ends while the process is still alive', async () => {
    const id = start('early', [init, text('hi'), result('SUCCESS', 'hi'), sleep(1500), { __fake: 'exit', code: 0 }]);
    promptAgent(id, 'go');
    await waitFor('result', () => terminal(id).length > 0, 1200);
    expect(updates(id).at(-1)!.busy).toBe(false);
    await Bun.sleep(1800);
    expect(terminal(id).filter((e) => e.kind === 'result')).toHaveLength(1);
    expect(terminal(id)).toHaveLength(1);
  });

  test('a non-zero exit after a delivered result adds no error', async () => {
    const id = start('late-fail', [init, text('hi'), result('SUCCESS', 'hi'), sleep(200), { __fake: 'stderr', text: 'cleanup failed' }, { __fake: 'exit', code: 1 }]);
    promptAgent(id, 'go');
    await expectEnded(id, 'result');
    await Bun.sleep(700);
    expect(terminal(id)).toHaveLength(1);
    expect(terminal(id)[0]!.kind).toBe('result');
  });

  test('a process that exits without any result still gives the error', async () => {
    const id = start('no-result', [init, { __fake: 'exit', code: 0 }]);
    promptAgent(id, 'go');
    const end = await expectEnded(id, 'error');
    expect(end.text).toMatch(/exited without a reply/i);
  });

  test('Stop mid-turn: cancelled status and busy false, no later error from the killed process', async () => {
    const id = start('stop', [init, tool('ACTIVE'), sleep(2000), result('SUCCESS')]);
    promptAgent(id, 'go');
    await waitFor('tool start', () => events(id).some((e) => e.kind === 'tool-start'));
    expect(cancelAgent(id).ok).toBe(true);
    await Bun.sleep(300);
    expect(events(id).some((e) => e.kind === 'status' && e.text === 'cancelled')).toBe(true);
    expect(terminal(id)).toHaveLength(0);
    expect(updates(id).at(-1)!.busy).toBe(false);
  });
});

describe('a host restart in the middle of a turn', () => {
  async function replay(events: unknown[], env: Record<string, string>) {
    const dir = mkdtempSync(join(tmpdir(), 'nexuslink-interrupted-'));
    try {
      const proc = Bun.spawn([process.execPath, join(import.meta.dir, 'fixtures', 'restart-replay.ts')], {
        env: { ...process.env, NEXUSLINK_DATA_DIR: dir, NEXUSLINK_DISABLE_PUSH: '1', NEXUSLINK_DISABLE_CHAT_DISCOVERY: '1', NEXUSLINK_LEGACY_AGENT_STORE: join(dir, 'no-legacy-store.json'), NODE_ENV: 'test', REPLAY_EVENTS: JSON.stringify(events), ...env },
        stdout: 'pipe', stderr: 'pipe',
      });
      const [code, stdout, stderr] = await Promise.all([proc.exited, new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
      expect({ code, stderr: code ? stderr : '' }).toEqual({ code: 0, stderr: '' });
      return JSON.parse(stdout.trim().split('\n').at(-1)!) as { sessions: AgentSessionInfo[]; stored: AgentEvent[]; memory: AgentEvent[] };
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
  const user: AgentEvent = { seq: 1, ts: 1, kind: 'user', text: 'go', turnId: 't1' };
  const thinking: AgentEvent = { seq: 2, ts: 2, kind: 'thinking', text: 'hmm', turnId: 't1' };

  test('the phone that reconnects gets a visible "interrupted" end, from storage and from memory', async () => {
    const result = await replay([user, thinking], { REPLAY_BUSY: '1', REPLAY_TASKSTATE: 'running', REPLAY_RUNNING_AGENTS: '0' });
    expect(result.sessions[0]).toMatchObject({ busy: false, taskState: 'interrupted' });
    for (const history of [result.stored, result.memory]) {
      const ends = history.filter((e) => e.kind === 'error' || e.kind === 'result');
      expect(ends).toHaveLength(1);
      expect(ends[0]!.kind).toBe('error');
      expect(ends[0]!.text).toMatch(/restart/i);
      expect(ends[0]!.seq).toBeGreaterThan(2);
    }
  }, 20000);

  test('a turn whose only stored event is the user message (busy not yet stored) is interrupted too', async () => {
    const result = await replay([user], { REPLAY_BUSY: '0', REPLAY_TASKSTATE: 'running', REPLAY_RUNNING_AGENTS: '0' });
    expect(result.sessions[0]).toMatchObject({ busy: false, taskState: 'interrupted' });
    expect(result.memory.filter((e) => e.kind === 'error')).toHaveLength(1);
  }, 20000);

  test('a finished turn is not marked interrupted', async () => {
    const result = await replay([user, { seq: 2, ts: 2, kind: 'result', text: 'ok', turnId: 't1' }], { REPLAY_BUSY: '0', REPLAY_TASKSTATE: 'completed', REPLAY_RUNNING_AGENTS: '0' });
    expect(result.sessions[0]).toMatchObject({ busy: false, taskState: 'completed' });
    expect(result.memory.filter((e) => e.kind === 'error')).toHaveLength(0);
  }, 20000);
});

test('an open turn is one whose last user message has no result, error or stop after it', async () => {
  // The store marks the task interrupted on first load; the stored error then ends the turn.
  expect(turnLeftOpen([{ seq: 1, ts: 1, kind: 'user' }, { seq: 2, ts: 2, kind: 'thinking' }])).toBe(true);
  expect(turnLeftOpen([{ seq: 1, ts: 1, kind: 'user' }, { seq: 2, ts: 2, kind: 'error', text: 'Interrupted' }])).toBe(false);
  expect(turnLeftOpen([{ seq: 1, ts: 1, kind: 'user' }, { seq: 2, ts: 2, kind: 'status', text: 'cancelled' }])).toBe(false);
  expect(turnLeftOpen([{ seq: 1, ts: 1, kind: 'user' }, { seq: 2, ts: 2, kind: 'result' }, { seq: 3, ts: 3, kind: 'agent-end', agentId: 'a' }])).toBe(false);
  expect(turnLeftOpen([])).toBe(false);
});
