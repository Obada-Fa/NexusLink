import { afterAll, afterEach, describe, expect, test } from 'bun:test';
import { appendFileSync, mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Database } from 'bun:sqlite';
import { setRoots, type ProviderRoots } from './paths';
import { Scanner } from './providers/scan';
import { setDiscoveryLimit } from './providers/local';
import { ChatService, type ChatGateway } from './index';

setDiscoveryLimit(Number.MAX_SAFE_INTEGER);
const directories: string[] = [];
const services: ChatService[] = [];
afterEach(async () => { for (const service of services.splice(0)) await service.close(); });
afterAll(() => { setRoots(); for (const path of directories) rmSync(path, { recursive: true, force: true }); });

const jsonl = (rows: unknown[]) => rows.map(r => JSON.stringify(r)).join('\n') + '\n';
const iso = (ms: number) => new Date(ms).toISOString();
const CLAUDE_ID = '11111111-2222-4333-8444-555555555555';
const BLOCKED_ID = '66666666-2222-4333-8444-555555555555';
const CODEX_ID = '01a1560a-5298-7de3-9f23-fa7427ca31da';
const CODEX_PRUNED = '01a12583-8e80-7330-a00a-1f85d3711be7';
const GUARDIAN = '01a155e8-909e-7e71-a852-e65a83fc6108';
const AGY_ID = '174101aa-af91-477f-bf00-4514a8de5f3a';

