// Discovery, live status and history for every native agent store on the PC.
// Runs inside ONE long-lived provider worker. Everything is read-only and
// incremental: files are re-read only when (mtime, size) changes, SQLite stores
// are opened read-only, and no agent CLI or app-server is ever spawned here.
import { closeSync, existsSync, openSync, readdirSync, readFileSync, readSync, statSync, type Stats } from 'node:fs';
import { dirname, join } from 'node:path';
import { Database } from 'bun:sqlite';
import type { ChatLive } from '../../../rpc-types/src/chat';
import { roots } from '../paths';
import { LIVE, agyFirstPrompt, agyHeadCwd, agyLive, claudeLive, clip, codexLive, freshnessLive, opencodeLive, parseJsonLines, type AgySummaryState, type OpencodeMessage } from './live';
import {
  cleanMessageText, clipTitle, cwdFromAgyCliHistory, cwdFromAgyProjectResources, cwdFromDashedSlug, extractProtobufStrings, listCursorCliHostChats,
  listCursorIdeHostChats, loadCursorCliHistory, loadCursorIdeHistory, parseAgyCliHistoryLine, parseAgyJsonl, parseAgyStepStrings,
  parseAgyWorkspaceUris, parseClaudeJsonl, parseOpencodeExport, type AgyCliHistoryEntry,
} from './local';
import { parseCodexHistoryItems, parseCodexJsonl } from './codex';

export interface ScanRow {
  hostChatId: string;
  title: string;
  preview?: string;
  cwd: string;
  updatedAt: number;
  resumable: boolean;
  source: string;
  archived?: boolean;
  live?: ChatLive;
  readOnlyReason?: string;
}
export interface ScanResult { result: ScanRow[]; reason?: string; complete: boolean }
export interface HistoryResult { result: any[]; fingerprint: string; unchanged?: boolean; reason?: string }

const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;
function stat(path: string): Stats | undefined { try { return statSync(path); } catch { return undefined; } }
function list(path: string): string[] { try { return readdirSync(path); } catch { return []; } }
function readBytes(path: string, start: number, length: number): Buffer {
  const fd = openSync(path, 'r');
  try { const buf = Buffer.alloc(Math.max(0, length)); const n = readSync(fd, buf, 0, buf.length, start); return buf.subarray(0, n); }
  finally { closeSync(fd); }
}
/** Complete lines from the start of a file; a cut-off final line is expected, not an error. */
export function readHead(path: string, max = 65_536): string {
  const buf = readBytes(path, 0, max);
  const nl = buf.lastIndexOf(0x0a);
  return buf.length < max ? buf.toString('utf8') : nl >= 0 ? buf.subarray(0, nl).toString('utf8') : '';
}
/** Complete lines from the end of a file. */
export function readTail(path: string, size: number, max: number): string {
  const start = Math.max(0, size - max);
  const buf = readBytes(path, start, size - start);
  if (!start) return buf.toString('utf8');
  const nl = buf.indexOf(0x0a);
  return nl >= 0 ? buf.subarray(nl + 1).toString('utf8') : '';
}
export function dbTime(value: unknown): number {
  if (typeof value === 'number') return value > 0 && value < 1e12 ? value * 1000 : value;
  if (typeof value !== 'string' || !value) return 0;
  const n = Date.parse(value.trim().replace(' ', 'T').replace(/(\.\d{3})\d+/, '$1'));
  return Number.isFinite(n) && n > 0 ? n : 0;
}
function openDb(path: string): Database | undefined {
  if (!existsSync(path)) return undefined;
  try { return new Database(path, { readonly: true, create: false }); } catch { return undefined; }
}
const fileKey = (st: Stats | undefined) => st ? `${st.mtimeMs}:${st.size}` : 'missing';

interface ClaudeDesktopMeta { title?: string; archived: boolean; cwd?: string; permissionMode?: string; blocked?: string; interrupted?: boolean }
interface AgySummary extends AgySummaryState { title?: string; preview?: string; workspaceUris?: string; projectId?: string; updated: number; parent: boolean; appDir: string }

export class Scanner {
  private heads = new Map<string, { key: string; value: any }>();
  private tails = new Map<string, { key: string; at: number; value: any; text?: string }>();
  private rows = new Map<string, ScanRow>();
  private located = new Map<string, { path?: string; slug?: string }>();
  private follows = new Map<string, { dev: number; ino: number; offset: number; events: any[]; used: number }>();
  private cursorBin = false;
  constructor(private now: () => number = Date.now) {}

  setCursorBin(installed: boolean) { this.cursorBin = installed; }

