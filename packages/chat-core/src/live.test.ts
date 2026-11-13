import { describe, expect, test } from 'bun:test';
import { agyLive, claudeLive, codexLive, describeTool, opencodeLive } from './providers/live';

const NOW = Date.parse('2026-10-20T10:00:00Z');
const at = (secondsAgo: number) => new Date(NOW - secondsAgo * 1000).toISOString();
const jsonl = (rows: unknown[]) => rows.map(r => JSON.stringify(r)).join('\n') + '\n';

// Claude Code transcript fixtures (shape of ~/.claude/projects/<slug>/<session>.jsonl)
const prompt = (text: string, ago: number, extra: object = {}) => ({ type: 'user', timestamp: at(ago), cwd: '/work/app', message: { role: 'user', content: text }, ...extra });
const toolUse = (id: string, name: string, input: object, ago: number) => ({ type: 'assistant', timestamp: at(ago), message: { role: 'assistant', model: 'claude-opus-5-5', stop_reason: 'tool_use', content: [{ type: 'tool_use', id, name, input }] } });
const toolResult = (id: string, ago: number, content = 'ok') => ({ type: 'user', timestamp: at(ago), message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: id, content }] } });
const say = (text: string, ago: number, stop: string | null = 'end_turn') => ({ type: 'assistant', timestamp: at(ago), message: { role: 'assistant', model: 'claude-opus-5-5', stop_reason: stop, content: [{ type: 'text', text }] } });

