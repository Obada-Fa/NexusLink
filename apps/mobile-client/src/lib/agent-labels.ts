export function agentSourceLabel(agentId: string, source?: string): string {
  const given = (source ?? '').trim();
  if (given) return given;
  switch (agentId) {
    case 'claude':
      return 'Claude Code';
    case 'cursor':
      return 'Cursor';
    case 'opencode':
      return 'OpenCode';
    case 'antigravity':
      return 'Antigravity';
    case 'mock':
      return 'Demo Agent';
    default: {
      const raw = agentId.trim();
      if (!raw) return 'Agent';
      return raw
        .replace(/[_\s]+/g, '-')
        .split('-')
        .filter(Boolean)
        .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
        .join(' ');
    }
  }
}

export function chatListSubtitle(input: {
  agent?: string;
  source?: string;
  cwd?: string;
  resumable?: boolean;
}): string {
  return [
    agentSourceLabel(input.agent ?? '', input.source),
    (input.cwd ?? '').trim(),
    input.resumable === false ? 'view only' : '',
  ]
    .filter(Boolean)
    .join(' · ');
}
