import { homedir } from 'node:os';
import { join } from 'node:path';

/** Where each agent keeps its native chats. Overridable so tests never touch real user data. */
export interface ProviderRoots {
  claude: string;
  claudeDesktop: string;
  codex: string;
  gemini: string;
  opencode: string;
  cursor: string;
}

export function defaultRoots(): ProviderRoots {
  const home = homedir();
  return {
    claude: process.env.CLAUDE_CONFIG_DIR || join(home, '.claude'),
    claudeDesktop: join(process.env.XDG_CONFIG_HOME || join(home, '.config'), 'Claude'),
    codex: process.env.CODEX_HOME || join(home, '.codex'),
    gemini: join(home, '.gemini'),
    opencode: join(process.env.XDG_DATA_HOME || join(home, '.local', 'share'), 'opencode'),
    cursor: join(home, '.cursor'),
  };
}

let current: ProviderRoots | undefined;
export function roots(): ProviderRoots { return current ??= defaultRoots(); }
export function setRoots(next?: Partial<ProviderRoots>) { current = { ...defaultRoots(), ...(next || {}) }; }

/** Native files whose writes mean "this source changed". Everything else (logs, -shm, tmp) is ignored. */
export interface WatchSpec { source: string; dir: string; recursive: boolean; match(name: string): boolean }
export function watchSpecs(r: ProviderRoots = roots()): WatchSpec[] {
  const base = (name: string) => name.split(/[\\/]/).pop() || '';
  const jsonl = (name: string) => base(name).endsWith('.jsonl');
  return [
    { source: 'claude', dir: join(r.claude, 'projects'), recursive: true, match: jsonl },
    { source: 'claude', dir: join(r.claudeDesktop, 'claude-code-sessions'), recursive: true, match: n => /^local_[^/\\]*\.json$/.test(base(n)) },
    { source: 'codex', dir: join(r.codex, 'sessions'), recursive: true, match: jsonl },
    { source: 'codex', dir: r.codex, recursive: false, match: n => base(n) === 'session_index.jsonl' },
    // Brain folders hold ~15k step directories: watch only the top level for new
    // conversations; hot chats are followed by the 2 s live poll instead.
    { source: 'antigravity', dir: join(r.gemini, 'antigravity', 'brain'), recursive: false, match: () => true },
    { source: 'antigravity', dir: join(r.gemini, 'antigravity-cli', 'brain'), recursive: false, match: () => true },
    { source: 'antigravity', dir: join(r.gemini, 'antigravity'), recursive: false, match: n => /^conversation_summaries\.db(-wal)?$/.test(base(n)) },
    { source: 'antigravity', dir: join(r.gemini, 'antigravity-cli'), recursive: false, match: n => /^conversation_summaries\.db(-wal)?$/.test(base(n)) },
    { source: 'opencode', dir: r.opencode, recursive: false, match: n => /^opencode\.db(-wal)?$/.test(base(n)) },
    { source: 'cursor', dir: join(r.cursor, 'projects'), recursive: true, match: jsonl },
    { source: 'cursor', dir: join(r.cursor, 'chats'), recursive: true, match: n => base(n) === 'meta.json' },
  ];
}
