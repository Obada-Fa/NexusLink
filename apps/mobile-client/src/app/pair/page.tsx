'use client';

import { useState, useCallback, useEffect, useRef, FormEvent } from 'react';
import { RpcClient } from '@/lib/rpc-client';
import { storeToken, clearToken, getToken } from '@/lib/auth-client';

type PairPhase = 'idle' | 'connecting' | 'paired' | 'authenticated' | 'error';

function isLocalHost(url: string): boolean {
  try {
    const host = new URL(url).hostname;
    return host === 'localhost' || host === '127.0.0.1' || host === '::1';
  } catch {
    return false;
  }
}

function useCountdown(from: number, active: boolean): number {
  const [val, setVal] = useState(from);

  useEffect(() => {
    if (!active) return;
    setVal(from);
    const id = setInterval(() => {
      setVal((v) => {
        if (v <= 1) {
          clearInterval(id);
          return 0;
        }
        return v - 1;
      });
    }, 1000);
    return () => clearInterval(id);
  }, [from, active]);

  return val;
}

export default function PairPage() {
  const [hostUrl, setHost] = useState('ws://localhost:45678/signal');
  const [phase, setPhase] = useState<PairPhase>('idle');
  const [pairingToken, setPairingToken] = useState('');
  const [totpCode, setTotpCode] = useState('');
  const [sessionToken, setSessionToken] = useState(() => getToken());
  const [error, setError] = useState('');
  const clientRef = useRef<RpcClient | null>(null);
  const pairingRef = useRef('');
  const countdown = useCountdown(30, phase === 'paired');

  const startPairing = useCallback(
    async (e: FormEvent) => {
      e.preventDefault();
      setError('');
      setPhase('connecting');

      const client = new RpcClient(hostUrl);
      clientRef.current = client;

      try {
        await client.connect();

        const local = isLocalHost(hostUrl);

        if (local) {
          const devToken = `dev-${crypto.randomUUID()}`;
          const authResult = (await client.request('session.authenticate', {
            code: devToken,
          })) as { token: string };
          setSessionToken(authResult.token);
          storeToken(authResult.token);
          setPhase('authenticated');
          return;
        }

        const clientKeyPair = await crypto.subtle.generateKey(
          { name: 'ECDH', namedCurve: 'P-256' },
          true,
          ['deriveBits']
        );
        const clientPubJwk = await crypto.subtle.exportKey('jwk', clientKeyPair.publicKey);
        const publicKey = JSON.stringify(clientPubJwk);

        const pairResult = (await client.request('session.pair', {
          publicKey,
        })) as { publicKey: string; totpIssuerUri: string };

        const secret = pairResult.totpIssuerUri.split('secret=')[1]?.split('&')[0] ?? '';
        pairingRef.current = secret;
        setPairingToken(secret.slice(0, 8));
        setPhase('paired');
      } catch (err) {
        setError(String(err));
        setPhase('error');
        client.disconnect();
      }
    },
    [hostUrl],
  );

  const sendAuth = useCallback(
    async (e: FormEvent) => {
      e.preventDefault();
      if (!clientRef.current || totpCode.length !== 6) return;

      try {
        const authResult = (await clientRef.current.request('session.authenticate', {
          code: totpCode,
        })) as { token: string };

        setSessionToken(authResult.token);
        storeToken(authResult.token);
        setPhase('authenticated');
      } catch (err) {
        setError(String(err));
        setPhase('error');
      }
    },
    [totpCode],
  );

  const disconnect = useCallback(() => {
    clientRef.current?.disconnect();
    clientRef.current = null;
    clearToken();
    setPhase('idle');
    setSessionToken('');
    setPairingToken('');
    setTotpCode('');
    setError('');
  }, []);

  if (sessionToken && phase !== 'idle') {
    return (
      <main style={S.container}>
        <h1 style={S.title}>NexusLink — Paired</h1>
        <div style={S.connectedCard}>
          <span style={S.dot} />
          <span style={S.connectedText}>Authenticated</span>
          <div style={S.tokenRow}>
            <span style={S.tokenLabel}>Session</span>
            <code style={S.token}>{sessionToken.slice(0, 12)}...</code>
          </div>
          <button onClick={disconnect} style={S.disconnectBtn}>
            Disconnect & Forget
          </button>
        </div>
      </main>
    );
  }

  return (
    <main style={S.container}>
      <h1 style={S.title}>Pair with Host</h1>

      <form onSubmit={startPairing} style={S.form}>
        <label style={S.label}>Host WebSocket URL</label>
        <input
          type="text"
          value={hostUrl}
          onChange={(e) => setHost(e.target.value)}
          style={S.input}
          placeholder="ws://192.168.x.x:45678/signal"
        />
        <button type="submit" disabled={phase === 'connecting'} style={S.btn}>
          {phase === 'connecting' ? 'Connecting...' : 'Pair'}
        </button>
      </form>

      {phase === 'paired' && pairingToken && (
        <div style={S.pairCard}>
          <p style={S.pairLabel}>Pairing Token</p>
          <div style={S.tokenBox}>
            <code style={S.tokenText}>{pairingToken}</code>
          </div>
          <p style={S.countdown}>
            Expires in <span style={{ ...S.countValue, color: countdown <= 10 ? '#e55' : '#888' }}>{countdown}</span>s
          </p>
          <form onSubmit={sendAuth} style={S.authForm}>
            <label style={S.label}>TOTP Code</label>
            <input
              type="text"
              inputMode="numeric"
              value={totpCode}
              onChange={(e) => setTotpCode(e.target.value.slice(0, 6))}
              style={{ ...S.input, maxWidth: 160, textAlign: 'center', fontSize: 20, letterSpacing: 4 }}
              placeholder="000000"
              maxLength={6}
              autoFocus
            />
            <button type="submit" disabled={totpCode.length !== 6} style={S.btn}>
              Verify &amp; Connect
            </button>
          </form>
        </div>
      )}

      {phase === 'error' && (
        <div style={S.errorCard}>
          <p style={S.errorText}>{error}</p>
          <button onClick={() => setPhase('idle')} style={S.btn}>
            Retry
          </button>
        </div>
      )}
    </main>
  );
}

