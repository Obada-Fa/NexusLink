import { expect, test } from 'bun:test';
import type { ChatSummary } from '../../../../../packages/rpc-types/src/chat';
import { petSummaries } from './pet-monitor';
const row = (id: string, source = 'codex', activityAt = 1): ChatSummary => ({
  id, hostId: 'host', source, sourceName: source, nativeId: 'private-native-id',
  title: 'A'.repeat(200), preview: 'B'.repeat(900), folderId: 'folder',
  folderPath: '/private/path', folderName: 'private', activityAt, archived: false,
  execution: 'working', capabilities: {read: true, continue: false, safety: 'busy'},
});
test('pet summaries include every agent app in recency order without duplicating managed tasks', () => {
  const result = petSummaries([row('codex'), row('agy', 'antigravity', 3), row('claude', 'claude', 2), row('oc', 'opencode', 0),
    row('unknown', 'mystery', 9), {...row('managed'), managed: true}, {...row('archived'), archived: true}]);
  expect(result.map(item => item.id)).toEqual(['agy', 'claude', 'codex', 'oc']);
  expect(result[0].execution).toBe('working');
  expect(result[0].project).toBe('private');
  expect(JSON.stringify(result)).not.toContain('/private/path');
  expect(Object.keys(result[0]).sort()).toEqual(['activity', 'activityAt', 'execution', 'id', 'preview', 'progress', 'project', 'provider', 'sessionId', 'state', 'title']);
  expect(result[0].title.length).toBe(160);
  expect(result[0].preview.length).toBe(500);
});
test('pet snapshots remain bounded and tolerate missing previews and timestamps', () => {
  expect(petSummaries(Array.from({length: 150}, (_, i) => row(String(i), 'codex', i)))).toHaveLength(100);
  const result = petSummaries([{...row('no-time'), activityAt: null, preview: undefined}, row('recent')]);
  expect(result.map(item => item.id)).toEqual(['recent', 'no-time']);
  expect(result[1].preview).toBe('');
});

test('pet summaries carry live state and plan progress, never commands or paths', () => {
  const live = {state: 'waiting' as const, step: 'Running: rm -rf /secret', activity: 'waiting', waitingFor: 'Approve: rm -rf /secret',
    todos: [{text: 'a', state: 'done' as const}, {text: 'b', state: 'active' as const}, {text: 'c', state: 'pending' as const}]};
  const [item] = petSummaries([{...row('live', 'claude'), execution: 'needsReply', live}]);
  expect(item.state).toBe('waiting');
  expect(item.activity).toBe('waiting');
  expect(item.progress).toEqual({done: 1, total: 3});
  expect(JSON.stringify(item)).not.toContain('secret');
});
