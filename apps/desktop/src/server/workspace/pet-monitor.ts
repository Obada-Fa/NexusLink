import type { ChatSummary } from '../../../../../packages/rpc-types/src/chat';

/** Every agent app the library discovers (NexusLink-managed tasks reach the pet separately). */
export const PET_SOURCES = ['claude', 'codex', 'antigravity', 'opencode', 'cursor'] as const;

/**
 * The background phone receives summaries, never native IDs, paths, commands
 * or controls: only the coarse state/activity category and plan progress.
 */
export function petSummaries(rows: ChatSummary[]) {
  return rows.filter(row => !row.managed && !row.archived && (PET_SOURCES as readonly string[]).includes(row.source))
    .sort((a, b) => rank(a) - rank(b) || (b.activityAt || 0) - (a.activityAt || 0))
    .slice(0, 100)
    .map(row => {
      const todos = row.live?.todos;
      return {id: row.id, title: row.title.slice(0, 160),
        provider: row.sourceName, project: row.folderName.slice(0, 100), sessionId: row.agentSessionId, preview: (row.preview || '').slice(0, 500),
        execution: row.execution, activityAt: row.activityAt,
        state: row.live?.state, activity: row.live?.activity,
        progress: todos?.length ? {done: todos.filter(t => t.state === 'done').length, total: todos.length} : undefined};
    });
}

function rank(row: ChatSummary) { return row.execution === 'needsReply' ? 0 : row.execution === 'working' ? 1 : 2; }
