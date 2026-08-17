// Agent gateway: run AI coding agents (Claude Code, Cursor CLI, OpenCode,
// Antigravity) on the host and expose them to the phone as chat sessions with a
// normalized event stream — the phone renders a native chat UI, never a terminal.
//
// Each CLI gets an adapter that translates its stream-json output into
// AgentEvent records. Events are buffered per session (so a reconnecting
// phone can replay history via agent.history) and pushed live as
// `agent-event` WebSocket messages.

import { existsSync, mkdirSync, statSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import type {
  AgentCapabilities,
  AgentEvent,
  AgentHostChat,
  AgentImageAttachment,
  AgentInfo,
  AgentMode,
  AgentModelOption,
  AgentSessionInfo,
  WsMessage,
} from '@nexuslink/rpc-types';
import {
  listAgyHostChats,
  listCursorCliHostChats,
  listCursorIdeHostChats,
  listOpencodeHostChats,
  loadHostChatHistory,
  type HostChatDelta,
} from './host-chats';

type SpawnOpts = Parameters<typeof Bun.spawn>[1];
type Proc = ReturnType<typeof Bun.spawn>;

const HISTORY_CAP = 1000;

type BroadcastFn = (msg: WsMessage) => void;
let broadcast: BroadcastFn = () => {};

export function setAgentBroadcast(fn: BroadcastFn): void {
  broadcast = fn;
}

// ---------------------------------------------------------------------------
// Agent catalog
// ---------------------------------------------------------------------------

export interface AgentPromptOpts {
  model?: string;
  mode?: AgentMode;
  thinking?: string;
  images?: AgentImageAttachment[];
}

interface AdapterPromptOpts {
  model?: string;
  mode?: AgentMode;
  thinking?: string;
  imagePaths?: string[];
  images?: { name: string; mime: string; data: string }[];
}

interface AgentDef {
  id: string;
  name: string;
  bin?: string;
  capabilities: AgentCapabilities;
  makeAdapter(session: AgentSession): AgentAdapter;
}

/** Extra dirs GUI/systemd launches often omit from PATH. */
function extraBinDirs(): string[] {
  const home = homedir();
  return [
    `${home}/.local/bin`,
    `${home}/.opencode/bin`,
    `${home}/.cursor/bin`,
    `${home}/.gemini/antigravity-cli`,
    `${home}/bin`,
    '/usr/local/bin',
  ];
}

export function resolveBin(bin: string): string | null {
  const seen = new Set<string>();
  for (const dir of [...(process.env.PATH ?? '').split(':'), ...extraBinDirs()]) {
    if (!dir || seen.has(dir)) continue;
    seen.add(dir);
    const p = `${dir}/${bin}`;
    if (existsSync(p)) return p;
  }
  return null;
}

function which(bin: string): string | null {
  return resolveBin(bin);
}

const MAX_IMAGES = 4;
const MAX_IMAGE_BYTES = 4 * 1024 * 1024;

const CURSOR_MODELS: AgentModelOption[] = [
  { id: 'auto', name: 'Auto' },
  { id: 'composer-2.5', name: 'Composer 2.5' },
  { id: 'gpt-5.3-codex', name: 'GPT-5.3 Codex' },
  { id: 'cursor-grok-4.6', name: 'Grok 4.6' },
  { id: 'claude-opus-5', name: 'Claude Opus 5' },
  { id: 'claude-sonnet-5', name: 'Claude Sonnet 5' },
  { id: 'gpt-5.6-sol', name: 'GPT-5.6' },
];

const OPENCODE_MODELS: AgentModelOption[] = [
  { id: 'opencode/deepseek-v4-flash-free', name: 'DeepSeek V4 Flash' },
  { id: 'opencode/mimo-v2.5-free', name: 'MiMo 2.5' },
  { id: 'opencode/big-pickle', name: 'Big Pickle' },
  { id: 'opencode/hy3-free', name: 'HY3' },
  { id: 'opencode/laguna-s-2.1-free', name: 'Laguna S 2.1' },
  { id: 'opencode/nemotron-3-ultra-free', name: 'Nemotron 3 Ultra' },
  { id: 'opencode/nemotron-3.5-lightning-free', name: 'Nemotron 3.5 Lightning' },
];

const ANTIGRAVITY_MODELS: AgentModelOption[] = [
  { id: 'gemini-3.7-flash', name: 'Gemini 3.7 Flash' },
  { id: 'gemini-3.1-pro', name: 'Gemini 3.1 Pro' },
  { id: 'claude-sonnet-4-6', name: 'Claude Sonnet 4.6' },
  { id: 'claude-opus-4-6', name: 'Claude Opus 4.6' },
  { id: 'gpt-oss-120b', name: 'GPT-OSS 120B' },
];

const CLAUDE_MODELS: AgentModelOption[] = [
  { id: 'default', name: 'Default' },
  { id: 'sonnet', name: 'Sonnet' },
  { id: 'opus', name: 'Opus' },
  { id: 'haiku', name: 'Haiku' },
];

const AGENT_DEFS: AgentDef[] = [
  {
    id: 'claude',
    name: 'Claude Code',
    bin: 'claude',
    capabilities: {
      modes: ['agent', 'plan'],
      thinkingLevels: ['low', 'medium', 'high'],
      models: CLAUDE_MODELS,
      images: true,
    },
    makeAdapter: (s) => new ClaudeAdapter(s),
  },
  {
    id: 'cursor',
    name: 'Cursor CLI',
    bin: 'cursor-agent',
    capabilities: {
      modes: ['agent', 'plan', 'ask'],
      thinkingLevels: ['low', 'medium', 'high', 'extra-high', 'max'],
      models: CURSOR_MODELS,
      images: true,
    },
    makeAdapter: (s) => new CursorAdapter(s),
  },
  {
    id: 'opencode',
    name: 'OpenCode',
    bin: 'opencode',
    capabilities: {
      modes: ['agent', 'plan'],
      thinkingLevels: ['minimal', 'low', 'medium', 'high', 'max'],
      models: OPENCODE_MODELS,
      images: true,
    },
    makeAdapter: (s) => new OpenCodeAdapter(s),
  },
  {
    id: 'antigravity',
    name: 'Antigravity',
    bin: 'agy',
    capabilities: {
      modes: ['agent', 'plan'],
      thinkingLevels: ['low', 'medium', 'high'],
      models: ANTIGRAVITY_MODELS,
      images: true,
    },
    makeAdapter: (s) => new AntigravityAdapter(s),
  },
  {
    id: 'mock',
    name: 'Demo Agent',
    capabilities: {
      modes: ['agent', 'plan', 'ask'],
      thinkingLevels: ['low', 'medium', 'high', 'extra-high'],
      models: [
        { id: 'demo', name: 'Demo' },
        { id: 'composer-2', name: 'Composer' },
      ],
      images: true,
    },
    makeAdapter: (s) => new MockAdapter(s),
  },
];

export function listAgents(): AgentInfo[] {
  return AGENT_DEFS.map((d) => ({
    id: d.id,
    name: d.name,
    available: d.bin ? which(d.bin) !== null : true,
    capabilities: {
      ...d.capabilities,
      models: modelCache.get(d.id) ?? d.capabilities.models,
    },
  }));
}

const modelCache = new Map<string, AgentModelOption[]>();

/** Parse `opencode models` / `cursor-agent models` stdout into picker rows. */
export function parseAgentModelList(text: string): AgentModelOption[] {
  const out: AgentModelOption[] = [];
  const seen = new Set<string>();
  for (const raw of text.split(/\r?\n/)) {
    const t = raw.replace(/\x1b\[[0-9;]*m/g, '').trim();
    if (!t) continue;
    const lower = t.toLowerCase();
    if (
      lower.startsWith('available') ||
      lower.startsWith('error') ||
      lower.startsWith('usage:') ||
      lower.startsWith('options:')
    ) {
      continue;
    }
    let id = '';
    let name = '';
    const tab = t.indexOf('\t');
    const dash = t.indexOf(' - ');
    if (tab > 0) {
      id = t.slice(0, tab).trim();
      name = t.slice(tab + 1).trim();
    } else if (dash > 0) {
      id = t.slice(0, dash).trim();
      name = t.slice(dash + 3).trim().replace(/\s*\(current.*\)$/i, '').trim();
    } else {
      id = t.split(/\s+/)[0] ?? '';
      name = id.includes('/') ? (id.split('/').pop() ?? id) : id;
    }
    if (!id || seen.has(id)) continue;
    seen.add(id);
    out.push({ id, name });
  }
  return out;
}

export function matchAgentModel(
  query: string,
  models: AgentModelOption[],
): AgentModelOption | undefined {
  const tokens = query.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
  const q = tokens.join('');
  if (!q) return undefined;
  let best: AgentModelOption | undefined;
  let bestScore = 0;
  for (const m of models) {
    const id = m.id.toLowerCase().replace(/[^a-z0-9]/g, '');
    const name = m.name.toLowerCase().replace(/[^a-z0-9]/g, '');
    let score = 0;
    if (id === q || name === q) score = 100;
    else if (id.endsWith(q) || name.endsWith(q)) score = 90;
    else if (id.includes(q) || name.includes(q)) score = 80;
    else if (tokens.every((t) => id.includes(t) || name.includes(t))) score = 70;
    if (score > bestScore) {
      bestScore = score;
      best = m;
    }
  }
  return best;
}

/** Strip thinking / effort suffixes so the phone can pick a family, not 40 variants. */
export function modelFamilyId(id: string): string {
  return id
    .replace(/-thinking(?=-|$)/gi, '')
    .replace(/-(low|medium|high|xhigh|max)(-fast)?$/i, '')
    .replace(/-fast$/i, '')
    .replace(/-+$/g, '');
}

export function collapseModelFamilies(models: AgentModelOption[]): AgentModelOption[] {
  const seen = new Set<string>();
  const out: AgentModelOption[] = [];
  for (const m of models) {
    const fam = modelFamilyId(m.id);
    if (!fam || seen.has(fam)) continue;
    seen.add(fam);
    const name = m.name
      .replace(/\s*\((High|Medium|Low|Extra High|Max|Thinking).*?\)/gi, '')
      .replace(/\s+Thinking\s*$/i, '')
      .replace(/\s*\(current.*\)$/i, '')
      .trim();
    out.push({ id: fam, name: name || fam });
  }
  return out;
}

function thinkingSuffixes(thinking?: string): string[] {
  const t = (thinking || 'medium').toLowerCase();
  if (t === 'minimal' || t === 'low') return ['low'];
  if (t === 'extra-high' || t === 'xhigh') return ['xhigh', 'extra-high', 'max', 'high'];
  if (t === 'max') return ['max', 'xhigh', 'high'];
  if (t === 'high') return ['high', 'thinking'];
  return ['medium'];
}

function variantScore(id: string, thinking?: string): number {
  const lower = id.toLowerCase();
  const t = (thinking || 'medium').toLowerCase();
  const isDefault = t === 'medium' || t === '' || t === 'none' || t === 'off';
  if (isDefault) {
    let s = 0;
    if (/-thinking(?=-|$)/.test(lower) || /-(low|high|xhigh|max)(-fast)?$/.test(lower)) s -= 10;
    if (lower.endsWith('-medium')) s += 15;
    if (lower.includes('-fast')) s -= 5;
    return s;
  }
  let s = 0;
  const suffixes = thinkingSuffixes(thinking);
  for (let i = 0; i < suffixes.length; i++) {
    const suf = suffixes[i]!;
    if (lower.includes(`thinking-${suf}`)) s += 40 - i * 5;
    else if (lower.endsWith(`-${suf}`) || lower.includes(`-${suf}-`)) s += 30 - i * 5;
    else if (suf === 'thinking' && /-thinking(?=-|$)/.test(lower)) s += 20;
  }
  if (lower.includes('-fast')) s -= 5;
  return s;
}

/** Resolve a family id + thinking chip to a concrete CLI model id. */
export function pickModelVariant(
  model: string | undefined,
  thinking: string | undefined,
  catalog: AgentModelOption[],
): string | undefined {
  const m = (model || '').trim();
  if (!m || m === 'auto' || m === 'default') return m || undefined;
  if (!catalog.length) return m;
  const fam = modelFamilyId(m);
  const family = catalog.filter((x) => modelFamilyId(x.id) === fam || x.id === m);
  if (!family.length) return m;
  let best = family[0]!;
  let bestScore = variantScore(best.id, thinking);
  for (const c of family.slice(1)) {
    const score = variantScore(c.id, thinking);
    if (score > bestScore) {
      bestScore = score;
      best = c;
    }
  }
  return best.id;
}

function fetchLiveModels(agentId: string, bin: string): AgentModelOption[] {
  const argv = agentId === 'cursor' ? [bin, 'models'] : [bin, 'models'];
  if (agentId === 'claude' || agentId === 'mock') return [];
  try {
    const proc = Bun.spawnSync(argv, {
      stdout: 'pipe',
      stderr: 'pipe',
      timeout: 8000,
      env: process.env as Record<string, string>,
    });
    const text = new TextDecoder().decode(proc.stdout ?? new Uint8Array());
    return parseAgentModelList(text);
  } catch {
    return [];
  }
}

export function listAgentModels(agentId: string): AgentModelOption[] {
  const def = AGENT_DEFS.find((d) => d.id === agentId);
  if (!def) return [];
  const cached = modelCache.get(agentId);
  if (cached?.length) return cached;
  let models = def.capabilities.models;
  if (def.bin) {
    const bin = which(def.bin);
    if (bin) {
      const live = fetchLiveModels(agentId, bin);
      if (live.length) models = live;
    }
  }
  modelCache.set(agentId, models);
  return models;
}

export function thinkingToEffort(thinking?: string): 'low' | 'medium' | 'high' | undefined {
  if (!thinking) return undefined;
  const t = thinking.toLowerCase();
  if (t === 'none' || t === 'off') return undefined;
  if (t === 'low' || t === 'minimal') return 'low';
  if (t === 'high' || t === 'extra-high' || t === 'max' || t === 'xhigh') return 'high';
  return 'medium';
}

/** Cursor `--model` value, including `[effort=…]` when thinking is set. */
export function cursorModelFlag(model?: string, thinking?: string): string | undefined {
  const m = (model || '').trim();
  if (!m || m === 'auto' || m === 'default') return undefined;
  if (m.includes('[')) return m;
  // Cursor model ids already encode thinking (…-thinking-high, …-xhigh).
  if (/thinking|xhigh|-high|-low|-medium|-max|-fast/i.test(m)) return m;
  const effort = thinkingToEffort(thinking);
  const extraHigh = ['extra-high', 'max', 'xhigh'].includes((thinking || '').toLowerCase());
  if (!effort || (effort === 'medium' && !extraHigh)) return m;
  return `${m}[effort=${effort}${extraHigh ? ',fast=false' : ''}]`;
}

export function withImageMentions(text: string, paths?: string[]): string {
  const body = text.trim() || (paths?.length ? 'Please look at the attached image(s).' : '');
  if (!paths?.length) return body;
  return `${body}\n\n${paths.map((p) => `@${p}`).join('\n')}`;
}

export function materializeAgentImages(
  sessionId: string,
  images: AgentImageAttachment[] | undefined,
): { paths: string[]; files: { name: string; mime: string; data: string }[] } {
  if (!images?.length) return { paths: [], files: [] };
  const dir = join(tmpdir(), 'nexuslink-agent-inbox', sessionId);
  mkdirSync(dir, { recursive: true });
  const paths: string[] = [];
  const files: { name: string; mime: string; data: string }[] = [];
  for (const img of images.slice(0, MAX_IMAGES)) {
    if (!img.data) continue;
    let raw: Buffer;
    try {
      raw = Buffer.from(img.data, 'base64');
    } catch {
      continue;
    }
    if (!raw.length || raw.length > MAX_IMAGE_BYTES) continue;
    const mime = (img.mime || 'image/jpeg').toLowerCase();
    if (!mime.startsWith('image/')) continue;
    const ext = mime.includes('png') ? 'png' : mime.includes('webp') ? 'webp' : mime.includes('gif') ? 'gif' : 'jpg';
    const rawName = (img.name || `photo.${ext}`).replace(/[^a-zA-Z0-9._-]/g, '_').slice(0, 80);
    const dest = join(dir, `${Date.now()}-${rawName || `photo.${ext}`}`);
    writeFileSync(dest, raw);
    paths.push(dest);
    files.push({ name: rawName || `photo.${ext}`, mime, data: img.data });
  }
  return { paths, files };
}

export function buildCursorArgv(opts: {
  bin: string;
  cwd: string;
  chatId?: string | null;
  text: string;
  model?: string;
  mode?: AgentMode;
  thinking?: string;
  imagePaths?: string[];
  catalog?: AgentModelOption[];
}): string[] {
  const argv = [
    opts.bin, '--print', '--output-format', 'stream-json',
    '--trust', '--force',
    '--workspace', opts.cwd,
  ];
  if (opts.mode === 'plan' || opts.mode === 'ask') argv.push('--mode', opts.mode);
  const resolved = pickModelVariant(opts.model, opts.thinking, opts.catalog ?? []);
  const model = cursorModelFlag(resolved, opts.thinking);
  if (model) argv.push('--model', model);
  if (opts.chatId) argv.push('--resume', opts.chatId);
  argv.push(withImageMentions(opts.text, opts.imagePaths));
  return argv;
}

export function buildOpencodeArgv(opts: {
  bin: string;
  cwd: string;
  session?: string | null;
  text: string;
  model?: string;
  mode?: AgentMode;
  thinking?: string;
  imagePaths?: string[];
}): string[] {
  const argv = [opts.bin, 'run', '--format', 'json', '--auto', '--dir', opts.cwd];
  if (opts.model && opts.model !== 'default') argv.push('--model', opts.model);
  if (opts.mode === 'plan') argv.push('--agent', 'plan');
  const variant = opts.thinking && opts.thinking !== 'medium' ? opts.thinking : undefined;
  if (variant) argv.push('--variant', variant === 'extra-high' ? 'max' : variant);
  if (opts.session) argv.push('--session', opts.session);
  for (const p of opts.imagePaths ?? []) argv.push('--file', p);
  argv.push(opts.text.trim() || 'Please look at the attached image(s).');
  return argv;
}

export function buildAgyArgv(opts: {
  bin: string;
  conversationId?: string | null;
  text: string;
  model?: string;
  mode?: AgentMode;
  thinking?: string;
  imagePaths?: string[];
  catalog?: AgentModelOption[];
}): string[] {
  const argv = [
    opts.bin,
    '--output-format', 'stream-json',
    '--dangerously-skip-permissions',
    '--print-timeout', '15m',
  ];
  if (opts.mode === 'plan') argv.push('--mode', 'plan');
  const resolved = pickModelVariant(opts.model, opts.thinking, opts.catalog ?? []);
  if (resolved && resolved !== 'default') argv.push('--model', resolved);
  const effort = thinkingToEffort(opts.thinking);
  if (effort) argv.push('--effort', effort);
  if (opts.conversationId) argv.push('--conversation', opts.conversationId);
  argv.push('-p', withImageMentions(opts.text, opts.imagePaths));
  return argv;
}

export function claudeSpawnArgs(opts: {
  bin: string;
  model?: string;
  mode?: AgentMode;
  thinking?: string;
}): string[] {
  const argv = [
    opts.bin, '--print',
    '--input-format', 'stream-json',
    '--output-format', 'stream-json',
    '--verbose',
    '--permission-mode', opts.mode === 'plan' ? 'plan' : 'acceptEdits',
  ];
  if (opts.model && opts.model !== 'default') argv.push('--model', opts.model);
  const effort = thinkingToEffort(opts.thinking);
  if (effort && effort !== 'medium') argv.push('--effort', effort);
  return argv;
}

export function claudeUserContent(
  text: string,
  images?: { mime: string; data: string }[],
): unknown[] {
  const content: unknown[] = [];
  for (const img of images ?? []) {
    content.push({
      type: 'image',
      source: { type: 'base64', media_type: img.mime, data: img.data },
    });
  }
  content.push({ type: 'text', text: text.trim() || 'Please look at the attached image(s).' });
  return content;
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

interface AgentSession {
  info: AgentSessionInfo;
  history: AgentEvent[];
  adapter: AgentAdapter;
  seq: number;
  pendingPermissions: Map<string, (allow: boolean) => void>;
}

interface AgentAdapter {
  prompt(text: string, opts?: AdapterPromptOpts): void;
  cancel(): void;
  close(): void;
  permission?(requestId: string, allow: boolean): void;
  bindHostChat?(id: string): void;
}

const agentSessions = new Map<string, AgentSession>();

function emit(session: AgentSession, event: Omit<AgentEvent, 'seq' | 'ts'>): void {
  const full: AgentEvent = { ...event, seq: ++session.seq, ts: Date.now() };
  session.history.push(full);
  if (session.history.length > HISTORY_CAP) session.history.splice(0, 100);
  broadcast({ type: 'agent-event', agentSessionId: session.info.agentSessionId, event: full });
}

function setBusy(session: AgentSession, busy: boolean): void {
  session.info.busy = busy;
}

/** Expand ~ and require an existing directory. Any path is allowed for now. */
export function resolveAgentCwd(cwd?: string, opts?: { fallbackHome?: boolean }): string {
  const home = homedir();
  const raw = (cwd ?? '').trim();
  const path = !raw || raw === '~' ? home : raw.startsWith('~/') ? join(home, raw.slice(2)) : raw;
  if (existsSync(path) && statSync(path).isDirectory()) return path;
  if (opts?.fallbackHome) return home;
  throw new Error(existsSync(path) ? `not a directory: ${path}` : `directory not found: ${path}`);
}

export function createAgentSession(
  agentId: string,
  cwd?: string,
  title?: string,
  opts?: { hostChatId?: string },
): AgentSessionInfo {
  const def = AGENT_DEFS.find((d) => d.id === agentId);
  if (!def) throw new Error(`unknown agent: ${agentId}`);
  if (def.bin && !which(def.bin)) throw new Error(`${def.name} CLI not installed on the host`);

  const info: AgentSessionInfo = {
    agentSessionId: crypto.randomUUID(),
    agent: agentId,
    cwd: resolveAgentCwd(cwd),
    title: title || def.name,
    createdAt: Date.now(),
    busy: false,
    status: 'running',
    hostChatId: opts?.hostChatId,
  };
  const session: AgentSession = {
    info, history: [], adapter: null as unknown as AgentAdapter, seq: 0,
    pendingPermissions: new Map(),
  };
  session.adapter = def.makeAdapter(session);
  if (opts?.hostChatId) session.adapter.bindHostChat?.(opts.hostChatId);
  agentSessions.set(info.agentSessionId, session);
  return { ...info };
}

export function listAgentSessions(): AgentSessionInfo[] {
  return [...agentSessions.values()].map((s) => ({ ...s.info }));
}

function seedHistory(session: AgentSession, events: HostChatDelta[]): void {
  for (const ev of events.slice(-HISTORY_CAP)) {
    session.history.push({
      ...ev,
      seq: ++session.seq,
      ts: ev.ts || Date.now(),
    });
  }
}

export function listHostChats(agent?: string): AgentHostChat[] {
  const want = (id: string) => !agent || agent === id;
  const out: AgentHostChat[] = [];
  if (want('opencode')) {
    const bin = which('opencode');
    if (bin) out.push(...listOpencodeHostChats(bin));
  }
  if (want('cursor')) {
    out.push(...listCursorCliHostChats(which('cursor-agent') !== null));
    out.push(...listCursorIdeHostChats());
  }
  if (want('antigravity')) {
    out.push(...listAgyHostChats());
  }
  return out.sort((a, b) => b.updatedAt - a.updatedAt).slice(0, 80);
}

export function openHostChat(params: {
  agent: string;
  hostChatId: string;
  cwd?: string;
  title?: string;
}): AgentSessionInfo {
  const { agent, hostChatId } = params;
  if (!hostChatId) throw new Error('missing hostChatId');
  const existing = [...agentSessions.values()].find(
    (s) => s.info.agent === agent && s.info.hostChatId === hostChatId && s.info.status === 'running',
  );
  if (existing) return { ...existing.info };

  const viewOnly = hostChatId.startsWith('ide:');
  const cwd = resolveAgentCwd(params.cwd, { fallbackHome: true });
  const title = params.title || 'Host chat';
  const info = createAgentSession(agent, cwd, title, { hostChatId });
  const session = agentSessions.get(info.agentSessionId);
  if (!session) return info;
  const def = AGENT_DEFS.find((d) => d.id === agent);
  const bin = def?.bin ? which(def.bin) : null;
  const history = loadHostChatHistory(agent, hostChatId, bin);
  seedHistory(session, history);
  if (!history.length) {
    seedHistory(session, [{
      kind: 'status',
      text: viewOnly
        ? 'Loaded from Cursor IDE. History is view-only — a new Cursor CLI chat starts if you send a message.'
        : 'Opened this conversation from the PC. Send a message to continue it.',
      ts: Date.now(),
    }]);
  } else if (viewOnly) {
    seedHistory(session, [{
      kind: 'status',
      text: 'Cursor IDE chats cannot be continued from the CLI. Sending a message starts a new Cursor CLI chat in this project.',
      ts: Date.now(),
    }]);
  }
  return { ...session.info };
}

export function agentHistory(agentSessionId: string): AgentEvent[] {
  return agentSessions.get(agentSessionId)?.history.slice() ?? [];
}

export function promptAgent(
  agentSessionId: string,
  text: string,
  opts: AgentPromptOpts = {},
): { ok: boolean } {
  const session = agentSessions.get(agentSessionId);
  if (!session || session.info.status !== 'running') return { ok: false };
  const materialized = materializeAgentImages(session.info.agentSessionId, opts.images);
  const key = parseEnvApiKey(text, ['CURSOR_API_KEY', 'GEMINI_API_KEY', 'GOOGLE_API_KEY']);
  const display = (key ? `${key.name}=••••` : text.trim())
    || (materialized.files.length ? 'Attached photo(s)' : '');
  if (!display) return { ok: false };
  emit(session, {
    kind: 'user',
    text: display,
    images: materialized.files.map((f) => f.name),
  });
  setBusy(session, true);
  session.adapter.prompt(text.trim() || 'Please look at the attached image(s).', {
    model: opts.model,
    mode: opts.mode,
    thinking: opts.thinking,
    imagePaths: materialized.paths,
    images: materialized.files,
  });
  return { ok: true };
}

export function cancelAgent(agentSessionId: string): { ok: boolean } {
  const session = agentSessions.get(agentSessionId);
  if (!session) return { ok: false };
  session.adapter.cancel();
  setBusy(session, false);
  emit(session, { kind: 'status', text: 'cancelled' });
  return { ok: true };
}

export function closeAgentSession(agentSessionId: string): { ok: boolean } {
  const session = agentSessions.get(agentSessionId);
  if (!session) return { ok: false };
  session.adapter.close();
  session.info.status = 'exited';
  agentSessions.delete(agentSessionId);
  return { ok: true };
}

/** ACP-shaped session/request_permission response from the phone. */
export function resolveAgentPermission(
  agentSessionId: string,
  requestId: string,
  allow: boolean,
): { ok: boolean } {
  const session = agentSessions.get(agentSessionId);
  if (!session) return { ok: false };
  const pending = session.pendingPermissions.get(requestId);
  if (pending) {
    session.pendingPermissions.delete(requestId);
    pending(allow);
    return { ok: true };
  }
  session.adapter.permission?.(requestId, allow);
  return { ok: true };
}

// ---------------------------------------------------------------------------
// Shared stream-json plumbing
// ---------------------------------------------------------------------------

async function pumpJsonLines(proc: Proc, onLine: (msg: Record<string, unknown>) => void): Promise<void> {
  const reader = (proc.stdout as unknown as ReadableStream<Uint8Array>).getReader();
  const decoder = new TextDecoder();
  let buf = '';
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      let nl: number;
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (!line) continue;
        try {
          onLine(JSON.parse(line));
        } catch {
          // non-JSON noise (progress spinners etc.)
        }
      }
    }
  } finally {
    reader.releaseLock();
  }
}

