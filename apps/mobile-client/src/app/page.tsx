'use client';

import { useState, useCallback, FormEvent, useEffect, useRef } from 'react';
import { useRouter } from 'next/navigation';
import { useConnectionStore } from '@/store/connection';
import ConnectionProvider, { STORAGE_KEY } from '@/components/ConnectionProvider';
import { deriveHostWsUrl, describeHost } from '@/lib/host-url';

interface WindowInfo {
  windowId: string;
  title: string;
  wmClass: string;
  icon?: string;
  appId?: string;
}

interface AppInfo {
  appId: string;
  name: string;
  icon?: string;
  wmClass?: string;
}

interface AppSessionInfo {
  sessionId: string;
  appId: string;
  name: string;
  icon?: string;
  width: number;
  height: number;
  status: 'starting' | 'running' | 'exited';
}

/** Shown while the auto-connect to the serving host is in flight. */
function ConnectingScreen() {
  return (
    <div style={styles.form}>
      <style dangerouslySetInnerHTML={{ __html: '@keyframes nl-spin{to{transform:rotate(360deg)}}' }} />
      <h1 style={styles.title}>NexusLink</h1>
      <div style={styles.spinner} />
      <p style={styles.subtitle}>Connecting to {describeHost()}…</p>
    </div>
  );
}

/** Manual fallback — only shown if auto-connect fails. URL is pre-filled. */
function ConnectForm() {
  const connect = useConnectionStore((s) => s.connect);
  const status = useConnectionStore((s) => s.status);
  const [url, setUrl] = useState('');
  const [error, setError] = useState('');
  const [advanced, setAdvanced] = useState(false);

  useEffect(() => {
    setUrl(deriveHostWsUrl());
  }, []);

  const doConnect = useCallback(
    async (target: string) => {
      setError('');
      try {
        await connect(target);
        localStorage.setItem(STORAGE_KEY, target);
      } catch {
        setError(`Could not reach ${describeHost()}. Is the host server running?`);
      }
    },
    [connect],
  );

  const handleSubmit = useCallback(
    (e: FormEvent) => {
      e.preventDefault();
      void doConnect(url);
    },
    [doConnect, url],
  );

  const isLoading = status === 'connecting';

  return (
    <form onSubmit={handleSubmit} style={styles.form}>
      <h1 style={styles.title}>NexusLink</h1>
      <p style={styles.subtitle}>Your PC, in your pocket</p>
      {error && <p style={styles.error}>{error}</p>}
      <button
        type="button"
        onClick={() => doConnect(deriveHostWsUrl())}
        disabled={isLoading}
        style={styles.button}
      >
        {isLoading ? 'Connecting…' : `Retry connecting to ${describeHost()}`}
      </button>
      <button type="button" onClick={() => setAdvanced((a) => !a)} style={styles.linkBtn}>
        {advanced ? 'Hide advanced' : 'Advanced: connect to another host'}
      </button>
      {advanced && (
        <>
          <input
            type="text"
            placeholder="ws://host:port/rpc"
            value={url}
            onChange={(e) => setUrl(e.target.value)}
            disabled={isLoading}
            style={styles.input}
          />
          <button type="submit" disabled={isLoading || !url} style={styles.button}>
            {isLoading ? 'Connecting…' : 'Connect'}
          </button>
        </>
      )}
    </form>
  );
}

const TOOL_ITEMS = [
  { id: 'terminal', label: 'Terminal', icon: '>_' },
  { id: 'ide', label: 'Code', icon: '</>' },
  { id: 'files', label: 'Files', icon: '\u{1F4C1}' },
  { id: 'system', label: 'System', icon: '\u{1F4CA}' },
  { id: 'mirror', label: 'Desktop', icon: '\u{1F5A5}' },
  { id: 'agents', label: 'Agents', icon: '\u2728' },
] as const;

function AppIcon({ icon, name, size = 52 }: { icon?: string; name: string; size?: number }) {
  if (icon) {
    // eslint-disable-next-line @next/next/no-img-element
    return <img src={icon} alt="" width={size} height={size} style={{ borderRadius: 12, objectFit: 'contain' }} draggable={false} />;
  }
  const letter = (name || '?').trim().charAt(0).toUpperCase();
  const hue = (name.charCodeAt(0) * 47) % 360;
  return (
    <span
      style={{
        width: size,
        height: size,
        borderRadius: 12,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        fontSize: size * 0.45,
        fontWeight: 700,
        color: '#fff',
        background: `linear-gradient(135deg, hsl(${hue},45%,38%), hsl(${(hue + 40) % 360},50%,26%))`,
      }}
    >
      {letter}
    </span>
  );
}