  scan(source: string): ScanResult {
    const now = this.now();
    switch (source) {
      case 'claude': return this.scanClaude(now);
      case 'codex': return this.scanCodex(now);
      case 'antigravity': return this.scanAgy(now);
      case 'opencode': return this.scanOpencode(now);
      case 'cursor': return this.scanCursor(now);
      default: throw new Error('Unknown conversation source');
    }
  }

  /** Cheap re-evaluation of a few hot chats (stat + cached tail). */
  live(source: string, ids: string[]): ScanRow[] {
    const now = this.now();
    const out: ScanRow[] = [];
    if (source === 'opencode') return this.opencodeRows(now, ids);
    for (const id of ids) {
      const previous = this.rows.get(`${source}:${id}`);
      if (!previous) continue;
      const where = this.located.get(`${source}:${id}`);
      let row: ScanRow | undefined;
      if (source === 'claude' && where?.path) row = this.claudeRow(where.slug || '', where.path, id, now, this.claudeDesktop());
      else if (source === 'codex') row = this.codexRefresh(previous, where?.path, now);
      else if (source === 'antigravity' && where?.path) row = this.agyRefresh(previous, where.path, now);
      else if (source === 'cursor' && where?.path) {
        const st = stat(where.path);
        if (st) row = { ...previous, updatedAt: Math.max(previous.updatedAt, st.mtimeMs), live: now - st.mtimeMs < LIVE.warmMs ? freshnessLive(st.mtimeMs, now) : previous.live };
      }
      if (row) { this.rows.set(`${source}:${id}`, row); out.push(row); }
    }
    return out;
  }

  private remember(source: string, row: ScanRow, location?: { path?: string; slug?: string }) {
    this.rows.set(`${source}:${row.hostChatId}`, row);
    if (location) this.located.set(`${source}:${row.hostChatId}`, location);
    return row;
  }
  private headed<T>(path: string, st: Stats, parse: (text: string) => T, max = 65_536): T {
    const key = st.size >= max ? `big:${st.ino}` : fileKey(st);
    const hit = this.heads.get(path);
    if (hit && hit.key === key) return hit.value;
    let value: T;
    try { value = parse(readHead(path, max)); } catch { value = parse(''); }
    this.heads.set(path, { key, value });
    return value;
  }
  /** Tail-derived state is recomputed when the file changes, or every ~1.5 s while time can still flip it. */
  private tailed<T>(path: string, st: Stats, now: number, bytes: number, extra: string, compute: (text: string) => T): T {
    const key = `${fileKey(st)}:${extra}`;
    const hit = this.tails.get(path);
    const timeSensitive = now - st.mtimeMs < LIVE.staleMs + 60_000;
    if (hit && hit.key === key && (!timeSensitive || now - hit.at < 1_500)) return hit.value;
    let text = hit && hit.key === key && hit.text !== undefined ? hit.text : undefined;
    if (text === undefined) {
      try { text = readTail(path, st.size, bytes); } catch { text = ''; }
    }
    const value = compute(text);
    this.tails.set(path, { key, at: now, value, text: timeSensitive ? text : undefined });
    if (this.tails.size > 400) this.tails.delete(this.tails.keys().next().value!);
    return value;
  }

