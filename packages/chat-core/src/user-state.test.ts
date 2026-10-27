import { afterEach, expect, test } from 'bun:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { LibraryStorage, STALE_ATTENTION_MS, applyUserState } from './storage';
import type { ChatSummary } from '../../rpc-types/src/chat';

const dirs: string[] = [];
const stores: LibraryStorage[] = [];
afterEach(() => { stores.splice(0).forEach(s => s.close()); dirs.splice(0).forEach(d => rmSync(d, { recursive: true, force: true })); });
function store() { const d = mkdtempSync(join(tmpdir(), 'nl-user-state-')); dirs.push(d); const s = new LibraryStorage(d); stores.push(s); return s; }

function chat(id: string, activityAt: number, extra: Partial<ChatSummary> = {}): ChatSummary {
  return { id, hostId: 'pc', source: 'claude', sourceName: 'Claude Code', nativeId: id, title: id, folderId: null, folderPath: null, folderName: 'No folder',
    activityAt, archived: false, execution: 'needsReply', capabilities: { read: true, continue: true, safety: 'ready' },
    live: { state: 'waiting', waitingFor: 'run gh auth login' }, ...extra };
}
const attention = (s: LibraryStorage) => (s.page({ sort: 'monitor', monitorFilter: 'attention' }).items as ChatSummary[]).map(r => r.id);

test('marking a chat done clears needs-you until the chat does something new', () => {
  const s = store();
  const now = Date.now();
  s.upsert([chat('blocked', now - 60_000)], 'claude');
  expect(attention(s)).toEqual(['blocked']);
  const before = s.revision();
  const { row, revision } = s.setState('blocked', { acknowledged: true });
  expect(revision).toBeGreaterThan(before);
  expect(row?.attentionCleared).toBe('acknowledged');
  expect(row?.execution).toBe('idle');
  expect(row?.live?.waitingFor).toBeUndefined();
  expect(attention(s)).toEqual([]);
  // A rescan with the same activity keeps it cleared…
  s.upsert([chat('blocked', now - 60_000)], 'claude');
  expect(attention(s)).toEqual([]);
  // …new activity after the mark brings it back.
  s.upsert([chat('blocked', Date.now() + 5_000)], 'claude');
  expect(attention(s)).toEqual(['blocked']);
  // Undo also restores it.
  s.setState('blocked', { acknowledged: true });
  s.setState('blocked', { acknowledged: false });
  expect(attention(s)).toEqual(['blocked']);
});

test('inferred needs-you goes stale after hours; a real pending approval never does', () => {
  const s = store();
  const old = Date.now() - STALE_ATTENTION_MS - 60_000;
  s.upsert([chat('stale', old)], 'claude');
  const row = s.get('stale')!;
  expect(row.attentionCleared).toBe('stale');
  expect(attention(s)).toEqual([]);
  const pending = applyUserState(chat('approval', old, { agentSessionId: 's1', managed: true }), undefined, Date.now(), true);
  expect(pending.attentionCleared).toBeUndefined();
  expect(pending.execution).toBe('needsReply');
});

test('decay clears rows that aged out after they were written', () => {
  const s = store();
  s.upsert([chat('aging', Date.now() - 1000)], 'claude');
  expect(attention(s)).toEqual(['aging']);
  const before = s.revision();
  expect(s.decay(Date.now() + STALE_ATTENTION_MS + 10_000)).toBe(before);
  // decay() consults the real clock inside write(); age the stored activity instead.
  s.db.query('UPDATE chats SET activity=? WHERE id=?').run(Date.now() - STALE_ATTENTION_MS - 5000, 'aging');
  s.db.query("UPDATE chats SET scan=json_set(scan,'$.activityAt',?) WHERE id=?").run(Date.now() - STALE_ATTENTION_MS - 5000, 'aging');
  expect(s.decay()).toBeGreaterThan(before);
  expect(attention(s)).toEqual([]);
});

test('hidden chats leave the Monitor and come back when unhidden', () => {
  const s = store();
  s.upsert([chat('noise', Date.now(), { execution: 'idle', live: { state: 'done' } })], 'claude');
  expect((s.page({}).items as ChatSummary[]).map(r => r.id)).toEqual(['noise']);
  s.setState('noise', { hidden: true });
  expect(s.page({}).items).toHaveLength(0);
  expect((s.page({ archived: true }).items as ChatSummary[]).map(r => r.id)).toEqual(['noise']);
  s.upsert([chat('noise', Date.now() + 1000, { execution: 'idle', live: { state: 'done' } })], 'claude');
  expect(s.page({}).items).toHaveLength(0);
  s.setState('noise', { hidden: false });
  expect((s.page({}).items as ChatSummary[]).map(r => r.id)).toEqual(['noise']);
  expect(() => s.setState('missing', { hidden: true })).toThrow();
});
