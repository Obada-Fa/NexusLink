import { expect, test } from 'bun:test';
import type { ChatSummary } from '../../../../../packages/rpc-types/src/chat';
import { petSummaries } from './pet-monitor';
const row = (id: string, source = 'codex', activityAt = 1): ChatSummary => ({
  id, hostId: 'host', source, sourceName: source, nativeId: 'private-native-id',
  title: 'A'.repeat(200), preview: 'B'.repeat(900), folderId: 'folder',
  folderPath: '/private/path', folderName: 'private', activityAt, archived: false,
  execution: 'working', capabilities: {read: true, continue: false, safety: 'busy'},
});
test('pet summaries include read-only GUI chats in recency order without duplicating managed tasks', () => {
  const result = petSummaries([row('codex'), row('agy', 'antigravity', 3), row('other', 'claude'),
    {...row('managed'), managed: true}, {...row('archived'), archived: true}]);
  expect(result.map(item => item.id)).toEqual(['agy', 'codex']);
  expect(result[0].execution).toBe('working');
  expect(result[0].project).toBe('private');
  expect(JSON.stringify(result)).not.toContain('/private/path');
  expect(Object.keys(result[0]).sort()).toEqual(['activityAt', 'execution', 'id', 'preview', 'project', 'provider', 'sessionId', 'title']);
  expect(result[0].title.length).toBe(160);
  expect(result[0].preview.length).toBe(500);
});
test('pet snapshots remain bounded and tolerate missing previews and timestamps', () => {
  expect(petSummaries(Array.from({length: 150}, (_, i) => row(String(i), 'codex', i)))).toHaveLength(100);
  const result = petSummaries([{...row('no-time'), activityAt: null, preview: undefined}, row('recent')]);
  expect(result.map(item => item.id)).toEqual(['recent', 'no-time']);
  expect(result[1].preview).toBe('');
});
