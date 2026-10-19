import { sessionActivity } from '../workspace/session-activity';
import { persistAgent, loadedAgentRows } from '../workspace/agent-store';
import { CodexAppServer } from '../../../../../packages/chat-core/src/providers/codex';
// Agent gateway: run AI coding agents (Claude Code, Cursor CLI, OpenCode,
// Antigravity) on the host and expose them to the phone as chat sessions with a
// normalized event stream — the phone renders a native chat UI, never a terminal.
//
// Each CLI gets an adapter that translates its stream-json output into
// AgentEvent records. Events are buffered per session (so a reconnecting
// phone can replay history via agent.history) and pushed live as
// `agent-event` WebSocket messages.

import { existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { delimiter, isAbsolute, join, resolve, sep } from 'node:path';
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
  agyProjectIdForCwd,
  clipTitle,
  getAgyChatTitle,
  listAgyHostChats,
  listCodexHostChats,
  listClaudeHostChats,
  listCursorCliHostChats,
  listCursorIdeHostChats,
  listOpencodeHostChats,
  loadHostChatHistory,
  normalizeHostChat,
  type HostChatDelta,
} from './host-chats';
import { hasActivePushSessions, sendAgentPushNotification } from './push';

type SpawnOpts = Parameters<typeof Bun.spawn>[1];
type Proc = ReturnType<typeof Bun.spawn>;

const HISTORY_CAP = 1000;

type BroadcastFn = (msg: WsMessage) => void;
let broadcast: BroadcastFn = () => {};

export function setAgentBroadcast(fn: BroadcastFn): void {
  broadcast = fn ?? (() => {});
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
  const local = process.env.LOCALAPPDATA || join(home, 'AppData', 'Local');
  const roaming = process.env.APPDATA || join(home, 'AppData', 'Roaming');
  const dirs = [
    join(home, '.local', 'bin'),
    join(home, '.opencode', 'bin'),
    join(home, '.cursor', 'bin'),
    join(home, '.gemini', 'antigravity-cli'),
    join(home, '.gemini', 'antigravity', 'bin'),
    join(home, '.gemini', 'antigravity'),
    join(local, 'agy', 'bin'),
    join(home, 'bin'),
    join(local, 'Programs', 'cursor', 'resources', 'app', 'bin'),
    join(roaming, 'npm'),
    join(home, 'AppData', 'Roaming', 'npm'),
    '/usr/local/bin',
    '/usr/bin',
    ...cursorAgentInstallDirs(roaming),
  ];
  return dirs;
}

/** Cursor ships cursor-agent.cmd under AppData, not always on PATH. */
function cursorAgentInstallDirs(roaming: string): string[] {
  const versions = join(
    roaming,
    'Cursor',
    'User',
    'globalStorage',
    'anysphere.cursor-agent-worker',
    'agent-cli',
    '.local',
    'share',
    'cursor-agent',
    'versions',
  );
  if (!existsSync(versions)) return [];
  try {
    return readdirSync(versions)
      .sort()
      .reverse()
      .map((v) => join(versions, v))
      .filter((dir) =>
        existsSync(join(dir, 'cursor-agent.cmd')) ||
        existsSync(join(dir, 'cursor-agent.exe')) ||
        existsSync(join(dir, 'cursor-agent')),
      );
  } catch {
    return [];
  }
}

const WIN_EXTS = ['', '.cmd', '.exe', '.bat', '.ps1'];

export function resolveBin(bin: string): string | null {
  if (!bin) return null;
  if (bin.includes('/') || bin.includes('\\')) {
    return existsSync(bin) ? bin : null;
  }
  const exts = process.platform === 'win32' ? WIN_EXTS : [''];
  const seen = new Set<string>();
  for (const dir of [...(process.env.PATH ?? '').split(delimiter), ...extraBinDirs()]) {
    if (!dir || seen.has(dir)) continue;
    seen.add(dir);
    for (const ext of exts) {
      const p = join(dir, `${bin}${ext}`);
      if (existsSync(p)) return p;
    }
  }
  return null;
}

/** .cmd/.bat need cmd.exe on Windows or Bun's uv_spawn returns ENOENT. */
export function spawnArgv(argv: string[]): string[] {
  if (process.platform !== 'win32' || argv.length === 0) return argv;
  const bin = argv[0]!;
  const rest = argv.slice(1);
  if (/\.(cmd|bat)$/i.test(bin)) return ['cmd.exe', '/d', '/s', '/c', bin, ...rest];
  if (/\.ps1$/i.test(bin)) {
    return ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', bin, ...rest];
  }
  return argv;
}

function which(bin: string): string | null {
  return resolveBin(bin);
}

const MAX_IMAGES = 4;
const MAX_IMAGE_BYTES = 4 * 1024 * 1024;

/** Fallback when `cursor-agent models` cannot run — ids must be valid CLI model slugs. */
const CURSOR_MODELS: AgentModelOption[] = [
  { id: 'auto', name: 'Auto', supportsEffort: false },
  { id: 'composer-2.5', name: 'Composer 2.5', supportsEffort: true },
  { id: 'gpt-5.3-codex', name: 'GPT-5.3 Codex', supportsEffort: true },
  { id: 'cursor-grok-4.6-medium', name: 'Grok 4.6', supportsEffort: true },
  { id: 'claude-opus-5-medium', name: 'Claude Opus 5', supportsEffort: true },
  { id: 'claude-sonnet-5-thinking-medium', name: 'Claude Sonnet 5', supportsEffort: true },
  { id: 'gpt-5.6-sol-medium', name: 'GPT-5.6', supportsEffort: true },
];

const OPENCODE_MODELS: AgentModelOption[] = [
  { id: 'opencode/deepseek-v4-flash-free', name: 'DeepSeek V4 Flash', supportsEffort: true },
  { id: 'opencode/mimo-v2.5-free', name: 'MiMo 2.5', supportsEffort: true },
  { id: 'opencode/big-pickle', name: 'Big Pickle', supportsEffort: true },
  { id: 'opencode/hy3-free', name: 'HY3', supportsEffort: true },
  { id: 'opencode/laguna-s-2.1-free', name: 'Laguna S 2.1', supportsEffort: true },
  { id: 'opencode/nemotron-3-ultra-free', name: 'Nemotron 3 Ultra', supportsEffort: true },
  { id: 'opencode/nemotron-3.5-lightning-free', name: 'Nemotron 3.5 Lightning', supportsEffort: true },
];

const ANTIGRAVITY_MODELS: AgentModelOption[] = [
  { id: 'gemini-3.7-flash', name: 'Gemini 3.7 Flash', supportsEffort: true },
  { id: 'gemini-3.1-pro', name: 'Gemini 3.1 Pro', supportsEffort: true },
  { id: 'claude-sonnet-4-6', name: 'Claude Sonnet 4.6', supportsEffort: false },
  { id: 'claude-opus-4-6', name: 'Claude Opus 4.6', supportsEffort: false },
  { id: 'gpt-oss-120b', name: 'GPT-OSS 120B', supportsEffort: false },
];


const CODEX_MODELS: AgentModelOption[] = [
  { id: 'gpt-5.3-codex', name: 'GPT-5.3 Codex', supportsEffort: true },
  { id: 'gpt-5.6-sol-medium', name: 'GPT-5.6', supportsEffort: true },
  { id: 'gpt-6-sol', name: 'GPT-6 Sol', supportsEffort: true },
  { id: 'o3-mini', name: 'o3-mini', supportsEffort: true },
  { id: 'o4-mini', name: 'o4-mini', supportsEffort: true },
];

const CLAUDE_MODELS: AgentModelOption[] = [
  { id: 'default', name: 'Default', supportsEffort: true },
  { id: 'sonnet', name: 'Sonnet', supportsEffort: true },
  { id: 'opus', name: 'Opus', supportsEffort: false },
  { id: 'haiku', name: 'Haiku', supportsEffort: false },
];

const AGENT_DEFS: AgentDef[] = [
  {
    id: 'codex',
    name: 'Codex',
    bin: 'codex',
    capabilities: {
      modes: ['agent'],
      thinkingLevels: ['low', 'medium', 'high'],
      models: CODEX_MODELS,
      images: true,
    },
    makeAdapter: (s) => new CodexAppServerAdapter(s),
  },

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

// Supported agents have unified client-side brand marks rather than scraping
// arbitrary and inconsistent desktop theme icons from the host PC.
export const AGENT_ICON_NAMES: Record<string, string[]> = {};

export async function resolveAgentIcon(_agentId: string): Promise<string | undefined> {
  return undefined;
}

export function getCachedAgentIcon(_agentId: string): string | undefined {
  return undefined;
}

export function listAgents(): AgentInfo[] {
  return AGENT_DEFS.map((d) => {
    const catalog = listAgentModels(d.id);
    const models = collapseModelFamilies(catalog).map((m) => ({
      ...m,
      supportsEffort: m.supportsEffort ?? isModelEffortSupported(d.id, m.id),
    }));
    const bin = d.bin ? which(d.bin) : null;
    return {
      id: d.id,
      name: d.name,
      icon: getCachedAgentIcon(d.id),
      available: bin !== null || !d.bin,
      capabilities: {
        ...d.capabilities,
        models,
        approvalMode: getAgentApprovalMode(d.id),
        // Include Go plan status for OpenCode so the phone can show a badge.
        // Uses cached value (populated during warm-up) — no extra blocking call.
        ...(d.id === 'opencode' && bin
          ? { plan: ocPlanCache.get(bin) ?? 'unknown' }
          : {}),
      },
    };
  });
}

const modelCache = new Map<string, AgentModelOption[]>();
const modelCacheLive = new Map<string, boolean>();
const modelCacheTime = new Map<string, number>(); // epoch ms when last fetched

const MODEL_CACHE_TTL_MS = 5 * 60 * 1000; // 5 minutes

// OpenCode Go plan status cache
const ocPlanCache = new Map<string, 'go' | 'byok' | 'unknown'>(); // keyed by bin path
const ocPlanCacheTime = new Map<string, number>();

const MODEL_VARIANT_SUFFIX =
  /-(?:low|medium|high|xhigh|max)(?:-fast)?$/i;

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
  const suffixed = family.filter(
    (x) => x.id !== fam && (MODEL_VARIANT_SUFFIX.test(x.id) || /-thinking/i.test(x.id)),
  );
  const pool = suffixed.length ? suffixed : family;
  let best = pool[0]!;
  let bestScore = variantScore(best.id, thinking);
  for (const c of pool.slice(1)) {
    const score = variantScore(c.id, thinking);
    if (score > bestScore) {
      bestScore = score;
      best = c;
    }
  }
  return best.id;
}

/**
 * Detect whether the user has an OpenCode Go subscription configured by
 * parsing `opencode auth list` output. Result is cached with the same TTL
 * as the model list so we don't block every RPC call.
 */
export function fetchOpencodeGoStatus(bin: string): 'go' | 'byok' | 'unknown' {
  const now = Date.now();
  const cacheTime = ocPlanCacheTime.get(bin) ?? 0;
  const cached = ocPlanCache.get(bin);
  if (cached !== undefined && now - cacheTime < MODEL_CACHE_TTL_MS) return cached;

  let status: 'go' | 'byok' | 'unknown' = 'unknown';
  try {
    const proc = Bun.spawnSync(spawnArgv([bin, 'auth', 'list']), {
      stdout: 'pipe',
      stderr: 'pipe',
      timeout: 5000,
      env: process.env as Record<string, string>,
    });
    const text = (proc.stdout?.toString() ?? '').toLowerCase();
    // OpenCode Go appears as a provider named "opencode" or "opencode-go"
    // in the auth list. Look for the domain too as a fallback.
    if (
      /\bopencode\b/.test(text) ||
      text.includes('opencode.ai') ||
      text.includes('go.opencode')
    ) {
      status = 'go';
    } else if (text.trim().length > 0) {
      // Some providers configured, but not Go
      status = 'byok';
    }
  } catch {
    status = 'unknown';
  }

  ocPlanCache.set(bin, status);
  ocPlanCacheTime.set(bin, now);
  return status;
}

function fetchLiveModels(agentId: string, bin: string): AgentModelOption[] {
  if (agentId === 'claude' || agentId === 'mock') return [];
  // For opencode: use --refresh flag so we always get the latest from the registry
  const argv = agentId === 'opencode' ? [bin, 'models', '--refresh'] : [bin, 'models'];
  try {
    const proc = Bun.spawnSync(spawnArgv(argv), {
      stdout: 'pipe',
      stderr: 'pipe',
      timeout: 8000,
      env: process.env as Record<string, string>,
    });
    const text = proc.stdout?.toString() ?? '';
    return parseAgentModelList(text);
  } catch {
    return [];
  }
}

