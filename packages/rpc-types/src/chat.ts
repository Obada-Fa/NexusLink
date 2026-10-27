import type { AgentEvent, AgentImageAttachment } from './index';

export type ContinuationSafety = 'ready' | 'busy' | 'unknown';
export interface ChatSummary {
  id: string;
  hostId: string;
  source: string;
  sourceName: string;
  nativeId?: string;
  agentSessionId?: string;
  managed?: boolean;
  title: string;
  preview?: string;
  folderId: string | null;
  folderPath: string | null;
  folderName: string;
  activityAt: number | null;
  archived: boolean;
  taskState?: string;
  activity?: string;
  execution: 'working' | 'needsReply' | 'idle' | 'unknown';
  capabilities: { read: boolean; continue: boolean; safety: ContinuationSafety; reason?: string };
  /** Live view of what the agent is doing right now, for chats running anywhere on the PC. */
  live?: ChatLive;
  /** Set when a needs-you state was cleared: the owner marked it done, or it went stale. */
  attentionCleared?: 'acknowledged' | 'stale';
}
export interface ChatLive {
  /** working: actively producing; waiting: blocked on the user (approval/question); done: finished its last turn; failed: last turn errored. */
  state: 'working' | 'waiting' | 'done' | 'failed' | 'idle';
  /** Human sentence for the current step, e.g. "Editing lib/main.dart", "Running: npm test", "Thinking". */
  step?: string;
  /** Raw tool name of the current step when known (Edit, Bash, shell, apply_patch…). */
  tool?: string;
  /** reading | editing | running-command | thinking | responding | searching | browsing | waiting */
  activity?: string;
  /** Start of the current run/turn (ms). */
  turnStartedAt?: number;
  /** Last time the agent wrote anything (ms). */
  updatedAt?: number;
  /** Plan/todo progress when the agent keeps one (TodoWrite, update_plan, task boundaries). */
  todos?: { text: string; state: 'pending' | 'active' | 'done' }[];
  /** Last assistant sentence, ≤ 280 chars. */
  lastText?: string;
  /** Why it is waiting, e.g. "Approve: rm -rf build" or the question text. */
  waitingFor?: string;
  model?: string;
  /** Turns/steps so far in this chat, when cheap to know. */
  steps?: number;
  /** Where the status came from: transcript tail, app metadata, process, nexuslink. */
  via?: string;
}
export interface FolderSummary {
  id: string | null;
  name: string;
  path: string | null;
  count: number;
  activityAt: number | null;
  latestTitle: string;
}
export interface SourceHealth {
  source: string;
  state: 'scanning' | 'ready' | 'error';
  reason?: string;
  lastSuccessAt?: number;
  durationMs?: number;
}
export interface ChatQuery {
  sort?: string;
  monitorFilter?: 'all' | 'running' | 'attention' | 'recent';
  query?: string;
  source?: string;
  folderId?: string | null;
  archived?: boolean;
  cursor?: string;
  limit?: number;
}
export interface ChatPage<T> {
  items: T[];
  nextCursor: string | null;
  revision: number;
  restart?: boolean;
  sources: SourceHealth[];
}
export interface ChatHistoryEvent extends AgentEvent {
  id: string;
  historical?: boolean;
  truncated?: boolean;
}
export interface ChatHistoryPage {
  appendOnly?: boolean;
  chat?: ChatSummary;
  events: ChatHistoryEvent[];
  olderCursor: string | null;
  newerCursor: string | null;
  revision: string;
  completeness: 'complete' | 'partial' | 'unavailable';
  reason?: string;
  restart?: boolean;
}
export interface ChatSend {
  chatId: string;
  text: string;
  images?: AgentImageAttachment[];
  model?: string;
  thinking?: string;
  mode?: import('./index').AgentMode;
  requiredFolder?: string;
  expectedRevision?: number;
  operationId: string;
  interrupt?: boolean;
}
export interface ChatDelivery {
  operationId: string;
  state: 'claimed' | 'dispatching' | 'delivered' | 'rejected' | 'uncertain';
  agentSessionId?: string;
  reason?: string;
}
export interface ChatRpc {
  'chat.list': { params: ChatQuery; result: ChatPage<ChatSummary> };
  'chat.folders': { params: ChatQuery & { sort?: 'activity' | 'name' }; result: ChatPage<FolderSummary> };
  'chat.historyPage': { params: { chatId: string; olderCursor?: string; newerCursor?: string; limit?: number }; result: ChatHistoryPage };
  'chat.refresh': { params: { source?: string }; result: { ok: boolean; revision: number } };
  'chat.subscribe': { params: { enabled: boolean }; result: { revision: number } };
  'chat.send': { params: ChatSend; result: ChatDelivery };
  'chat.sendStatus': { params: { operationId: string }; result: ChatDelivery | null };
  'chat.setState': { params: { chatId: string; acknowledged?: boolean; hidden?: boolean }; result: { ok: boolean; chat?: ChatSummary; revision: number } };
}