  // -------------------------------------------------------------------------
  // Claude Code CLI + Claude Desktop "Code" sessions
  // -------------------------------------------------------------------------
  private claudeDesktop(): Map<string, ClaudeDesktopMeta> {
    const out = new Map<string, ClaudeDesktopMeta>();
    const base = join(roots().claudeDesktop, 'claude-code-sessions');
    for (const account of list(base)) for (const org of list(join(base, account))) for (const name of list(join(base, account, org))) {
      if (!/^local_.*\.json$/.test(name)) continue;
      const path = join(base, account, org, name);
      const st = stat(path);
      if (!st) continue;
      const meta = this.headed(path, st, () => {
        try {
          const d = JSON.parse(readFileSync(path, 'utf8'));
          const summary = d.postTurnSummary || {};
          const current = !d.postTurnSummaryFor || !d.lastAssistantUuid || d.postTurnSummaryFor === d.lastAssistantUuid;
          return {
            id: typeof d.cliSessionId === 'string' ? d.cliSessionId : undefined,
            meta: {
              title: typeof d.title === 'string' ? d.title : undefined, archived: d.isArchived === true,
              cwd: typeof d.cwd === 'string' ? d.cwd : undefined, permissionMode: typeof d.permissionMode === 'string' ? d.permissionMode : undefined,
              blocked: current && summary.status_category === 'blocked' && typeof summary.needs_action === 'string' && summary.needs_action.trim() ? summary.needs_action.trim() : undefined,
              interrupted: !!d.interruptedAwaitingPerson,
            } satisfies ClaudeDesktopMeta,
          };
        } catch { return { id: undefined, meta: undefined }; }
      }, Number.MAX_SAFE_INTEGER);
      if (meta.id && meta.meta) out.set(meta.id, meta.meta);
    }
    return out;
  }
  private claudeRow(slug: string, path: string, id: string, now: number, desktop: Map<string, ClaudeDesktopMeta>): ScanRow | undefined {
    const st = stat(path);
    if (!st) return undefined;
    const d = desktop.get(id);
    const head = this.headed(path, st, text => {
      let cwd: string | undefined; let prompt: string | undefined;
      for (const row of parseJsonLines(text)) {
        if (!cwd && typeof row.cwd === 'string' && row.cwd.startsWith('/')) cwd = row.cwd;
        if (!prompt && row.type === 'user' && !row.isMeta && !row.isSidechain) {
          const user = parseClaudeJsonl(JSON.stringify(row)).find(e => e.kind === 'user' && e.text && !/^<(command-|local-command)/.test(e.text));
          if (user) prompt = user.text;
        }
        if (cwd && prompt) break;
      }
      return { cwd, prompt };
    });
    let tail: ReturnType<typeof claudeLive> | undefined;
    if (now - st.mtimeMs < LIVE.warmMs) {
      const subagents: Array<{ mtimeMs: number; description?: string }> = [];
      const subDir = join(dirname(path), id, 'subagents');
      for (const name of list(subDir)) {
        if (!name.endsWith('.jsonl')) continue;
        const s = stat(join(subDir, name));
        if (!s || now - s.mtimeMs > 120_000) continue;
        const metaPath = join(subDir, name.replace(/\.jsonl$/, '.meta.json'));
        let description: string | undefined;
        try { description = JSON.parse(readFileSync(metaPath, 'utf8')).description; } catch { /* optional */ }
        subagents.push({ mtimeMs: s.mtimeMs, description });
      }
      const extra = `${subagents.map(s => s.mtimeMs).join(',')}|${d?.permissionMode || ''}`;
      tail = this.tailed(path, st, now, 262_144, extra, text => claudeLive(text, { mtimeMs: st.mtimeMs, now, permissionMode: d?.permissionMode, subagents }));
    }
    let live = tail?.live;
    if (d && (!live || !['working', 'waiting'].includes(live.state))) {
      if (d.blocked) live = { ...(live || { updatedAt: st.mtimeMs }), state: 'waiting', activity: 'waiting', waitingFor: clip(d.blocked, 200), via: 'claude-desktop' };
      else if (d.interrupted && live) live = { ...live, state: 'waiting', activity: 'waiting', waitingFor: 'Interrupted — continue when ready', via: 'claude-desktop' };
    }
    const title = clipTitle(d?.title || '') || clipTitle(tail?.title || '') || clipTitle(head.prompt || '') || clipTitle(tail?.lastPrompt || '') || 'Claude Code chat';
    const row: ScanRow = {
      hostChatId: id, title, preview: clip(cleanMessageText(tail?.lastPrompt || head.prompt || ''), 160), cwd: head.cwd || tail?.cwd || d?.cwd || cwdFromDashedSlug(slug),
      updatedAt: st.mtimeMs, resumable: true, source: d ? 'Claude Code · Desktop' : 'Claude Code', archived: d?.archived === true, live,
    };
    return this.remember('claude', row, { path, slug });
  }
  private scanClaude(now: number): ScanResult {
    const root = join(roots().claude, 'projects');
    if (!existsSync(root)) return { result: [], complete: true };
    const desktop = this.claudeDesktop();
    const out: ScanRow[] = [];
    const seen = new Set<string>();
    let complete = true;
    let slugs: string[];
    try { slugs = readdirSync(root); } catch { return { result: [], reason: 'Claude Code’s chat folder could not be read.', complete: false }; }
    for (const slug of slugs) {
      const dir = join(root, slug);
      let names: string[];
      try { if (!statSync(dir).isDirectory()) continue; names = readdirSync(dir); } catch { complete = false; continue; }
      for (const name of names) {
        if (!name.endsWith('.jsonl') || name.startsWith('agent-') || name.startsWith('journal')) continue;
        const id = name.slice(0, -6);
        if (seen.has(id)) continue;
        seen.add(id);
        const row = this.claudeRow(slug, join(dir, name), id, now, desktop);
        if (row) out.push(row);
      }
    }
    return { result: out, complete };
  }

