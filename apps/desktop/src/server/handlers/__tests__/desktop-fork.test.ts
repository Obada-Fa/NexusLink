// Continuing a Claude Desktop chat from Nexus forks it (the desktop app never
// reloads turns another process adds), and the host records its running-turn
// count for scripts/deploy-host.sh.
import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { delimiter, join } from 'node:path';
import type { WsMessage } from '@nexuslink/rpc-types';
import { setRoots } from '../../../../../../packages/chat-core/src/paths';
import {
  agentWatchdogTestHooks,
  busyTurnsMarkerPath,
  claudeDesktopOwnsSession,
  claudeSpawnArgs,
  closeAgentSession,
  createAgentSession,
  promptAgent,
  setAgentBroadcast,
} from '../agents';

const root = mkdtempSync(join(tmpdir(), 'nexuslink-desktop-fork-'));
const desktopDir = join(root, 'Claude');
const sessionsDir = join(desktopDir, 'claude-code-sessions', 'acct', 'org');
const DESKTOP_ID = '11111111-2222-3333-4444-555555555555';
const ARCHIVED_ID = '66666666-7777-8888-9999-000000000000';
const FORK_ID = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
const oldDataDir = process.env.NEXUSLINK_DATA_DIR;

beforeAll(() => {
  mkdirSync(sessionsDir, { recursive: true });
  writeFileSync(join(sessionsDir, 'local_a.json'), JSON.stringify({ sessionId: 'local_a', cliSessionId: DESKTOP_ID, isArchived: false }));
  writeFileSync(join(sessionsDir, 'local_b.json'), JSON.stringify({ sessionId: 'local_b', cliSessionId: ARCHIVED_ID, isArchived: true }));
  writeFileSync(join(sessionsDir, 'local_c.json'), '{ not json');
  setRoots({ claudeDesktop: desktopDir });
  process.env.NEXUSLINK_DATA_DIR = join(root, 'data');
});

afterAll(() => {
  setRoots();
  if (oldDataDir === undefined) delete process.env.NEXUSLINK_DATA_DIR; else process.env.NEXUSLINK_DATA_DIR = oldDataDir;
  rmSync(root, { recursive: true, force: true });
});

test('claudeDesktopOwnsSession: only live desktop sessions count', () => {
  expect(claudeDesktopOwnsSession(DESKTOP_ID)).toBe(true);
  expect(claudeDesktopOwnsSession(ARCHIVED_ID)).toBe(false);
  expect(claudeDesktopOwnsSession(FORK_ID)).toBe(false);
  expect(claudeDesktopOwnsSession('')).toBe(false);
  expect(claudeDesktopOwnsSession(DESKTOP_ID, join(root, 'missing'))).toBe(false);
});

test('claudeSpawnArgs adds --fork-session only with --resume', () => {
  const forked = claudeSpawnArgs({ bin: 'claude', resumeId: DESKTOP_ID, forkSession: true });
  expect(forked.slice(forked.indexOf('--resume'), forked.indexOf('--resume') + 3)).toEqual(['--resume', DESKTOP_ID, '--fork-session']);
  expect(claudeSpawnArgs({ bin: 'claude', resumeId: DESKTOP_ID })).not.toContain('--fork-session');
  expect(claudeSpawnArgs({ bin: 'claude', forkSession: true })).not.toContain('--fork-session');
});

test('busy-turns marker follows setBusy', () => {
  const info = createAgentSession('claude', root, 'marker');
  try {
    // Other test files share this module, so compare with the count before.
    agentWatchdogTestHooks.setBusy(info.agentSessionId, false);
    const before = JSON.parse(readFileSync(busyTurnsMarkerPath(), 'utf8')).busy as number;
    agentWatchdogTestHooks.setBusy(info.agentSessionId, true);
    expect(JSON.parse(readFileSync(busyTurnsMarkerPath(), 'utf8'))).toMatchObject({ busy: before + 1, pid: process.pid });
    agentWatchdogTestHooks.setBusy(info.agentSessionId, false);
    expect(JSON.parse(readFileSync(busyTurnsMarkerPath(), 'utf8')).busy).toBe(before);
  } finally {
    closeAgentSession(info.agentSessionId);
  }
});

