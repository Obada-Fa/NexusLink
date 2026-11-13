export interface ConversationSummary {
  agent: string;
  cwd: string;
  title: string;
  busy?: boolean;
  taskState?: string;
  updatedAt?: number;
  preview?: string;
}

export function matchesConversation(chat: ConversationSummary, search: string): boolean {
  return `${chat.title} ${chat.cwd} ${chat.agent} ${chat.preview ?? ''}`.toLowerCase().includes(search.trim().toLowerCase());
}

export function conversationState(chat: ConversationSummary, approval = false): string {
  if (approval || chat.taskState === 'waiting') return 'Needs you';
  if (chat.busy || chat.taskState === 'running') return 'Working';
  if (chat.taskState === 'failed') return 'Failed';
  if (chat.taskState === 'completed') return 'Completed';
  if (chat.taskState === 'canceled') return 'Stopped';
  return 'Ready';
}

export function groupConversations<T extends ConversationSummary>(chats: T[]): Array<{ path: string; chats: T[] }> {
  const groups = new Map<string, T[]>();
  for (const chat of chats) {
    const path = chat.cwd.trim();
    const group = groups.get(path) ?? [];
    group.push(chat);
    groups.set(path, group);
  }
  return [...groups].map(([path, chats]) => ({ path, chats: chats.slice().sort((a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0)) }))
    .sort((a, b) => (b.chats[0]?.updatedAt ?? 0) - (a.chats[0]?.updatedAt ?? 0) || a.path.localeCompare(b.path));
}