  // -------------------------------------------------------------------------
  // Codex Desktop + CLI: thread metadata from state_N.sqlite, status from rollouts
  // -------------------------------------------------------------------------
  private codexStateDb(): string | undefined {
    const home = roots().codex;
    const found = list(home).map(name => name.match(/^state_(\d+)\.sqlite$/)).filter(Boolean) as RegExpMatchArray[];
    found.sort((a, b) => Number(b[1]) - Number(a[1]));
    return found[0] ? join(home, found[0][0]) : undefined;
  }
  private codexRollouts(): Map<string, { path: string; archived: boolean }> {
    const files = new Map<string, { path: string; archived: boolean }>();
    const visit = (path: string, archived: boolean, depth: number) => {
      if (depth > 5) return;
      let entries;
      try { entries = readdirSync(path, { withFileTypes: true }); } catch { return; }
      for (const entry of entries) {
        const child = join(path, entry.name);
        if (entry.isDirectory()) visit(child, archived, depth + 1);
        else if (entry.isFile() && entry.name.endsWith('.jsonl')) {
          const id = entry.name.match(UUID)?.[0];
          if (id) files.set(id, { path: child, archived });
        }
      }
    };
    visit(join(roots().codex, 'sessions'), false, 0);
    visit(join(roots().codex, 'archived_sessions'), true, 0);
    return files;
  }
  private codexNames(): Map<string, string> {
    const path = join(roots().codex, 'session_index.jsonl');
    const st = stat(path);
    if (!st) return new Map();
    return this.headed(path, st, () => {
      const names = new Map<string, string>();
      for (const row of parseJsonLines(readFileSync(path, 'utf8'))) if (typeof row.id === 'string' && typeof row.thread_name === 'string') names.set(row.id, row.thread_name);
      return names;
    }, Number.MAX_SAFE_INTEGER);
  }
  private codexTail(path: string | undefined, now: number) {
    const st = path ? stat(path) : undefined;
    if (!path || !st) return { st, tail: undefined };
    const tail = now - st.mtimeMs < LIVE.warmMs ? this.tailed(path, st, now, 524_288, '', text => codexLive(text, { mtimeMs: st.mtimeMs, now })) : undefined;
    return { st, tail };
  }
  private codexRefresh(previous: ScanRow, path: string | undefined, now: number): ScanRow {
    const { st, tail } = this.codexTail(path, now);
    return { ...previous, updatedAt: Math.max(previous.updatedAt, st?.mtimeMs || 0), live: tail?.live ?? previous.live };
  }
  private scanCodex(now: number): ScanResult {
    const files = this.codexRollouts();
    const names = this.codexNames();
    const out = new Map<string, ScanRow>();
    const dbPath = this.codexStateDb();
    const db = dbPath ? openDb(dbPath) : undefined;
    let complete = true;
    if (db) {
      try {
        const threads = db.query('SELECT * FROM threads').all() as any[];
        for (const t of threads) {
          if (typeof t.id !== 'string' || /subagent/.test(String(t.source || '')) || t.agent_role) continue;
          const file = files.get(t.id) || (typeof t.rollout_path === 'string' && existsSync(t.rollout_path) ? { path: t.rollout_path, archived: t.rollout_path.includes('archived_sessions') } : undefined);
          const { st, tail } = this.codexTail(file?.path, now);
          const row: ScanRow = {
            hostChatId: t.id,
            title: clipTitle(names.get(t.id) || t.name || '') || clipTitle(t.title || '') || clipTitle(t.first_user_message || '') || 'Codex conversation',
            preview: clip(t.preview || t.first_user_message, 160),
            cwd: (typeof t.cwd === 'string' && t.cwd) || tail?.cwd || '',
            updatedAt: Math.max(Number(t.updated_at_ms) || dbTime(t.updated_at), st?.mtimeMs || 0),
            resumable: true, source: 'Codex', archived: !!t.archived || !!file?.archived, live: tail?.live,
          };
          out.set(t.id, this.remember('codex', row, { path: file?.path }));
        }
      } catch { complete = false; } finally { db.close(); }
    }
    for (const [id, file] of files) {
      if (out.has(id)) continue;
      const st = stat(file.path);
      if (!st) continue;
      const meta = this.headed(file.path, st, text => {
        const first = parseJsonLines(text.split('\n')[0] || '')[0];
        return first?.type === 'session_meta' ? { cwd: first.payload?.cwd, sub: JSON.stringify(first.payload?.source ?? '').includes('subagent') } : { cwd: undefined, sub: false };
      });
      if (meta.sub) continue;
      const { tail } = this.codexTail(file.path, now);
      const row: ScanRow = { hostChatId: id, title: clipTitle(names.get(id) || '') || 'Codex conversation', cwd: meta.cwd || tail?.cwd || '', updatedAt: st.mtimeMs, resumable: true, source: 'Codex', archived: file.archived, live: tail?.live };
      out.set(id, this.remember('codex', row, { path: file.path }));
    }
    if (!db) {
      // Without the state database the index still names threads whose rollouts were pruned.
      const index = join(roots().codex, 'session_index.jsonl');
      if (existsSync(index)) for (const entry of parseJsonLines(readFileSync(index, 'utf8'))) {
        if (typeof entry.id !== 'string' || out.has(entry.id)) continue;
        out.set(entry.id, this.remember('codex', { hostChatId: entry.id, title: clipTitle(entry.thread_name || '') || 'Codex conversation', cwd: '', updatedAt: dbTime(entry.updated_at), resumable: true, source: 'Codex' }, {}));
      }
    }
    return { result: [...out.values()], complete };
  }

