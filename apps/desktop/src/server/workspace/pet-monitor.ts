import type { ChatSummary } from '../../../../../packages/rpc-types/src/chat';

/** The background phone receives summaries, never native IDs, paths or controls. */
export function petSummaries(rows: ChatSummary[]) {
  return rows.filter(row => !row.managed && !row.archived && ['codex', 'antigravity'].includes(row.source))
    .sort((a, b) => rank(a) - rank(b) || (b.activityAt || 0) - (a.activityAt || 0))
    .slice(0, 100)
    .map(row => ({id: row.id, title: row.title.slice(0, 160),
      provider: row.sourceName, project: row.folderName.slice(0, 100), sessionId: row.agentSessionId, preview: (row.preview || '').slice(0, 500),
      execution: row.execution, activityAt: row.activityAt}));
}

function rank(row: ChatSummary) { return row.execution === 'needsReply' ? 0 : row.execution === 'working' ? 1 : 2; }
