export type AgentModelOption = { id: string; name: string };

export type AgentCapabilities = {
  modes: string[];
  thinkingLevels: string[];
  models: AgentModelOption[];
  images: boolean;
};

export type GitWorkingTree = {
  cwd: string;
  branch: string;
  ahead: number;
  behind: number;
  changed: number;
  files: string[];
};

export type ComposerPrefs = {
  mode: string;
  thinking: string;
  model: string | null;
};

const CURSOR_MODELS: AgentModelOption[] = [
  { id: 'auto', name: 'Auto' },
  { id: 'composer-2.5', name: 'Composer 2.5' },
  { id: 'gpt-5.3-codex', name: 'GPT-5.3 Codex' },
  { id: 'cursor-grok-4.6-medium', name: 'Grok 4.6' },
  { id: 'claude-opus-5-medium', name: 'Claude Opus 5' },
  { id: 'claude-sonnet-5-thinking-medium', name: 'Claude Sonnet 5' },
];

const OPENCODE_MODELS: AgentModelOption[] = [
  { id: 'opencode/deepseek-v4-flash-free', name: 'DeepSeek V4 Flash' },
  { id: 'opencode/mimo-v2.5-free', name: 'MiMo 2.5' },
  { id: 'opencode/big-pickle', name: 'Big Pickle' },
];

const ANTIGRAVITY_MODELS: AgentModelOption[] = [
  { id: 'gemini-3.7-flash', name: 'Gemini 3.7 Flash' },
  { id: 'gemini-3.1-pro', name: 'Gemini 3.1 Pro' },
  { id: 'claude-sonnet-4-6', name: 'Claude Sonnet 4.6' },
  { id: 'claude-opus-4-6', name: 'Claude Opus 4.6' },
  { id: 'gpt-oss-120b', name: 'GPT-OSS 120B' },
];

const CLAUDE_MODELS: AgentModelOption[] = [
  { id: 'sonnet', name: 'Sonnet' },
  { id: 'opus', name: 'Opus' },
  { id: 'haiku', name: 'Haiku' },
];

export function fallbackCaps(agentId: string): AgentCapabilities {
  switch (agentId) {
    case 'cursor':
      return {
        modes: ['agent', 'plan', 'ask'],
        thinkingLevels: ['low', 'medium', 'high', 'extra-high', 'max'],
        models: CURSOR_MODELS,
        images: true,
      };
    case 'opencode':
      return {
        modes: ['agent', 'plan'],
        thinkingLevels: ['minimal', 'low', 'medium', 'high', 'max'],
        models: OPENCODE_MODELS,
        images: true,
      };
    case 'claude':
      return {
        modes: ['agent', 'plan'],
        thinkingLevels: ['low', 'medium', 'high'],
        models: CLAUDE_MODELS,
        images: true,
      };
    case 'antigravity':
      return {
        modes: ['agent', 'plan'],
        thinkingLevels: ['low', 'medium', 'high'],
        models: ANTIGRAVITY_MODELS,
        images: true,
      };
    default:
      return {
        modes: ['agent', 'plan', 'ask'],
        thinkingLevels: ['low', 'medium', 'high'],
        models: agentId === 'mock'
          ? [{ id: 'demo', name: 'Demo' }, { id: 'composer-2', name: 'Composer' }]
          : [],
        images: true,
      };
  }
}

export function resolveAgentCaps(
  agentId: string,
  host?: Partial<AgentCapabilities> | null,
  liveModels?: AgentModelOption[],
): AgentCapabilities {
  const fb = fallbackCaps(agentId);
  const models = liveModels && liveModels.length > 0
    ? liveModels
    : (host?.models && host.models.length > 1 ? host.models : fb.models);
  return {
    modes: host?.modes && host.modes.length > 1 ? host.modes : fb.modes,
    thinkingLevels: host?.thinkingLevels && host.thinkingLevels.length > 0
      ? host.thinkingLevels
      : fb.thinkingLevels,
    models,
    images: true,
  };
}

export function modeLabel(mode: string): string {
  if (mode === 'plan') return 'Plan';
  if (mode === 'ask') return 'Ask';
  return 'Agent';
}

export function thinkingLabel(level: string): string {
  switch (level) {
    case 'minimal': return 'Minimal';
    case 'low': return 'Low';
    case 'high': return 'High';
    case 'extra-high': return 'Extra high';
    case 'max': return 'Max';
    default: return 'Medium';
  }
}

export function modelFamilyId(id: string): string {
  return id
    .replace(/-thinking(?=-|$)/gi, '')
    .replace(/-(?:low|medium|high|xhigh|max|fast)(?:-fast)?$/i, '')
    .replace(/-fast$/i, '');
}

export function modelLabel(model: string | null, models: AgentModelOption[]): string {
  if (!model || model === 'auto' || model === 'default') return 'Model';
  const fam = modelFamilyId(model);
  const hit = models.find((m) => m.id === model || m.id === fam || modelFamilyId(m.id) === fam);
  if (hit) return hit.name;
  return fam.includes('/') ? (fam.split('/').pop() ?? fam) : fam;
}

export function workingTreeSubtitle(git: GitWorkingTree): string {
  const bits = [git.branch];
  if (git.ahead > 0) bits.push(`ahead ${git.ahead}`);
  if (git.behind > 0) bits.push(`behind ${git.behind}`);
  bits.push(git.changed > 0 ? `${git.changed} changed` : 'clean');
  return bits.join(' · ');
}

export function composerPrefKey(agentId: string): string {
  return `nexuslink-agent-composer-${agentId}`;
}

export function loadComposerPrefs(agentId: string): ComposerPrefs {
  try {
    const raw = localStorage.getItem(composerPrefKey(agentId));
    if (!raw) return { mode: 'agent', thinking: 'medium', model: null };
    const parsed = JSON.parse(raw) as Partial<ComposerPrefs>;
    return {
      mode: typeof parsed.mode === 'string' ? parsed.mode : 'agent',
      thinking: typeof parsed.thinking === 'string' ? parsed.thinking : 'medium',
      model: typeof parsed.model === 'string' ? parsed.model : null,
    };
  } catch {
    return { mode: 'agent', thinking: 'medium', model: null };
  }
}

export function saveComposerPrefs(agentId: string, prefs: ComposerPrefs): void {
  localStorage.setItem(composerPrefKey(agentId), JSON.stringify(prefs));
}

export function applyComposerPrefs(caps: AgentCapabilities, prefs: ComposerPrefs): ComposerPrefs {
  let mode = prefs.mode;
  if (!caps.modes.includes(mode)) mode = caps.modes[0] ?? 'agent';
  let thinking = prefs.thinking;
  if (caps.thinkingLevels.length && !caps.thinkingLevels.includes(thinking)) {
    thinking = caps.thinkingLevels.includes('medium')
      ? 'medium'
      : caps.thinkingLevels[Math.floor(caps.thinkingLevels.length / 2)] ?? 'medium';
  }
  let model = prefs.model ? modelFamilyId(prefs.model) : null;
  if (model && caps.models.length && !caps.models.some((m) => m.id === model || modelFamilyId(m.id) === model)) {
    model = caps.models[0]?.id ?? null;
  }
  model ??= caps.models[0]?.id ?? null;
  return { mode, thinking, model };
}