/** A miniature PC with one chat per agent app, built from scratch (never real user data). */
function fixture(now = Date.now()) {
  const root = mkdtempSync(join(tmpdir(), 'nexuslink-discovery-'));
  directories.push(root);
  const work = join(root, 'work', 'app');
  mkdirSync(work, { recursive: true });
  const roots: ProviderRoots = { claude: join(root, 'claude'), claudeDesktop: join(root, 'desktop'), codex: join(root, 'codex'), gemini: join(root, 'gemini'), opencode: join(root, 'opencode'), cursor: join(root, 'cursor') };
  // Claude Code: one chat mid-edit, one Desktop chat blocked on the user.
  const project = join(roots.claude, 'projects', '-work-app');
  mkdirSync(project, { recursive: true });
  const claudeFile = join(project, `${CLAUDE_ID}.jsonl`);
  writeFileSync(claudeFile, jsonl([
    { type: 'user', cwd: work, timestamp: iso(now - 20_000), message: { role: 'user', content: 'Rename the login button' } },
    { type: 'assistant', timestamp: iso(now - 2000), message: { role: 'assistant', stop_reason: 'tool_use', content: [{ type: 'tool_use', id: 'e1', name: 'Edit', input: { file_path: `${work}/login.dart` } }] } },
  ]));
  writeFileSync(join(project, `${BLOCKED_ID}.jsonl`), jsonl([
    { type: 'user', cwd: work, timestamp: iso(now - 90_000), message: { role: 'user', content: 'Push the branch' } },
    { type: 'assistant', timestamp: iso(now - 80_000), message: { role: 'assistant', stop_reason: 'end_turn', content: [{ type: 'text', text: 'Push needs GitHub sign-in.' }] } },
  ]));
  utimesSync(join(project, `${BLOCKED_ID}.jsonl`), new Date(now - 80_000), new Date(now - 80_000));
  const desktop = join(roots.claudeDesktop, 'claude-code-sessions', 'account', 'org');
  mkdirSync(desktop, { recursive: true });
  writeFileSync(join(desktop, 'local_a.json'), JSON.stringify({ cliSessionId: CLAUDE_ID, title: 'Login button rename', isArchived: false, permissionMode: 'acceptEdits', cwd: work }));
  writeFileSync(join(desktop, 'local_b.json'), JSON.stringify({ cliSessionId: BLOCKED_ID, title: 'Push branch', isArchived: false, lastAssistantUuid: 'u1', postTurnSummaryFor: 'u1', postTurnSummary: { status_category: 'blocked', needs_action: 'Run `gh auth login` on the PC' } }));
  // Codex Desktop: thread metadata in state_5.sqlite, one live rollout, one pruned rollout, one guardian sub-agent.
  const day = join(roots.codex, 'sessions', '2026', '10', '20');
  mkdirSync(day, { recursive: true });
  const rollout = join(day, `rollout-2026-10-20T10-00-00-${CODEX_ID}.jsonl`);
  writeFileSync(rollout, jsonl([
    { timestamp: iso(now - 60_000), type: 'session_meta', payload: { id: CODEX_ID, cwd: work, source: 'vscode' } },
    { timestamp: iso(now - 50_000), type: 'event_msg', payload: { type: 'task_started', started_at: Math.floor((now - 50_000) / 1000) } },
    { timestamp: iso(now - 1000), type: 'response_item', payload: { type: 'custom_tool_call', name: 'exec', call_id: 'c1', input: 'text(await tools.exec_command({cmd:"cargo test"}));' } },
  ]));
  const state = new Database(join(roots.codex, 'state_5.sqlite'), { create: true });
  state.exec('CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, cwd TEXT, title TEXT, name TEXT, preview TEXT, first_user_message TEXT, archived INTEGER, updated_at INTEGER, updated_at_ms INTEGER, source TEXT, agent_role TEXT)');
  const thread = state.query('INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?,?,?,?)');
  thread.run(CODEX_ID, rollout, work, 'run the tests and fix failures', 'Fix failing tests', 'run the tests', 'run the tests', 0, Math.floor(now / 1000), now - 1000, 'vscode', null);
  thread.run(CODEX_PRUNED, join(roots.codex, 'sessions', 'gone.jsonl'), '/srv/old', 'old work', null, '', '', 0, Math.floor((now - 9e6) / 1000), now - 9e6, 'vscode', null);
  thread.run(GUARDIAN, join(day, 'missing.jsonl'), work, 'Guardian review', null, '', '', 0, Math.floor(now / 1000), now, '{"subagent":{"other":"guardian"}}', null);
  state.close();
  // Antigravity IDE: summary DB (no workspace URI) + brain transcript whose commands reveal the folder.
  const agyApp = join(roots.gemini, 'antigravity');
  const brain = join(agyApp, 'brain', AGY_ID, '.system_generated', 'logs');
  mkdirSync(brain, { recursive: true });
  writeFileSync(join(brain, 'transcript.jsonl'), jsonl([
    { step_index: 0, type: 'USER_INPUT', status: 'DONE', created_at: iso(now - 30_000), content: '<USER_REQUEST>Disable both monitors</USER_REQUEST>' },
    { step_index: 1, type: 'PLANNER_RESPONSE', status: 'DONE', created_at: iso(now - 1000), tool_calls: [{ name: 'run_command', args: { CommandLine: '"xrandr --listmonitors"', Cwd: JSON.stringify(work), toolAction: '"Checking displays"' } }] },
  ]));
  const summaries = new Database(join(agyApp, 'conversation_summaries.db'), { create: true });
  summaries.exec("CREATE TABLE conversation_summaries (conversation_id TEXT, title TEXT, preview TEXT, step_count INTEGER, last_modified_time DATETIME, workspace_uris TEXT, status TEXT, project_id TEXT, parent_conversation_id TEXT, nesting_depth INTEGER, not_fully_idle NUMERIC, killed NUMERIC, last_user_input_time DATETIME, app_data_dir TEXT)");
  summaries.query('INSERT INTO conversation_summaries VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)').run(AGY_ID, 'Disable Monitors And Fix Claude', 'Disable Monitors', 2, new Date(now - 1000).toISOString().replace('T', ' ').replace('Z', '123456+00:00'), '', 'CASCADE_RUN_STATUS_IDLE', 'this-pc', '', 0, 0, 0, '', 'antigravity');
  summaries.close();
  // OpenCode: the CLI's own SQLite store.
  mkdirSync(roots.opencode, { recursive: true });
  const oc = new Database(join(roots.opencode, 'opencode.db'), { create: true });
  oc.exec('CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT, time_updated INTEGER, time_archived INTEGER); CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT); CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT); CREATE TABLE todo (session_id TEXT, content TEXT, status TEXT, position INTEGER)');
  oc.query('INSERT INTO session VALUES (?,?,?,?,?,?)').run('ses_1', null, work, 'Profile the server', now - 3000, null);
  oc.query('INSERT INTO session VALUES (?,?,?,?,?,?)').run('ses_child', 'ses_1', work, 'subtask', now, null);
  oc.query('INSERT INTO message VALUES (?,?,?,?,?)').run('m1', 'ses_1', now - 9000, now - 9000, JSON.stringify({ role: 'user', time: { created: now - 9000 } }));
  oc.query('INSERT INTO message VALUES (?,?,?,?,?)').run('m2', 'ses_1', now - 8000, now - 3000, JSON.stringify({ role: 'assistant', time: { created: now - 8000 } }));
  oc.query('INSERT INTO part VALUES (?,?,?,?,?,?)').run('p0', 'm1', 'ses_1', now - 9000, now - 9000, JSON.stringify({ type: 'text', text: 'profile it' }));
  oc.query('INSERT INTO part VALUES (?,?,?,?,?,?)').run('p1', 'm2', 'ses_1', now - 8000, now - 3000, JSON.stringify({ type: 'tool', tool: 'bash', callID: 'b', state: { status: 'running', input: { command: 'perf record' } } }));
  oc.query('INSERT INTO todo VALUES (?,?,?,?)').run('ses_1', 'Record a profile', 'in_progress', 0);
  oc.close();
  return { root, roots, work, claudeFile, rollout };
}

