export type AgentHistoryEvent = { seq: number };

/** Keep live events that arrived after the host snapshot was taken. */
export function mergeAgentHistory<T extends AgentHistoryEvent>(
  history: T[],
  live: T[],
): T[] {
  if (history.length === 0) return [...live];
  let maxSeq = -1;
  for (const e of history) {
    if (e.seq > maxSeq) maxSeq = e.seq;
  }
  return [...history, ...live.filter((e) => e.seq > maxSeq)];
}