function contentToText(content: unknown): string {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .map((p) => {
        if (typeof p === 'string') return p;
        const part = p as Record<string, unknown>;
        if (typeof part.text === 'string') return part.text;
        return '';
      })
      .join('');
  }
  return '';
}

type AgentDelta = Omit<AgentEvent, 'seq' | 'ts'>;

async function collectText(stream: unknown): Promise<string> {
  if (!stream || typeof stream !== 'object' || !('getReader' in stream)) return '';
  const reader = (stream as ReadableStream<Uint8Array>).getReader();
  const decoder = new TextDecoder();
  let out = '';
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      out += decoder.decode(value, { stream: true });
    }
    out += decoder.decode();
  } finally {
    reader.releaseLock();
  }
  return out.replace(/\x1b\[[0-9;]*m/g, '').trim();
}

/** When a CLI dies without a result event, turn stderr into a phone-visible error. */
export function finishCliTurn(opts: {
  sawResult: boolean;
  exitCode: number | null;
  stderr: string;
}): AgentDelta | null {
  if (opts.sawResult) return null;
  const err = opts.stderr.trim();
  if (err) return { kind: 'error', text: err };
  return {
    kind: 'error',
    text: `Agent CLI exited without a reply (code ${opts.exitCode ?? '?'})`,
  };
}