  // -------------------------------------------------------------------------
  // Antigravity IDE (~/.gemini/antigravity) and agy CLI (~/.gemini/antigravity-cli)
  // -------------------------------------------------------------------------
  private agySummaries(): Map<string, AgySummary> {
    const out = new Map<string, AgySummary>();
    for (const app of ['antigravity-cli', 'antigravity']) {
      const path = join(roots().gemini, app, 'conversation_summaries.db');
      const st = stat(path);
      if (!st) continue;
      const wal = stat(`${path}-wal`);
      const key = `${fileKey(st)}:${fileKey(wal)}`;
      const hit = this.heads.get(path);
      let rows: Map<string, AgySummary>;
      if (hit && hit.key === key) rows = hit.value;
      else {
        rows = new Map();
        const db = openDb(path);
        if (db) {
          try {
            for (const r of db.query('SELECT * FROM conversation_summaries').all() as any[]) {
              if (!r.conversation_id) continue;
              rows.set(r.conversation_id, {
                title: r.title || undefined, preview: r.preview || undefined, workspaceUris: r.workspace_uris || undefined, projectId: r.project_id || undefined,
                updated: dbTime(r.last_modified_time), status: r.status || undefined, notFullyIdle: Number(r.not_fully_idle) === 1 || r.not_fully_idle === 'true',
                killed: Number(r.killed) === 1 || r.killed === 'true', stepCount: Number(r.step_count) || undefined,
                parent: !!(r.parent_conversation_id || Number(r.nesting_depth) > 0), appDir: r.app_data_dir || app,
              });
            }
          } catch { /* older schema: brain transcripts still list the chat */ } finally { db.close(); }
        }
        this.heads.set(path, { key, value: rows });
      }
      for (const [id, row] of rows) out.set(id, row);
    }
    return out;
  }
  private agyCliHistory(): AgyCliHistoryEntry[] {
    const path = join(roots().gemini, 'antigravity-cli', 'history.jsonl');
    const st = stat(path);
    if (!st) return [];
    return this.headed(path, st, () => parseJsonLines(readFileSync(path, 'utf8')).map(parseAgyCliHistoryLine).filter(Boolean) as AgyCliHistoryEntry[], Number.MAX_SAFE_INTEGER);
  }
  private agyProjectCwd(projectId: string | undefined): string {
    if (!projectId || projectId === 'default-cli-project') return '';
    const path = join(roots().gemini, 'config', 'projects', `${projectId}.json`);
    const st = stat(path);
    if (!st) return '';
    return this.headed(path, st, () => { try { return cwdFromAgyProjectResources(JSON.parse(readFileSync(path, 'utf8'))); } catch { return ''; } }, Number.MAX_SAFE_INTEGER);
  }
  private agyRow(id: string, app: 'antigravity' | 'antigravity-cli', transcript: string | undefined, summary: AgySummary | undefined, history: AgyCliHistoryEntry[], now: number, fallbackUpdated = 0): ScanRow {
    const st = transcript ? stat(transcript) : undefined;
    const head = transcript && st ? this.headed(transcript, st, text => ({ prompt: agyFirstPrompt(text), cwd: agyHeadCwd(text) })) : { prompt: undefined, cwd: undefined };
    const ide = app === 'antigravity';
    const cwd = parseAgyWorkspaceUris(summary?.workspaceUris) || this.agyProjectCwd(summary?.projectId)
      || (ide ? '' : cwdFromAgyCliHistory(id, `${summary?.title ?? ''} ${summary?.preview ?? ''}`, history)) || head.cwd || '';
    let live: ChatLive | undefined;
    if (transcript && st && now - st.mtimeMs < LIVE.warmMs) {
      const extra = `${summary?.status}|${summary?.notFullyIdle}|${summary?.killed}`;
      live = this.tailed(transcript, st, now, 262_144, extra, text => agyLive(text, { mtimeMs: st.mtimeMs, now, summary })).live;
    } else if (summary && (summary.notFullyIdle || /RUNNING/.test(summary.status || '')) && !summary.killed) {
      live = { state: 'working', step: 'Working', activity: 'working', updatedAt: summary.updated || undefined, via: 'app-db' };
    }
    const title = clipTitle(summary?.title || '') || clipTitle(summary?.preview || '') || clipTitle(head.prompt || '') || 'Antigravity conversation';
    return this.remember('antigravity', {
      hostChatId: id, title, preview: clip(head.prompt ? clipTitle(head.prompt) : summary?.preview, 160), cwd,
      updatedAt: Math.max(st?.mtimeMs || 0, summary?.updated || 0, fallbackUpdated), resumable: !ide, source: ide ? 'Antigravity' : 'Antigravity CLI', live,
      readOnlyReason: ide ? 'Antigravity IDE chats can be followed here. Continue them in Antigravity on the PC, or start a new chat.' : undefined,
    }, { path: transcript });
  }
  private agyRefresh(previous: ScanRow, transcript: string, now: number): ScanRow {
    const app = transcript.includes(`${join('antigravity-cli', 'brain')}`) ? 'antigravity-cli' : 'antigravity';
    return this.agyRow(previous.hostChatId, app, transcript, this.agySummaries().get(previous.hostChatId), this.agyCliHistory(), now);
  }
  private scanAgy(now: number): ScanResult {
    const summaries = this.agySummaries();
    const history = this.agyCliHistory();
    const seen = new Set<string>();
    const out: ScanRow[] = [];
    for (const app of ['antigravity-cli', 'antigravity'] as const) {
      const base = join(roots().gemini, app);
      for (const id of list(join(base, 'brain'))) {
        if (seen.has(id) || !UUID.test(id)) continue;
        const summary = summaries.get(id);
        if (summary?.parent) continue;
        const transcript = join(base, 'brain', id, '.system_generated', 'logs', 'transcript.jsonl');
        if (!existsSync(transcript) && !summary) continue;
        seen.add(id);
        out.push(this.agyRow(id, app, existsSync(transcript) ? transcript : undefined, summary, history, now));
      }
      for (const name of list(join(base, 'conversations'))) {
        if (!name.endsWith('.db')) continue;
        const id = name.slice(0, -3);
        if (seen.has(id) || summaries.get(id)?.parent) continue;
        seen.add(id);
        out.push(this.agyRow(id, app, undefined, summaries.get(id), history, now, stat(join(base, 'conversations', name))?.mtimeMs || 0));
      }
    }
    return { result: out, complete: true };
  }