describe('Claude Code transcript tail → live status', () => {
  test('a pending Edit is the current step, with todos from TodoWrite and the last assistant sentence', () => {
    const text = jsonl([
      { type: 'custom-title', customTitle: 'Fix the login flow' },
      prompt('Fix login please', 40),
      say('I will look at the auth module first.', 38, null),
      toolUse('t1', 'TodoWrite', { todos: [{ content: 'Read auth', status: 'completed' }, { content: 'Patch login', status: 'in_progress' }, { content: 'Run tests', status: 'pending' }] }, 37),
      toolResult('t1', 37),
      toolUse('t2', 'Edit', { file_path: '/work/app/lib/login.dart', old_string: 'a', new_string: 'b' }, 2),
    ]);
    const tail = claudeLive(text, { mtimeMs: NOW - 2000, now: NOW, permissionMode: 'acceptEdits' });
    expect(tail.title).toBe('Fix the login flow');
    expect(tail.live.state).toBe('working');
    expect(tail.live.step).toBe('Editing login.dart');
    expect(tail.live.activity).toBe('editing');
    expect(tail.live.tool).toBe('Edit');
    expect(tail.live.todos).toEqual([{ text: 'Read auth', state: 'done' }, { text: 'Patch login', state: 'active' }, { text: 'Run tests', state: 'pending' }]);
    expect(tail.live.lastText).toBe('I will look at the auth module first.');
    expect(tail.live.turnStartedAt).toBe(NOW - 40_000);
    expect(tail.model).toBe('claude-opus-5-5');
  });

  test('Bash step text, TaskCreate/TaskUpdate todos, and thinking after a tool result', () => {
    const base = [
      prompt('ship it', 60),
      toolUse('c1', 'TaskCreate', { subject: 'Build', activeForm: 'Building' }, 59), toolResult('c1', 59, 'Task #1 created successfully: Build'),
      toolUse('c2', 'TaskCreate', { subject: 'Deploy' }, 58), toolResult('c2', 58, 'Task #2 created successfully: Deploy'),
      toolUse('u1', 'TaskUpdate', { taskId: '1', status: 'completed' }, 57), toolResult('u1', 57),
      toolUse('u2', 'TaskUpdate', { taskId: '2', status: 'in_progress' }, 56), toolResult('u2', 56),
    ];
    const running = claudeLive(jsonl([...base, toolUse('b1', 'Bash', { command: 'npm run build && npm test -- --watch=false --reporter=verbose' }, 1)]), { mtimeMs: NOW - 1000, now: NOW });
    expect(running.live.step).toBe('Running: npm run build && npm test -- --watch=false --reporter=verbos…');
    expect(running.live.activity).toBe('running-command');
    expect(running.live.todos).toEqual([{ text: 'Build', state: 'done' }, { text: 'Deploy', state: 'active' }]);
    const thinking = claudeLive(jsonl([...base, toolUse('b1', 'Bash', { command: 'ls' }, 3), toolResult('b1', 2)]), { mtimeMs: NOW - 2000, now: NOW });
    expect(thinking.live.state).toBe('working');
    expect(thinking.live.step).toBe('Thinking');
  });

  test('end_turn is done; an old open turn is idle, not working forever', () => {
    const done = claudeLive(jsonl([prompt('hi', 30), say('All set — tests pass.', 20)]), { mtimeMs: NOW - 20_000, now: NOW });
    expect(done.live.state).toBe('done');
    expect(done.live.lastText).toBe('All set — tests pass.');
    const stale = claudeLive(jsonl([prompt('hi', 3600)]), { mtimeMs: NOW - 3_600_000, now: NOW });
    expect(stale.live.state).toBe('idle');
  });

  test('a gated tool with no writes for > 8 s is waiting for approval, unless its command is visibly running', () => {
    const text = jsonl([prompt('clean', 30), toolUse('b', 'Bash', { command: 'rm -rf build' }, 12)]);
    const waiting = claudeLive(text, { mtimeMs: NOW - 12_000, now: NOW, permissionMode: 'default', isRunning: () => false });
    expect(waiting.live.state).toBe('waiting');
    expect(waiting.live.waitingFor).toBe('Approve: rm -rf build');
    expect(waiting.live.via).toBe('transcript-heuristic');
    expect(claudeLive(text, { mtimeMs: NOW - 12_000, now: NOW, permissionMode: 'default', isRunning: () => true }).live.state).toBe('working');
    // Modes that never prompt cannot be waiting on a prompt.
    expect(claudeLive(text, { mtimeMs: NOW - 12_000, now: NOW, permissionMode: 'auto', isRunning: () => false }).live.state).toBe('working');
    // Read never asks.
    expect(claudeLive(jsonl([prompt('x', 30), toolUse('r', 'Read', { file_path: '/a/b.ts' }, 12)]), { mtimeMs: NOW - 12_000, now: NOW, isRunning: () => false }).live.state).toBe('working');
  });

  test('AskUserQuestion waits with the question; interruptions and API errors are reported', () => {
    const ask = claudeLive(jsonl([prompt('plan', 10), toolUse('q', 'AskUserQuestion', { questions: [{ question: 'Which database?', options: [] }] }, 5)]), { mtimeMs: NOW - 5000, now: NOW });
    expect(ask.live.state).toBe('waiting');
    expect(ask.live.waitingFor).toBe('Which database?');
    const interrupted = claudeLive(jsonl([prompt('go', 10), toolUse('b', 'Bash', { command: 'sleep 100' }, 9), { type: 'user', timestamp: at(8), message: { role: 'user', content: [{ type: 'text', text: '[Request interrupted by user for tool use]' }] } }]), { mtimeMs: NOW - 8000, now: NOW });
    expect(interrupted.live.state).toBe('idle');
    const failed = claudeLive(jsonl([prompt('go', 10), { type: 'assistant', isApiErrorMessage: true, timestamp: at(9), message: { role: 'assistant', content: [{ type: 'text', text: 'API Error: overloaded' }] } }]), { mtimeMs: NOW - 9000, now: NOW });
    expect(failed.live.state).toBe('failed');
  });

  test('background sub-agents keep a finished main turn working; sidechains and cut lines are ignored', () => {
    const text = '{"type":"assistant","timestamp":"cut-off line' + '\n' + jsonl([prompt('delegate', 120), { ...say('sidechain noise', 1, null), isSidechain: true }, say('Started two agents.', 100)]);
    const live = claudeLive(text, { mtimeMs: NOW - 100_000, now: NOW, subagents: [{ mtimeMs: NOW - 5000, description: 'Audit host' }] }).live;
    expect(live.state).toBe('working');
    expect(live.step).toBe('Background agent: Audit host');
    expect(live.lastText).toBe('Started two agents.');
  });

  test('Claude Desktop update_plan tool drives todos (items, advance, done/start)', () => {
    const plan = (id: string, input: object, ago: number) => [toolUse(id, 'mcp__ccd_turn__update_plan', input, ago), toolResult(id, ago)];
    const text = jsonl([prompt('do it', 30),
      ...plan('p1', { items: [{ content: 'One', status: 'in_progress' }, { content: 'Two', status: 'pending' }, { content: 'Three', status: 'pending' }] }, 29),
      ...plan('p2', { advance: true }, 20), ...plan('p3', { done: [2], start: 3 }, 10)]);
    expect(claudeLive(text, { mtimeMs: NOW - 10_000, now: NOW }).live.todos).toEqual([{ text: 'One', state: 'done' }, { text: 'Two', state: 'done' }, { text: 'Three', state: 'active' }]);
  });
});