function HomeScreen() {
  const status = useConnectionStore((s) => s.status);
  const client = useConnectionStore((s) => s.client);
  const disconnect = useConnectionStore((s) => s.disconnect);
  const router = useRouter();

  const [windows, setWindows] = useState<WindowInfo[]>([]);
  const [apps, setApps] = useState<AppInfo[]>([]);
  const [phoneSessions, setPhoneSessions] = useState<AppSessionInfo[]>([]);
  const [appsLoading, setAppsLoading] = useState(true);
  const [search, setSearch] = useState('');
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const refreshWindows = useCallback(async () => {
    if (!client) return;
    try {
      const list = (await client.request('window.list')) as WindowInfo[];
      setWindows(list);
    } catch {
      /* host may not support window.list yet */
    }
    try {
      const sessions = (await client.request('appSession.list')) as AppSessionInfo[];
      setPhoneSessions(sessions.filter((s) => s.status === 'running'));
    } catch {
      /* host may not support virtual sessions yet */
    }
  }, [client]);

  useEffect(() => {
    if (status !== 'connected' || !client) return;
    void refreshWindows();
    client
      .request('apps.list', {}, 30000)
      .then((list) => setApps(list as AppInfo[]))
      .catch(() => {})
      .finally(() => setAppsLoading(false));

    const unsubApps = client.subscribe('apps-update', (msg: unknown) => {
      const data = msg as { apps?: AppInfo[] };
      if (Array.isArray(data?.apps)) {
        setApps(data.apps);
      }
    });

    const unsubWindows = client.subscribe('windows-update', (msg: unknown) => {
      const data = msg as { windows?: WindowInfo[] };
      if (Array.isArray(data?.windows)) {
        setWindows(data.windows);
      }
    });

    const unsubSessions = client.subscribe('app-session-update', () => {
      void refreshWindows();
    });

    // Fallback slow poll (15s) in case of missed push
    pollRef.current = setInterval(() => void refreshWindows(), 15000);
    return () => {
      unsubApps();
      unsubWindows();
      unsubSessions();
      if (pollRef.current) clearInterval(pollRef.current);
    };
  }, [status, client, refreshWindows]);

  if (status === 'connecting') return <ConnectingScreen />;
  if (status !== 'connected') return <ConnectForm />;

  const openApp = (w: WindowInfo) => {
    router.push(`/mirror?w=${encodeURIComponent(w.windowId)}&title=${encodeURIComponent(bestName(w, apps))}`);
  };

  const attachSession = (s: AppSessionInfo) => {
    router.push(`/mirror?s=${encodeURIComponent(s.sessionId)}&title=${encodeURIComponent(s.name)}`);
  };

  const closePhoneSession = (s: AppSessionInfo, e: React.MouseEvent) => {
    e.stopPropagation();
    setPhoneSessions((list) => list.filter((x) => x.sessionId !== s.sessionId));
    client?.request('appSession.close', { sessionId: s.sessionId }).catch(() => {});
  };

  const launchApp = (a: AppInfo) => {
    const session = phoneSessions.find((s) => s.appId === a.appId);
    if (session) {
      attachSession(session);
      return;
    }
    const openWin = windows.find((w) => matchesApp(w, a));
    if (openWin) {
      openApp(openWin);
      return;
    }
    if (a.appId.startsWith('nexus.')) {
      router.push(`/mirror?vapp=${encodeURIComponent(a.appId)}&title=${encodeURIComponent(a.name)}`);
    } else {
      const clsParam = a.wmClass ? `&cls=${encodeURIComponent(a.wmClass)}` : '';
      router.push(`/mirror?app=${encodeURIComponent(a.appId)}&title=${encodeURIComponent(a.name)}${clsParam}`);
    }
  };

  const q = search.trim().toLowerCase();
  const filteredApps = q ? apps.filter((a) => a.name.toLowerCase().includes(q)) : apps;

  return (
    <main style={styles.container}>
      <header style={styles.header}>
        <span style={styles.statusDot} />
        <span style={styles.statusText}>{describeHost()}</span>
        <button onClick={() => disconnect()} style={styles.headerBtn} aria-label="Disconnect">
          {'⏻'}
        </button>
      </header>

      {phoneSessions.length > 0 && !q && (
        <section style={styles.section}>
          <h2 style={styles.sectionTitle}>Running on your phone</h2>
          <div style={styles.runningRow}>
            {phoneSessions.map((s) => (
              <button key={s.sessionId} style={styles.runningCard} onClick={() => attachSession(s)}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8, width: '100%' }}>
                  <AppIcon icon={s.icon} name={s.name} size={44} />
                  <span
                    role="button"
                    aria-label={`Close ${s.name}`}
                    onClick={(e) => closePhoneSession(s, e)}
                    style={styles.sessionClose}
                  >
                    {'✕'}
                  </span>
                </div>
                <span style={styles.runningLabel}>{s.name}</span>
                <span style={styles.runningTitle}>Tap to resume</span>
              </button>
            ))}
          </div>
        </section>
      )}

      {windows.length > 0 && !q && (
        <section style={styles.section}>
          <h2 style={styles.sectionTitle}>Open on your PC</h2>
          <div style={styles.runningRow}>
            {windows.map((w) => (
              <button key={w.windowId} style={styles.runningCard} onClick={() => openApp(w)}>
                <AppIcon icon={w.icon} name={bestName(w, apps)} size={44} />
                <span style={styles.runningLabel}>{bestName(w, apps)}</span>
                <span style={styles.runningTitle}>{w.title}</span>
              </button>
            ))}
          </div>
        </section>
      )}

      <section style={{ ...styles.section, flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column' }}>
        <div style={styles.appsHeader}>
          <h2 style={styles.sectionTitle}>Apps</h2>
          <input
            type="search"
            placeholder="Search apps…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            style={styles.search}
          />
        </div>
        <div style={styles.appGridScroll}>
          {appsLoading ? (
            <p style={styles.loadingText}>Loading apps…</p>
          ) : (
            <div style={styles.appGrid}>
              {filteredApps.map((a) => {
                const running =
                  phoneSessions.some((s) => s.appId === a.appId) ||
                  windows.some((w) => matchesApp(w, a));
                return (
                  <button key={a.appId} style={styles.appCell} onClick={() => launchApp(a)}>
                    <div style={{ position: 'relative' }}>
                      <AppIcon icon={a.icon} name={a.name} />
                      {running && <span style={styles.runningDot} />}
                    </div>
                    <span style={styles.appLabel}>{a.name}</span>
                  </button>
                );
              })}
            </div>
          )}
        </div>
      </section>

      <nav style={styles.dock}>
        {TOOL_ITEMS.map((item) => (
          <button
            key={item.id}
            style={styles.dockBtn}
            onClick={() => router.push(item.id === 'mirror' ? '/mirror' : `/${item.id}`)}
          >
            <span style={styles.dockIcon}>{item.icon}</span>
            <span style={styles.dockLabel}>{item.label}</span>
          </button>
        ))}
      </nav>
    </main>
  );
}

