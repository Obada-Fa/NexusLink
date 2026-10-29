import { afterAll, describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setRoots, type ProviderRoots } from './paths';
import { Scanner } from './providers/scan';
import { scanSummary } from './index';
import { claudeLive } from './providers/live';

const directories: string[] = [];
afterAll(() => { setRoots(); for (const path of directories) rmSync(path, { recursive: true, force: true }); });

const jsonl = (rows: unknown[]) => rows.map(r => JSON.stringify(r)).join('\n') + '\n';
const iso = (ms: number) => new Date(ms).toISOString();
const ORCH_ID = 'aaaaaaaa-2222-4333-8444-555555555555';
const WORKER_ID = 'bbbbbbbb-2222-4333-8444-555555555555';
const touch = (path: string, ms: number) => utimesSync(path, new Date(ms), new Date(ms));

/** An orchestrator session with one worker session and two sub-agents (never real user data). */
function fixture(now: number, blockedHelper: boolean) {
  const root = mkdtempSync(join(tmpdir(), 'nexuslink-orchestration-'));
  directories.push(root);
  const work = join(root, 'work');
  mkdirSync(work, { recursive: true });
  const roots: ProviderRoots = { claude: join(root, 'claude'), claudeDesktop: join(root, 'desktop'), codex: join(root, 'codex'), gemini: join(root, 'gemini'), opencode: join(root, 'opencode'), cursor: join(root, 'cursor') };
  const project = join(roots.claude, 'projects', '-work');
  mkdirSync(project, { recursive: true });
  // The orchestrator is mid-delegation: an Agent call with no result yet.
  const orch = join(project, `${ORCH_ID}.jsonl`);
  writeFileSync(orch, jsonl([
    { type: 'user', cwd: work, timestamp: iso(now - 60_000), message: { role: 'user', content: 'Ship the release' } },
    { type: 'assistant', timestamp: iso(now - 3000), message: { role: 'assistant', stop_reason: 'tool_use', content: [{ type: 'tool_use', id: 'a1', name: 'Agent', input: { description: 'Deploy check' } }] } },
  ]));
  touch(orch, now - 3000);
  const subs = join(project, ORCH_ID, 'subagents');
  mkdirSync(subs, { recursive: true });
  // A finished helper from earlier in the turn.
  writeFileSync(join(subs, 'agent-done.jsonl'), jsonl([
    { type: 'user', isSidechain: true, timestamp: iso(now - 600_000), message: { role: 'user', content: 'Read the changelog' } },
    { type: 'assistant', isSidechain: true, timestamp: iso(now - 590_000), message: { role: 'assistant', stop_reason: 'end_turn', content: [{ type: 'text', text: 'Changelog is fine.' }] } },
  ]));
  writeFileSync(join(subs, 'agent-done.meta.json'), JSON.stringify({ agentType: 'Explore', description: 'Read changelog' }));
  touch(join(subs, 'agent-done.jsonl'), now - 590_000);
  // The live helper: either still running a command or sitting on a permission prompt.
  writeFileSync(join(subs, 'agent-live.jsonl'), jsonl([
    { type: 'user', isSidechain: true, timestamp: iso(now - 40_000), message: { role: 'user', content: 'Check the deploy' } },
    { type: 'assistant', isSidechain: true, timestamp: iso(now - 30_000), message: { role: 'assistant', stop_reason: 'tool_use', content: [{ type: 'tool_use', id: 'b1', name: 'Bash', input: { command: 'nexus-fixture-deploy --prod' } }] } },
  ]));
  writeFileSync(join(subs, 'agent-live.meta.json'), JSON.stringify({ agentType: 'general-purpose', description: 'Deploy check' }));
  touch(join(subs, 'agent-live.jsonl'), blockedHelper ? now - 30_000 : now - 1000);
  // The worker finished its turn with a question for whoever reads its report.
  const worker = join(project, `${WORKER_ID}.jsonl`);
  writeFileSync(worker, jsonl([
    { type: 'user', cwd: work, timestamp: iso(now - 300_000), message: { role: 'user', content: 'Fix the flaky test' } },
    { type: 'assistant', timestamp: iso(now - 200_000), message: { role: 'assistant', stop_reason: 'end_turn', content: [{ type: 'text', text: 'Fixed. Should I commit it?' }] } },
  ]));
  touch(worker, now - 200_000);
  const desktop = join(roots.claudeDesktop, 'claude-code-sessions', 'account', 'org');
  mkdirSync(desktop, { recursive: true });
  writeFileSync(join(desktop, 'local_orch.json'), JSON.stringify({ cliSessionId: ORCH_ID, title: 'Release orchestrator', permissionMode: 'default', cwd: work }));
  writeFileSync(join(desktop, 'local_worker.json'), JSON.stringify({
    cliSessionId: WORKER_ID, title: 'Flaky test fix', cwd: work, spawnedFrom: { sessionId: 'local_orch', name: 'flaky-test' },
    lastAssistantUuid: 'u9', postTurnSummaryFor: 'u9', postTurnSummary: { status_category: 'blocked', needs_action: 'Should I commit it?' },
  }));
  return roots;
}