describe('Codex rollout tail → live status', () => {
  const ev = (type: string, payload: object, ago: number) => ({ timestamp: at(ago), type: 'event_msg', payload: { type, ...payload } });
  const item = (type: string, payload: object, ago: number) => ({ timestamp: at(ago), type: 'response_item', payload: { type, ...payload } });
  test('open turn with a pending Desktop exec call shows the shell command; plan + messages are tracked', () => {
    const text = jsonl([
      { timestamp: at(100), type: 'session_meta', payload: { id: 'x', cwd: '/work/game' } },
      ev('task_started', { turn_id: 't', started_at: (NOW - 90_000) / 1000 }, 90),
      item('message', { role: 'assistant', content: [{ type: 'output_text', text: 'Checking the build.' }] }, 80),
      item('function_call', { name: 'update_plan', call_id: 'p', arguments: JSON.stringify({ plan: [{ step: 'Build', status: 'completed' }, { step: 'Test', status: 'in_progress' }] }) }, 70),
      item('function_call_output', { call_id: 'p', output: 'ok' }, 70),
      item('custom_tool_call', { name: 'exec', call_id: 'e', input: 'text(await tools.exec_command({cmd:"npm test -- --run",max_output_tokens:5000}));' }, 3),
    ]);
    const tail = codexLive(text, { mtimeMs: NOW - 3000, now: NOW });
    expect(tail.cwd).toBe('/work/game');
    expect(tail.live.state).toBe('working');
    expect(tail.live.step).toBe('Running: npm test -- --run');
    expect(tail.live.todos).toEqual([{ text: 'Build', state: 'done' }, { text: 'Test', state: 'active' }]);
    expect(tail.live.lastText).toBe('Checking the build.');
    expect(tail.live.turnStartedAt).toBe(NOW - 90_000);
  });
  test('task_complete is done with the final message; aborted and approval requests are reported', () => {
    const done = codexLive(jsonl([ev('task_started', {}, 50), ev('task_complete', { last_agent_message: 'Merged and pushed.' }, 5)]), { mtimeMs: NOW - 5000, now: NOW });
    expect(done.live.state).toBe('done');
    expect(done.live.lastText).toBe('Merged and pushed.');
    expect(codexLive(jsonl([ev('task_started', {}, 50), ev('turn_aborted', { reason: 'interrupted' }, 5)]), { mtimeMs: NOW - 5000, now: NOW }).live.state).toBe('idle');
    const approval = codexLive(jsonl([ev('task_started', {}, 50), ev('exec_approval_request', { command: ['bash', '-lc', 'git push --force'] }, 4)]), { mtimeMs: NOW - 4000, now: NOW });
    expect(approval.live.state).toBe('waiting');
    expect(approval.live.waitingFor).toBe('Approve: bash -lc git push --force');
    const question = codexLive(jsonl([ev('task_started', {}, 50), item('function_call', { name: 'request_user_input', call_id: 'q', arguments: JSON.stringify({ questions: [{ question: 'Ship now?' }] }) }, 4)]), { mtimeMs: NOW - 4000, now: NOW });
    expect(question.live.state).toBe('waiting');
    expect(question.live.waitingFor).toBe('Ship now?');
  });
  test('an open turn silent for 20+ minutes is idle', () => {
    expect(codexLive(jsonl([ev('task_started', {}, 3000)]), { mtimeMs: NOW - 3_000_000, now: NOW }).live.state).toBe('idle');
  });
});