describe('ClaudeAdapter on a desktop-owned chat (fake claude binary)', () => {
  const binDir = join(root, 'bin');
  const work = join(root, 'work');
  const oldPath = process.env.PATH;
  let messages: WsMessage[] = [];

  beforeAll(() => {
    mkdirSync(binDir, { recursive: true });
    mkdirSync(work, { recursive: true });
    const wrapper = join(binDir, 'claude');
    writeFileSync(wrapper, `#!/bin/sh\nexec "${process.execPath}" "${join(import.meta.dir, 'fixtures', 'fake-claude.ts')}" "$@"\n`);
    chmodSync(wrapper, 0o755);
    process.env.PATH = `${binDir}${delimiter}${oldPath ?? ''}`;
    setAgentBroadcast((m) => messages.push(m));
  });

  afterAll(() => {
    process.env.PATH = oldPath;
    delete process.env.FAKE_CLAUDE_SCRIPT;
    delete process.env.FAKE_CLAUDE_ARGV;
    delete process.env.FAKE_CLAUDE_ENV;
    setAgentBroadcast(() => {});
  });

  async function runTurn(name: string, hostChatId: string, sid: string): Promise<{ argv: string[]; events: WsMessage[]; hostChatId?: string }> {
    const script = join(root, `${name}.jsonl`);
    writeFileSync(script, [
      { type: 'system', subtype: 'init', session_id: sid },
      { type: 'assistant', session_id: sid, message: { role: 'assistant', content: [{ type: 'text', text: 'ok' }] } },
      { type: 'result', subtype: 'success', session_id: sid, result: 'ok' },
    ].map((l) => JSON.stringify(l)).join('\n') + '\n');
    const argvFile = join(root, `${name}.argv.json`);
    process.env.FAKE_CLAUDE_SCRIPT = script;
    process.env.FAKE_CLAUDE_ARGV = argvFile;
    messages = [];
    const info = createAgentSession('claude', work, name, { hostChatId });
    try {
      expect(promptAgent(info.agentSessionId, 'hello').ok).toBe(true);
      const until = Date.now() + 8000;
      const done = () => messages.some((m) => m.type === 'agent-event' && m.agentSessionId === info.agentSessionId && m.event.kind === 'result');
      while (!done()) {
        if (Date.now() > until) throw new Error('timed out waiting for result');
        await Bun.sleep(10);
      }
      const updates = messages.filter((m): m is Extract<WsMessage, { type: 'agent-session-update' }> => m.type === 'agent-session-update' && m.session.agentSessionId === info.agentSessionId);
      return {
        argv: existsSync(argvFile) ? JSON.parse(readFileSync(argvFile, 'utf8')) : [],
        events: messages.filter((m) => m.type === 'agent-event' && m.agentSessionId === info.agentSessionId),
        hostChatId: updates.at(-1)?.session.hostChatId,
      };
    } finally {
      closeAgentSession(info.agentSessionId);
    }
  }

  const statusTexts = (events: WsMessage[]) => events
    .map((m) => (m.type === 'agent-event' && m.event.kind === 'status' ? m.event.text ?? '' : ''))
    .filter(Boolean);

  test('forks, says so, and follows the copy', async () => {
    const run = await runTurn('desktop', DESKTOP_ID, FORK_ID);
    expect(run.argv).toContain('--fork-session');
    expect(run.argv[run.argv.indexOf('--resume') + 1]).toBe(DESKTOP_ID);
    expect(statusTexts(run.events).some((t) => t.includes('separate copy'))).toBe(true);
    expect(run.hostChatId).toBe(FORK_ID);
  });

  test('a CLI-only chat resumes in place', async () => {
    const run = await runTurn('cli', FORK_ID, FORK_ID);
    expect(run.argv).not.toContain('--fork-session');
    expect(run.argv[run.argv.indexOf('--resume') + 1]).toBe(FORK_ID);
    expect(statusTexts(run.events).some((t) => t.includes('separate copy'))).toBe(false);
  });

  test('agent processes carry NEXUSLINK_AGENT_TURN', async () => {
    // The env var is what deploy-host.sh checks; the fake records nothing of
    // the env, so check through a tiny wrapper instead.
    const envFile = join(root, 'env.txt');
    const wrapper = join(binDir, 'claude');
    writeFileSync(wrapper, `#!/bin/sh\necho "$NEXUSLINK_AGENT_TURN" > "${envFile}"\nexec "${process.execPath}" "${join(import.meta.dir, 'fixtures', 'fake-claude.ts')}" "$@"\n`);
    chmodSync(wrapper, 0o755);
    await runTurn('env', FORK_ID, FORK_ID);
    expect(readFileSync(envFile, 'utf8').trim()).toBe('1');
  });
});