export function sessionIdFromEvent(msg: Record<string, unknown>): string | undefined {
  for (const key of [
    'chatId', 'chat_id', 'sessionId', 'session_id', 'sessionID',
    'conversation_id', 'conversationId',
  ]) {
    if (typeof msg[key] === 'string' && msg[key]) return msg[key] as string;
  }
  const nested = [msg.step_update, msg.result, msg.init];
  for (const raw of nested) {
    if (!raw || typeof raw !== 'object') continue;
    const inner = sessionIdFromEvent(raw as Record<string, unknown>);
    if (inner) return inner;
  }
  return undefined;
}

/** Chat text that should run the CLI's login subcommand, not a model prompt. */
export function looksLikeAgentLogin(text: string): boolean {
  const t = text.trim().toLowerCase().replace(/^\/+/, '');
  return (
    t === 'login' ||
    t === 'agent login' ||
    t === 'auth login' ||
    t === 'agy login' ||
    t === 'agy auth login' ||
    t === 'cursor-agent login'
  );
}

export function parseEnvApiKey(text: string, names: string[]): { name: string; value: string } | undefined {
  const trimmed = text.trim().replace(/^export\s+/i, '');
  for (const name of names) {
    const m = trimmed.match(new RegExp(`^${name}\\s*=\\s*(\\S+)`, 'i'));
    if (m?.[1]) return { name, value: m[1] };
  }
  return undefined;
}