  // -------------------------------------------------------------------------
  // OpenCode: one read-only SQLite store, no CLI
  // -------------------------------------------------------------------------
  private opencodeDb() { return openDb(join(roots().opencode, 'opencode.db')); }
  private opencodeLiveFor(db: Database, id: string, updated: number, now: number): ChatLive {
    const messages = (db.query('SELECT id,data,time_created,time_updated FROM message WHERE session_id=? ORDER BY time_created DESC LIMIT 8').all(id) as any[]).reverse();
    const parsed: OpencodeMessage[] = messages.map((m, i) => {
      let data: any = {};
      try { data = JSON.parse(m.data); } catch { /* skip */ }
      const parts = i >= messages.length - 2
        ? (db.query('SELECT data FROM part WHERE message_id=? ORDER BY id DESC LIMIT 40').all(m.id) as any[]).reverse().map(p => { try { return JSON.parse(p.data); } catch { return {}; } })
        : [];
      return { data, time_created: m.time_created, time_updated: m.time_updated, parts };
    });
    const todos = db.query('SELECT content,status FROM todo WHERE session_id=? ORDER BY position').all(id) as any[];
    return opencodeLive(parsed, { updatedMs: updated, now, todos });
  }
  private opencodeRows(now: number, ids?: string[]): ScanRow[] {
    const db = this.opencodeDb();
    if (!db) return [];
    try {
      const sessions = (ids
        ? ids.map(id => db.query('SELECT id,directory,title,time_updated,time_archived FROM session WHERE id=?').get(id)).filter(Boolean)
        : db.query('SELECT id,directory,title,time_updated,time_archived FROM session WHERE parent_id IS NULL').all()) as any[];
      return sessions.map(s => {
        const updated = Number(s.time_updated) || 0;
        const key = `opencode:${s.id}`;
        const hit = this.tails.get(key);
        let live: ChatLive | undefined;
        if (now - updated < LIVE.warmMs) {
          if (hit && hit.key === String(updated) && (now - updated > LIVE.staleMs + 60_000 || now - hit.at < 1_500)) live = hit.value;
          else { live = this.opencodeLiveFor(db, s.id, updated, now); this.tails.set(key, { key: String(updated), at: now, value: live }); }
        }
        return this.remember('opencode', { hostChatId: s.id, title: clipTitle(s.title || '') || 'OpenCode conversation', cwd: s.directory || '', updatedAt: updated, resumable: true, source: 'OpenCode', archived: !!s.time_archived, live });
      });
    } finally { db.close(); }
  }
  private scanOpencode(now: number): ScanResult {
    if (!existsSync(join(roots().opencode, 'opencode.db'))) return { result: [], complete: true };
    try { return { result: this.opencodeRows(now), complete: true }; }
    catch { return { result: [], reason: 'OpenCode’s chat database could not be read.', complete: false }; }
  }