describe('read-only discovery of native chats', () => {
  test('Claude Code JSONL + Claude Desktop metadata: titles, folders, live step, needs-attention', () => {
    const { roots, work } = fixture();
    setRoots(roots);
    const rows = new Scanner().scan('claude').result;
    const editing = rows.find(r => r.hostChatId === CLAUDE_ID)!;
    expect(editing.title).toBe('Login button rename');
    expect(editing.cwd).toBe(work);
    expect(editing.source).toBe('Claude Code · Desktop');
    expect(editing.live).toMatchObject({ state: 'working', step: 'Editing login.dart', activity: 'editing' });
    const blocked = rows.find(r => r.hostChatId === BLOCKED_ID)!;
    // The Desktop's after-turn "blocked" summary is a follow-up for the owner, not a paused agent.
    expect(blocked.live).toMatchObject({ state: 'done', ask: 'Run `gh auth login` on the PC', via: 'claude-desktop' });
    expect(blocked.live?.waitingFor).toBeUndefined();
  });

  test('Codex Desktop threads come from the state DB: folders for pruned rollouts, no sub-agents, live from the rollout', () => {
    const { roots, work } = fixture();
    setRoots(roots);
    const rows = new Scanner().scan('codex').result;
    expect(rows.map(r => r.hostChatId).sort()).toEqual([CODEX_ID, CODEX_PRUNED].sort());
    const live = rows.find(r => r.hostChatId === CODEX_ID)!;
    expect(live).toMatchObject({ title: 'Fix failing tests', cwd: work, resumable: true });
    expect(live.live).toMatchObject({ state: 'working', step: 'Running: cargo test' });
    expect(rows.find(r => r.hostChatId === CODEX_PRUNED)!.cwd).toBe('/srv/old');
  });

  test('Antigravity IDE summary DB: real title, folder from the transcript, live status, readable history', () => {
    const { roots, work } = fixture();
    setRoots(roots);
    const scanner = new Scanner();
    const [row] = scanner.scan('antigravity').result;
    expect(row).toMatchObject({ hostChatId: AGY_ID, title: 'Disable Monitors And Fix Claude', cwd: work, source: 'Antigravity', resumable: false });
    expect(row.live).toMatchObject({ state: 'working', step: 'Running: xrandr --listmonitors' });
    const history = scanner.history('antigravity', AGY_ID);
    expect(history.result.map(e => e.kind)).toEqual(['user', 'tool-start']);
    expect(history.result[0].text).toBe('Disable both monitors');
  });

  test('OpenCode is read from its database without running the CLI', () => {
    const { roots, work } = fixture();
    setRoots(roots);
    const scanner = new Scanner();
    const rows = scanner.scan('opencode').result;
    expect(rows.map(r => r.hostChatId)).toEqual(['ses_1']);
    expect(rows[0]).toMatchObject({ title: 'Profile the server', cwd: work });
    expect(rows[0].live).toMatchObject({ state: 'working', step: 'Running: perf record', todos: [{ text: 'Record a profile', state: 'active' }] });
    expect(scanner.history('opencode', 'ses_1').result.map(e => e.kind)).toEqual(['user', 'tool-start']);
  });

  test('history follows an appended transcript incrementally and reports unchanged files', () => {
    const { roots, claudeFile } = fixture();
    setRoots(roots);
    const scanner = new Scanner();
    const first = scanner.history('claude', CLAUDE_ID);
    expect(first.result.map(e => e.kind)).toEqual(['user', 'tool-start']);
    expect(scanner.history('claude', CLAUDE_ID, first.fingerprint).unchanged).toBe(true);
    appendFileSync(claudeFile, jsonl([{ type: 'user', timestamp: iso(Date.now()), message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'e1', content: 'edited' }] } }]) + '{"type":"assistant","partial');
    const second = scanner.history('claude', CLAUDE_ID, first.fingerprint);
    expect(second.unchanged).toBeUndefined();
    expect(second.result.map(e => e.kind)).toEqual(['user', 'tool-start', 'tool-end']);
  });
});