describe('Antigravity transcript + summary → live status', () => {
  const step = (i: number, type: string, extra: object, ago: number) => ({ step_index: i, type, status: 'DONE', created_at: at(ago), ...extra });
  test('planner tool call uses the toolAction; ask_question waits; final answer is done', () => {
    const base = [step(0, 'USER_INPUT', { content: '<USER_REQUEST>fix monitors</USER_REQUEST>' }, 60)];
    const viewing = agyLive(jsonl([...base, step(1, 'PLANNER_RESPONSE', { tool_calls: [{ name: 'view_file', args: { AbsolutePath: '"/tmp/x.png"', toolAction: '"Viewing screenshot"' } }] }, 2)]), { mtimeMs: NOW - 2000, now: NOW });
    expect(viewing.live.state).toBe('working');
    expect(viewing.live.step).toBe('Viewing screenshot');
    const command = agyLive(jsonl([...base, step(1, 'PLANNER_RESPONSE', { tool_calls: [{ name: 'run_command', args: { CommandLine: '"xrandr --listmonitors"', Cwd: '"/home/me"', toolAction: '"Checking displays"' } }] }, 2)]), { mtimeMs: NOW - 2000, now: NOW });
    expect(command.live.step).toBe('Running: xrandr --listmonitors');
    expect(command.cwd).toBe('/home/me');
    const ask = agyLive(jsonl([...base, step(1, 'PLANNER_RESPONSE', { tool_calls: [{ name: 'ask_question', args: { questions: JSON.stringify([{ question: 'Keep HDMI on?' }]) } }] }, 2)]), { mtimeMs: NOW - 2000, now: NOW });
    expect(ask.live.state).toBe('waiting');
    expect(ask.live.waitingFor).toBe('Keep HDMI on?');
    const done = agyLive(jsonl([...base, step(1, 'PLANNER_RESPONSE', { content: 'Both monitors are off.' }, 30)]), { mtimeMs: NOW - 30_000, now: NOW });
    expect(done.live.state).toBe('done');
    expect(done.live.lastText).toBe('Both monitors are off.');
  });
  test('the app database marks a quiet transcript as still running', () => {
    const live = agyLive(jsonl([step(0, 'USER_INPUT', { content: 'go' }, 600), step(1, 'PLANNER_RESPONSE', { content: 'Working on it' }, 590)]), { mtimeMs: NOW - 590_000, now: NOW, summary: { status: 'CASCADE_RUN_STATUS_RUNNING', notFullyIdle: true } });
    expect(live.live.state).toBe('working');
  });
});

test('OpenCode DB rows → live status with todos and running tool', () => {
  const live = opencodeLive([
    { data: { role: 'user' }, time_created: NOW - 20_000, time_updated: NOW - 20_000, parts: [] },
    { data: { role: 'assistant', modelID: 'big-pickle', time: { created: NOW - 19_000 } }, time_created: NOW - 19_000, time_updated: NOW - 1000, parts: [
      { type: 'text', text: 'Running the tests now.' }, { type: 'tool', tool: 'bash', state: { status: 'running', input: { command: 'bun test' } } }] },
  ], { updatedMs: NOW - 1000, now: NOW, todos: [{ content: 'Write tests', status: 'completed' }, { content: 'Run tests', status: 'in_progress' }] });
  expect(live.state).toBe('working');
  expect(live.step).toBe('Running: bun test');
  expect(live.lastText).toBe('Running the tests now.');
  expect(live.todos?.map(t => t.state)).toEqual(['done', 'active']);
  expect(live.model).toBe('big-pickle');
});

test('tool descriptions are short and phone-sized', () => {
  expect(describeTool('Write', { file_path: '/a/b/c/README.md' }).step).toBe('Editing README.md');
  expect(describeTool('Grep', { pattern: 'TODO' }).step).toBe('Searching: TODO');
  expect(describeTool('WebFetch', { url: 'https://docs.example.com/x' }).step).toBe('Browsing docs.example.com');
  expect(describeTool('Task', { description: 'Audit host' }).step).toBe('Delegating: Audit host');
  expect(describeTool('shell', { command: "/bin/bash -lc 'git status --short'" }).step).toBe('Running: git status --short');
});
