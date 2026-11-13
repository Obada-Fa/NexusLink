// Silent-turn watchdog: one status line when a busy turn goes quiet.
import { afterAll, beforeAll, beforeEach, describe, expect, test } from 'bun:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { AgentEvent, WsMessage } from '@nexuslink/rpc-types';
import {
  agentWatchdogTestHooks as hooks,
  closeAgentSession,
  createAgentSession,
  SILENT_TURN_MS,
  SILENT_TURN_TEXT,
  setAgentBroadcast,
  silentWatchdogConfig,
} from '../agents';

const T = 60;
const work = mkdtempSync(join(tmpdir(), 'nexuslink-watchdog-'));
let messages: WsMessage[] = [];
let id = '';
const opened: string[] = [];
const notes = () => messages
  .filter((m): m is Extract<WsMessage, { type: 'agent-event' }> => m.type === 'agent-event' && m.agentSessionId === id)
  .map((m) => m.event)
  .filter((e: AgentEvent) => e.kind === 'status' && e.text === SILENT_TURN_TEXT);

beforeAll(() => { silentWatchdogConfig.thresholdMs = T; });
afterAll(() => {
  silentWatchdogConfig.thresholdMs = SILENT_TURN_MS;
  for (const o of opened) closeAgentSession(o);
  setAgentBroadcast(() => {});
  rmSync(work, { recursive: true, force: true });
});
beforeEach(() => {
  messages = [];
  setAgentBroadcast((m) => messages.push(m));
  id = createAgentSession('mock', work, 'wd').agentSessionId;
  opened.push(id);
});

describe('silent-turn watchdog', () => {
  test('default is 10 minutes and the text is exact', () => {
    expect(SILENT_TURN_MS).toBe(600_000);
    expect(SILENT_TURN_TEXT).toBe('No output for 10 min. Still running; tap Stop if it looks stuck.');
  });

  test('fires once when busy and quiet', async () => {
    hooks.setBusy(id, true);
    await Bun.sleep(T * 3);
    expect(notes()).toHaveLength(1);
  });

  test('does not fire when not busy', async () => {
    await Bun.sleep(T * 3);
    expect(notes()).toHaveLength(0);
    expect(hooks.watching(id)).toBe(false);
  });

  test('an event resets the clock', async () => {
    hooks.setBusy(id, true);
    for (let i = 0; i < 4; i++) { await Bun.sleep(T / 2); hooks.emit(id, { kind: 'thinking', text: 'x' }); }
    expect(notes()).toHaveLength(0);
  });

  test('not with a pending permission', async () => {
    hooks.setBusy(id, true);
    hooks.pendingPermissions(id)!.set('p1', () => {});
    await Bun.sleep(T * 3);
    expect(notes()).toHaveLength(0);
  });

  test('not with a pending approval request', async () => {
    hooks.setBusy(id, true);
    hooks.emit(id, { kind: 'permission-request', refId: 'ap1', toolName: 'Shell', text: 'Allow?' });
    await Bun.sleep(T * 3);
    expect(notes()).toHaveLength(0);
  });

  test('not with an open tool; fires after it ends', async () => {
    hooks.setBusy(id, true);
    hooks.emit(id, { kind: 'tool-start', toolName: 'Shell', refId: 't1' });
    await Bun.sleep(T * 3);
    expect(notes()).toHaveLength(0);
    hooks.emit(id, { kind: 'tool-end', toolName: 'Shell', refId: 't1' });
    await Bun.sleep(T * 3);
    expect(notes()).toHaveLength(1);
  });

  test('once per stretch; again after a real event and another threshold', async () => {
    hooks.setBusy(id, true);
    await Bun.sleep(T * 4);
    expect(notes()).toHaveLength(1);
    hooks.emit(id, { kind: 'text', text: 'alive' });
    await Bun.sleep(T * 4);
    expect(notes()).toHaveLength(2);
  });

  test('stops at turn end and never changes busy', async () => {
    hooks.setBusy(id, true);
    await Bun.sleep(T * 3);
    expect(notes()).toHaveLength(1);
    hooks.setBusy(id, false);
    hooks.setBusy(id, true);
    hooks.setBusy(id, false);
    expect(hooks.watching(id)).toBe(false);
    await Bun.sleep(T * 3);
    expect(notes()).toHaveLength(1);
  });

  test('stops when the session closes', async () => {
    hooks.setBusy(id, true);
    closeAgentSession(id);
    await Bun.sleep(T * 3);
    expect(notes()).toHaveLength(0);
  });

  test('busy stays true after firing', async () => {
    hooks.setBusy(id, true);
    await Bun.sleep(T * 3);
    const last = messages.filter((m) => m.type === 'agent-session-update' && m.session.agentSessionId === id).at(-1);
    expect((last as Extract<WsMessage, { type: 'agent-session-update' }>).session.busy).toBe(true);
  });
});