function gateway(overrides: Partial<ChatGateway> = {}): ChatGateway {
  return { sessions: () => [], history: async () => ({ events: [], hasMore: false }), send: () => ({ ok: true }), flush: async () => {}, bin: () => '/bin/true', ...overrides };
}

describe('chat service', () => {
  test('its own writes never trigger rescans; a real transcript write refreshes only that source', async () => {
    const { root, roots } = fixture();
    const counts: Record<string, number> = {};
    const service = await new ChatService({
      directory: join(root, 'library'), hostId: 'pc', notify: () => {}, gateway: gateway(), roots, watchDebounceMs: 100, pollMs: 60_000, backgroundDiscovery: false,
      provider: async (source, op) => {
        if (op === 'scan') {
          counts[source] = (counts[source] || 0) + 1;
          // What a provider used to do as a side effect (app-server logs, sqlite shm, temp files).
          writeFileSync(join(roots.codex, 'logs_2.sqlite-wal'), String(Math.random()));
          mkdirSync(join(roots.codex, 'tmp'), { recursive: true });
          writeFileSync(join(roots.codex, 'tmp', 'scratch'), String(Math.random()));
          writeFileSync(join(roots.codex, 'sessions', '2026', 'state.sqlite-shm'), String(Math.random()));
          writeFileSync(join(roots.opencode, 'opencode.db-shm'), String(Math.random()));
          writeFileSync(join(roots.claude, 'projects', '-work-app', 'notes.txt'), String(Math.random()));
        }
        return { result: [], complete: true };
      },
    }).initialize();
    services.push(service);
    service.subscribe({}, true);
    await Bun.sleep(1500);
    expect(counts).toEqual({ claude: 1, cursor: 1, codex: 1, opencode: 1, antigravity: 1 });
    appendFileSync(join(roots.codex, 'sessions', '2026', '10', '20', `rollout-2026-10-20T10-00-00-${CODEX_ID}.jsonl`), '{"type":"event_msg","payload":{"type":"task_complete"}}\n');
    await Bun.sleep(800);
    expect(counts.codex).toBe(2);
    expect(counts.claude).toBe(1);
    await Bun.sleep(1000);
    expect(counts.codex).toBe(2);
  });

  test('one long-lived provider worker: live rows, current read-only history, attach only on send', async () => {
    const { root, roots, claudeFile } = fixture();
    const disabled = process.env.NEXUSLINK_DISABLE_CHAT_DISCOVERY;
    delete process.env.NEXUSLINK_DISABLE_CHAT_DISCOVERY;
    const opened: any[] = [];
    const sent: string[] = [];
    try {
      const service = await new ChatService({
        directory: join(root, 'library'), hostId: 'pc', notify: () => {}, roots, pollMs: 60_000, backgroundDiscovery: false,
        gateway: gateway({
          openHostChat: params => { opened.push(params); return { agentSessionId: 'attached', agent: params.agent, cwd: params.cwd || '', title: params.title || '', createdAt: 1, busy: false, status: 'running', hostChatId: params.hostChatId }; },
          send: (_id, text) => { sent.push(text); return { ok: true }; },
        }),
      }).initialize();
      services.push(service);
      service.refresh();
      for (let i = 0; i < 100 && Object.keys(service.stats.scanMs).length < 5; i++) await Bun.sleep(20);
      const page = await service.list({ limit: 100, sort: 'monitor' }) as any;
      const claude = page.items.find((row: any) => row.nativeId === CLAUDE_ID);
      expect(claude.execution).toBe('working');
      expect(claude.live.step).toBe('Editing login.dart');
      expect(claude.capabilities.safety).toBe('busy');
      expect(page.items.find((row: any) => row.nativeId === BLOCKED_ID).execution).toBe('idle');
      expect(page.items.find((row: any) => row.nativeId === CODEX_ID).live.step).toBe('Running: cargo test');
      // Reading is read-only and stays current as the transcript grows.
      const first = await service.request('chat.historyPage', { chatId: claude.id }, {}, 'phone');
      expect(first.events.map((e: any) => e.kind)).toEqual(['user', 'tool-start']);
      expect(opened).toHaveLength(0);
      appendFileSync(claudeFile, jsonl([{ type: 'user', timestamp: iso(Date.now()), message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'e1', content: 'done' }] } }, { type: 'assistant', timestamp: iso(Date.now()), message: { role: 'assistant', stop_reason: 'end_turn', content: [{ type: 'text', text: 'Renamed.' }] } }]));
      const newer = await service.request('chat.historyPage', { chatId: claude.id, newerCursor: first.newerCursor }, {}, 'phone');
      expect(newer.restart).toBeUndefined();
      expect(newer.events.map((e: any) => e.kind)).toEqual(['tool-end', 'text']);
      expect(newer.revision).toBe(first.revision);
      // The finished chat can now be continued; sending attaches with the worker-parsed transcript.
      await service.poll();
      const ready = await service.request('chat.historyPage', { chatId: claude.id, limit: 1 }, {}, 'phone');
      expect(ready.chat.live.state).toBe('done');
      const delivery = await service.send('phone', { chatId: claude.id, text: 'Also update the tests', operationId: 'op-1' });
      expect(delivery.state).toBe('delivered');
      expect(opened).toHaveLength(1);
      expect(opened[0].history.map((e: any) => e.kind)).toEqual(['user', 'tool-start', 'tool-end', 'text']);
      expect(opened[0].updatedAt).toBe(ready.chat.activityAt);
      expect(sent).toEqual(['Also update the tests']);
    } finally {
      if (disabled === undefined) delete process.env.NEXUSLINK_DISABLE_CHAT_DISCOVERY; else process.env.NEXUSLINK_DISABLE_CHAT_DISCOVERY = disabled;
    }
  });

  test('a chat running in another app is never driven or interrupted from the phone', async () => {
    const { root, roots } = fixture();
    const cancels: string[] = [];
    const service = await new ChatService({
      directory: join(root, 'library'), hostId: 'pc', notify: () => {}, roots, backgroundDiscovery: false,
      gateway: gateway({ cancel: id => { cancels.push(id); return { ok: true }; } }),
      provider: async (source, op) => ({ result: op === 'scan' && source === 'claude' ? [{ hostChatId: CLAUDE_ID, title: 'Busy', cwd: root, updatedAt: Date.now(), resumable: true, live: { state: 'working', step: 'Editing a.ts' } }] : [] }),
    }).initialize();
    services.push(service);
    service.refresh('claude');
    for (let i = 0; i < 100 && !service.stats.scanMs.claude; i++) await Bun.sleep(10);
    const [row] = (await service.list({ source: 'claude' }) as any).items;
    const result = await service.send('phone', { chatId: row.id, text: 'stop and do this', operationId: 'op-busy', interrupt: true });
    expect(result.state).toBe('rejected');
    expect(result.reason).toContain('working in Claude Code on the PC');
    expect(cancels).toHaveLength(0);
  });
});
