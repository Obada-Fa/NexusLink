import type { AgentEvent, AgentSessionInfo } from '../../../../../packages/rpc-types/src/index';

/** Summarize a tool's name only; commands, arguments and output stay private. */
export function sessionActivity(event: Pick<AgentEvent, 'kind' | 'toolName'>): AgentSessionInfo['activity'] {
  if(event.kind === 'thinking') return 'thinking';
  if(event.kind === 'text' || event.kind === 'text-delta') return 'responding';
  if(event.kind === 'user' || event.kind === 'tool-end') return 'working';
  if(event.kind !== 'tool-start') return undefined;
  const name=(event.toolName || '').toLowerCase().replace(/[^a-z0-9]+/g,' ');
  if(/\b(edit|write|patch|apply patch|file changes?|filechange|replace|create file|notebookedit)\b/.test(name)) return 'editing';
  if(/\b(read|readfile|read file|search|grep|glob|find|list|ls|view|fetch|browse)\b/.test(name)) return 'reading';
  if(/\b(shell|bash|terminal|command|exec|execute|run)\b/.test(name)) return 'running-command';
  return 'working';
}
