'use client';

import { useState, useCallback, FormEvent, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { useConnectionStore } from '@/store/connection';
import ConnectionProvider, { STORAGE_KEY } from '@/components/ConnectionProvider';
import { getToken, clearToken } from '@/lib/auth-client';

function ConnectForm() {
  const connect = useConnectionStore((s) => s.connect);
  const status = useConnectionStore((s) => s.status);
  const [url, setUrl] = useState('');
  const [error, setError] = useState('');

  const handleSubmit = useCallback(
    async (e: FormEvent) => {
      e.preventDefault();
      setError('');
      try {
        await connect(url);
        localStorage.setItem(STORAGE_KEY, url);
      } catch {
        setError('Failed to connect. Check the host URL.');
      }
    },
    [connect, url]
  );

  const isLoading = status === 'connecting';

  return (
    <form onSubmit={handleSubmit} style={styles.form}>
      <h1 style={styles.title}>NexusLink</h1>
      <p style={styles.subtitle}>Remote Desktop Client</p>
      <input
        type="text"
        placeholder="ws://host:port"
        value={url}
        onChange={(e) => setUrl(e.target.value)}
        disabled={isLoading}
        style={styles.input}
      />
      <button type="submit" disabled={isLoading || !url} style={styles.button}>
        {isLoading ? 'Connecting...' : 'Connect'}
      </button>
      {error && <p style={styles.error}>{error}</p>}
    </form>
  );
}

const LAUNCHER_ITEMS = [
  { id: 'terminal', label: 'Terminal', icon: '>_' },
  { id: 'files', label: 'Files', icon: '\u{1F4C1}' },
  { id: 'processes', label: 'Processes', icon: '\u2699' },
  { id: 'system', label: 'System', icon: '\u{1F4CA}' },
] as const;

function HomeScreen() {
  const status = useConnectionStore((s) => s.status);
  const hostUrl = useConnectionStore((s) => s.hostUrl);
  const disconnect = useConnectionStore((s) => s.disconnect);
  const [mirrorMode, setMirrorMode] = useState(false);
  const [sessionToken, setSessionToken] = useState<string | null>(null);
  const router = useRouter();

  useEffect(() => {
    setSessionToken(getToken());
  }, [status]);

  if (status !== 'connected') {
    return <ConnectForm />;
  }

  return (
    <main style={styles.container}>
      <header style={styles.header}>
        <span style={styles.statusDot} />
        <span style={styles.statusText}>Connected</span>
        <button
          onClick={() => {
            if (mirrorMode) {
              router.push('/mirror');
            } else {
              setMirrorMode(true);
            }
          }}
          style={{
            ...styles.mirrorBtn,
            background: mirrorMode ? '#2a6aff' : 'transparent',
            color: mirrorMode ? '#fff' : '#888',
            borderColor: mirrorMode ? '#2a6aff' : '#333',
          }}
        >
          Mirror Mode {mirrorMode ? 'ON' : 'OFF'}
        </button>
      </header>

      <div style={styles.statusCard}>
        <div style={styles.statusRow}>
          <span style={styles.statusLabel}>Host</span>
          <code style={styles.statusValue}>{hostUrl || '—'}</code>
        </div>
        <div style={styles.statusRow}>
          <span style={styles.statusLabel}>Session</span>
          <code style={styles.statusValue}>
            {sessionToken ? sessionToken.slice(0, 12) + '...' : '—'}
          </code>
        </div>
        <div style={styles.statusActions}>
          <button onClick={() => router.push('/pair')} style={styles.pairBtn}>
            Pair
          </button>
          <button
            onClick={() => {
              clearToken();
              setSessionToken(null);
              disconnect();
            }}
            style={styles.disconnectBtn}
          >
            Disconnect
          </button>
        </div>
      </div>

      <div style={styles.grid}>
        {LAUNCHER_ITEMS.map((item) => (
          <button
            key={item.id}
            style={styles.card}
            onClick={() => router.push(`/${item.id}`)}
          >
            <span style={styles.cardIcon}>{item.icon}</span>
            <span style={styles.cardLabel}>{item.label}</span>
          </button>
        ))}
      </div>
    </main>
  );
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
    minHeight: '100dvh',
    background: '#0a0a0f',
    color: '#e0e0e0',
    fontFamily: 'system-ui, sans-serif',
    padding: '16px',
    boxSizing: 'border-box',
  },
  header: {
    display: 'flex',
    alignItems: 'center',
    gap: '10px',
    padding: '8px 0',
    marginBottom: '16px',
  },
  statusDot: {
    width: '8px',
    height: '8px',
    borderRadius: '50%',
    background: '#4ade80',
  },
  statusText: {
    fontSize: '13px',
    color: '#888',
    flex: 1,
  },
  mirrorBtn: {
    padding: '6px 14px',
    borderRadius: '6px',
    border: '1px solid #333',
    background: 'transparent',
    color: '#888',
    fontSize: '12px',
    fontWeight: 600,
    cursor: 'pointer',
  },
  statusCard: {
    background: '#141420',
    border: '1px solid #1e1e30',
    borderRadius: 10,
    padding: '12px 14px',
    marginBottom: 16,
    display: 'flex',
    flexDirection: 'column',
    gap: 8,
  },
  statusRow: {
    display: 'flex',
    alignItems: 'center',
    gap: 8,
  },
  statusLabel: {
    fontSize: 12,
    color: '#555',
    minWidth: 50,
  },
  statusValue: {
    fontSize: 12,
    color: '#aaa',
    background: '#0a0a0f',
    padding: '2px 8px',
    borderRadius: 4,
  },
  statusActions: {
    display: 'flex',
    gap: 8,
    marginTop: 4,
  },
  pairBtn: {
    flex: 1,
    padding: '8px',
    borderRadius: 6,
    border: '1px solid #2a3a6a',
    background: '#141420',
    color: '#2a6aff',
    fontSize: 12,
    fontWeight: 600,
    cursor: 'pointer',
  },
  grid: {
    display: 'grid',
    gridTemplateColumns: 'repeat(2, 1fr)',
    gap: '12px',
    flex: 1,
  },
  card: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    justifyContent: 'center',
    gap: '10px',
    padding: '24px 12px',
    background: '#141420',
    border: '1px solid #1e1e30',
    borderRadius: '12px',
    cursor: 'pointer',
    color: '#ccc',
    fontSize: '14px',
  },
  cardIcon: {
    fontSize: '28px',
  },
  cardLabel: {
    fontSize: '13px',
    fontWeight: 500,
  },
  disconnectBtn: {
    flex: 1,
    padding: '8px',
    borderRadius: 6,
    border: '1px solid #3a1a1a',
    background: '#1a1010',
    color: '#e55',
    fontSize: 12,
    fontWeight: 600,
    cursor: 'pointer',
  },
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
  title: {
    fontSize: '32px',
    fontWeight: 700,
    margin: 0,
    color: '#fff',
  },
  subtitle: {
    fontSize: '14px',
    color: '#666',
    margin: 0,
    marginBottom: '20px',
  },
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
  error: {
    color: '#e55',
    fontSize: '13px',
    margin: 0,
  },
};