function augmentAgentModels(agentId: string, models: AgentModelOption[]): AgentModelOption[] {
  return models.map((m) => ({
    ...m,
    supportsEffort: m.supportsEffort ?? isModelEffortSupported(agentId, m.id),
  }));
}

export function listAgentModels(agentId: string, forceRefresh = false): AgentModelOption[] {
  const def = AGENT_DEFS.find((d) => d.id === agentId);
  if (!def) return [];

  // Return cached result if it's still fresh and refresh wasn't forced
  const cacheTime = modelCacheTime.get(agentId) ?? 0;
  const cacheStale = Date.now() - cacheTime > MODEL_CACHE_TTL_MS;
  if (!forceRefresh && modelCacheLive.get(agentId) && modelCache.has(agentId) && !cacheStale) {
    return augmentAgentModels(agentId, modelCache.get(agentId)!);
  }

  if (def.bin) {
    const bin = which(def.bin);
    if (bin) {
      const live = fetchLiveModels(agentId, bin);
      if (live.length) {
        const augmented = augmentAgentModels(agentId, live);
        modelCache.set(agentId, augmented);
        modelCacheLive.set(agentId, true);
        modelCacheTime.set(agentId, Date.now());
        return augmented;
      }
    }
  }

  if (modelCache.has(agentId)) {
    return augmentAgentModels(agentId, modelCache.get(agentId)!);
  }

  const augmented = augmentAgentModels(agentId, def.capabilities.models);
  modelCache.set(agentId, augmented);
  modelCacheLive.set(agentId, false);
  modelCacheTime.set(agentId, Date.now());
  return augmented;
}

function warmAgentModelCatalogs(): void {
  for (const def of AGENT_DEFS) {
    if (!def.bin) continue;
    const bin = which(def.bin);
    if (!bin) continue;
    try {
      listAgentModels(def.id);
    } catch {
      // Offline host — fallback catalog still works.
    }
    // Prime the Go plan cache for OpenCode so listAgents() has it ready.
    if (def.id === 'opencode') {
      try {
        fetchOpencodeGoStatus(bin);
      } catch {
        // Auth list unavailable — 'unknown' will be served.
      }
    }
  }
}

warmAgentModelCatalogs();

export function thinkingToEffort(thinking?: string): 'low' | 'medium' | 'high' | undefined {
  if (!thinking) return undefined;
  const t = thinking.toLowerCase();
  if (t === 'none' || t === 'off') return undefined;
  if (t === 'low' || t === 'minimal') return 'low';
  if (t === 'high' || t === 'extra-high' || t === 'max' || t === 'xhigh') return 'high';
  return 'medium';
}

export function isModelEffortSupported(agentId?: string, modelId?: string): boolean {
  const agent = (agentId || '').toLowerCase().trim();
  const m = (modelId || '').toLowerCase().trim();
  if (agent === 'antigravity') {
    if (!m || m === 'default' || m === 'auto') return true;
    if (m.includes('claude') || m.includes('gpt-') || m.includes('grok') || m.includes('composer')) {
      return false;
    }
    return m.includes('gemini');
  }
  if (agent === 'claude') {
    if (!m || m === 'default' || m === 'sonnet' || m.includes('sonnet')) return true;
    if (m === 'opus' || m === 'haiku' || m.includes('opus') || m.includes('haiku')) return false;
    return true;
  }
  if (agent === 'cursor') {
    if (m === 'auto') return false;
    if (m.includes('haiku') || m === 'gpt-4o-mini' || m.includes('gpt-4o-mini')) return false;
    return true;
  }
  if (agent === 'opencode') {
    if (m.includes('non-reasoning') || m.includes('standard')) return false;
    return true;
  }
  return true;
}

/** Antigravity `--effort` is Gemini-only; Claude/GPT models reject it. */
export function agyEffortFlag(model?: string, thinking?: string): 'low' | 'medium' | 'high' | undefined {
  const effort = thinkingToEffort(thinking);
  if (!effort) return undefined;
  const m = (model || '').toLowerCase();
  if (m.includes('claude') || m.includes('gpt-') || m.includes('grok') || m.includes('composer')) {
    return undefined;
  }
  return effort;
}

/** Cursor `--model` value, including `[effort=…]` when thinking is set. */
export function cursorModelFlag(model?: string, thinking?: string): string | undefined {
  const m = (model || '').trim();
  if (!m || m === 'auto' || m === 'default') return undefined;
  if (m.includes('[')) return m;
  if (!isModelEffortSupported('cursor', m)) return m;
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
  const argv = [opts.bin, 'run', '--format', 'json', '--dir', opts.cwd];
  if (opts.model && opts.model !== 'default') argv.push('--model', opts.model);
  if (opts.mode === 'plan') argv.push('--agent', 'plan');
  if (isModelEffortSupported('opencode', opts.model)) {
    const variant = opts.thinking && opts.thinking !== 'medium' ? opts.thinking : undefined;
    if (variant) argv.push('--variant', variant === 'extra-high' ? 'max' : variant);
  }
  if (opts.session) argv.push('--session', opts.session);
  for (const p of opts.imagePaths ?? []) argv.push('--file', p);
  argv.push(opts.text.trim() || 'Please look at the attached image(s).');
  return argv;
}

