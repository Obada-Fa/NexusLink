const LAST_AGENT_CWD_KEY = 'nexuslink-last-agent-cwd';

export function loadLastAgentCwd(): string | null {
  try {
    const path = localStorage.getItem(LAST_AGENT_CWD_KEY);
    if (!path?.trim()) return null;
    return path.trim();
  } catch {
    return null;
  }
}

export function saveLastAgentCwd(path: string): void {
  const trimmed = path.trim();
  if (!trimmed) return;
  try {
    localStorage.setItem(LAST_AGENT_CWD_KEY, trimmed);
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
