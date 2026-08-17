'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useConnectionStore } from '@/store/connection';
import ConnectionProvider from '@/components/ConnectionProvider';

function IdeView() {
  const client = useConnectionStore((s) => s.client);
  const status = useConnectionStore((s) => s.status);
  const router = useRouter();
  const [url, setUrl] = useState<string | null>(null);
  const [error, setError] = useState('');

  useEffect(() => {
    if (status !== 'connected' || !client) return;
    let cancelled = false;
    (async () => {
      try {
        const st = (await client.request('ide.start', {})) as {
          available?: boolean;
          port?: number;
          reason?: string;
        };
        if (cancelled) return;
        if (!st.available || !st.port) {
          setError(st.reason || 'Install code-server on the PC.');
          return;
        }
        const host = window.location.hostname;
        setUrl(`http://${host}:${st.port}`);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : 'Could not start VS Code.');
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [status, client]);

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100dvh', background: '#0a0a0f', color: '#eee' }}>
      <header style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 12px', background: '#0a0a0f' }}>
        <button onClick={() => router.push('/')} style={{ background: 'none', border: 0, color: '#aaa', fontSize: 20 }}>
          ⌂
        </button>
        <span>VS Code</span>
      </header>
      {error ? (
        <p style={{ padding: 24, textAlign: 'center', color: '#aaa' }}>{error}</p>
      ) : url ? (
        <iframe title="VS Code" src={url} style={{ flex: 1, border: 0, width: '100%' }} />
      ) : (
        <p style={{ padding: 24, textAlign: 'center', color: '#aaa' }}>Starting the editor on the PC…</p>
      )}
    </div>
  );
}

export default function IdePage() {
  return (
    <ConnectionProvider>
      <IdeView />
    </ConnectionProvider>
  );
}