export function extractAuthUrl(text: string): string | undefined {
  const m = text.match(/https?:\/\/[^\s"'<>\\]+/i);
  if (!m) return undefined;
  return m[0].replace(/[.,;:)\\]+$/, '');
}

export function isCliAuthError(text: string): boolean {
  return /authentication required|not authenticated|not logged in|please run ['`]?agent login/i.test(text);
}

export function rewriteCliAuthError(stderr: string, agentName: string): string {
  if (agentName === 'Cursor CLI') {
    return [
      "Cursor CLI isn't signed in on the PC.",
      'Send **login** in this chat to open a sign-in link, or paste `CURSOR_API_KEY=…` from https://cursor.com/dashboard/api',
    ].join('\n\n');
  }
  if (agentName === 'Antigravity') {
    return [
      "Antigravity isn't signed in on the PC.",
      'Run `agy` once on the PC to sign in, or paste `GEMINI_API_KEY=…` here.',
    ].join('\n\n');
  }
  return stderr.trim();
}

/** Cursor CLI nests tools as `{ readToolCall: { args, result } }` rather than `{ name, args }`. */
export function describeCursorToolCall(toolCall: unknown): {
  name: string;
  args: unknown;
  result: unknown;
} {
  if (!toolCall || typeof toolCall !== 'object') {
    return { name: 'tool', args: {}, result: {} };
  }
  const obj = toolCall as Record<string, unknown>;
  for (const [key, raw] of Object.entries(obj)) {
    if (!raw || typeof raw !== 'object') continue;
    const inner = raw as Record<string, unknown>;
    if (key === 'function') {
      return {
        name: String(inner.name ?? 'function'),
        args: inner.arguments ?? inner.args ?? {},
        result: inner.result ?? {},
      };
    }
    const name = key.replace(/ToolCall$/, '') || 'tool';
    return { name, args: inner.args ?? inner, result: inner.result ?? {} };
  }
  return {
    name: String(obj.name ?? 'tool'),
    args: obj.args ?? obj,
    result: obj.result ?? {},
  };
}

export function parseCursorStreamEvent(msg: Record<string, unknown>): AgentDelta[] {
  const type = msg.type;
  if (type === 'assistant') {
    const message = msg.message as Record<string, unknown> | undefined;
    const text = contentToText(message?.content);
    if (text.trim()) return [{ kind: 'text', text }];
    return [];
  }
  if (type === 'tool_call') {
    const meta = describeCursorToolCall(msg.tool_call ?? msg);
    const refId = String(msg.call_id ?? msg.id ?? '');
    if (msg.subtype === 'started') {
      return [{
        kind: 'tool-start',
        toolName: meta.name,
        toolInput: JSON.stringify(meta.args, null, 2).slice(0, 4000),
        refId,
      }];
    }
    if (msg.subtype === 'completed') {
      return [{
        kind: 'tool-end',
        toolName: meta.name,
        refId,
        toolOutput: JSON.stringify(meta.result, null, 2).slice(0, 4000),
      }];
    }
    return [];
  }
  if (type === 'result') {
    const text = typeof msg.result === 'string' ? msg.result : '';
    if (msg.is_error === true || msg.subtype === 'error') {
      return [{ kind: 'error', text: text || 'Cursor CLI reported an error' }];
    }
    return [{ kind: 'result', text }];
  }
  if (type === 'system' && msg.subtype === 'init') {
    return [];
  }
  return [];
}

/** Phone paints `result` as a chat bubble — blank it if the reply already streamed. */
export function withoutDuplicateResult(
  ev: AgentDelta,
  streamedText: boolean,
): AgentDelta {
  if (ev.kind === 'result' && streamedText) return { kind: 'result', text: '' };
  return ev;
}

export function parseOpencodeStreamEvent(msg: Record<string, unknown>): AgentDelta[] {
  const type = msg.type;
  const part = (msg.part as Record<string, unknown> | undefined) ?? {};
  if (type === 'text' || part.type === 'text') {
    const text = typeof part.text === 'string' ? part.text : typeof msg.text === 'string' ? msg.text : '';
    if (text.trim()) return [{ kind: 'text', text }];
    return [];
  }
  if (type === 'tool_use') {
    const state = (part.state as Record<string, unknown> | undefined) ?? {};
    const status = String(state.status ?? 'completed');
    const refId = String(part.callID ?? part.id ?? '');
    const name = String(part.tool ?? part.name ?? 'tool');
    const input = JSON.stringify(state.input ?? part.input ?? {}, null, 2).slice(0, 4000);
    const output = typeof state.output === 'string'
      ? state.output.slice(0, 4000)
      : JSON.stringify(state.output ?? {}, null, 2).slice(0, 4000);
    if (status === 'pending' || status === 'running') {
      return [{ kind: 'tool-start', toolName: name, toolInput: input, refId }];
    }
    return [
      { kind: 'tool-start', toolName: name, toolInput: input, refId },
      { kind: 'tool-end', toolName: name, toolOutput: output, refId },
    ];
  }
  if (type === 'step_start') {
    return [];
  }
  if (type === 'step_finish') {
    return [{ kind: 'result', text: '' }];
  }
  if (type === 'error') {
    const text =
      (typeof msg.error === 'string' && msg.error) ||
      (typeof part.message === 'string' && part.message) ||
      (typeof msg.message === 'string' && msg.message) ||
      JSON.stringify(msg.error ?? part ?? msg);
    return [{ kind: 'error', text }];
  }
  return [];
}

export function parseAgyStreamEvent(msg: Record<string, unknown>): AgentDelta[] {
  const event = String(msg.event ?? msg.type ?? '');
  if (event === 'init') return [];
  if (event === 'step_update') {
    const step = (msg.step_update as Record<string, unknown> | undefined) ?? {};
    const stepType = String(step.step_type ?? '');
    const state = String(step.state ?? '');
    if (stepType === 'agent_response') {
      const text = typeof step.text_delta === 'string' ? step.text_delta : '';
      if (text) return [{ kind: 'text-delta', text }];
      return [];
    }
    if (stepType === 'tool') {
      const info = (step.tool_info as Record<string, unknown> | undefined) ?? {};
      const name = String(step.tool_name ?? info.name ?? 'tool');
      const refId = String(step.step_index ?? info.name ?? name);
      const input = JSON.stringify(info.parameters ?? {}, null, 2).slice(0, 4000);
      const output = typeof info.output === 'string'
        ? info.output.slice(0, 4000)
        : JSON.stringify(info.output ?? {}, null, 2).slice(0, 4000);
      if (state === 'ACTIVE') {
        return [{ kind: 'tool-start', toolName: name, toolInput: input, refId }];
      }
      return [{ kind: 'tool-end', toolName: name, toolOutput: output, refId }];
    }
    return [];
  }
  if (event === 'result') {
    const result = (msg.result as Record<string, unknown> | undefined) ?? msg;
    const status = String(result.status ?? '');
    const response = typeof result.response === 'string' ? result.response : '';
    const error = typeof result.error === 'string' ? result.error : '';
    if (status === 'ERROR' || (error && status !== 'SUCCESS')) {
      return [{ kind: 'error', text: error || 'Antigravity reported an error' }];
    }
    return [{ kind: 'result', text: response }];
  }
  return [];
}

function hostEnv(extra?: Record<string, string>): Record<string, string> {
  return { ...(process.env as Record<string, string>), ...extra };
}

function spawnJsonCli(
  argv: string[],
  cwd: string,
  onEvent: (msg: Record<string, unknown>) => void,
  extraEnv?: Record<string, string>,
): { proc: Proc; stderr: Promise<string> } {
  const proc = Bun.spawn(argv, {
    cwd,
    stdin: 'ignore',
    stdout: 'pipe',
    stderr: 'pipe',
    env: hostEnv(extraEnv),
  } as unknown as SpawnOpts);
  void pumpJsonLines(proc, onEvent).catch(() => {});
  return { proc, stderr: collectText(proc.stderr) };
}

async function pumpTextStream(
  stream: unknown,
  onChunk: (chunk: string) => void,
): Promise<string> {
  if (!stream || typeof stream !== 'object' || !('getReader' in stream)) return '';
  const reader = (stream as ReadableStream<Uint8Array>).getReader();
  const decoder = new TextDecoder();
  let out = '';
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      const chunk = decoder.decode(value, { stream: true });
      out += chunk;
      if (chunk) onChunk(chunk);
    }
    const tail = decoder.decode();
    if (tail) {
      out += tail;
      onChunk(tail);
    }
  } finally {
    reader.releaseLock();
  }
  return out.replace(/\x1b\[[0-9;]*m/g, '');
}

function openUrlOnHost(url: string): void {
  try {
    Bun.spawn([resolveBin('xdg-open') ?? 'xdg-open', url], {
      stdin: 'ignore',
      stdout: 'ignore',
      stderr: 'ignore',
      env: hostEnv({ DISPLAY: process.env.DISPLAY || ':0' }),
    } as unknown as SpawnOpts);
  } catch {
    // Phone still gets the URL in chat.
  }
}

// ---------------------------------------------------------------------------
// Claude Code adapter — persistent `claude --print` with stream-json in/out.
// ---------------------------------------------------------------------------

class ClaudeAdapter implements AgentAdapter {
  private proc: Proc | null = null;
  private spawnKey = '';

  constructor(private session: AgentSession) {}

  private ensureProc(opts?: AdapterPromptOpts): Proc {
    const key = `${opts?.model ?? ''}|${opts?.mode ?? 'agent'}|${opts?.thinking ?? ''}`;
    if (this.proc && this.proc.exitCode === null && !this.proc.killed && this.spawnKey === key) {
      return this.proc;
    }
    this.cancel();
    this.spawnKey = key;
    const bin = resolveBin('claude') ?? 'claude';
    this.proc = Bun.spawn(
      claudeSpawnArgs({
        bin,
        model: opts?.model,
        mode: opts?.mode,
        thinking: opts?.thinking,
      }),
      {
        cwd: this.session.info.cwd,
        stdin: 'pipe',
        stdout: 'pipe',
        stderr: 'pipe',
        env: process.env as Record<string, string>,
      } as unknown as SpawnOpts,
    );
    const stderrP = collectText(this.proc.stderr);
    void pumpJsonLines(this.proc, (msg) => this.onEvent(msg)).catch(() => {});
    const spawned = this.proc;
    spawned.exited.then(async (code) => {
      if (this.proc !== spawned) return;
      const stderr = await stderrP.catch(() => '');
      if (this.session.info.busy) {
        setBusy(this.session, false);
        emit(this.session, finishCliTurn({
          sawResult: false,
          exitCode: code,
          stderr: stderr || 'Claude Code process exited',
        })!);
      }
      this.proc = null;
    }).catch(() => {});
    return this.proc;
  }

  private onEvent(msg: Record<string, unknown>): void {
    const s = this.session;
    const type = msg.type;
    if (type === 'assistant') {
      const message = msg.message as Record<string, unknown> | undefined;
      const content = message?.content;
      if (Array.isArray(content)) {
        for (const raw of content) {
          const part = raw as Record<string, unknown>;
          if (part.type === 'text' && typeof part.text === 'string' && part.text.trim()) {
            emit(s, { kind: 'text', text: part.text });
          } else if (part.type === 'thinking' && typeof part.thinking === 'string') {
            emit(s, { kind: 'thinking', text: part.thinking });
          } else if (part.type === 'tool_use') {
            emit(s, {
              kind: 'tool-start',
              toolName: String(part.name ?? 'tool'),
              toolInput: JSON.stringify(part.input ?? {}, null, 2),
              refId: String(part.id ?? ''),
            });
          }
        }
      }
    } else if (type === 'user') {
      // Tool results come back as user messages in the transcript stream.
      const message = msg.message as Record<string, unknown> | undefined;
      const content = message?.content;
      if (Array.isArray(content)) {
        for (const raw of content) {
          const part = raw as Record<string, unknown>;
          if (part.type === 'tool_result') {
            emit(s, {
              kind: 'tool-end',
              refId: String(part.tool_use_id ?? ''),
              toolOutput: contentToText(part.content).slice(0, 4000),
            });
          }
        }
      }
    } else if (type === 'result') {
      setBusy(s, false);
      emit(s, {
        kind: 'result',
        text: typeof msg.result === 'string' ? msg.result : '',
      });
    } else if (type === 'system' && msg.subtype === 'init') {
      emit(s, { kind: 'status', text: 'ready' });
    } else if (type === 'control_request' || msg.subtype === 'can_use_tool') {
      const requestId = String(msg.request_id ?? msg.id ?? crypto.randomUUID());
      const tool = (msg.request as Record<string, unknown> | undefined) ?? msg;
      emit(s, {
        kind: 'permission-request',
        refId: requestId,
        toolName: String(tool.tool_name ?? tool.name ?? 'tool'),
        toolInput: JSON.stringify(tool.input ?? tool.tool_input ?? {}, null, 2),
        text: `Allow ${String(tool.tool_name ?? tool.name ?? 'this tool')}?`,
      });
      s.pendingPermissions.set(requestId, (allow) => {
        try {
          const stdin = this.proc?.stdin as unknown as { write(s: string): unknown; flush?: () => void } | undefined;
          stdin?.write(JSON.stringify({
            type: 'control_response',
            request_id: requestId,
            response: { allowed: allow },
          }) + '\n');
          stdin?.flush?.();
        } catch {
          emit(s, { kind: 'error', text: 'failed to send permission response' });
        }
      });
    }
  }

  prompt(text: string, opts?: AdapterPromptOpts): void {
    const proc = this.ensureProc(opts);
    const line = JSON.stringify({
      type: 'user',
      message: { role: 'user', content: claudeUserContent(text, opts?.images) },
    });
    try {
      const stdin = proc.stdin as unknown as { write(s: string): unknown; flush?: () => void };
      stdin.write(line + '\n');
      stdin.flush?.();
    } catch {
      setBusy(this.session, false);
      emit(this.session, { kind: 'error', text: 'failed to reach the Claude Code process' });
    }
  }

  cancel(): void {
    // Claude Code has no in-band cancel on stream-json stdin; drop the process.
    try {
      this.proc?.kill();
    } catch {
      // already gone
    }
    this.proc = null;
  }

  close(): void {
    this.cancel();
  }
}

// ---------------------------------------------------------------------------
// Cursor CLI adapter — one `cursor-agent --print` process per prompt, chained
// with --resume for multi-turn conversations.
// ---------------------------------------------------------------------------

class CursorAdapter implements AgentAdapter {
  private proc: Proc | null = null;
  private chatId: string | null = null;
  private sawResult = false;
  private streamedText = false;
  private lastText = '';
  private apiKey = process.env.CURSOR_API_KEY || '';
  private loggingIn = false;
  private autoLoginAttempted = false;
  private loginTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(private session: AgentSession) {}

  bindHostChat(id: string): void {
    if (id.startsWith('ide:')) return;
    this.chatId = id;
  }

  private extraEnv(): Record<string, string> {
    const env: Record<string, string> = {};
    if (this.apiKey) env.CURSOR_API_KEY = this.apiKey;
    return env;
  }

  prompt(text: string, opts?: AdapterPromptOpts): void {
    const key = parseEnvApiKey(text, ['CURSOR_API_KEY']);
    if (key) {
      this.apiKey = key.value;
      this.cancel();
      setBusy(this.session, false);
      emit(this.session, {
        kind: 'status',
        text: 'Saved CURSOR_API_KEY for this chat. Send your task again.',
      });
      return;
    }
    if (looksLikeAgentLogin(text)) {
      this.startLogin();
      return;
    }
    this.runPrompt(text, opts);
  }

  private runPrompt(text: string, opts?: AdapterPromptOpts): void {
    this.cancel();
    this.sawResult = false;
    this.streamedText = false;
    this.lastText = '';
    const bin = resolveBin('cursor-agent') ?? 'cursor-agent';
    const argv = buildCursorArgv({
      bin,
      cwd: this.session.info.cwd,
      chatId: this.chatId,
      text,
      model: opts?.model,
      mode: opts?.mode,
      thinking: opts?.thinking,
      imagePaths: opts?.imagePaths,
      catalog: listAgentModels('cursor'),
    });
    const { proc, stderr } = spawnJsonCli(
      argv,
      this.session.info.cwd,
      (msg) => this.onEvent(msg),
      this.extraEnv(),
    );
    this.proc = proc;
    proc.exited.then(async (code) => {
      if (this.proc !== proc) return;
      const errText = await stderr.catch(() => '');
      if (!this.session.info.busy) return;
      setBusy(this.session, false);
      const fail = finishCliTurn({
        sawResult: this.sawResult,
        exitCode: code,
        stderr: errText,
      });
      if (!fail) return;
      if (isCliAuthError(fail.text ?? '')) {
        emit(this.session, {
          kind: 'error',
          text: rewriteCliAuthError(fail.text ?? '', 'Cursor CLI'),
        });
        if (!this.autoLoginAttempted) {
          this.autoLoginAttempted = true;
          this.startLogin();
        }
        return;
      }
      emit(this.session, fail);
    }).catch(() => {});
  }

  private startLogin(): void {
    if (this.loggingIn && this.proc && this.proc.exitCode === null) {
      setBusy(this.session, false);
      emit(this.session, {
        kind: 'status',
        text: 'Sign-in is already waiting — open the link above, or paste `CURSOR_API_KEY=…`.',
      });
      return;
    }
    this.cancel();
    this.loggingIn = true;
    setBusy(this.session, true);
    const bin = resolveBin('cursor-agent') ?? 'cursor-agent';
    const proc = Bun.spawn([bin, 'login'], {
      cwd: this.session.info.cwd,
      stdin: 'ignore',
      stdout: 'pipe',
      stderr: 'pipe',
      env: hostEnv({
        NO_OPEN_BROWSER: '1',
        DISPLAY: process.env.DISPLAY || ':0',
        ...this.extraEnv(),
      }),
    } as unknown as SpawnOpts);
    this.proc = proc;
    emit(this.session, { kind: 'status', text: 'Starting Cursor sign-in on the PC…' });

    let combined = '';
    let urlEmitted = false;
    const onChunk = (chunk: string) => {
      combined += chunk;
      if (urlEmitted) return;
      const url = extractAuthUrl(combined);
      if (!url) return;
      urlEmitted = true;
      openUrlOnHost(url);
      setBusy(this.session, false);
      emit(this.session, {
        kind: 'text',
        text: [
          'Open this link to sign in (a browser may also open on the PC):',
          '',
          url,
          '',
          'Or paste a key from https://cursor.com/dashboard/api as `CURSOR_API_KEY=…`.',
        ].join('\n'),
      });
    };

    this.loginTimer = setTimeout(() => {
      try { proc.kill(); } catch { /* already gone */ }
    }, 5 * 60 * 1000);

    void Promise.all([
      pumpTextStream(proc.stdout, onChunk),
      pumpTextStream(proc.stderr, onChunk),
      proc.exited,
    ]).then(([, , code]) => {
      if (this.proc !== proc) return;
      this.loggingIn = false;
      if (this.loginTimer) {
        clearTimeout(this.loginTimer);
        this.loginTimer = null;
      }
      setBusy(this.session, false);
      if (code === 0) {
        this.autoLoginAttempted = false;
        emit(this.session, {
          kind: 'result',
          text: 'Signed in to Cursor CLI. Send your task again.',
        });
      } else if (!urlEmitted) {
        emit(this.session, {
          kind: 'error',
          text: rewriteCliAuthError(combined || 'login failed', 'Cursor CLI'),
        });
      }
    }).catch(() => {
      this.loggingIn = false;
      setBusy(this.session, false);
    });
  }

  private onEvent(msg: Record<string, unknown>): void {
    const sid = sessionIdFromEvent(msg);
    if (sid) this.chatId = sid;
    const events = parseCursorStreamEvent(msg);
    for (const ev of events) {
      if (ev.kind === 'text' || ev.kind === 'text-delta') {
        if ((ev.text ?? '') === this.lastText) continue;
        this.lastText = ev.text ?? '';
        this.streamedText = true;
      }
      if (ev.kind === 'result' || ev.kind === 'error') {
        this.sawResult = true;
        setBusy(this.session, false);
      }
      emit(this.session, withoutDuplicateResult(ev, this.streamedText));
    }
  }

  cancel(): void {
    if (this.loginTimer) {
      clearTimeout(this.loginTimer);
      this.loginTimer = null;
    }
    this.loggingIn = false;
    try {
      this.proc?.kill();
    } catch {
      // already gone
    }
    this.proc = null;
  }

  close(): void {
    this.cancel();
  }
}

// ---------------------------------------------------------------------------
// OpenCode adapter — `opencode run --format json` per prompt, resumed with
// --session. JSONL events are step_start / text / tool_use / step_finish.
// ---------------------------------------------------------------------------

class OpenCodeAdapter implements AgentAdapter {
  private proc: Proc | null = null;
  private ocSession: string | null = null;
  private sawResult = false;

  constructor(private session: AgentSession) {}

  bindHostChat(id: string): void {
    this.ocSession = id;
  }

  prompt(text: string, opts?: AdapterPromptOpts): void {
    this.cancel();
    this.sawResult = false;
    const bin = resolveBin('opencode') ?? 'opencode';
    const argv = buildOpencodeArgv({
      bin,
      cwd: this.session.info.cwd,
      session: this.ocSession,
      text,
      model: opts?.model,
      mode: opts?.mode,
      thinking: opts?.thinking,
      imagePaths: opts?.imagePaths,
    });
    const { proc, stderr } = spawnJsonCli(argv, this.session.info.cwd, (msg) => this.onEvent(msg));
    this.proc = proc;
    proc.exited.then(async (code) => {
      if (this.proc !== proc) return;
      const errText = await stderr.catch(() => '');
      if (this.session.info.busy) {
        setBusy(this.session, false);
        const fail = finishCliTurn({
          sawResult: this.sawResult,
          exitCode: code,
          stderr: errText,
        });
        if (fail) emit(this.session, fail);
      }
    }).catch(() => {});
  }

  private onEvent(msg: Record<string, unknown>): void {
    const sid = sessionIdFromEvent(msg);
    if (sid) this.ocSession = sid;
    const events = parseOpencodeStreamEvent(msg);
    for (const ev of events) {
      if (ev.kind === 'result' || ev.kind === 'error') {
        this.sawResult = true;
        setBusy(this.session, false);
      }
      emit(this.session, ev);
    }
  }

  cancel(): void {
    try {
      this.proc?.kill();
    } catch {
      // already gone
    }
    this.proc = null;
  }

  close(): void {
    this.cancel();
  }
}

// ---------------------------------------------------------------------------
// Antigravity adapter — `agy -p` with stream-json, resumed via --conversation.
// ---------------------------------------------------------------------------

class AntigravityAdapter implements AgentAdapter {
  private proc: Proc | null = null;
  private conversationId: string | null = null;
  private sawResult = false;
  private streamedText = false;
  private apiKey = process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY || '';

  constructor(private session: AgentSession) {}

  bindHostChat(id: string): void {
    this.conversationId = id;
  }

  private extraEnv(): Record<string, string> {
    const env: Record<string, string> = {};
    if (this.apiKey) {
      env.GEMINI_API_KEY = this.apiKey;
      env.GOOGLE_API_KEY = this.apiKey;
    }
    return env;
  }

  prompt(text: string, opts?: AdapterPromptOpts): void {
    const key = parseEnvApiKey(text, ['GEMINI_API_KEY', 'GOOGLE_API_KEY']);
    if (key) {
      this.apiKey = key.value;
      this.cancel();
      setBusy(this.session, false);
      emit(this.session, {
        kind: 'status',
        text: `Saved ${key.name} for this chat. Send your task again.`,
      });
      return;
    }
    if (looksLikeAgentLogin(text)) {
      setBusy(this.session, false);
      emit(this.session, {
        kind: 'text',
        text: [
          'Antigravity has no headless login command.',
          'Run `agy` once in a terminal on the PC to sign in, or paste `GEMINI_API_KEY=…` here.',
        ].join('\n\n'),
      });
      return;
    }
    this.cancel();
    this.sawResult = false;
    this.streamedText = false;
    const bin = resolveBin('agy') ?? 'agy';
    const argv = buildAgyArgv({
      bin,
      conversationId: this.conversationId,
      text,
      model: opts?.model,
      mode: opts?.mode,
      thinking: opts?.thinking,
      imagePaths: opts?.imagePaths,
      catalog: listAgentModels('antigravity'),
    });
    const { proc, stderr } = spawnJsonCli(
      argv,
      this.session.info.cwd,
      (msg) => this.onEvent(msg),
      this.extraEnv(),
    );
    this.proc = proc;
    proc.exited.then(async (code) => {
      if (this.proc !== proc) return;
      const errText = await stderr.catch(() => '');
      if (!this.session.info.busy) return;
      setBusy(this.session, false);
      const fail = finishCliTurn({
        sawResult: this.sawResult,
        exitCode: code,
        stderr: errText,
      });
      if (!fail) return;
      emit(this.session, isCliAuthError(fail.text ?? '')
        ? { kind: 'error', text: rewriteCliAuthError(fail.text ?? '', 'Antigravity') }
        : fail);
    }).catch(() => {});
  }

  private onEvent(msg: Record<string, unknown>): void {
    const sid = sessionIdFromEvent(msg);
    if (sid) this.conversationId = sid;
    const events = parseAgyStreamEvent(msg);
    for (const ev of events) {
      if (ev.kind === 'text' || ev.kind === 'text-delta') this.streamedText = true;
      if (ev.kind === 'result' || ev.kind === 'error') {
        this.sawResult = true;
        setBusy(this.session, false);
      }
      emit(this.session, withoutDuplicateResult(ev, this.streamedText));
    }
  }

  cancel(): void {
    try {
      this.proc?.kill();
    } catch {
      // already gone
    }
    this.proc = null;
  }

  close(): void {
    this.cancel();
  }
}

// ---------------------------------------------------------------------------
// Mock adapter — deterministic canned conversation for tests and demos, so the
// whole gateway → WS → phone chat pipeline can be exercised without any CLI.
// ---------------------------------------------------------------------------

class MockAdapter implements AgentAdapter {
  private timers: ReturnType<typeof setTimeout>[] = [];

  constructor(private session: AgentSession) {}

  prompt(text: string, opts?: AdapterPromptOpts): void {
    const s = this.session;
    const at = (ms: number, fn: () => void) => this.timers.push(setTimeout(fn, ms));
    const bits: string[] = [];
    if (opts?.mode && opts.mode !== 'agent') bits.push(`mode=${opts.mode}`);
    if (opts?.thinking) bits.push(`thinking=${opts.thinking}`);
    if (opts?.model) bits.push(`model=${opts.model}`);
    if (opts?.imagePaths?.length) bits.push(`${opts.imagePaths.length} photo(s)`);
    const extras = bits.length ? `\n\nComposer: ${bits.join(', ')}` : '';
    at(150, () => emit(s, { kind: 'thinking', text: 'Looking at the request…' }));
    at(400, () =>
      emit(s, {
        kind: 'tool-start',
        toolName: 'Shell',
        toolInput: JSON.stringify({ command: 'echo demo' }, null, 2),
        refId: 'mock-1',
      }));
    at(500, () => {
      emit(s, {
        kind: 'permission-request',
        refId: 'mock-perm',
        toolName: 'Shell',
        toolInput: JSON.stringify({ command: 'echo demo' }, null, 2),
        text: 'Allow the demo agent to run `echo demo`?',
      });
      s.pendingPermissions.set('mock-perm', (allow) => {
        if (!allow) {
          emit(s, { kind: 'error', text: 'Permission denied' });
          setBusy(s, false);
          emit(s, { kind: 'result', text: '' });
          return;
        }
        emit(s, { kind: 'tool-end', refId: 'mock-1', toolOutput: 'demo\n' });
        emit(s, {
          kind: 'text',
          text: `You said: "${text}"${extras}\n\nThis is the **demo agent** — install Claude Code, Cursor CLI, OpenCode, or Antigravity on the PC to chat with a real agent here.\n\n\`\`\`diff\n--- a/README.md\n+++ b/README.md\n@@ -1,3 +1,4 @@\n # NexusLink\n+Phone OS for your PC\n\`\`\``,
        });
        setBusy(s, false);
        emit(s, { kind: 'result', text: '' });
      });
    });
  }

  cancel(): void {
    this.timers.forEach(clearTimeout);
    this.timers = [];
  }

  close(): void {
    this.cancel();
  }
}