export function buildAgyArgv(opts: {
  bin: string;
  cwd?: string;
  conversationId?: string | null;
  projectId?: string | null;
  newProject?: boolean;
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
  if (opts.cwd) argv.push('--add-dir', opts.cwd);
  if (opts.newProject && !opts.conversationId) argv.push('--new-project');
  if (opts.projectId && opts.projectId !== 'default-cli-project') {
    argv.push('--project', opts.projectId);
  }
  if (opts.mode === 'plan') argv.push('--mode', 'plan');
  const resolved = pickModelVariant(opts.model, opts.thinking, opts.catalog ?? []);
  if (resolved && resolved !== 'default') argv.push('--model', resolved);
  const effort = agyEffortFlag(resolved || opts.model, opts.thinking);
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
  resumeId?: string | null;
}): string[] {
  const argv = [
    opts.bin, '--print',
    '--input-format', 'stream-json',
    '--output-format', 'stream-json',
    '--verbose',
    '--permission-mode', opts.mode === 'plan' ? 'plan' : 'acceptEdits',
  ];
  if (opts.model && opts.model !== 'default') argv.push('--model', opts.model);
  if (opts.resumeId) argv.push('--resume', opts.resumeId);
  if (isModelEffortSupported('claude', opts.model)) {
    const effort = thinkingToEffort(opts.thinking);
    if (effort && effort !== 'medium') argv.push('--effort', effort);
  }
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
const pendingApprovalEvents = new Map<string, Map<string, AgentEvent>>();
export function pendingAgentApprovals(id: string): AgentEvent[] {
  return [...(pendingApprovalEvents.get(id)?.values() ?? [])];
}
function settleApproval(session: AgentSession, requestId: string, outcome: string) {
  pendingApprovalEvents.get(session.info.agentSessionId)?.delete(requestId);
  session.info.taskState=pendingAgentApprovals(session.info.agentSessionId).length ? 'waiting' : session.info.busy ? 'running' : 'idle';
  emit(session,{kind:'status',refId:requestId,approvalOutcome:outcome as AgentEvent['approvalOutcome'],text:`Approval ${outcome}.`});
}


/**
 * Per-agent approval policy.
 *
 * 'ask' — surface every permission request to the phone and wait for an answer.
 * 'auto' — never ask; approve immediately so a turn can never block on a
 *          phone that is closed, backgrounded, or attached to another session.
 *
 * A permission request that nobody answers is worse than an unwanted one: the
 * agent sits blocked until its own timeout, so 'auto' is the escape hatch.
 */
export type AgentApprovalMode = 'ask' | 'auto';

const APPROVAL_MODES: readonly AgentApprovalMode[] = ['ask', 'auto'];

const approvalModes = new Map<string, AgentApprovalMode>();

function getApprovalStorePath(): string {
  const dir = process.env.NEXUSLINK_DATA_DIR || join(homedir(), '.cache', 'nexuslink');
  if (!existsSync(dir)) {
    try {
      mkdirSync(dir, { recursive: true });
    } catch (_) {}
  }
  return join(dir, 'agent_approval.json');
}

function loadApprovalModes(): void {
  try {
    const p = getApprovalStorePath();
    if (!existsSync(p)) return;
    const parsed = JSON.parse(readFileSync(p, 'utf-8')) as unknown;
    if (!parsed || typeof parsed !== 'object') return;
    for (const [agent, mode] of Object.entries(parsed as Record<string, unknown>)) {
      if (APPROVAL_MODES.includes(mode as AgentApprovalMode)) {
        approvalModes.set(agent, mode as AgentApprovalMode);
      }
    }
  } catch (_) {}
}

function saveApprovalModes(): void {
  try {
    writeFileSync(
      getApprovalStorePath(),
      JSON.stringify(Object.fromEntries(approvalModes), null, 2),
      'utf-8',
    );
  } catch (_) {}
}

loadApprovalModes();

export function getAgentApprovalMode(agentId: string): AgentApprovalMode {
  return approvalModes.get(agentId) ?? 'ask';
}

export function setAgentApprovalMode(agentId: string, mode: string): { ok: boolean; mode?: AgentApprovalMode } {
  if (!APPROVAL_MODES.includes(mode as AgentApprovalMode)) return { ok: false };
  approvalModes.set(agentId, mode as AgentApprovalMode);
  saveApprovalModes();
  return { ok: true, mode: mode as AgentApprovalMode };
}

/** How long a surfaced permission request may wait before the host auto-denies it. */
const PERMISSION_TIMEOUT_MS = 5 * 60 * 1000;

const permissionTimers = new Map<string, Map<string, ReturnType<typeof setTimeout>>>();

/**
 * Deny a permission request that nobody answered. Without this the CLI holds the
 * request open and the session is wedged until its own timeout, which is the
 * "asked on my PC, never reached my phone, request died" failure.
 */
function trackPermissionTimeout(session: AgentSession, requestId: string): void {
  const key = session.info.agentSessionId;
  let byRequest = permissionTimers.get(key);
  if (!byRequest) {
    byRequest = new Map();
    permissionTimers.set(key, byRequest);
  }
  byRequest.get(requestId)?.unref?.();
  const timer = setTimeout(() => {
    const pending = permissionTimers.get(key);
    pending?.delete(requestId);
    if (pending && !pending.size) permissionTimers.delete(key);
    const resolve = session.pendingPermissions.get(requestId);
    if (!resolve) return;
    session.pendingPermissions.delete(requestId);
    settleApproval(session, requestId, 'expired');
    resolve(false);
  }, PERMISSION_TIMEOUT_MS);
  timer.unref?.();
  byRequest.set(requestId, timer);
}

function clearPermissionTimeout(agentSessionId: string, requestId: string): void {
  const byRequest = permissionTimers.get(agentSessionId);
  const timer = byRequest?.get(requestId);
  if (!byRequest || timer === undefined) return;
  timer.unref?.();
  clearTimeout(timer);
  byRequest.delete(requestId);
  if (!byRequest.size) permissionTimers.delete(agentSessionId);
}

function clearAllPermissionTimeouts(agentSessionId: string): void {
  const byRequest = permissionTimers.get(agentSessionId);
  if (!byRequest) return;
  for (const timer of byRequest.values()) clearTimeout(timer);
  permissionTimers.delete(agentSessionId);
}

function getSessionsStorePath(): string {
  const dir = process.env.NEXUSLINK_DATA_DIR || join(homedir(), '.cache', 'nexuslink');
  if (!existsSync(dir)) {
    try {
      mkdirSync(dir, { recursive: true });
    } catch (_) {}
  }
  return join(dir, 'agent_sessions.json');
}

const savedSequences = new Map<string, number>();
const savedSummaries = new Map<string, string>();
function saveAgentSessionsToDisk(): void {
  for (const session of agentSessions.values()) {
    const id=session.info.agentSessionId;
    const events=session.history.filter(event=>event.seq>(savedSequences.get(id) ?? 0));
    const summary=JSON.stringify(session.info);
    if(!events.length && savedSummaries.get(id)===summary) continue;
    savedSummaries.set(id,summary);
    if(events.length)savedSequences.set(id,events.at(-1)!.seq);
    void persistAgent({info:{...session.info},events}).catch(error=>{
      savedSummaries.delete(id);savedSequences.delete(id);
      console.error('[agents] Persistence failed:',error.message);
    });
  }
}

let agentSessionsLoaded = false;
function loadAgentSessionsFromDisk(): void {
  if (agentSessionsLoaded) return;
  agentSessionsLoaded = true;
  try {
    const list = loadedAgentRows();
    if (!Array.isArray(list)) return;
    for (const item of list) {
      if (!item?.info?.agentSessionId || agentSessions.has(item.info.agentSessionId)) continue;
      const info: AgentSessionInfo = item.info;
      const def = AGENT_DEFS.find((d) => d.id === info.agent);
      if (!def) continue;
      const history = Array.isArray(item.history)
        ? closeDanglingToolStarts(sanitizeAgentHistory(item.history))
        : [];
      const session: AgentSession = {
        info: { ...info, busy: false, status: 'running', taskState: info.busy ? 'interrupted' : (info.taskState || 'idle') },
        history,
        adapter: null as unknown as AgentAdapter,
        seq: history.length > 0 ? (history[history.length - 1].seq ?? 0) : 0,
        pendingPermissions: new Map(),
      };
      session.adapter = def.makeAdapter(session);
      if (info.hostChatId) session.adapter.bindHostChat?.(info.hostChatId);
      agentSessions.set(info.agentSessionId, session);
    }
  } catch (_) {}
}

function emit(session: AgentSession, event: Omit<AgentEvent, 'seq' | 'ts'>): void {
  if (isRedundantToolStart(session.history, event)) return;
  const full: AgentEvent = { ...event, seq: ++session.seq, ts: Date.now(), turnId: session.info.turnId };
  session.info.updatedAt=full.ts;
  const activity=sessionActivity(full);
  const activityChanged=activity!==undefined && activity!==session.info.activity;
  if(activityChanged){session.info.activity=activity;session.info.activityAt=full.ts;}
  if(['result','error','permission-request'].includes(full.kind) || (full.kind==='status' && full.text==='cancelled')){
    delete session.info.activity;delete session.info.activityAt;
  }
  if(full.kind==='user') { session.info.taskState='running'; session.info.preview=full.text?.slice(0,160); }
  if(full.kind==='permission-request' && full.refId) {
    session.info.taskState='waiting';
    const pending=pendingApprovalEvents.get(session.info.agentSessionId) ?? new Map<string,AgentEvent>();
    pending.set(full.refId,full);pendingApprovalEvents.set(session.info.agentSessionId,pending);
  }
  if(full.kind==='result') session.info.taskState='completed';
  if(full.kind==='error') session.info.taskState='failed';
  if(full.kind==='status' && full.text==='cancelled') session.info.taskState='canceled';
  session.history.push(full);
  if (session.history.length > HISTORY_CAP) session.history.splice(0, 100);
  savedSequences.set(session.info.agentSessionId, full.seq);
  const savedInfo={...session.info};
  void persistAgent({info:savedInfo,events:[full]}).then(()=>{
    broadcast({ type:'agent-event', agentSessionId:savedInfo.agentSessionId,event:full });
    if(activityChanged || ['result','error','permission-request','user','status'].includes(full.kind)) broadcast({type:'agent-session-update',session:savedInfo});
  }).catch(error=>{
    session.info.taskState='failed';
    broadcast({type:'agent-event',agentSessionId:session.info.agentSessionId,event:{kind:'error',seq:++session.seq,ts:Date.now(),text:'Task history could not be saved. Check host storage.'}});
    console.error('[agents] Persistence failed:',error.message);
  });

  // If no active websocket clients are connected (e.g. mobile app is closed/screen off),
  // send a native push notification to registered devices.
  if (!hasActivePushSessions()) {
    if (full.kind === 'result') {
      const title = session.info.title ? `Agent Done (${session.info.title})` : 'Agent is Done';
      const body = (full.text || '').trim() || 'The agent has finished working.';
      void sendAgentPushNotification({
        title,
        body: body.slice(0, 200),
        agentSessionId: session.info.agentSessionId,
        sessionTitle: session.info.title,
        kind: 'result',
      });
    } else if (full.kind === 'permission-request') {
      const title = `Action Required (${session.info.title || session.info.agent})`;
      const body = full.text || `Allow ${full.toolName ?? 'action'}?`;
      void sendAgentPushNotification({
        title,
        body: body.slice(0, 200),
        agentSessionId: session.info.agentSessionId,
        sessionTitle: session.info.title,
        kind: 'permission-request',
      });
    } else if (full.kind === 'error') {
      const title = session.info.title ? `Agent Error (${session.info.title})` : 'Agent Encountered an Error';
      const body = (full.text || '').trim() || 'An error occurred during execution.';
      void sendAgentPushNotification({
        title,
        body: body.slice(0, 200),
        agentSessionId: session.info.agentSessionId,
        sessionTitle: session.info.title,
        kind: 'error',
      });
    }
  }
}

function setBusy(session: AgentSession, busy: boolean): void {
  session.info.busy = busy;
  broadcast({ type: 'agent-session-update', session: { ...session.info } });
}

/** Expand ~ and require an existing directory. Any path is allowed for now. */
export function resolveAgentCwd(cwd?: string, opts?: { fallbackHome?: boolean }): string {
  const home = homedir();
  const raw = (cwd ?? '').trim();
  let path: string;
  if (!raw || raw === '~') {
    path = home;
  } else if (raw.startsWith('~/') || raw.startsWith('~\\')) {
    path = join(home, raw.slice(2));
  } else if (process.platform === 'win32' && (raw === '/' || raw.startsWith('/home/'))) {
    path = home;
  } else {
    path = raw;
  }
  if (existsSync(path) && statSync(path).isDirectory()) {
    try {
      return realpathSync(path).replace(/\\/g, '/');
    } catch {
      return path.replace(/\\/g, '/');
    }
  }
  if (opts?.fallbackHome) return home.replace(/\\/g, '/');
  throw new Error(existsSync(path) ? `not a directory: ${path}` : `directory not found: ${path}`);
}

export function isDefaultSessionTitle(title: string | undefined, agentId?: string): boolean {
  const current = (title || '').trim();
  const def = agentId ? AGENT_DEFS.find((d) => d.id === agentId) : undefined;
  return (
    !current ||
    current === 'Agent' ||
    current === 'Host chat' ||
    current === 'New chat' ||
    current === (def?.name ?? '') ||
    current === 'Antigravity' ||
    current === 'OpenCode' ||
    current === 'Cursor CLI' ||
    current === 'Claude Code' ||
    current === 'Demo Agent'
  );
}

export function createAgentSession(
  agentId: string,
  cwd?: string,
  title?: string,
  opts?: { hostChatId?: string },
): AgentSessionInfo {
  loadAgentSessionsFromDisk();
  const def = AGENT_DEFS.find((d) => d.id === agentId);
  if (!def) throw new Error(`unknown agent: ${agentId}`);
  if (def.bin && !which(def.bin)) throw new Error(`${def.name} CLI not installed on the host`);

  const info: AgentSessionInfo = {
    agentSessionId: crypto.randomUUID(),
    agent: agentId,
    icon: getCachedAgentIcon(agentId),
    cwd: resolveAgentCwd(cwd),
    title: title || def.name,
    createdAt: Date.now(),
    busy: false,
    status: 'running',
    taskState: 'idle',
    updatedAt: Date.now(),
    hostChatId: opts?.hostChatId,
    imported: !!opts?.hostChatId,
  };
  const session: AgentSession = {
    info, history: [], adapter: null as unknown as AgentAdapter, seq: 0,
    pendingPermissions: new Map(),
  };
  session.adapter = def.makeAdapter(session);
  if (opts?.hostChatId) session.adapter.bindHostChat?.(opts.hostChatId);
  agentSessions.set(info.agentSessionId, session);
  saveAgentSessionsToDisk();
  broadcast({ type: 'agent-session-update', session: { ...info } });
  return { ...info };
}

export function listAgentSessions(): AgentSessionInfo[] {
  loadAgentSessionsFromDisk();
  return [...agentSessions.values()]
    .map((s) => ({
      ...s.info,
      icon: s.info.icon ?? getCachedAgentIcon(s.info.agent),
    }))
    .sort((a, b) => b.createdAt - a.createdAt);
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
  if (want('codex')) {
    out.push(...listCodexHostChats());
  }
  if (want('antigravity')) {
    out.push(...listAgyHostChats());
  }
  if (want('claude')) {
    out.push(...listClaudeHostChats());
  }
  // New agents: append their list*HostChats() here. normalizeHostChat fills
  // source + cwd so the phone always shows `Source · /folder`.
  return out
    .map((c) => {
      const norm = normalizeHostChat(c);
      return {
        ...norm,
        icon: getCachedAgentIcon(norm.agent),
      };
    })
    .sort((a, b) => b.updatedAt - a.updatedAt)
    .slice(0, 80);
}

export function findHostChatProcesses(agent: string, hostChatId: string): number[] {
  const pids: number[] = [];
  if (!hostChatId) return pids;
  if (process.platform === 'linux') {
    try {
      const entries = readdirSync('/proc');
      for (const entry of entries) {
        if (!/^[0-9]+$/.test(entry)) continue;
        const pid = Number(entry);
        if (pid === process.pid) continue;
        try {
          const cmd = readFileSync(`/proc/${entry}/cmdline`, 'utf8');
          if (cmd.includes(hostChatId)) {
            pids.push(pid);
          }
        } catch {}
      }
    } catch {}
  } else if (process.platform === 'win32') {
    try {
      const proc = Bun.spawnSync(
        ['powershell.exe', '-NoProfile', '-Command', `Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*${hostChatId}*" } | Select-Object -ExpandProperty ProcessId`],
        { stdout: 'pipe' },
      );
      const text = proc.stdout.toString('utf8');
      for (const line of text.split('\n')) {
        const num = Number(line.trim());
        if (num > 0 && num !== process.pid) pids.push(num);
      }
    } catch {}
  }
  return pids;
}

export function isHostChatBusy(agent: string, hostChatId: string, cwd?: string): boolean {
  loadAgentSessionsFromDisk();
  const managed = [...agentSessions.values()].find(
    (s) => (s.info.hostChatId === hostChatId || s.info.agentSessionId === hostChatId) && s.info.status === 'running',
  );
  if (managed && managed.info.busy) return true;

  const pids = findHostChatProcesses(agent, hostChatId);
  return pids.length > 0;
}

export function killHostChatProcesses(agent: string, hostChatId: string): boolean {
  const pids = findHostChatProcesses(agent, hostChatId);
  let killed = false;
  for (const pid of pids) {
    try {
      process.kill(pid, 'SIGINT');
      killed = true;
    } catch {}
  }
  return killed;
}

export function openHostChat(params: {
  agent: string;
  hostChatId: string;
  cwd?: string;
  title?: string;
}): AgentSessionInfo {
  loadAgentSessionsFromDisk();
  const { agent, hostChatId } = params;
  if (!hostChatId) throw new Error('missing hostChatId');
  const existing = [...agentSessions.values()].find(
    (s) => s.info.agent === agent && s.info.hostChatId === hostChatId,
  );
  if (existing) {
    existing.info.status = 'running';
    existing.info.icon = existing.info.icon ?? getCachedAgentIcon(agent);
    if (params.cwd?.trim()) {
      existing.info.cwd = resolveAgentCwd(params.cwd);
    }
    const busy = isHostChatBusy(agent, hostChatId, existing.info.cwd);
    if (busy !== existing.info.busy) {
      existing.info.busy = busy;
    }
    existing.info.imported = false;
    saveAgentSessionsToDisk();
    broadcast({ type: 'agent-session-update', session: { ...existing.info } });
    return { ...existing.info };
  }

  const viewOnly = hostChatId.startsWith('ide:');
  const inferred = params.cwd?.trim()
    ? ''
    : (listHostChats(agent).find((c) => c.hostChatId === hostChatId)?.cwd ?? '');
  const cwd = params.cwd?.trim()
    ? resolveAgentCwd(params.cwd)
    : inferred.trim()
      ? resolveAgentCwd(inferred)
      : resolveAgentCwd(params.cwd, { fallbackHome: true });
  const title = params.title || 'Host chat';
  const info = createAgentSession(agent, cwd, title, { hostChatId });
  const session = agentSessions.get(info.agentSessionId);
  if (!session) return info;
  session.info.imported = false;
  const busy = isHostChatBusy(agent, hostChatId, cwd);
  if (busy) {
    session.info.busy = true;
  }
  const def = AGENT_DEFS.find((d) => d.id === agent);
  const bin = def?.bin ? which(def.bin) : null;
  const history = loadHostChatHistory(agent, hostChatId, bin);
  seedHistory(session, history);
  if (!history.length) {
    seedHistory(session, [{
      kind: 'status',
      text: viewOnly
        ? 'Loaded from Cursor IDE. Read only. Start a new chat to use Cursor CLI.'
        : 'Opened this conversation from the PC. Send a message to continue it.',
      ts: Date.now(),
    }]);
  } else if (viewOnly) {
    seedHistory(session, [{
      kind: 'status',
      text: 'Cursor IDE chats are read only. Start a new chat to use Cursor CLI.',
      ts: Date.now(),
    }]);
  }
  saveAgentSessionsToDisk();
  return { ...session.info };
}

export function agentHistory(agentSessionId: string): AgentEvent[] {
  loadAgentSessionsFromDisk();
  const session = agentSessions.get(agentSessionId);
  if (!session) return [];
  if (session.history.length === 0 && session.info.hostChatId) {
    const def = AGENT_DEFS.find((d) => d.id === session.info.agent);
    const bin = def?.bin ? which(def.bin) : null;
    const history = loadHostChatHistory(session.info.agent, session.info.hostChatId, bin);
    seedHistory(session, history);
  }
  session.history = sanitizeAgentHistory(session.history);
  if (!session.info.busy) {
    const settled = closeDanglingToolStarts(session.history);
    if (settled.length !== session.history.length) {
      session.history = settled;
      session.seq = Math.max(session.seq, settled[settled.length - 1]?.seq ?? 0);
      saveAgentSessionsToDisk();
    }
  }
  return session.history.slice();
}

export function promptAgent(
  agentSessionId: string,
  text: string,
  opts: AgentPromptOpts = {},
): { ok: boolean } {
  loadAgentSessionsFromDisk();
  const session = agentSessions.get(agentSessionId);
  if (!session || session.info.status !== 'running') return { ok: false };
  if (session.info.hostChatId?.startsWith('ide:')) throw new Error('Cursor IDE chats are read only. Start a new chat to use Cursor CLI.');
  if(session.info.busy) throw new Error('This task is already working. Stop it before sending another prompt.');
  if (session.info.agent === 'codex' && opts.mode === 'plan') throw new Error('Codex Plan mode is unavailable. Select Agent mode.');
  session.info.turnId=crypto.randomUUID();
  const materialized = materializeAgentImages(session.info.agentSessionId, opts.images);
  const key = parseEnvApiKey(text, ['CURSOR_API_KEY', 'GEMINI_API_KEY', 'GOOGLE_API_KEY', 'OPENAI_API_KEY']);
  const display = (key ? `${key.name}=••••` : text.trim())
    || (materialized.files.length ? 'Attached photo(s)' : '');
  if (!display) return { ok: false };

  // Auto-name the session if it still has the default/generic name
  if (isDefaultSessionTitle(session.info.title, session.info.agent)) {
    const newTitle = clipTitle(display);
    if (newTitle) {
      session.info.title = newTitle;
      saveAgentSessionsToDisk();
      broadcast({ type: 'agent-session-update', session: { ...session.info } });
    }
  }

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

export function renameAgentSession(
  agentSessionId: string,
  title: string,
): { ok: boolean; title: string } {
  loadAgentSessionsFromDisk();
  const session = agentSessions.get(agentSessionId);
  if (!session) return { ok: false, title: '' };
  const cleaned = clipTitle(title) || session.info.title;
  session.info.title = cleaned;
  saveAgentSessionsToDisk();
  broadcast({ type: 'agent-session-update', session: { ...session.info } });
  return { ok: true, title: cleaned };
}

export function setAgentSessionCwd(
  agentSessionId: string,
  cwd: string,
): AgentSessionInfo {
  loadAgentSessionsFromDisk();
  const session = agentSessions.get(agentSessionId);
  if (!session) throw new Error('session not found');
  session.info.cwd = resolveAgentCwd(cwd);
  saveAgentSessionsToDisk();
  broadcast({ type: 'agent-session-update', session: { ...session.info } });
  return { ...session.info };
}

export function cancelAgent(agentSessionId: string): { ok: boolean } {
  const session = agentSessions.get(agentSessionId);
  if (!session) return { ok: false };
  session.adapter.cancel();
  if (session.info.hostChatId) {
    killHostChatProcesses(session.info.agent, session.info.hostChatId);
  }
  const settled = closeDanglingToolStarts(session.history, 'Stopped.');
  if (settled.length !== session.history.length) {
    session.history = settled;
    session.seq = Math.max(session.seq, settled[settled.length - 1]?.seq ?? 0);
    saveAgentSessionsToDisk();
  }
  for(const event of pendingAgentApprovals(agentSessionId)) settleApproval(session,event.refId!,'canceled');
  clearAllPermissionTimeouts(agentSessionId);
  session.pendingPermissions.clear();
  emit(session, { kind: 'status', text: 'cancelled' });
  setBusy(session, false);
  return { ok: true };
}

export function closeAgentSession(agentSessionId: string): { ok: boolean } {
  const session = agentSessions.get(agentSessionId);
  if (!session) return { ok: false };
  clearAllPermissionTimeouts(agentSessionId);
  session.adapter?.close?.();
  session.info.status = 'exited';
  agentSessions.delete(agentSessionId);
  void persistAgent({delete:agentSessionId}).catch(error=>console.error(error.message));
  saveAgentSessionsToDisk();
  broadcast({ type: 'agent-session-deleted', agentSessionId });
  return { ok: true };
}

/** ACP-shaped session/request_permission response from the phone. */
export function resolveAgentPermission(
  agentSessionId: string,
  requestId: string,
  allow: boolean,
): { ok: boolean; reason?: string } {
  const session = agentSessions.get(agentSessionId);
  if (!session) return { ok: false, reason: 'unknown session' };
  if (!pendingApprovalEvents.get(agentSessionId)?.has(requestId)) return {ok:false,reason:'request already expired'};
  const pending = session.pendingPermissions.get(requestId);
  if (pending) {
    clearPermissionTimeout(agentSessionId, requestId);
    session.pendingPermissions.delete(requestId);
    settleApproval(session, requestId, allow ? 'allowed' : 'denied');
    pending(allow);
    return { ok: true };
  }
  if (session.adapter.permission) {
    clearPermissionTimeout(agentSessionId, requestId);
    settleApproval(session, requestId, allow ? 'allowed' : 'denied');
    session.adapter.permission(requestId, allow);
    return { ok: true };
  }
  // Previously this returned ok:true unconditionally, so a stale card in the
  // phone looked accepted while the agent was still blocked. Say so instead.
  return { ok: false, reason: 'request already expired' };
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
  if (opts.exitCode === 0) return null;
  const err = opts.stderr.trim();
  if (err) return { kind: 'error', text: err };
  return {
    kind: 'error',
    text: `Agent CLI exited without a reply (code ${opts.exitCode ?? '?'})`,
  };
}

export function sessionIdFromEvent(msg: Record<string, unknown>): string | undefined {
  for (const key of [
    'chatId', 'chat_id', 'sessionId', 'session_id', 'sessionID', 'thread_id',
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
  return /authentication required|not authenticated|not logged in|not logged into|please run ['`]?agent login|authentication failed|auth timed out|token exchange failed|you are not logged into antigravity/i.test(text);
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
      'A Google sign-in window should open on the PC. Finish it there, then send your task again.',
      'If no window appears, run `agy` once in a terminal on the PC, or paste `GEMINI_API_KEY=…` here.',
    ].join('\n\n');
  }
  return stderr.trim();
}

export function isInternalCliNoise(text: string): boolean {
  if (!text || typeof text !== 'string') return false;
  const trimmed = text.trim();
  return (
    /invalid tool call error \(invalid_args\)/i.test(trimmed) ||
    /is not a valid artifact path; artifacts must be in/i.test(trimmed)
  );
}

export function sanitizeCliError(text: string, agentName: string): string {
  if (!text || typeof text !== 'string') return '';
  if (isCliAuthError(text)) {
    return rewriteCliAuthError(text, agentName);
  }
  let cleaned = text.trim();
  if (/^declaring permissions:\s*cortex tool/i.test(cleaned)) {
    const m = cleaned.match(/invalid tool call error \([^)]*\)\s*(.*)$/i)
      ?? cleaned.match(/model output error:\s*(.*)$/i);
    if (m?.[1] && m[1].trim()) {
      cleaned = m[1].trim();
    } else {
      cleaned = `${agentName} requires tool permissions on the host PC.`;
    }
  }
  return cleaned;
}

export function sanitizeAgentHistory(history: AgentEvent[]): AgentEvent[] {
  return history.filter((e) => {
    if (e.kind === 'error' && isInternalCliNoise(e.text ?? '')) {
      return false;
    }
    return true;
  });
}

/** Tool-starts that never got a matching tool-end, FIFO per refId (including empty). */
export function unmatchedToolStarts(history: AgentEvent[]): AgentEvent[] {
  const open: AgentEvent[] = [];
  for (const e of history) {
    if (e.kind === 'tool-start') {
      open.push(e);
    } else if (e.kind === 'tool-end') {
      const ref = (e.refId ?? '').trim();
      const i = open.findIndex((s) => (s.refId ?? '').trim() === ref);
      if (i >= 0) open.splice(i, 1);
    }
  }
  return open;
}

/** Repeated ACTIVE/start for a ref that is already in flight. */
export function isRedundantToolStart(
  history: AgentEvent[],
  event: { kind?: string; refId?: string },
): boolean {
  if (event.kind !== 'tool-start') return false;
  const ref = (event.refId ?? '').trim();
  if (!ref) return false;
  return unmatchedToolStarts(history).some((s) => (s.refId ?? '').trim() === ref);
}

/** Close tool-start events that never got a tool-end (host crash / restart). */
export function closeDanglingToolStarts(
  history: AgentEvent[],
  output = 'Interrupted — host restarted.',
): AgentEvent[] {
  const open = unmatchedToolStarts(history);
  if (open.length === 0) return history;
  let seq = history.reduce((m, e) => Math.max(m, e.seq ?? 0), 0);
  const extra: AgentEvent[] = open.map((start) => ({
    seq: ++seq,
    ts: Date.now(),
    kind: 'tool-end',
    toolName: start.toolName,
    toolInput: start.toolInput,
    toolOutput: output,
    refId: start.refId,
  }));
  return [...history, ...extra];
}

function asToolRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function pickToolString(obj: Record<string, unknown>, ...keys: string[]): string {
  for (const key of keys) {
    const value = obj[key];
    if (typeof value === 'string' && value.trim()) return value.trim();
  }
  return '';
}

function toolBasename(path: string): string {
  const trimmed = path.replace(/\/+$/, '');
  const i = trimmed.lastIndexOf('/');
  return i < 0 ? trimmed : trimmed.slice(i + 1);
}

/** One-line summary of what a Cursor tool is doing — no raw JSON on the phone. */
export function formatCursorToolInput(name: string, args: unknown): string {
  const a = asToolRecord(args);
  const tool = name.toLowerCase();

  if (tool === 'shell' || tool === 'bash') {
    return pickToolString(a, 'command', 'cmd');
  }
  if (tool === 'read' || tool === 'write' || tool === 'edit' || tool === 'delete') {
    return pickToolString(a, 'path', 'file', 'target_file');
  }
  if (tool === 'readlints') {
    const paths = a.paths;
    if (Array.isArray(paths) && paths.length) {
      return paths.map((p) => toolBasename(String(p))).join(', ');
    }
    return pickToolString(a, 'path');
  }
  if (tool === 'grep' || tool === 'search') {
    const pattern = pickToolString(a, 'pattern', 'query');
    const path = pickToolString(a, 'path', 'glob');
    return path ? `${pattern} in ${toolBasename(path) || path}` : pattern;
  }
  if (tool === 'glob' || tool === 'glob_file_search') {
    return pickToolString(a, 'pattern', 'glob_pattern', 'glob');
  }
  if (tool === 'list' || tool === 'ls') {
    return pickToolString(a, 'path', 'target_directory') || '.';
  }
  if (tool === 'webfetch' || tool === 'fetch') {
    return pickToolString(a, 'url');
  }
  if (tool === 'task') {
    return pickToolString(a, 'description', 'prompt');
  }
  if (
    tool === 'createplan' ||
    tool === 'create_plan' ||
    tool === 'setplan' ||
    tool === 'set_plan' ||
    tool === 'updateplan' ||
    tool === 'writeplan' ||
    tool === 'plan'
  ) {
    const path = pickToolString(a, 'path', 'filePath', 'planPath', 'target_file', 'targetFile', 'file');
    if (path) return path;
    const title = pickToolString(a, 'title', 'description', 'prompt');
    if (title) return title;
    const plan = pickToolString(a, 'plan', 'content', 'text');
    if (plan) {
      const firstLine = plan.split('\n').find((l) => l.trim().length > 0) || '';
      return firstLine.replace(/^[#\s*-]+/, '').trim() || 'Implementation plan';
    }
    return 'Implementation plan';
  }

  for (const key of ['command', 'path', 'query', 'pattern', 'url', 'description', 'prompt', 'plan', 'title']) {
    const text = pickToolString(a, key);
    if (text) return text;
  }
  return '';
}

/** Short tool result for the phone — hide empty success payloads and metadata JSON. */
export function formatCursorToolOutput(name: string, result: unknown): string {
  if (result == null) return '';
  if (typeof result === 'string') return result.trim().slice(0, 2000);

  const r = asToolRecord(result);
  const tool = name.toLowerCase();
  const failure = asToolRecord(r.failure);
  if (Object.keys(failure).length) {
    return pickToolString(failure, 'message', 'error', 'reason') || 'failed';
  }

  const success = asToolRecord(r.success);
  const bag = Object.keys(success).length ? success : r;

  if (tool === 'shell' || tool === 'bash') {
    const stdout = pickToolString(bag, 'stdout', 'output', 'stdoutText');
    const stderr = pickToolString(bag, 'stderr');
    const exitCode = bag.exitCode ?? r.exitCode;
    if (stdout) return stdout.slice(0, 2000);
    if (stderr) return stderr.slice(0, 500);
    if (exitCode === 0 || exitCode === '0') return '';
    if (exitCode != null && exitCode !== '') return `exit ${exitCode}`;
    return '';
  }

  if (tool === 'readlints') {
    const count = bag.totalDiagnostics ?? r.totalDiagnostics;
    if (count === 0 || count === '0') return '';
    return `${count} issue(s)`;
  }

  if (tool === 'read') {
    const content = bag.content ?? bag.text;
    if (typeof content === 'string' && content.trim()) return content.slice(0, 2000);
  }

  if (
    tool === 'createplan' ||
    tool === 'create_plan' ||
    tool === 'setplan' ||
    tool === 'set_plan' ||
    tool === 'updateplan' ||
    tool === 'writeplan' ||
    tool === 'plan'
  ) {
    const text = pickToolString(bag, 'plan', 'output', 'text', 'content', 'message', 'result');
    if (text) return text.slice(0, 2000);
  }

  if (tool === 'write' || tool === 'edit' || tool === 'delete') {
    return '';
  }

  const text = pickToolString(bag, 'output', 'text', 'content', 'message');
  if (text) return text.slice(0, 2000);

  const keys = Object.keys(r);
  if (
    keys.length <= 3 &&
    keys.some((k) => k === 'success' || k === 'exitCode' || k === 'command')
  ) {
    return '';
  }
  if (r.totalDiagnostics === 0 || bag.totalDiagnostics === 0) return '';

  return '';
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

/** Cursor sometimes embeds newlines in call_id; that breaks start/end pairing. */
export function normalizeToolRefId(id: string): string {
  return (id || '').replace(/\s+/g, '');
}

export function parseCursorStreamEvent(msg: Record<string, unknown>): AgentDelta[] {
  const type = String(msg.type ?? msg.event ?? '');
  const subtype = String(msg.subtype ?? '');
  if (type === 'assistant') {
    const message = msg.message as Record<string, unknown> | undefined;
    const text = contentToText(message?.content);
    if (text.trim()) return [{ kind: 'text', text }];
    return [];
  }
  if (type === 'tool_call') {
    const meta = describeCursorToolCall(msg.tool_call ?? msg);
    const refId = normalizeToolRefId(String(msg.call_id ?? msg.id ?? ''));
    if (subtype === 'started' || subtype === 'start') {
      let toolInput = formatCursorToolInput(meta.name, meta.args).slice(0, 500);
      if (meta.args && typeof meta.args === 'object' && Object.keys(meta.args as Record<string, unknown>).length > 0) {
        const isPlanOrFile = /plan|write|edit|file/i.test(meta.name);
        if (isPlanOrFile) {
          toolInput = JSON.stringify(meta.args, null, 2).slice(0, 4000);
        }
      }
      return [{
        kind: 'tool-start',
        toolName: meta.name,
        toolInput,
        refId,
      }];
    }
    if (subtype === 'completed' || subtype === 'end' || subtype === 'finished') {
      return [{
        kind: 'tool-end',
        toolName: meta.name,
        refId,
        toolOutput: formatCursorToolOutput(meta.name, meta.result).slice(0, 2000),
      }];
    }
    return [];
  }
  if (type === 'result' || type === 'done' || type === 'complete'
    || (type === 'system' && (subtype === 'completed' || subtype === 'turn_complete'))) {
    const raw = msg.result ?? msg.message ?? msg.text;
    const text = typeof raw === 'string' ? raw : contentToText(raw);
    if (msg.is_error === true || subtype === 'error') {
      return [{ kind: 'error', text: text || 'Cursor CLI reported an error' }];
    }
    if (type === 'system') return [{ kind: 'result', text: '' }];
    return [{ kind: 'result', text }];
  }
  if (type === 'system' && subtype === 'init') {
    return [];
  }
  return [];
}

/** End a CLI turn shortly after the last event when no tool is in flight.
 *  Cursor often streams the final answer before the `result` line, so the
 *  phone would otherwise keep showing Working… until the process exits. */
class TurnIdle {
  private timer: ReturnType<typeof setTimeout> | null = null;
  inflight = 0;
  constructor(private readonly onIdle: () => void, private readonly ms = 1600) {}

  note(ev: AgentDelta): void {
    if (ev.kind === 'tool-start') this.inflight += 1;
    if (ev.kind === 'tool-end') this.inflight = Math.max(0, this.inflight - 1);
    if (ev.kind === 'result' || ev.kind === 'error') {
      this.clear();
      this.inflight = 0;
      return;
    }
    this.arm();
  }

  arm(): void {
    this.clear();
    this.timer = setTimeout(() => {
      this.timer = null;
      if (this.inflight > 0) return;
      this.onIdle();
    }, this.ms);
  }

  clear(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }
}

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
    return [{ kind: 'error', text: sanitizeCliError(text, 'OpenCode') }];
  }
  return [];
}

export function parseAgyStreamEvent(msg: Record<string, unknown>): AgentDelta[] {
  const event = String(msg.event ?? msg.type ?? '');
  if (event === 'init') return [];

  // 1. Direct model / planner responses (e.g. from stream-json or transcript replay)
  if (event === 'PLANNER_RESPONSE' || event === 'MODEL_RESPONSE') {
    const out: AgentDelta[] = [];
    if (typeof msg.thinking === 'string' && msg.thinking.trim()) {
      out.push({ kind: 'thinking', text: msg.thinking.trim() });
    }
    if (typeof msg.content === 'string' && msg.content.trim()) {
      out.push({ kind: 'text', text: msg.content.trim() });
    }
    if (Array.isArray(msg.tool_calls)) {
      for (const tc of msg.tool_calls) {
        if (!tc || typeof tc !== 'object') continue;
        const name = String(tc.name ?? 'tool');
        const input = typeof tc.args === 'string'
          ? tc.args
          : JSON.stringify(tc.args ?? {}, null, 2);
        out.push({
          kind: 'tool-start',
          toolName: name,
          toolInput: input.slice(0, 4000),
          refId: String(tc.id ?? tc.name ?? name),
        });
      }
    }
    if (out.length) return out;
  }

  // 2. Control / Permission Requests from agy
  if (
    event === 'control_request' ||
    event === 'permission_request' ||
    event === 'can_use_tool' ||
    msg.subtype === 'can_use_tool'
  ) {
    const tool = (msg.request as Record<string, unknown> | undefined) ?? msg;
    const name = String(tool.tool_name ?? tool.name ?? 'tool');
    const refId = String(msg.request_id ?? msg.id ?? crypto.randomUUID());
    const input = JSON.stringify(tool.input ?? tool.tool_input ?? tool.parameters ?? {}, null, 2).slice(0, 4000);
    const reason = typeof msg.reason === 'string'
      ? msg.reason
      : typeof tool.reason === 'string'
        ? tool.reason
        : `Allow ${name}?`;
    return [{
      kind: 'permission-request',
      toolName: name,
      toolInput: input,
      refId,
      text: reason,
    }];
  }

  // 3. Thinking / Thought events
  if (event === 'thinking' || event === 'thought') {
    const text = String(msg.text ?? msg.content ?? msg.thinking ?? msg.thought ?? '').trim();
    if (text) return [{ kind: 'thinking', text }];
  }

  // 4. Step Updates
  if (event === 'step_update') {
    const step = (msg.step_update as Record<string, unknown> | undefined) ?? {};
    const stepType = String(step.step_type ?? '');
    const state = String(step.state ?? '');

    // Planner response (may contain both thinking and text)
    if (stepType === 'planner_response') {
      const out: AgentDelta[] = [];
      if (typeof step.thinking === 'string' && step.thinking.trim()) {
        out.push({ kind: 'thinking', text: step.thinking.trim() });
      }
      const content = step.content ?? step.text ?? step.response ?? step.text_delta;
      if (typeof content === 'string' && content.trim()) {
        out.push({ kind: typeof step.text_delta === 'string' ? 'text-delta' : 'text', text: content.trim() });
      }
      if (out.length) return out;
    }

    // Thinking / reasoning step
    if (
      stepType === 'thought' ||
      stepType === 'thinking' ||
      stepType === 'reasoning' ||
      typeof step.thinking === 'string' ||
      typeof step.thought === 'string'
    ) {
      const text = String(step.thinking ?? step.thought ?? step.text ?? step.content ?? '').trim();
      if (text) return [{ kind: 'thinking', text }];
    }

    // Agent response text
    if (stepType === 'agent_response' || stepType === 'response' || stepType === 'model_response') {
      if (typeof step.text_delta === 'string' && step.text_delta) {
        return [{ kind: 'text-delta', text: step.text_delta }];
      }
      const fullText = typeof step.text === 'string'
        ? step.text
        : typeof step.content === 'string'
          ? step.content
          : typeof step.response === 'string'
            ? step.response
            : '';
      if (fullText) return [{ kind: 'text', text: fullText }];
      return [];
    }

    // Permission request within step
    if (stepType === 'waiting_for_input' || stepType === 'permission_request' || state === 'WAITING_FOR_INPUT' || state === 'WAITING_INPUT') {
      const info = (step.tool_info as Record<string, unknown> | undefined) ?? {};
      const name = String(step.tool_name ?? info.name ?? 'tool');
      const refId = String(step.step_index ?? info.name ?? name);
      const input = JSON.stringify(info.parameters ?? {}, null, 2).slice(0, 4000);
      const reason = typeof step.reason === 'string' ? step.reason : `Allow ${name}?`;
      return [{
        kind: 'permission-request',
        toolName: name,
        toolInput: input,
        refId,
        text: reason,
      }];
    }

    // Tool execution
    if (stepType === 'tool') {
      const info = (step.tool_info as Record<string, unknown> | undefined) ?? {};
      const name = String(step.tool_name ?? info.name ?? 'tool');
      const refId = String(step.step_index ?? info.name ?? name);
      const input = JSON.stringify(info.parameters ?? {}, null, 2).slice(0, 4000);
      const errStr = typeof info.error === 'string'
        ? info.error
        : typeof step.error === 'string'
          ? step.error
          : '';
      const output = typeof info.output === 'string'
        ? info.output.slice(0, 4000)
        : info.output !== undefined
          ? JSON.stringify(info.output, null, 2).slice(0, 4000)
          : errStr
            ? errStr.slice(0, 4000)
            : '';
      if (state === 'ACTIVE' || state === 'START' || state === 'RUNNING') {
        return [{ kind: 'tool-start', toolName: name, toolInput: input, refId }];
      }
      return [{ kind: 'tool-end', toolName: name, toolOutput: output, refId }];
    }

    if (state === 'ERROR' || stepType === 'generic' || stepType === 'error') {
      const err = String(step.error ?? step.content ?? '');
      if (err) return [{ kind: 'status', text: `Tool error: ${err.slice(0, 300)}` }];
    }
    return [];
  }

  // 5. Turn Result
  if (event === 'result') {
    const result = (msg.result as Record<string, unknown> | undefined) ?? msg;
    const status = String(result.status ?? '');
    const response = typeof result.response === 'string' ? result.response : '';
    const error = typeof result.error === 'string' ? result.error : '';
    if (status === 'ERROR' || (error && status !== 'SUCCESS')) {
      const cleaned = sanitizeCliError(error || 'Antigravity reported an error', 'Antigravity');
      return [{ kind: 'error', text: cleaned }];
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
  onStderr?: (chunk: string) => void,
  opts?: { stdin?: 'pipe' | 'ignore' },
): { proc: Proc; stderr: Promise<string>; drained: Promise<void> } {
  const proc = Bun.spawn(spawnArgv(argv), {
    cwd,
    stdin: opts?.stdin ?? 'ignore',
    stdout: 'pipe',
    stderr: 'pipe',
    env: hostEnv(extraEnv),
  } as unknown as SpawnOpts);
  const drained = pumpJsonLines(proc, onEvent);
  void drained.catch(() => {});
  const stderr = onStderr
    ? pumpTextStream(proc.stderr, onStderr)
    : collectText(proc.stderr);
  return { proc, stderr, drained };
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
    const argv =
      process.platform === 'win32'
        ? ['cmd.exe', '/c', 'start', '', url]
        : process.platform === 'darwin'
          ? ['open', url]
          : [resolveBin('xdg-open') ?? 'xdg-open', url];
    Bun.spawn(argv, {
      stdin: 'ignore',
      stdout: 'ignore',
      stderr: 'ignore',
      env: hostEnv(),
    } as unknown as SpawnOpts);
  } catch {
    // Phone still gets the URL in chat.
  }
}

export function isSafeAgentToolCall(
  toolName: string,
  rawInput: unknown,
  cwd?: string,
): { safe: boolean; reason?: string } {
  const normName = (toolName || '').toLowerCase().trim();
  let inputObj: Record<string, unknown> = {};
  if (rawInput && typeof rawInput === 'object') {
    inputObj = rawInput as Record<string, unknown>;
  } else if (typeof rawInput === 'string' && rawInput.trim()) {
    try {
      inputObj = JSON.parse(rawInput) as Record<string, unknown>;
    } catch {
      inputObj = { CommandLine: rawInput.trim() };
    }
  }

  // 1. Path Safety: Check if any file/directory parameters target outside assigned cwd
  const pathKeys = [
    'path', 'target_file', 'file_path', 'filePath', 'TargetFile', 'AbsolutePath',
    'SearchDirectory', 'directory', 'dir', 'Destination', 'destination', 'cwd',
  ];
  const pathsToCheck: string[] = [];
  for (const k of pathKeys) {
    const val = inputObj[k];
    if (typeof val === 'string' && val.trim()) {
      pathsToCheck.push(val.trim());
    }
  }
  if (Array.isArray(inputObj.paths)) {
    for (const p of inputObj.paths) {
      if (typeof p === 'string' && p.trim()) pathsToCheck.push(p.trim());
    }
  }
  if (Array.isArray(inputObj.files)) {
    for (const p of inputObj.files) {
      if (typeof p === 'string' && p.trim()) pathsToCheck.push(p.trim());
    }
  }

  if (cwd && cwd.trim()) {
    const resolvedCwd = resolve(cwd.trim());
    for (const p of pathsToCheck) {
      if (p.startsWith('http://') || p.startsWith('https://')) continue;
      const target = isAbsolute(p) ? resolve(p) : resolve(resolvedCwd, p);
      if (target !== resolvedCwd && !target.startsWith(resolvedCwd + sep)) {
        return {
          safe: false,
          reason: `Target path '${p}' is outside the assigned directory (${cwd})`,
        };
      }
    }
  }

  // 2. Command / Shell Execution Safety
  const isCommandTool = [
    'task', 'run_command', 'runcommand', 'bash', 'shell', 'exec', 'execute_command',
    'terminal', 'cmd', 'command',
  ].includes(normName);

  if (isCommandTool) {
    const cmd = String(
      inputObj.CommandLine ?? inputObj.commandLine ?? inputObj.command ?? inputObj.cmd ?? inputObj.script ?? '',
    ).trim();

    if (!cmd) return { safe: true };

    // 2a. Git actions require permission if mutating repository state
    if (/\bgit\b/i.test(cmd)) {
      const parts = cmd.split(/&&|;|\|\|/).map((p) => p.trim());
      const hasMutating = parts.some((p) => {
        if (!/\bgit\b/i.test(p)) return false;
        if (/(^|\s)(-D|--delete|-d|--force|-f|--hard|--amend)(\s|$)/i.test(p)) return true;
        const m = p.match(/^\s*git\s+([a-zA-Z_-]+)/i);
        if (!m) return true;
        const sub = m[1].toLowerCase();
        const mutatingSubs = [
          'commit', 'push', 'reset', 'checkout', 'switch', 'restore',
          'merge', 'rebase', 'cherry-pick', 'revert', 'clean', 'rm',
          'mv', 'stash', 'pull', 'fetch'
        ];
        return mutatingSubs.includes(sub);
      });

      if (hasMutating) {
        return {
          safe: false,
          reason: `Git action requested: \`${cmd}\``,
        };
      }
    }

    // 2b. Database operations and migrations require permission
    const dbPatterns = [
      /\b(psql|pg_dump|pg_restore|mysql|mysqldump|mariadb|mongosh|mongo|mongodump|sqlite3|redis-cli|influx)\b/i,
      /\b(prisma\s+(migrate|db\s+push)|drizzle-kit|supabase\s+db|knex\s+migrate|typeorm\s+migration|alembic\s+upgrade|flyway\s+migrate|sequelize\s+db:migrate)\b/i,
      /\b(DROP\s+DATABASE|DROP\s+TABLE|TRUNCATE|DELETE\s+FROM|ALTER\s+TABLE)\b/i,
      /\b(db\.[a-zA-Z0-9_]+\.(drop|deleteMany|dropDatabase))\b/i,
      /\b(flushall|flushdb)\b/i,
    ];
    for (const pat of dbPatterns) {
      if (pat.test(cmd)) {
        return {
          safe: false,
          reason: `Database operation requested: \`${cmd}\``,
        };
      }
    }

    // 2c. Destructive or dangerous system commands require permission
    const dangerousPatterns = [
      /\b(rm\s+-[a-zA-Z]*r|rm\s+-[a-zA-Z]*f|rmdir|unlink|shred|wipe)(\s|$)/i,
      /\b(sudo|su|chmod|chown|chgrp)(\s|$)/i,
      /\b(mkfs|dd|fdisk|parted)(\s|$)/i,
      /\b(kill|killall|pkill)(\s|$)/i,
      /\b(reboot|shutdown|poweroff|systemctl\s+(stop|disable|restart))(\s|$)/i,
      /(\bcurl\b|\bwget\b)[^|]*\|\s*(bash|sh|zsh)/i,
    ];
    for (const pat of dangerousPatterns) {
      if (pat.test(cmd)) {
        return {
          safe: false,
          reason: `Potentially dangerous system command: \`${cmd}\``,
        };
      }
    }

    // 2d. Check if command attempts to navigate outside cwd
    if (/\bcd\s+(\.\.|\/|~)/.test(cmd)) {
      return {
        safe: false,
        reason: `Command attempts to navigate outside assigned directory: \`${cmd}\``,
      };
    }

    return { safe: true };
  }

  // 3. Known Safe Read & Edit Tools (validated within cwd)
  const safeToolNames = [
    'view', 'view_file', 'read', 'cat',
    'glob', 'find_by_name', 'grep', 'grep_search', 'list_dir',
    'read_url_content', 'search_web', 'search',
    'edit', 'replace', 'replace_file_content', 'write', 'write_to_file', 'create_file', 'edit_file',
    'ask_question', 'askquestion', 'ask_user', 'askuser', 'question',
  ];

  if (
    safeToolNames.includes(normName) ||
    normName.includes('file') ||
    normName.includes('read') ||
    normName.includes('view')
  ) {
    return { safe: true };
  }

  return {
    safe: false,
    reason: `Tool '${toolName}' requested execution`,
  };
}

// ---------------------------------------------------------------------------
// Claude Code adapter — persistent `claude --print` with stream-json in/out.
// ---------------------------------------------------------------------------

class ClaudeAdapter implements AgentAdapter {
  private proc: Proc | null = null;
  private spawnKey = '';
  private sawResult = false;
  private streamedText = false;
  private resumeId: string | null = null;
  private hasPrompted = false;

  constructor(private session: AgentSession) {}

  bindHostChat(id: string): void { this.resumeId = id; this.hasPrompted = true; }

  private ensureProc(opts?: AdapterPromptOpts): Proc {
    const key = `${opts?.model ?? ''}|${opts?.mode ?? 'agent'}|${opts?.thinking ?? ''}`;
    if (this.proc && this.proc.exitCode === null && !this.proc.killed && this.spawnKey === key) {
      return this.proc;
    }
    this.cancel();
    this.spawnKey = key;
    const bin = resolveBin('claude') ?? 'claude';
    this.proc = Bun.spawn(
      spawnArgv(claudeSpawnArgs({
        bin,
        model: opts?.model,
        mode: opts?.mode,
        thinking: opts?.thinking,
        resumeId: this.resumeId,
      })),
      {
        cwd: this.session.info.cwd,
        stdin: 'pipe',
        stdout: 'pipe',
        stderr: 'pipe',
        env: process.env as Record<string, string>,
      } as unknown as SpawnOpts,
    );
    const stderrP = collectText(this.proc.stderr);
    const spawned = this.proc;
    void pumpJsonLines(spawned, (msg) => {
      if (this.proc !== spawned) return;
      this.onEvent(msg);
    }).catch(() => {});
    spawned.exited.then(async (code) => {
      if (this.proc !== spawned) return;
      const stderr = await stderrP.catch(() => '');
      if (!this.session.info.busy) return;
      setBusy(this.session, false);
      const isSuccess = code === 0 && (this.streamedText || this.sawResult);
      const fail = finishCliTurn({
        sawResult: isSuccess,
        exitCode: code,
        stderr: isSuccess ? '' : stderr,
      });
      if (!fail) {
        if (!this.sawResult) {
          emit(this.session, { kind: 'result', text: '' });
        }
        return;
      }
      const cleaned = sanitizeCliError(fail.text ?? '', 'Claude Code');
      emit(this.session, withoutDuplicateResult({ kind: 'error', text: cleaned }, this.streamedText));
    }).catch(() => {});
    return this.proc;
  }

  private onEvent(msg: Record<string, unknown>): void {
    const s = this.session;
    const sid = sessionIdFromEvent(msg);
    if (sid) {
      this.resumeId = sid;
      if (this.session.info.hostChatId !== sid) {
        this.session.info.hostChatId = sid;
        saveAgentSessionsToDisk();
        broadcast({ type: 'agent-session-update', session: { ...this.session.info } });
      }
    }
    const type = String(msg.type ?? '');
    if (type === 'assistant') {
      const message = msg.message as Record<string, unknown> | undefined;
      const content = message?.content;
      if (Array.isArray(content)) {
        for (const raw of content) {
          const part = raw as Record<string, unknown>;
          if (part.type === 'text' && typeof part.text === 'string' && part.text.trim()) {
            this.streamedText = true;
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
      this.sawResult = true;
      setBusy(s, false);
      const failed = msg.is_error === true || (typeof msg.subtype === 'string' && msg.subtype.startsWith('error'));
      emit(s, withoutDuplicateResult({
        kind: failed ? 'error' : 'result',
        text: typeof msg.result === 'string' ? msg.result : failed ? JSON.stringify(msg.errors ?? 'Provider turn failed') : '',
      }, this.streamedText));
    } else if (type === 'system' && msg.subtype === 'init') {
      emit(s, { kind: 'status', text: 'ready' });
    } else if (type === 'control_request' || msg.subtype === 'can_use_tool') {
      const requestId = String(msg.request_id ?? msg.id ?? crypto.randomUUID());
      const tool = (msg.request as Record<string, unknown> | undefined) ?? msg;
      
      const toolName = String(tool.tool_name ?? tool.name ?? 'tool');
      const toolInput = (tool.input ?? tool.tool_input ?? {}) as Record<string, unknown>;
      const toolInputStr = JSON.stringify(toolInput, null, 2);

      const respond = (allow: boolean) => {
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
      };

      // Check selective safety against the session workspace folder
      const safety = isSafeAgentToolCall(toolName, toolInput, s.info.cwd);

      // Auto mode answers immediately, so a turn can never block on a phone that
      // is closed, backgrounded, or watching a different session. Actions that
      // would have required a tap are still announced, so the log stays honest.
      if (getAgentApprovalMode(s.info.agent) === 'auto') {
        respond(true);
        if (!safety.safe) {
          emit(s, { kind: 'status', text: `Auto-approved: ${safety.reason || toolName}` });
        }
        return;
      }

      if (safety.safe) {
        respond(true);
        return;
      }

      emit(s, {
        kind: 'permission-request',
        refId: requestId,
        toolName,
        toolInput: toolInputStr,
        text: safety.reason || `Allow ${toolName}?`,
      });
      s.pendingPermissions.set(requestId, respond);
      trackPermissionTimeout(s, requestId);
    }
  }

  prompt(text: string, opts?: AdapterPromptOpts): void {
    this.sawResult = false;
    this.streamedText = false;
    const nextKey = `${opts?.model ?? ''}|${opts?.mode ?? 'agent'}|${opts?.thinking ?? ''}`;
    if (this.hasPrompted && !this.resumeId && (!this.proc || this.proc.exitCode !== null || this.proc.killed || this.spawnKey !== nextKey)) {
      setBusy(this.session, false);
      emit(this.session, { kind: 'error', text: 'Cannot continue Claude conversation: provider session ID was not recovered.' });
      return;
    }
    const proc = this.ensureProc(opts);
    this.hasPrompted = true;
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
  private streamGen = 0;
  private chatId: string | null = null;
  private sawResult = false;
  private pendingResult: AgentDelta | undefined;
  private streamedText = false;
  private lastText = '';
  private apiKey = process.env.CURSOR_API_KEY || '';
  private loggingIn = false;
  private autoLoginAttempted = false;
  private loginTimer: ReturnType<typeof setTimeout> | null = null;
  private idle = new TurnIdle(() => this.finishIdle());

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
    this.pendingResult = undefined;
    this.streamedText = false;
    this.lastText = '';
    this.idle.clear();
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
    const gen = this.streamGen;
    const { proc, stderr, drained } = spawnJsonCli(
      argv,
      this.session.info.cwd,
      (msg) => {
        if (this.streamGen !== gen) return;
        this.onEvent(msg);
      },
      this.extraEnv(),
    );
    this.proc = proc;
    proc.exited.then(async (code) => {
      if (this.streamGen !== gen) return;
      await drained.catch(() => {});
      if (this.streamGen !== gen) return;
      const errText = await stderr.catch(() => '');
      if (!this.session.info.busy) return;
      setBusy(this.session, false);
      const isSuccess = code === 0;
      const fail = finishCliTurn({
        sawResult: isSuccess,
        exitCode: code,
        stderr: isSuccess ? '' : errText,
      });
      if (!fail) {
        emit(this.session, this.pendingResult ?? { kind: 'result', text: '' });
        return;
      }
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
    const proc = Bun.spawn(spawnArgv([bin, 'login']), {
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

    const gen = this.streamGen;
    let combined = '';
    let urlEmitted = false;
    const onChunk = (chunk: string) => {
      if (this.streamGen !== gen) return;
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
      if (this.streamGen !== gen) return;
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
      if (this.streamGen !== gen) return;
      this.loggingIn = false;
      setBusy(this.session, false);
    });
  }

  private onEvent(msg: Record<string, unknown>): void {
    const sid = sessionIdFromEvent(msg);
    if (sid) {
      this.chatId = sid;
      if (!this.session.info.hostChatId) {
        this.session.info.hostChatId = sid;
        saveAgentSessionsToDisk();
        broadcast({ type: 'agent-session-update', session: { ...this.session.info } });
      }
    }
    const events = parseCursorStreamEvent(msg);
    for (const ev of events) {
      if (ev.kind === 'text' || ev.kind === 'text-delta') {
        if ((ev.text ?? '') === this.lastText) continue;
        this.lastText = ev.text ?? '';
        this.streamedText = true;
      }
      if (
        !this.session.info.busy
        && (ev.kind === 'tool-start' || ev.kind === 'text' || ev.kind === 'text-delta')
      ) {
        this.sawResult = false;
    this.pendingResult = undefined;
        setBusy(this.session, true);
      }
      if (ev.kind === 'result') {
        this.pendingResult = withoutDuplicateResult(ev, this.streamedText);
        this.sawResult = true;
        continue;
      }
      if (ev.kind === 'error') {
        this.sawResult = true;
        setBusy(this.session, false);
      }
      emit(this.session, withoutDuplicateResult(ev, this.streamedText));
      this.idle.note(ev);
    }
  }

  private finishIdle(): void {
    // Output silence is not evidence of completion; wait for the process exit.
  }

  cancel(): void {
    this.streamGen += 1;
    this.idle.clear();
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
  private streamGen = 0;
  private ocSession: string | null = null;
  private sawResult = false;
  private pendingResult: AgentDelta | undefined;
  private streamedText = false;

  constructor(private session: AgentSession) {}

  bindHostChat(id: string): void {
    this.ocSession = id;
  }

  prompt(text: string, opts?: AdapterPromptOpts): void {
    this.cancel();
    this.sawResult = false;
    this.pendingResult = undefined;
    this.streamedText = false;
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
    const gen = this.streamGen;
    const { proc, stderr, drained } = spawnJsonCli(
      argv,
      this.session.info.cwd,
      (msg) => {
        if (this.streamGen !== gen) return;
        this.onEvent(msg);
      },
    );
    this.proc = proc;
    proc.exited.then(async (code) => {
      if (this.streamGen !== gen) return;
      await drained.catch(() => {});
      if (this.streamGen !== gen) return;
      const errText = await stderr.catch(() => '');
      if (!this.session.info.busy) return;
      setBusy(this.session, false);
      const isSuccess = code === 0;
      const fail = finishCliTurn({
        sawResult: isSuccess,
        exitCode: code,
        stderr: isSuccess ? '' : errText,
      });
      if (!fail) {
        emit(this.session, this.pendingResult ?? { kind: 'result', text: '' });
        return;
      }
      emit(this.session, fail);
    }).catch(() => {});
  }

  private onEvent(msg: Record<string, unknown>): void {
    const sid = sessionIdFromEvent(msg);
    if (sid) {
      this.ocSession = sid;
      if (!this.session.info.hostChatId) {
        this.session.info.hostChatId = sid;
        saveAgentSessionsToDisk();
        broadcast({ type: 'agent-session-update', session: { ...this.session.info } });
      }
    }
    const events = parseOpencodeStreamEvent(msg);
    for (const ev of events) {
      if (ev.kind === 'text' || ev.kind === 'text-delta') {
        this.streamedText = true;
      }
      if (ev.kind === 'result') {
        this.pendingResult = withoutDuplicateResult(ev, this.streamedText);
        this.sawResult = true;
        continue;
      }
      if (ev.kind === 'error') {
        this.sawResult = true;
        setBusy(this.session, false);
      }
      emit(this.session, withoutDuplicateResult(ev, this.streamedText));
    }
  }

  cancel(): void {
    this.streamGen += 1;
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
  private streamGen = 0;
  private conversationId: string | null = null;
  private sawResult = false;
  private pendingResult: AgentDelta | undefined;
  private streamedText = false;
  private newProjectAttempted = false;
  private authUrlEmitted = false;
  private authHintEmitted = false;
  private loggingIn = false;
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
      this.startLogin();
      return;
    }
    this.cancel();
    this.sawResult = false;
    this.pendingResult = undefined;
    this.streamedText = false;
    this.authUrlEmitted = false;
    this.authHintEmitted = false;
    const bin = resolveBin('agy') ?? resolveBin('antigravity') ?? 'agy';
    const cwd = this.session.info.cwd;
    const projectId = cwd ? agyProjectIdForCwd(cwd) : undefined;
    const newProject = !this.conversationId && !projectId && !this.newProjectAttempted;
    if (newProject) this.newProjectAttempted = true;
    const argv = buildAgyArgv({
      bin,
      cwd,
      conversationId: this.conversationId,
      projectId,
      newProject,
      text,
      model: opts?.model,
      mode: opts?.mode,
      thinking: opts?.thinking,
      imagePaths: opts?.imagePaths,
      catalog: listAgentModels('antigravity'),
    });
    let stderrCombined = '';
    const gen = this.streamGen;
    const { proc, stderr, drained } = spawnJsonCli(
      argv,
      this.session.info.cwd,
      (msg) => {
        if (this.streamGen !== gen) return;
        this.onEvent(msg);
      },
      this.extraEnv(),
      (chunk) => {
        if (this.streamGen !== gen) return;
        stderrCombined += chunk;
        this.onAuthNoise(stderrCombined);
      },
      { stdin: 'pipe' },
    );
    this.proc = proc;
    proc.exited.then(async (code) => {
      if (this.streamGen !== gen) return;
      await drained.catch(() => {});
      if (this.streamGen !== gen) return;
      const errText = await stderr.catch(() => '');
      if (this.conversationId) {
        let changed = false;
        if (!this.session.info.hostChatId) {
          this.session.info.hostChatId = this.conversationId;
          changed = true;
        }
        if (isDefaultSessionTitle(this.session.info.title, this.session.info.agent)) {
          const agyTitle = getAgyChatTitle(this.conversationId);
          if (agyTitle) {
            this.session.info.title = agyTitle;
            changed = true;
          }
        }
        if (changed) {
          saveAgentSessionsToDisk();
          broadcast({ type: 'agent-session-update', session: { ...this.session.info } });
        }
      }
      if (!this.session.info.busy) return;
      setBusy(this.session, false);
      const isSuccess = (code === 0 && (this.sawResult || this.streamedText)) || (this.sawResult && code === 0);
      const fail = finishCliTurn({
        sawResult: isSuccess,
        exitCode: code,
        stderr: isSuccess ? '' : errText,
      });
      if (!fail) {
        emit(this.session, this.pendingResult ?? { kind: 'result', text: '' });
        return;
      }
      const cleaned = sanitizeCliError(fail.text ?? '', 'Antigravity');
      emit(this.session, { kind: 'error', text: cleaned });
    }).catch(() => {});
  }

  permission(requestId: string, allow: boolean): void {
    const cb = this.session.pendingPermissions.get(requestId);
    if (cb) {
      this.session.pendingPermissions.delete(requestId);
      cb(allow);
    }
  }

  private onEvent(msg: Record<string, unknown>): void {
    const sid = sessionIdFromEvent(msg);
    if (sid) {
      this.conversationId = sid;
      let changed = false;
      if (!this.session.info.hostChatId) {
        this.session.info.hostChatId = sid;
        changed = true;
      }
      if (isDefaultSessionTitle(this.session.info.title, this.session.info.agent)) {
        const agyTitle = getAgyChatTitle(sid);
        if (agyTitle) {
          this.session.info.title = agyTitle;
          changed = true;
        }
      }
      if (changed) {
        saveAgentSessionsToDisk();
        broadcast({ type: 'agent-session-update', session: { ...this.session.info } });
      }
    }
    const events = parseAgyStreamEvent(msg);
    for (const ev of events) {
      if (ev.kind === 'text' || ev.kind === 'text-delta') this.streamedText = true;
      if (ev.kind === 'result') {
        this.pendingResult = withoutDuplicateResult(ev, this.streamedText);
        this.sawResult = true;
        continue;
      }
      if (ev.kind === 'error') {
        this.sawResult = true;
        setBusy(this.session, false);
      }

      // Check tool safety & permissions
      if (ev.kind === 'permission-request') {
        const requestId = ev.refId || crypto.randomUUID();
        const respond = (allow: boolean) => {
          try {
            const stdin = this.proc?.stdin as unknown as { write(s: string): unknown; flush?: () => void } | undefined;
            stdin?.write(JSON.stringify({
              type: 'control_response',
              request_id: requestId,
              response: { allowed: allow },
            }) + '\n');
            stdin?.flush?.();
          } catch {
            emit(this.session, { kind: 'error', text: 'failed to send permission response to Antigravity' });
          }
        };

        const approvalMode = getAgentApprovalMode(this.session.info.agent);
        if (approvalMode === 'auto') {
          respond(true);
          emit(this.session, { kind: 'status', text: `Auto-approved: ${ev.toolName || 'action'}` });
          continue;
        }

        this.session.pendingPermissions.set(requestId, respond);
        trackPermissionTimeout(this.session, requestId);
        emit(this.session, ev);
        continue;
      }

      if (ev.kind === 'tool-start') {
        const safety = isSafeAgentToolCall(ev.toolName ?? 'tool', ev.toolInput, this.session.info.cwd);
        const approvalMode = getAgentApprovalMode(this.session.info.agent);
        if (approvalMode === 'auto') {
          if (!safety.safe) {
            emit(this.session, { kind: 'status', text: `Auto-approved: ${safety.reason || ev.toolName}` });
          }
        } else if (!safety.safe) {
          this.cancel();
          setBusy(this.session, false);
          emit(this.session, {
            kind: 'error',
            text: `Action blocked by safety policy: ${safety.reason || ev.toolName}. Turn cancelled to prevent unauthorized changes. Switch approval mode to auto in chat settings to allow this command.`,
          });
          return;
        }
      }

      const out = ev.kind === 'error'
        ? { kind: 'error' as const, text: sanitizeCliError(ev.text ?? '', 'Antigravity') }
        : ev;
      emit(this.session, withoutDuplicateResult(out, this.streamedText));
    }
  }

  private onAuthNoise(combined: string): void {
    const url = extractAuthUrl(combined);
    if (url && !this.authUrlEmitted) {
      this.authUrlEmitted = true;
      this.authHintEmitted = true;
      openUrlOnHost(url);
      setBusy(this.session, false);
      emit(this.session, {
        kind: 'text',
        text: [
          'Open this link to sign in to Antigravity (a browser may also open on the PC):',
          '',
          url,
          '',
          'Then send your task again. Or paste `GEMINI_API_KEY=…`.',
        ].join('\n'),
      });
      return;
    }
    if (this.authHintEmitted) return;
    if (!/not logged into|not authenticated|interactive oauth|starting oauth/i.test(combined)) {
      return;
    }
    this.authHintEmitted = true;
    emit(this.session, {
      kind: 'status',
      text: 'Antigravity needs a Google sign-in on the PC. A browser may open — finish it there.',
    });
  }

  private startLogin(): void {
    if (this.loggingIn && this.proc && this.proc.exitCode === null) {
      setBusy(this.session, false);
      emit(this.session, {
        kind: 'status',
        text: 'Sign-in is already waiting — finish it in the PC browser, or paste `GEMINI_API_KEY=…`.',
      });
      return;
    }
    this.cancel();
    this.loggingIn = true;
    this.authUrlEmitted = false;
    this.authHintEmitted = false;
    setBusy(this.session, true);
    const bin = resolveBin('agy') ?? 'agy';
    const proc = Bun.spawn(
      spawnArgv([bin, '--output-format', 'text', '--print-timeout', '3m', '-p', 'ping']),
      {
        cwd: this.session.info.cwd,
        stdin: 'ignore',
        stdout: 'pipe',
        stderr: 'pipe',
        env: hostEnv({
          NO_OPEN_BROWSER: '1',
          DISPLAY: process.env.DISPLAY || ':0',
          ...this.extraEnv(),
        }),
      } as unknown as SpawnOpts,
    );
    this.proc = proc;
    emit(this.session, {
      kind: 'status',
      text: 'Starting Antigravity sign-in on the PC…',
    });
    const gen = this.streamGen;
    let combined = '';
    const onChunk = (chunk: string) => {
      if (this.streamGen !== gen) return;
      combined += chunk;
      this.onAuthNoise(combined);
    };
    void Promise.all([
      pumpTextStream(proc.stdout, onChunk),
      pumpTextStream(proc.stderr, onChunk),
      proc.exited,
    ]).then(([, , code]) => {
      if (this.streamGen !== gen) return;
      this.loggingIn = false;
      setBusy(this.session, false);
      if (this.authUrlEmitted) return;
      if (code === 0) {
        emit(this.session, {
          kind: 'result',
          text: 'Signed in to Antigravity. Send your task again.',
        });
        return;
      }
      emit(this.session, {
        kind: 'error',
        text: rewriteCliAuthError(combined || 'authentication failed or timed out', 'Antigravity'),
      });
    }).catch(() => {
      if (this.streamGen !== gen) return;
      this.loggingIn = false;
      setBusy(this.session, false);
    });
  }

  cancel(): void {
    this.streamGen += 1;
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

export function buildCodexArgv(opts: {
  bin: string;
  cwd: string;
  threadId?: string | null;
  text: string;
  model?: string;
  mode?: AgentMode;
  thinking?: string;
  imagePaths?: string[];
}): string[] {
  if (opts.mode === 'plan') throw new Error('Codex Plan mode is unavailable. Select Agent mode.');
  const argv = [opts.bin, 'exec', '--json', '--cd', opts.cwd];
  if (opts.model && opts.model !== 'default') argv.push('--model', opts.model);
  const effort = thinkingToEffort(opts.thinking);
  if (effort && isModelEffortSupported('codex', opts.model)) argv.push('--config', `model_reasoning_effort=${JSON.stringify(effort)}`);
  if (opts.threadId) argv.push('resume', opts.threadId);
  for (const p of opts.imagePaths ?? []) argv.push('--image', p);
  argv.push(opts.text.trim() || 'Please proceed.');
  return argv;
}

export function parseCodexStreamEvent(msg: Record<string, unknown>): AgentDelta[] {
  const type = String(msg.type ?? msg.event ?? '');
  if (type === 'item.created' || type === 'item.updated' || type === 'item.completed') {
    const item = (msg.item ?? msg.data ?? {}) as Record<string, unknown>;
    const itemType = String(item.type ?? '');
    if (itemType === 'message' || itemType === 'agent_message') {
      const text = typeof item.text === 'string' ? item.text : typeof item.content === 'string' ? item.content : '';
      if (text) return [{ kind: 'text', text }];
      return [];
    }
    if (itemType === 'reasoning' || itemType === 'thinking') {
      const text = typeof item.text === 'string' ? item.text : '';
      if (text) return [{ kind: 'thinking', text }];
      return [];
    }
    if (itemType === 'command_execution' || itemType === 'function_call' || itemType === 'tool_call') {
      const name = String(item.command ?? item.name ?? item.tool ?? 'tool');
      const refId = String(item.id ?? item.call_id ?? '');
      const input = typeof item.arguments === 'string' ? item.arguments : JSON.stringify(item.input ?? item.arguments ?? {}, null, 2);
      return [{ kind: 'tool-start', toolName: name, toolInput: input, refId }];
    }
    if (itemType === 'command_output' || itemType === 'function_call_output' || itemType === 'tool_output') {
      const refId = String(item.call_id ?? item.id ?? '');
      const output = String(item.output ?? item.content ?? '').slice(0, 4000);
      return [{ kind: 'tool-end', toolName: 'tool', toolOutput: output, refId }];
    }
  }
  if (type === 'turn.completed' || type === 'response.completed') return [{ kind: 'result', text: '' }];
  if (type === 'error' || type === 'turn.failed') {
    return [{ kind: 'error', text: sanitizeCliError(String(msg.message ?? msg.error ?? 'Codex error'), 'Codex') }];
  }
  if (type === 'text' || type === 'content_block_delta') {
    const text = typeof msg.text === 'string' ? msg.text : typeof (msg.delta as any)?.text === 'string' ? (msg.delta as any).text : '';
    if (text) return [{ kind: 'text-delta', text }];
  }
  return [];
}

class CodexAppServerAdapter implements AgentAdapter {
  private server?: CodexAppServer;
  private initialization?: Promise<void>;
  private threadId?: string;
  private turnId?: string;
  private generation=0;
  private streamed = new Set<string>();
  constructor(private session: AgentSession) {}
  bindHostChat(id:string) {this.threadId=id;}
  private async ready() {
    if(!this.initialization) {
      const server=new CodexAppServer({
        notification:(method,params)=>this.notification(method,params),
        request:(id,method,params)=>this.request(id,method,params),
        closed:()=>{
          if(this.server!==server)return;
          this.initialization=undefined;this.server=undefined;
          if(this.session.info.busy){emit(this.session,{kind:'error',text:'Codex disconnected. Check the PC installation and sign-in before replying.'});setBusy(this.session,false);}
        },
      });
      this.server=server;
      this.initialization=server.initialize(resolveBin('codex') || 'codex').catch(error=>{server.close();if(this.server===server){this.server=undefined;this.initialization=undefined;}throw error;});
    }
    await this.initialization;
  }
  prompt(text:string,options:AdapterPromptOpts={}) {
    const generation=++this.generation;
    this.streamed.clear();
    void this.start(text,options,generation).catch(()=>{
      if(generation!==this.generation)return;
      emit(this.session,{kind:'error',text:'Codex could not start this reply. Update Codex and check its sign-in on the PC.'});setBusy(this.session,false);
    });
  }
  private async start(text:string,options:AdapterPromptOpts,generation:number) {
    await this.ready();
    if(generation!==this.generation)return;
    const result=await this.server!.request(this.threadId?'thread/resume':'thread/start',this.threadId?{threadId:this.threadId}:{cwd:this.session.info.cwd,...(options.model?{model:options.model}:{})});
    if(generation!==this.generation)return;
    if(!result.thread?.id)throw new Error('Codex returned no thread identity');
    this.threadId=result.thread.id;
    this.session.info.hostChatId=this.threadId;
    saveAgentSessionsToDisk();broadcast({type:'agent-session-update',session:{...this.session.info}});
    const input:any[]=[{type:'text',text}];
    for(const path of options.imagePaths || []) input.push({type:'localImage',path});
    const turn=await this.server!.request('turn/start',{threadId:this.threadId,input,...(options.model?{model:options.model}:{}),...(options.thinking?{effort:options.thinking==='extra-high'?'xhigh':options.thinking}:{})});
    if(generation!==this.generation){if(turn.turn?.id)await this.server?.request('turn/interrupt',{threadId:this.threadId,turnId:turn.turn.id});return;}
    if(this.session.info.busy)this.turnId=turn.turn?.id;
  }
  private notification(method:string,params:any) {
    if(params?.threadId && params.threadId!==this.threadId)return;
    if(!this.session.info.busy)return;
    if(method==='item/agentMessage/delta') {
      this.streamed.add(params.itemId);emit(this.session,{kind:'text-delta',text:params.delta,refId:params.itemId});
    } else if(method==='item/started' || method==='item/completed') {
      const item=params.item;
      if(item?.type==='agentMessage' && method==='item/completed' && !this.streamed.has(item.id))emit(this.session,{kind:'text',text:item.text,refId:item.id});
      else if(item?.type==='commandExecution' || item?.type==='fileChange')emit(this.session,{kind:method==='item/started'?'tool-start':'tool-end',toolName:item.type==='commandExecution'?'Command':'File changes',toolInput:item.command || JSON.stringify(item.changes),toolOutput:item.aggregatedOutput,refId:item.id});
    } else if(method==='turn/started') {this.turnId=params.turn?.id;}
    else if(method==='turn/completed') {
      const failed=params.turn?.status==='failed';
      emit(this.session,{kind:failed?'error':'result',text:failed?'Codex reply failed. Check the app on the PC.':''});setBusy(this.session,false);this.turnId=undefined;
    } else if(method==='error' && params.willRetry!==true) {
      emit(this.session,{kind:'error',text:'Codex reported an error. Check sign-in and configuration on the PC.'});setBusy(this.session,false);
    }
  }
  private request(id:string|number,method:string,params:any) {
    const ref=String(id);
    if(params?.threadId!==this.threadId || !this.session.info.busy) {this.server?.respond(id,{decision:'decline'});return;}
    if(!['item/commandExecution/requestApproval','item/fileChange/requestApproval'].includes(method)) {
      if(method==='item/permissions/requestApproval')this.server?.respond(id,{permissions:{},scope:'turn'});else this.server?.reject(id);
      emit(this.session,{kind:'status',text:'Codex requested an interaction this phone does not support. Open the chat on the PC.'});return;
    }
    if(getAgentApprovalMode('codex')==='auto'){this.server?.respond(id,{decision:'accept'});return;}
    this.session.pendingPermissions.set(ref,allow=>this.server?.respond(id,{decision:allow?'accept':'decline'}));
    emit(this.session,{kind:'permission-request',refId:ref,toolName:method==='item/commandExecution/requestApproval'?'Command':'File changes',toolInput:JSON.stringify(params),text:params.reason || 'Codex needs your approval.'});
  }
  permission(id:string,allow:boolean) {const callback=this.session.pendingPermissions.get(id);this.session.pendingPermissions.delete(id);callback?.(allow);}
  cancel() {
    ++this.generation;
    if(this.server && this.threadId && this.turnId)void this.server.request('turn/interrupt',{threadId:this.threadId,turnId:this.turnId}).catch(()=>{});
  }
  close() {this.cancel();this.server?.close();this.server=undefined;this.initialization=undefined;}
}

export function archiveAgentSession(id:string,archived:boolean) {
  const s=agentSessions.get(id);if(!s)throw new Error('Task not found');
  s.info.archived=archived;
  void persistAgent({info:s.info,events:[]}).then(()=>broadcast({type:'agent-session-update',session:{...s.info}}));
  return {...s.info};
}