  // -------------------------------------------------------------------------
  // Cursor CLI (~/.cursor/chats) and Cursor IDE agent transcripts (read only)
  // -------------------------------------------------------------------------
  private scanCursor(now: number): ScanResult {
    const out: ScanRow[] = [];
    for (const chat of [...listCursorCliHostChats(this.cursorBin), ...listCursorIdeHostChats()]) {
      const ide = chat.hostChatId.startsWith('ide:');
      const path = ide ? this.cursorIdePath(chat.hostChatId) : undefined;
      out.push(this.remember('cursor', {
        hostChatId: chat.hostChatId, title: chat.title, cwd: chat.cwd, updatedAt: chat.updatedAt, resumable: chat.resumable !== false && !ide, source: chat.source || 'Cursor',
        live: now - chat.updatedAt < LIVE.warmMs ? freshnessLive(chat.updatedAt, now) : undefined,
        readOnlyReason: ide ? 'Cursor IDE chats are read only. Start a new chat to use Cursor CLI.' : chat.resumable === false ? 'Cursor CLI is not installed on the PC.' : undefined,
      }, { path }));
    }
    return { result: out, complete: true };
  }
  private cursorIdePath(hostChatId: string): string | undefined {
    const id = hostChatId.replace(/^ide:/, '');
    const root = join(roots().cursor, 'projects');
    for (const slug of list(root)) {
      const file = join(root, slug, 'agent-transcripts', id, `${id}.jsonl`);
      if (existsSync(file)) return file;
    }
    return undefined;
  }