const S: Record<string, React.CSSProperties> = {
  container: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    justifyContent: 'center',
    minHeight: '100dvh',
    background: '#0a0a0f',
    color: '#e0e0e0',
    fontFamily: 'system-ui, sans-serif',
    padding: 24,
    boxSizing: 'border-box',
    gap: 20,
  },
  title: {
    fontSize: 24,
    fontWeight: 700,
    color: '#fff',
    margin: 0,
  },
  form: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: 12,
    width: '100%',
    maxWidth: 360,
  },
  label: {
    fontSize: 13,
    color: '#888',
    alignSelf: 'flex-start',
    marginBottom: -4,
  },
  input: {
    width: '100%',
    padding: '12px 16px',
    borderRadius: 8,
    border: '1px solid #2a2a3a',
    background: '#141420',
    color: '#e0e0e0',
    fontSize: 14,
    outline: 'none',
    boxSizing: 'border-box',
  },
  btn: {
    width: '100%',
    padding: '12px',
    borderRadius: 8,
    border: 'none',
    background: '#2a6aff',
    color: '#fff',
    fontSize: 14,
    fontWeight: 600,
    cursor: 'pointer',
  },
  pairCard: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: 14,
    padding: 24,
    background: '#141420',
    border: '1px solid #1e1e30',
    borderRadius: 12,
    maxWidth: 360,
    width: '100%',
  },
  pairLabel: {
    fontSize: 13,
    color: '#888',
    margin: 0,
  },
  tokenBox: {
    background: '#0a0a0f',
    border: '2px dashed #2a6aff',
    borderRadius: 12,
    padding: '20px 32px',
  },
  tokenText: {
    fontSize: 36,
    fontWeight: 700,
    color: '#2a6aff',
    letterSpacing: 6,
    fontFamily: 'monospace',
  },
  countdown: {
    fontSize: 12,
    color: '#555',
    margin: 0,
  },
  countValue: {
    fontWeight: 600,
  },
  authForm: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: 12,
    width: '100%',
    marginTop: 4,
  },
  connectedCard: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: 12,
    padding: 24,
    background: '#141420',
    border: '1px solid #1e1e30',
    borderRadius: 12,
    maxWidth: 360,
    width: '100%',
  },
  dot: {
    width: 10,
    height: 10,
    borderRadius: '50%',
    background: '#4ade80',
  },
  connectedText: {
    fontSize: 15,
    color: '#ccc',
  },
  tokenRow: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: 4,
    margin: '8px 0',
  },
  tokenLabel: {
    fontSize: 11,
    color: '#555',
  },
  token: {
    fontSize: 12,
    color: '#4ade80',
    background: '#0a0a0f',
    padding: '4px 10px',
    borderRadius: 4,
  },
  disconnectBtn: {
    width: '100%',
    padding: '10px',
    borderRadius: 8,
    border: '1px solid #3a1a1a',
    background: '#1a1010',
    color: '#e55',
    fontSize: 13,
    fontWeight: 600,
    cursor: 'pointer',
    marginTop: 4,
  },
  errorCard: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: 12,
    padding: 24,
    background: '#1a1010',
    border: '1px solid #3a1a1a',
    borderRadius: 12,
    maxWidth: 360,
    width: '100%',
  },
  errorText: {
    color: '#e55',
    fontSize: 13,
    margin: 0,
    textAlign: 'center',
  },
};
