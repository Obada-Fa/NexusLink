import { afterEach, describe, expect, test } from 'bun:test';
import { appendFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ApprovalBridge, describeRequest, hasClaudeHook, withClaudeHook } from '../approval-bridge';

const dirs: string[] = [];
const bridges: ApprovalBridge[] = [];
afterEach(() => { bridges.splice(0).forEach(b => b.stop()); dirs.splice(0).forEach(d => rmSync(d, { recursive: true, force: true })); });

const DESKTOP_ID = '11111111-2222-4333-8444-555555555555';
const CLI_ID = '22222222-2222-4333-8444-555555555555';
const jsonl = (rows: unknown[]) => rows.map(r => JSON.stringify(r)).join('\n') + '\n';

/** A scratch PC: data dir, ~/.claude, Claude Desktop metadata, one transcript (never real user data). */
function setup(now = { t: 1_000_000 }) {
  const root = mkdtempSync(join(tmpdir(), 'nl-approvals-'));
  dirs.push(root);
  const desktop = join(root, 'desktop', 'acct', 'org');
  mkdirSync(desktop, { recursive: true });
  writeFileSync(join(desktop, 'local_a.json'), JSON.stringify({ cliSessionId: DESKTOP_ID }));
  const project = join(root, 'claude', 'projects', '-work');
  mkdirSync(project, { recursive: true });
  const transcript = join(project, `${DESKTOP_ID}.jsonl`);
  writeFileSync(transcript, jsonl([
    { type: 'user', message: { role: 'user', content: 'go' } },
    { type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', id: 'toolu_old', name: 'Bash', input: { command: 'npm test' } }] } },
    { type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'toolu_old', content: 'ok' }] } },
    { type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', id: 'toolu_new', name: 'Bash', input: { command: 'npm test' } }] } },
  ]));
  const changes: number[] = [];
  const pushed: string[] = [];
  const bridge = new ApprovalBridge({
    dataDir: join(root, 'data'), hostId: 'pc', claudeSettingsPath: join(root, 'claude', 'settings.json'), desktopSessionsDir: join(root, 'desktop'),
    port: 0, now: () => now.t, onChange: items => changes.push(items.length), push: item => pushed.push(item.title),
  });
  bridges.push(bridge);
  return { root, bridge, transcript, changes, pushed, now };
}
const hook = (session: string, tool: string, input: Record<string, unknown>, transcript?: string) => ({
  hook_event_name: 'PermissionRequest', session_id: session, tool_name: tool, tool_input: input, cwd: '/work', ...(transcript ? { transcript_path: transcript } : {}),
});
const tick = () => new Promise(r => setTimeout(r, 5));

describe('Claude settings', () => {
  test('adding and removing the hook keeps everything else', () => {
    const mine = { model: 'opus', hooks: { Stop: [{ hooks: [{ type: 'command', command: 'notify' }] }], PermissionRequest: [{ matcher: 'Bash', hooks: [{ type: 'command', command: 'mine' }] }] } };
    const on = withClaudeHook(mine, { url: 'http://127.0.0.1:1/nexuslink/claude/permission', token: 't' });
    expect(hasClaudeHook(on)).toBe(true);
    expect(on.model).toBe('opus');
    expect(on.hooks.Stop).toEqual(mine.hooks.Stop);
    expect(on.hooks.PermissionRequest).toHaveLength(2);
    // Re-installing replaces ours instead of duplicating it.
    expect(withClaudeHook(on, { url: 'http://127.0.0.1:2/nexuslink/claude/permission', token: 'u' }).hooks.PermissionRequest).toHaveLength(2);
    expect(withClaudeHook(on, null)).toEqual(mine);
    // Nothing of ours left means no empty hooks object either.
    expect(withClaudeHook(withClaudeHook({}, { url: 'http://127.0.0.1:1/nexuslink/claude/permission', token: 't' }), null)).toEqual({});
  });

  test('configure writes settings with a one-time backup, and refuses files that are not plain JSON', () => {
    const { root, bridge } = setup();
    const path = join(root, 'claude', 'settings.json');
    writeFileSync(path, JSON.stringify({ theme: 'dark' }));
    expect(bridge.configure({ claude: true }).claude.installed).toBe(true);
    const written = JSON.parse(readFileSync(path, 'utf8'));
    expect(written.theme).toBe('dark');
    const entry = written.hooks.PermissionRequest[0].hooks[0];
    expect(entry).toMatchObject({ type: 'http', timeout: 1800 });
    expect(entry.url).toStartWith('http://127.0.0.1:');
    expect(entry.headers.Authorization).toMatch(/^Bearer [0-9a-f]{64}$/);
    expect(JSON.parse(readFileSync(`${path}.nexuslink-backup`, 'utf8'))).toEqual({ theme: 'dark' });
    expect(bridge.configure({ claude: false }).claude.installed).toBe(false);
    expect(JSON.parse(readFileSync(path, 'utf8'))).toEqual({ theme: 'dark' });
    writeFileSync(path, '{ "theme": "dark", // comment\n}');
    const status = bridge.configure({ claude: true });
    expect(status.claude.installed).toBe(false);
    expect(status.claude.error).toContain('not plain JSON');
    expect(readFileSync(path, 'utf8')).toBe('{ "theme": "dark", // comment\n}');
    // The token file is private to the owner.
    expect(statSync(join(root, 'data', 'approval-bridge.json')).mode & 0o077).toBe(0);
  });
});