  // -------------------------------------------------------------------------
  // History: read-only, fingerprinted on (mtime, size), appended incrementally
  // -------------------------------------------------------------------------
  private follow(path: string, parse: (text: string) => any[]): { events: any[]; fingerprint: string } {
    const st = statSync(path);
    let f = this.follows.get(path);
    if (!f || f.dev !== st.dev || f.ino !== st.ino || st.size < f.offset) f = { dev: st.dev, ino: st.ino, offset: 0, events: [], used: 0 };
    if (st.size > f.offset) {
      const buf = readBytes(path, f.offset, st.size - f.offset);
      const nl = buf.lastIndexOf(0x0a);
      if (nl >= 0) {
        f.events.push(...parse(buf.subarray(0, nl + 1).toString('utf8')));
        f.offset += nl + 1;
      }
    }
    f.used = Date.now();
    this.follows.set(path, f);
    if (this.follows.size > 4) {
      const oldest = [...this.follows.entries()].sort((a, b) => a[1].used - b[1].used)[0];
      if (oldest && oldest[0] !== path) this.follows.delete(oldest[0]);
    }
    return { events: f.events.slice(), fingerprint: `${st.dev}:${st.ino}:${f.offset}` };
  }
  private locate(source: string, id: string): string | undefined {
    const known = this.located.get(`${source}:${id}`)?.path;
    if (known && existsSync(known)) return known;
    if (source === 'claude') {
      const root = join(roots().claude, 'projects');
      for (const slug of list(root)) { const file = join(root, slug, `${id}.jsonl`); if (existsSync(file)) return file; }
    } else if (source === 'codex') return this.codexRollouts().get(id)?.path;
    else if (source === 'antigravity') {
      for (const app of ['antigravity-cli', 'antigravity']) {
        const file = join(roots().gemini, app, 'brain', id, '.system_generated', 'logs', 'transcript.jsonl');
        if (existsSync(file)) return file;
      }
    } else if (source === 'cursor' && id.startsWith('ide:')) return this.cursorIdePath(id);
    return undefined;
  }
  history(source: string, id: string, fingerprint?: string | null): HistoryResult {
    if (source === 'opencode') return this.opencodeHistory(id, fingerprint);
    const path = this.locate(source, id);
    if (path && source !== 'cursor') {
      const st = statSync(path);
      if (fingerprint && fingerprint === `${st.dev}:${st.ino}:${st.size}`) return { result: [], fingerprint, unchanged: true };
      const parse = source === 'claude' ? parseClaudeJsonl : source === 'codex' ? parseCodexJsonl : parseAgyJsonl;
      const { events } = this.follow(path, parse);
      const followed = this.follows.get(path)!;
      const fp = `${st.dev}:${st.ino}:${followed.offset}`;
      if (fingerprint && fingerprint === fp) return { result: [], fingerprint: fp, unchanged: true };
      return { result: events, fingerprint: fp };
    }
    if (source === 'codex') return this.codexDbHistory(id, fingerprint);
    if (source === 'antigravity') return this.agyDbHistory(id, fingerprint);
    if (source === 'cursor') {
      const st = path ? stat(path) : undefined;
      const fp = st ? fileKey(st) : `cli:${Math.floor(this.now() / 5000)}`;
      if (fingerprint && fingerprint === fp) return { result: [], fingerprint: fp, unchanged: true };
      return { result: id.startsWith('ide:') ? loadCursorIdeHistory(id) : loadCursorCliHistory(id), fingerprint: fp };
    }
    throw new Error('This conversation’s transcript is no longer on the PC.');
  }
  private codexDbHistory(id: string, fingerprint?: string | null): HistoryResult {
    const db = openDb(join(roots().codex, 'thread_history_1.sqlite'));
    if (!db) throw new Error('Codex transcript is unavailable on this PC');
    try {
      const mark = db.query('SELECT COUNT(*) AS n, MAX(updated_at_ordinal) AS u, MAX(rollout_ordinal) AS o FROM thread_items WHERE thread_id=?').get(id) as any;
      const fp = `db:${mark.n}:${mark.u}:${mark.o}`;
      if (!mark.n) throw new Error('Codex transcript is unavailable on this PC');
      if (fingerprint === fp) return { result: [], fingerprint: fp, unchanged: true };
      const items = (db.query('SELECT item_json, created_at_ms FROM thread_items WHERE thread_id=? ORDER BY rollout_ordinal').all(id) as any[]);
      return { result: parseCodexHistoryItems(items.map(i => { try { return { ...JSON.parse(i.item_json), _ts: i.created_at_ms }; } catch { return {}; } })), fingerprint: fp };
    } finally { db.close(); }
  }
  private agyDbHistory(id: string, fingerprint?: string | null): HistoryResult {
    for (const app of ['antigravity-cli', 'antigravity']) {
      const path = join(roots().gemini, app, 'conversations', `${id}.db`);
      const st = stat(path);
      if (!st) continue;
      const fp = `${fileKey(st)}:${fileKey(stat(`${path}-wal`))}`;
      if (fingerprint === fp) return { result: [], fingerprint: fp, unchanged: true };
      const db = openDb(path);
      if (!db) continue;
      try {
        const strings: string[] = [];
        for (const row of db.query('SELECT step_payload FROM steps ORDER BY idx').all() as any[]) if (row.step_payload) strings.push(...extractProtobufStrings(Buffer.from(row.step_payload)));
        return { result: parseAgyStepStrings(strings), fingerprint: fp };
      } catch { /* unknown schema */ } finally { db.close(); }
    }
    throw new Error('This Antigravity conversation has no readable transcript on the PC.');
  }
  private opencodeHistory(id: string, fingerprint?: string | null): HistoryResult {
    const db = this.opencodeDb();
    if (!db) throw new Error('OpenCode’s chat database is unavailable on this PC.');
    try {
      const mark = db.query('SELECT s.time_updated AS t, (SELECT COUNT(*) FROM message WHERE session_id=s.id) AS n, (SELECT MAX(time_updated) FROM part WHERE session_id=s.id) AS p FROM session s WHERE s.id=?').get(id) as any;
      if (!mark) throw new Error('This OpenCode conversation no longer exists.');
      const fp = `${mark.t}:${mark.n}:${mark.p}`;
      if (fingerprint === fp) return { result: [], fingerprint: fp, unchanged: true };
      const messages = db.query('SELECT id,data FROM message WHERE session_id=? ORDER BY time_created').all(id) as any[];
      const parts = new Map<string, any[]>();
      for (const p of db.query('SELECT message_id,data FROM part WHERE session_id=? ORDER BY id').all(id) as any[]) {
        try { (parts.get(p.message_id) || parts.set(p.message_id, []).get(p.message_id)!).push(JSON.parse(p.data)); } catch { /* skip */ }
      }
      const exported = { messages: messages.map(m => { let info = {}; try { info = JSON.parse(m.data); } catch { /* skip */ } return { info, parts: parts.get(m.id) || [] }; }) };
      return { result: parseOpencodeExport(exported), fingerprint: fp };
    } finally { db.close(); }
  }
}
