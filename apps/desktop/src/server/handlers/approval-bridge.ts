// Phone approvals for Claude sessions NexusLink did not start, through Claude Code's own
// PermissionRequest HTTP hook (https://code.claude.com/docs/en/hooks). Rules:
// - The listener is loopback-only and needs the bearer token written into the hook config.
// - Nothing is ever decided without the owner: no answer (timeout, NexusLink down, phone
//   asleep) returns an empty 200, and Claude shows its normal prompt.
// - Claude Desktop shows its own dialog in parallel; whichever side answers first wins, and
//   Claude cancels the other. An answer given on the PC is noticed in the transcript.
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { chmodSync, closeSync, existsSync, mkdirSync, openSync, readdirSync, readFileSync, readSync, renameSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import type { ApprovalBridgeStatus, ExternalApproval, ExternalApprovalQuestion } from '@nexuslink/rpc-types';
import { clip, describeTool } from '../../../../../packages/chat-core/src/providers/live';
import { identity } from '../../../../../packages/chat-core/src/identity';

/** Claude's hook timeout; the bridge gives up a little earlier so Claude never cancels it. */
export const HOOK_TIMEOUT_S = 1800;
const HOLD_MS = (HOOK_TIMEOUT_S - 15) * 1000;
const HOOK_PATH = '/nexuslink/claude/permission';
const PUSH_AFTER_MS = 10_000;

export interface ApprovalBridgeOptions {
  dataDir: string;
  hostId: string;
  /** ~/.claude/settings.json */
  claudeSettingsPath: string;
  /** ~/.config/Claude/claude-code-sessions (Claude Desktop's session metadata). */
  desktopSessionsDir: string;
  port?: number;
  onChange?: (items: ExternalApproval[]) => void;
  push?: (approval: ExternalApproval) => void;
  now?: () => number;
  pollMs?: number;
}

type Decision = Record<string, unknown> | null;
interface Pending {
  item: ExternalApproval;
  input: Record<string, unknown>;
  settle: (decision: Decision) => void;
  transcript?: string;
  /** Bytes of the transcript already looked at (always at a line end). */
  scanned: number;
  /** This call's tool_use id, once seen. Claude may write it just after the hook fires. */
  toolUseId?: string;
  pushTimer?: ReturnType<typeof setTimeout>;
}
interface Config { token: string; holdTerminal: boolean }

function readTail(path: string, from: number): string {
  const size = statSync(path).size;
  const start = Math.max(0, Math.min(from, size));
  const fd = openSync(path, 'r');
  try { const buf = Buffer.alloc(size - start); readSync(fd, buf, 0, buf.length, start); return buf.toString('utf8'); }
  finally { closeSync(fd); }
}
const fileSize = (path: string) => { try { return statSync(path).size; } catch { return -1; } };
const sameJson = (a: unknown, b: unknown) => { try { return JSON.stringify(a) === JSON.stringify(b); } catch { return false; } };

/** What the phone shows for one hook request. */
export function describeRequest(tool: string, input: Record<string, unknown>): Pick<ExternalApproval, 'kind' | 'title' | 'detail' | 'questions'> {
  if (tool === 'AskUserQuestion') {
    const questions: ExternalApprovalQuestion[] = (Array.isArray(input.questions) ? input.questions : []).filter((q: any) => q && typeof q.question === 'string').map((q: any) => ({
      question: q.question,
      ...(typeof q.header === 'string' ? { header: q.header } : {}),
      options: (Array.isArray(q.options) ? q.options : []).filter((o: any) => o && typeof o.label === 'string').map((o: any) => ({ label: o.label, ...(typeof o.description === 'string' ? { description: o.description } : {}) })),
      ...(q.multiSelect === true ? { multiSelect: true } : {}),
    }));
    return { kind: 'question', title: clip(questions[0]?.question, 200) || 'Answer a question', questions };
  }
  if (tool === 'ExitPlanMode') return { kind: 'plan', title: 'Approve the plan', detail: typeof input.plan === 'string' ? input.plan.slice(0, 4000) : undefined };
  const { step } = describeTool(tool, input);
  let detail: string | undefined;
  if (typeof input.command === 'string') detail = input.command;
  else if (typeof input.file_path === 'string') {
    const change = [input.old_string && `- ${input.old_string}`, input.new_string && `+ ${input.new_string}`, typeof input.content === 'string' && input.content].filter(Boolean).join('\n');
    detail = change ? `${input.file_path}\n${change}` : String(input.file_path);
  } else if (typeof input.url === 'string') detail = input.url;
  else { try { detail = JSON.stringify(input, null, 1); } catch { /* unprintable */ } }
  return { kind: 'approval', title: step.startsWith('Running: ') ? `Run: ${step.slice(9)}` : step, detail: detail?.slice(0, 4000) };
}

/** Adds or removes NexusLink's hook in a Claude settings object; everything else is kept as is. */
export function withClaudeHook(settings: any, hook: { url: string; token: string } | null): any {
  const next = settings && typeof settings === 'object' && !Array.isArray(settings) ? { ...settings } : {};
  const hooks = next.hooks && typeof next.hooks === 'object' ? { ...next.hooks } : {};
  const ours = (h: any) => typeof h?.url === 'string' && h.url.includes(HOOK_PATH);
  const groups = (Array.isArray(hooks.PermissionRequest) ? hooks.PermissionRequest : [])
    .map((g: any) => ({ ...g, hooks: (Array.isArray(g?.hooks) ? g.hooks : []).filter((h: any) => !ours(h)) }))
    .filter((g: any) => g.hooks.length);
  if (hook) groups.push({ matcher: '*', hooks: [{ type: 'http', url: hook.url, timeout: HOOK_TIMEOUT_S, headers: { Authorization: `Bearer ${hook.token}` } }] });
  if (groups.length) hooks.PermissionRequest = groups; else delete hooks.PermissionRequest;
  if (Object.keys(hooks).length) next.hooks = hooks; else delete next.hooks;
  return next;
}
export function hasClaudeHook(settings: any): boolean {
  const groups = settings?.hooks?.PermissionRequest;
  return Array.isArray(groups) && groups.some((g: any) => Array.isArray(g?.hooks) && g.hooks.some((h: any) => typeof h?.url === 'string' && h.url.includes(HOOK_PATH)));
}

export class ApprovalBridge {
  private pending = new Map<string, Pending>();
  private config: Config;
  private server?: ReturnType<typeof Bun.serve>;
  private timer?: ReturnType<typeof setInterval>;
  private desktopCache?: { at: number; ids: Set<string> };
  private installError?: string;
  private readonly now: () => number;
  readonly port: number;

  constructor(private options: ApprovalBridgeOptions) {
    this.now = options.now ?? Date.now;
    this.port = options.port ?? (Number(process.env.NEXUSLINK_HOOK_PORT) || 47817);
    this.config = this.loadConfig();
  }

  private get configPath() { return join(this.options.dataDir, 'approval-bridge.json'); }
  private loadConfig(): Config {
    try {
      const raw = JSON.parse(readFileSync(this.configPath, 'utf8'));
      if (typeof raw.token === 'string' && raw.token.length >= 32) return { token: raw.token, holdTerminal: raw.holdTerminal === true };
    } catch { /* first run */ }
    const fresh = { token: randomBytes(32).toString('hex'), holdTerminal: false };
    this.saveConfig(fresh);
    return fresh;
  }
  private saveConfig(config: Config) {
    mkdirSync(this.options.dataDir, { recursive: true });
    writeFileSync(this.configPath, JSON.stringify(config), { mode: 0o600 });
    try { chmodSync(this.configPath, 0o600); } catch { /* not POSIX */ }
  }

  start() {
    try {
      this.server = Bun.serve({ hostname: '127.0.0.1', port: this.port, fetch: req => this.fetch(req) });
    } catch (err) {
      console.warn(`[approvals] hook listener could not start on 127.0.0.1:${this.port}:`, err instanceof Error ? err.message : err);
    }
    this.timer = setInterval(() => this.sweep(), this.options.pollMs ?? 1500);
    return this;
  }
  stop() {
    clearInterval(this.timer);
    for (const p of [...this.pending.values()]) this.finish(p, null);
    this.server?.stop(true);
  }

  list(): ExternalApproval[] { return [...this.pending.values()].map(p => p.item).sort((a, b) => a.createdAt - b.createdAt); }

  status(): ApprovalBridgeStatus {
    let installed = false;
    try { installed = hasClaudeHook(JSON.parse(readFileSync(this.options.claudeSettingsPath, 'utf8'))); } catch { /* no settings yet */ }
    return { claude: { installed, ...(this.installError ? { error: this.installError } : {}) }, holdTerminal: this.config.holdTerminal, listening: !!this.server };
  }

  configure(change: { claude?: boolean; holdTerminal?: boolean }): ApprovalBridgeStatus {
    if (typeof change.holdTerminal === 'boolean') { this.config = { ...this.config, holdTerminal: change.holdTerminal }; this.saveConfig(this.config); }
    if (typeof change.claude === 'boolean') this.installClaude(change.claude);
    return this.status();
  }

  /** Edits ~/.claude/settings.json in place (atomic rename). A file that is not plain JSON is left alone. */
  private installClaude(enable: boolean) {
    this.installError = undefined;
    const path = this.options.claudeSettingsPath;
    let settings: any = {};
    if (existsSync(path)) {
      const text = readFileSync(path, 'utf8');
      try { settings = text.trim() ? JSON.parse(text) : {}; } catch {
        this.installError = `${path} is not plain JSON, so NexusLink left it untouched.`;
        return;
      }
      const backup = `${path}.nexuslink-backup`;
      if (!existsSync(backup)) writeFileSync(backup, text);
    } else if (!enable) return;
    const next = withClaudeHook(settings, enable ? { url: `http://127.0.0.1:${this.port}${HOOK_PATH}`, token: this.config.token } : null);
    mkdirSync(dirname(path), { recursive: true });
    const tmp = `${path}.nexuslink-tmp`;
    writeFileSync(tmp, `${JSON.stringify(next, null, 2)}\n`);
    renameSync(tmp, path);
  }

  resolve(id: string, decision: 'allow' | 'deny', answers?: Record<string, string>, message?: string): { ok: boolean; message?: string } {
    const p = this.pending.get(id);
    if (!p) return { ok: false, message: 'Already answered or no longer waiting.' };
    const { kind } = p.item;
    let out: Record<string, unknown>;
    if (decision === 'deny') {
      const fallback = kind === 'plan' ? 'Keep planning.' : 'Denied from the phone (NexusLink).';
      out = { behavior: 'deny', message: clip(message, 2000) || fallback };
    } else if (kind === 'question') {
      const questions = p.item.questions || [];
      const given = answers || {};
      if (!questions.length || questions.some(q => typeof given[q.question] !== 'string' || !given[q.question].trim())) return { ok: false, message: 'Answer every question first.' };
      out = { behavior: 'allow', updatedInput: { ...p.input, answers: Object.fromEntries(questions.map(q => [q.question, given[q.question]])) } };
    } else {
      out = { behavior: 'allow', updatedInput: p.input };
    }
    this.finish(p, { hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: out } });
    return { ok: true };
  }

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname !== HOOK_PATH || req.method !== 'POST') return new Response('Not found', { status: 404 });
    const auth = req.headers.get('authorization') || '';
    const want = Buffer.from(`Bearer ${this.config.token}`);
    const got = Buffer.from(auth);
    if (got.length !== want.length || !timingSafeEqual(got, want)) return new Response('Forbidden', { status: 403 });
    let body: any;
    try { body = await req.json(); } catch { return new Response('', { status: 200 }); }
    const decision = await this.handleHook(body, req.signal);
    return decision ? Response.json(decision) : new Response('', { status: 200 });
  }

  /** One PermissionRequest. Resolves with Claude's hook output, or null for "no decision". */
  handleHook(body: any, signal?: AbortSignal): Promise<Decision> {
    if (body?.hook_event_name !== 'PermissionRequest' || typeof body.session_id !== 'string' || typeof body.tool_name !== 'string') return Promise.resolve(null);
    const mirrored = this.isDesktopSession(body.session_id);
    if (!mirrored && !this.config.holdTerminal) return Promise.resolve(null);
    const input = body.tool_input && typeof body.tool_input === 'object' ? body.tool_input : {};
    const now = this.now();
    const item: ExternalApproval = {
      id: randomBytes(9).toString('base64url'), agent: 'claude', chatId: identity(this.options.hostId, 'claude', body.session_id), sessionId: body.session_id,
      ...describeRequest(body.tool_name, input), tool: body.tool_name, mirrored, createdAt: now, expiresAt: now + HOLD_MS,
      ...(typeof body.cwd === 'string' ? { cwd: body.cwd } : {}),
      ...(typeof body.agent_type === 'string' && body.agent_id ? { subagent: body.agent_type } : {}),
    };
    for (const key of Object.keys(item) as (keyof ExternalApproval)[]) if (item[key] === undefined) delete item[key];
    const transcript = this.transcriptFor(body);
    return new Promise<Decision>(settle => {
      const p: Pending = { item, input, settle, transcript, scanned: 0 };
      // Find this call in the transcript so an answer given on the PC can be noticed. An
      // identical earlier call that already has a result is not this one.
      if (transcript) {
        try {
          const size = fileSize(transcript);
          const text = readTail(transcript, Math.max(0, size - 262_144));
          const end = text.lastIndexOf('\n') + 1;
          p.scanned = size - Buffer.byteLength(text.slice(end));
          p.toolUseId = lastToolUse(text.slice(0, end), body.tool_name, input, true);
        } catch { /* unreadable transcript: rely on abort + timeout */ }
      }
      this.pending.set(item.id, p);
      signal?.addEventListener('abort', () => this.finish(p, null));
      p.pushTimer = setTimeout(() => { if (this.pending.has(item.id)) this.options.push?.(item); }, PUSH_AFTER_MS);
      this.changed();
    });
  }

  private finish(p: Pending, decision: Decision) {
    if (!this.pending.delete(p.item.id)) return;
    clearTimeout(p.pushTimer);
    p.settle(decision);
    this.changed();
  }
  private changed() { this.options.onChange?.(this.list()); }

  /** Drops prompts that timed out or were answered on the PC. */
  sweep() {
    const now = this.now();
    for (const p of [...this.pending.values()]) {
      if (now >= p.item.expiresAt) { this.finish(p, null); continue; }
      if (!p.transcript) continue;
      const size = fileSize(p.transcript);
      if (size < 0 || size <= p.scanned) continue;
      let added = '';
      try { added = readTail(p.transcript, p.scanned); } catch { continue; }
      const end = added.lastIndexOf('\n') + 1;
      if (!end) continue;
      added = added.slice(0, end);
      p.scanned += Buffer.byteLength(added);
      p.toolUseId ??= lastToolUse(added, p.item.tool, p.input);
      if (p.toolUseId && added.includes(`"tool_use_id":"${p.toolUseId}"`)) this.finish(p, null);
    }
  }

  private transcriptFor(body: any): string | undefined {
    const main = typeof body.transcript_path === 'string' ? body.transcript_path : undefined;
    if (!main) return undefined;
    if (typeof body.agent_id === 'string' && /^[\w-]+$/.test(body.agent_id)) {
      const sub = join(dirname(main), body.session_id, 'subagents', `agent-${body.agent_id}.jsonl`);
      if (existsSync(sub)) return sub;
    }
    return existsSync(main) ? main : undefined;
  }

  private isDesktopSession(sessionId: string): boolean {
    const now = this.now();
    if (!this.desktopCache || now - this.desktopCache.at > 5000 || !this.desktopCache.ids.has(sessionId)) {
      const ids = new Set<string>();
      const base = this.options.desktopSessionsDir;
      const list = (p: string) => { try { return readdirSync(p); } catch { return []; } };
      for (const account of list(base)) for (const org of list(join(base, account))) for (const name of list(join(base, account, org))) {
        if (!/^local_.*\.json$/.test(name)) continue;
        try { const id = JSON.parse(readFileSync(join(base, account, org, name), 'utf8')).cliSessionId; if (typeof id === 'string') ids.add(id); } catch { /* being written */ }
      }
      this.desktopCache = { at: now, ids };
    }
    return this.desktopCache.ids.has(sessionId);
  }
}

/**
 * The newest tool_use with this name and input in some transcript lines. With `openOnly`,
 * calls that already have a result in the same text are skipped (they are earlier calls).
 */
export function lastToolUse(text: string, tool: string, input: unknown, openOnly = false): string | undefined {
  let found: string | undefined;
  for (const line of text.split('\n')) {
    if (!line.includes('"tool_use"')) continue;
    let row: any;
    try { row = JSON.parse(line); } catch { continue; }
    for (const part of Array.isArray(row?.message?.content) ? row.message.content : []) {
      if (part?.type === 'tool_use' && part.name === tool && typeof part.id === 'string' && sameJson(part.input, input)) found = part.id;
    }
  }
  if (found && openOnly && text.includes(`"tool_use_id":"${found}"`)) return undefined;
  return found;
}