describe('orchestrators, workers and sub-agents', () => {
  test('a worker links to its orchestrator, and its after-turn question is a soft ask', () => {
    const now = Date.now();
    setRoots(fixture(now, false));
    const rows = new Scanner().scan('claude').result;
    const worker = rows.find(r => r.hostChatId === WORKER_ID)!;
    expect(worker.parentHostChatId).toBe(ORCH_ID);
    expect(worker.live).toMatchObject({ state: 'done', ask: 'Should I commit it?' });
    const summary = scanSummary('pc', 'claude', worker);
    expect(summary.execution).toBe('idle');
    expect(summary.parentId).toBe(scanSummary('pc', 'claude', rows.find(r => r.hostChatId === ORCH_ID)!).id);
  });

  test('sub-agents are listed newest first with their type and step', () => {
    const now = Date.now();
    setRoots(fixture(now, false));
    const orch = new Scanner().scan('claude').result.find(r => r.hostChatId === ORCH_ID)!;
    expect(orch.live?.state).toBe('working');
    expect(orch.live?.subagents).toEqual([
      { name: 'Deploy check', kind: 'general-purpose', state: 'working', step: 'Running: nexus-fixture-deploy --prod', updatedAt: now - 1000 },
      { name: 'Read changelog', kind: 'Explore', state: 'done', updatedAt: now - 590_000 },
    ]);
  });

  test('a sub-agent stuck on a permission prompt makes its parent wait', () => {
    const now = Date.now();
    setRoots(fixture(now, true));
    const orch = new Scanner().scan('claude').result.find(r => r.hostChatId === ORCH_ID)!;
    expect(orch.live).toMatchObject({ state: 'waiting', waitKind: 'approval', waitingFor: 'Deploy check: Approve: nexus-fixture-deploy --prod', via: 'transcript-heuristic' });
    expect(orch.live?.subagents?.[0]).toMatchObject({ state: 'waiting', step: 'Approve: nexus-fixture-deploy --prod' });
  });
});

describe('what a waiting chat is blocked on', () => {
  const now = Date.now();
  const turn = (tool: string, input: unknown) => jsonl([
    { type: 'user', timestamp: iso(now - 20_000), message: { role: 'user', content: 'go' } },
    { type: 'assistant', timestamp: iso(now - 10_000), message: { role: 'assistant', stop_reason: 'tool_use', content: [{ type: 'tool_use', id: 't', name: tool, input }] } },
  ]);
  test('questions, plans and approvals', () => {
    expect(claudeLive(turn('AskUserQuestion', { questions: [{ question: 'Which port?' }] }), { mtimeMs: now - 10_000, now }).live).toMatchObject({ state: 'waiting', waitKind: 'question', waitingFor: 'Which port?' });
    expect(claudeLive(turn('ExitPlanMode', { plan: 'x' }), { mtimeMs: now - 10_000, now }).live).toMatchObject({ state: 'waiting', waitKind: 'plan' });
    expect(claudeLive(turn('Write', { file_path: '/w/a.txt' }), { mtimeMs: now - 10_000, now, permissionMode: 'default' }).live).toMatchObject({ state: 'waiting', waitKind: 'approval', waitingFor: 'Approve: Editing a.txt' });
  });
});