describe('hook requests', () => {
  test('terminal sessions pass straight through unless the owner holds them for the phone', async () => {
    const { bridge } = setup();
    expect(await bridge.handleHook(hook(CLI_ID, 'Bash', { command: 'ls' }))).toBeNull();
    expect(bridge.list()).toEqual([]);
    bridge.configure({ holdTerminal: true });
    const waiting = bridge.handleHook(hook(CLI_ID, 'Bash', { command: 'ls' }));
    await tick();
    expect(bridge.list()).toHaveLength(1);
    expect(bridge.list()[0].mirrored).toBe(false);
    bridge.resolve(bridge.list()[0].id, 'deny');
    expect(await waiting).toMatchObject({ hookSpecificOutput: { decision: { behavior: 'deny', message: 'Denied from the phone (NexusLink).' } } });
  });

  test('a Desktop approval is mirrored to the phone; allow returns the original input', async () => {
    const { bridge, transcript, changes } = setup();
    const waiting = bridge.handleHook(hook(DESKTOP_ID, 'Bash', { command: 'npm test' }, transcript));
    await tick();
    const [item] = bridge.list();
    expect(item).toMatchObject({ kind: 'approval', title: 'Run: npm test', detail: 'npm test', tool: 'Bash', mirrored: true, cwd: '/work' });
    expect(bridge.resolve('nope', 'allow').ok).toBe(false);
    expect(bridge.resolve(item.id, 'allow').ok).toBe(true);
    expect(await waiting).toEqual({ hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: { behavior: 'allow', updatedInput: { command: 'npm test' } } } });
    expect(bridge.list()).toEqual([]);
    expect(changes).toEqual([1, 0]);
  });

  test('questions need an answer for every question', async () => {
    const { bridge } = setup();
    const input = { questions: [{ question: 'Which port?', header: 'Port', options: [{ label: '8080' }, { label: '3000', description: 'dev' }] }] };
    const waiting = bridge.handleHook(hook(DESKTOP_ID, 'AskUserQuestion', input));
    await tick();
    const [item] = bridge.list();
    expect(item).toMatchObject({ kind: 'question', title: 'Which port?', questions: [{ question: 'Which port?', header: 'Port', options: [{ label: '8080' }, { label: '3000', description: 'dev' }] }] });
    expect(bridge.resolve(item.id, 'allow', {}).ok).toBe(false);
    expect(bridge.resolve(item.id, 'allow', { 'Which port?': '3000', 'Other?': 'x' }).ok).toBe(true);
    expect(await waiting).toMatchObject({ hookSpecificOutput: { decision: { behavior: 'allow', updatedInput: { ...input, answers: { 'Which port?': '3000' } } } } });
  });

  test('a plan can be sent back with feedback', async () => {
    const { bridge } = setup();
    const waiting = bridge.handleHook(hook(DESKTOP_ID, 'ExitPlanMode', { plan: '1. Do it' }));
    await tick();
    const [item] = bridge.list();
    expect(item).toMatchObject({ kind: 'plan', title: 'Approve the plan', detail: '1. Do it' });
    bridge.resolve(item.id, 'deny', undefined, 'Add tests first');
    expect(await waiting).toMatchObject({ hookSpecificOutput: { decision: { behavior: 'deny', message: 'Add tests first' } } });
  });

  test('an answer given on the PC shows up in the transcript and releases the hook', async () => {
    const { bridge, transcript } = setup();
    const waiting = bridge.handleHook(hook(DESKTOP_ID, 'Bash', { command: 'npm test' }, transcript));
    await tick();
    bridge.sweep();
    expect(bridge.list()).toHaveLength(1);
    appendFileSync(transcript, jsonl([{ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'toolu_new', content: 'passed' }] } }]));
    bridge.sweep();
    expect(await waiting).toBeNull();
    expect(bridge.list()).toEqual([]);
  });

  test('an earlier identical call that was answered is not mistaken for this one', async () => {
    const { bridge, transcript } = setup();
    // Claude writes this call's tool_use just after the hook fires.
    appendFileSync(transcript, jsonl([{ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'toolu_new', content: 'passed' }] } }]));
    const waiting = bridge.handleHook(hook(DESKTOP_ID, 'Bash', { command: 'npm test' }, transcript));
    await tick();
    bridge.sweep();
    expect(bridge.list()).toHaveLength(1);
    appendFileSync(transcript, jsonl([
      { type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', id: 'toolu_third', name: 'Bash', input: { command: 'npm test' } }] } },
      { type: 'last-prompt', lastPrompt: 'go' },
    ]));
    bridge.sweep();
    expect(bridge.list()).toHaveLength(1);
    appendFileSync(transcript, jsonl([{ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'toolu_third', content: 'ok' }] } }]));
    bridge.sweep();
    expect(await waiting).toBeNull();
    expect(bridge.list()).toEqual([]);
  });

  test('other tools and bookkeeping rows never dismiss a card', async () => {
    const { bridge, transcript } = setup();
    const waiting = bridge.handleHook(hook(DESKTOP_ID, 'Bash', { command: 'npm test' }, transcript));
    await tick();
    appendFileSync(transcript, jsonl([
      { type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', id: 'toolu_x', name: 'Read', input: { file_path: '/a' } }] } },
      { type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'toolu_x', content: 'a' }] } },
      { type: 'cost-state' },
    ]));
    bridge.sweep();
    expect(bridge.list()).toHaveLength(1);
    bridge.resolve(bridge.list()[0].id, 'allow');
    expect(await waiting).toMatchObject({ hookSpecificOutput: { decision: { behavior: 'allow' } } });
  });

  test('aborted, expired and stopped requests fall back to the normal prompt', async () => {
    const { bridge, now } = setup();
    const abort = new AbortController();
    const aborted = bridge.handleHook(hook(DESKTOP_ID, 'Bash', { command: 'a' }), abort.signal);
    const expired = bridge.handleHook(hook(DESKTOP_ID, 'Bash', { command: 'b' }));
    await tick();
    abort.abort();
    expect(await aborted).toBeNull();
    now.t += 1800_000;
    bridge.sweep();
    expect(await expired).toBeNull();
    const stopped = bridge.handleHook(hook(DESKTOP_ID, 'Bash', { command: 'c' }));
    await tick();
    bridge.stop();
    expect(await stopped).toBeNull();
  });

  test('the HTTP endpoint needs the exact bearer token', async () => {
    const { bridge, root } = setup();
    const token = JSON.parse(readFileSync(join(root, 'data', 'approval-bridge.json'), 'utf8')).token;
    const url = 'http://127.0.0.1/nexuslink/claude/permission';
    const body = JSON.stringify(hook(CLI_ID, 'Bash', { command: 'ls' }));
    expect((await bridge.fetch(new Request(url, { method: 'POST', body }))).status).toBe(403);
    expect((await bridge.fetch(new Request(url, { method: 'POST', body, headers: { Authorization: `Bearer ${token}x` } }))).status).toBe(403);
    const ok = await bridge.fetch(new Request(url, { method: 'POST', body, headers: { Authorization: `Bearer ${token}` } }));
    expect(ok.status).toBe(200);
    expect(await ok.text()).toBe('');
    expect((await bridge.fetch(new Request('http://127.0.0.1/other', { method: 'POST', body }))).status).toBe(404);
  });
});

test('descriptions for common tools', () => {
  expect(describeRequest('Edit', { file_path: '/w/a.dart', old_string: 'x', new_string: 'y' })).toMatchObject({ kind: 'approval', title: 'Editing a.dart', detail: '/w/a.dart\n- x\n+ y' });
  expect(describeRequest('WebFetch', { url: 'https://example.com/x' })).toMatchObject({ title: 'Browsing example.com', detail: 'https://example.com/x' });
  expect(describeRequest('mcp__db__query', { sql: 'select 1' }).detail).toContain('select 1');
});
