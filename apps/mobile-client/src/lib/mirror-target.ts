export interface MirrorTarget {
  windowId?: string;
  appId?: string;
  wmClass?: string;
  title?: string;
  virtualAppId?: string;
  sessionId?: string;
}

const PREFIX = 'nexuslink-mirror:';
const targets = new Map<string, MirrorTarget>();

/** Keep application identity in this tab, never in browser addresses/history. */
export function mirrorUrl(target: MirrorTarget): string {
  const id = Array.from(crypto.getRandomValues(new Uint8Array(16)), b => b.toString(16).padStart(2, '0')).join('');
  targets.set(id, target);
  try { sessionStorage.setItem(PREFIX + id, JSON.stringify(target)); } catch { /* In-memory navigation still works. */ }
  return `/mirror?view=${id}`;
}

export function readMirrorTarget(): MirrorTarget {
  const params = new URLSearchParams(window.location.search);
  const id = params.get('view');
  if (id) {
    const cached = targets.get(id);
    if (cached) return cached;
    try {
      const saved = sessionStorage.getItem(PREFIX + id);
      if (saved) return JSON.parse(saved) as MirrorTarget;
    } catch { /* Report an unavailable target instead of opening the desktop. */ }
    throw new Error('This view is no longer available in this tab. Go back and open the app again.');
  }
  // Migrate existing bookmarks without leaving names in the current address.
  const target: MirrorTarget = {
    windowId: params.get('w') ?? undefined,
    appId: params.get('app') ?? undefined,
    wmClass: params.get('cls') ?? undefined,
    title: params.get('title') ?? undefined,
    virtualAppId: params.get('vapp') ?? undefined,
    sessionId: params.get('s') ?? undefined,
  };
  if (params.size) window.history.replaceState(window.history.state, '', mirrorUrl(target));
  return target;
}
