const RECENT_AGENT_CWD_CAP_CONST = 8;
export const RECENT_AGENT_CWD_CAP = RECENT_AGENT_CWD_CAP_CONST;

/** Derive a short stable key from a host URL to namespace storage per PC. */
export function hostStorageKey(hostUrl: string): string {
  try {
    const { hostname, port } = new URL(hostUrl);
    const raw = port ? `${hostname}:${port}` : hostname;
    return raw.replace(/[^a-zA-Z0-9:._-]/g, '_');
  } catch {
    return 'default';
  }
}

function cwdKeys(hostKey: string) {
  const suffix = hostKey && hostKey !== 'default' ? `-${hostKey}` : '';
  return {
    list: `nexuslink-recent-agent-cwds${suffix}`,
    last: `nexuslink-last-agent-cwd${suffix}`,
  };
}

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

export function loadRecentAgentCwds(hostUrl = ''): string[] {
  try {
    const { list, last } = cwdKeys(hostStorageKey(hostUrl));
    return parseStoredRecentCwds(
      localStorage.getItem(list),
      localStorage.getItem(last),
    );
  } catch {
    return [];
  }
}

export function saveLastAgentCwd(path: string, hostUrl = ''): void {
  const next = mergeRecentAgentCwd(path, loadRecentAgentCwds(hostUrl));
  if (next.length === 0) return;
  try {
    const { list, last } = cwdKeys(hostStorageKey(hostUrl));
    localStorage.setItem(list, JSON.stringify(next));
    localStorage.setItem(last, next[0]!);
  } catch {
    /* ignore quota / private mode */
  }
}

export function folderDisplayName(path: string): string {
  if (!path || path === '/') return path === '/' ? 'This PC' : path;
  const trimmed = path.endsWith('/') && path !== '/' ? path.slice(0, -1) : path;
  if (/^[A-Za-z]:$/.test(trimmed)) return trimmed;
  const i = trimmed.lastIndexOf('/');
  return i < 0 ? trimmed : trimmed.slice(i + 1);
}

export function comparePathNames(a: string, b: string): number {
  return a.toLowerCase().localeCompare(b.toLowerCase());
}
