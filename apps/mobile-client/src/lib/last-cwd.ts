const LAST_AGENT_CWD_KEY = 'nexuslink-last-agent-cwd';
const RECENT_AGENT_CWDS_KEY = 'nexuslink-recent-agent-cwds';

export const RECENT_AGENT_CWD_CAP = 8;

export function mergeRecentAgentCwd(path: string, existing: string[]): string[] {
  const trimmed = path.trim();
  if (!trimmed) return existing;
  return [trimmed, ...existing.filter((p) => p !== trimmed)].slice(0, RECENT_AGENT_CWD_CAP);
}

export function parseStoredRecentCwds(
  rawList: string | null,
  legacySingle: string | null,
): string[] {
  if (rawList) {
    try {
      const parsed = JSON.parse(rawList) as unknown;
      if (Array.isArray(parsed)) {
        const paths = parsed
          .filter((p): p is string => typeof p === 'string' && p.trim().length > 0)
          .map((p) => p.trim());
        return paths.slice(0, RECENT_AGENT_CWD_CAP);
      }
    } catch {
      /* fall through to legacy */
    }
  }
  const legacy = legacySingle?.trim();
  return legacy ? [legacy] : [];
}

export function loadRecentAgentCwds(): string[] {
  try {
    return parseStoredRecentCwds(
      localStorage.getItem(RECENT_AGENT_CWDS_KEY),
      localStorage.getItem(LAST_AGENT_CWD_KEY),
    );
  } catch {
    return [];
  }
}

export function saveLastAgentCwd(path: string): void {
  const next = mergeRecentAgentCwd(path, loadRecentAgentCwds());
  if (next.length === 0) return;
  try {
    localStorage.setItem(RECENT_AGENT_CWDS_KEY, JSON.stringify(next));
    localStorage.setItem(LAST_AGENT_CWD_KEY, next[0]!);
  } catch {
    /* ignore quota / private mode */
  }
}

export function folderDisplayName(path: string): string {
  if (!path) return path;
  const trimmed = path.endsWith('/') && path !== '/' ? path.slice(0, -1) : path;
  const i = trimmed.lastIndexOf('/');
  return i < 0 ? trimmed : trimmed.slice(i + 1);
}

export function comparePathNames(a: string, b: string): number {
  return a.toLowerCase().localeCompare(b.toLowerCase());
}