function normClass(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9]/g, '');
}

function matchesApp(w: WindowInfo, a: AppInfo): boolean {
  if (w.appId && w.appId === a.appId) return true;
  const nWin = normClass(w.wmClass.split('.').pop() ?? '');
  const nApp = normClass(a.wmClass ?? a.appId);
  return nWin.length >= 4 && nApp.length >= 4 && (nApp.includes(nWin) || nWin.includes(nApp));
}

/** Prefer the app's launcher name over raw window titles for the running row. */
function bestName(w: WindowInfo, apps: AppInfo[]): string {
  if (w.appId) {
    const app = apps.find((a) => a.appId === w.appId);
    if (app) return app.name;
  }
  const cls = w.wmClass.split('.').pop() ?? '';
  return cls.replace(/[-_]/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase()) || w.title;
}

export default function Page() {
  return (
    <ConnectionProvider>
      <HomeScreen />
    </ConnectionProvider>
  );
}

const styles: Record<string, React.CSSProperties> = {
  container: {
    display: 'flex',
    flexDirection: 'column',
    height: '100dvh',
    background: '#0a0a0f',
    color: '#e0e0e0',
    fontFamily: 'system-ui, sans-serif',
    padding: '12px 14px 8px',
    boxSizing: 'border-box',
    overflow: 'hidden',
  },
  header: {
    display: 'flex',
    alignItems: 'center',
    gap: '8px',
    padding: '4px 2px 10px',
    flexShrink: 0,
  },
  statusDot: { width: 8, height: 8, borderRadius: '50%', background: '#4ade80', flexShrink: 0 },
  statusText: { fontSize: 13, color: '#999', flex: 1, fontWeight: 500 },
  headerBtn: {
    background: 'transparent',
    border: '1px solid #2a2a3a',
    color: '#777',
    borderRadius: 8,
    width: 30,
    height: 30,
    fontSize: 14,
    cursor: 'pointer',
  },
  section: { marginBottom: 10, flexShrink: 0 },
  sectionTitle: {
    fontSize: 11,
    textTransform: 'uppercase',
    letterSpacing: '0.08em',
    color: '#556',
    margin: '0 0 8px 2px',
    fontWeight: 600,
  },
  runningRow: {
    display: 'flex',
    gap: 10,
    overflowX: 'auto',
    paddingBottom: 4,
    WebkitOverflowScrolling: 'touch',
  },
  runningCard: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'flex-start',
    gap: 6,
    minWidth: 120,
    maxWidth: 150,
    padding: '10px 12px',
    background: '#151522',
    border: '1px solid #22223a',
    borderRadius: 14,
    cursor: 'pointer',
    color: '#ddd',
    flexShrink: 0,
    textAlign: 'left',
  },
  runningLabel: { fontSize: 12, fontWeight: 600, color: '#eee', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', maxWidth: '100%' },
  sessionClose: {
    marginLeft: 'auto',
    width: 22,
    height: 22,
    borderRadius: 6,
    border: '1px solid #2a2a3a',
    color: '#889',
    fontSize: 11,
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    cursor: 'pointer',
  },
  runningTitle: { fontSize: 10, color: '#667', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', maxWidth: '100%' },
  appsHeader: { display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8 },
  search: {
    flex: 1,
    maxWidth: 200,
    marginLeft: 'auto',
    padding: '6px 12px',
    borderRadius: 8,
    border: '1px solid #22223a',
    background: '#12121c',
    color: '#ddd',
    fontSize: 12,
    outline: 'none',
  },
  appGridScroll: { flex: 1, overflowY: 'auto', minHeight: 0, WebkitOverflowScrolling: 'touch' },
  appGrid: {
    display: 'grid',
    gridTemplateColumns: 'repeat(auto-fill, minmax(76px, 1fr))',
    gap: '14px 8px',
    paddingBottom: 12,
  },
  appCell: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: 6,
    background: 'transparent',
    border: 'none',
    cursor: 'pointer',
    color: '#ccc',
    padding: 0,
  },
  appLabel: {
    fontSize: 11,
    color: '#bbc',
    maxWidth: 76,
    whiteSpace: 'nowrap',
    overflow: 'hidden',
    textOverflow: 'ellipsis',
  },
  runningDot: {
    position: 'absolute',
    bottom: -3,
    left: '50%',
    transform: 'translateX(-50%)',
    width: 5,
    height: 5,
    borderRadius: '50%',
    background: '#4ade80',
  },
  loadingText: { color: '#556', fontSize: 13, textAlign: 'center', marginTop: 30 },
  dock: {
    display: 'flex',
    justifyContent: 'space-around',
    gap: 4,
    padding: '8px 4px calc(6px + env(safe-area-inset-bottom))',
    background: '#12121ccc',
    backdropFilter: 'blur(12px)',
    border: '1px solid #1e1e30',
    borderRadius: 18,
    flexShrink: 0,
  },
  dockBtn: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: 3,
    background: 'transparent',
    border: 'none',
    color: '#aab',
    cursor: 'pointer',
    fontSize: 18,
    padding: '2px 8px',
  },
  dockIcon: { fontSize: 20 },
  dockLabel: { fontSize: 9.5, color: '#667' },
  form: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    justifyContent: 'center',
    minHeight: '100dvh',
    background: '#0a0a0f',
    color: '#e0e0e0',
    fontFamily: 'system-ui, sans-serif',
    padding: '24px',
    boxSizing: 'border-box',
    gap: '12px',
  },
  title: { fontSize: '32px', fontWeight: 700, margin: 0, color: '#fff' },
  subtitle: { fontSize: '14px', color: '#666', margin: 0, marginBottom: '20px' },
  input: {
    width: '100%',
    maxWidth: '320px',
    padding: '12px 16px',
    borderRadius: '8px',
    border: '1px solid #2a2a3a',
    background: '#141420',
    color: '#e0e0e0',
    fontSize: '14px',
    outline: 'none',
    boxSizing: 'border-box',
  },
  button: {
    width: '100%',
    maxWidth: '320px',
    padding: '12px',
    borderRadius: '8px',
    border: 'none',
    background: '#2a6aff',
    color: '#fff',
    fontSize: '14px',
    fontWeight: 600,
    cursor: 'pointer',
  },
  error: { color: '#e55', fontSize: '13px', margin: 0, textAlign: 'center', maxWidth: '320px' },
  linkBtn: {
    background: 'transparent',
    border: 'none',
    color: '#6b8cff',
    fontSize: '13px',
    cursor: 'pointer',
    textDecoration: 'underline',
    padding: '4px',
  },
  spinner: {
    width: '32px',
    height: '32px',
    borderRadius: '50%',
    border: '3px solid #1e2a4a',
    borderTopColor: '#2a6aff',
    animation: 'nl-spin 0.8s linear infinite',
  },
};
