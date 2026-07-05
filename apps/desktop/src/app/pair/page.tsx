'use client';

import { useState, useCallback, useRef, FormEvent } from 'react';
import { getHostUrl, setHostUrl } from '@/lib/desktop-runtime';

type PairingPhase = 'idle' | 'connecting' | 'pairing' | 'authenticating' | 'connected' | 'error';

export default function PairPage() {
  const [hostUrl, setHost] = useState(() => getHostUrl() ?? 'ws://localhost:45678/signal');
  const [phase, setPhase] = useState<PairingPhase>('idle');
  const [pairingCode, setPairingCode] = useState('');
  const [totpCode, setTotpCode] = useState('');
  const [sessionToken, setSessionToken] = useState('');
  const [error, setError] = useState('');
  const [countdown, setCountdown] = useState(30);
  const pairingRef = useRef('');
  const wsRef = useRef<WebSocket | null>(null);

  const reset = useCallback(() => {
    wsRef.current?.close();
    wsRef.current = null;
    setPhase('idle');
    setPairingCode('');
    setTotpCode('');
    setSessionToken('');
    setError('');
    pairingRef.current = '';
    setCountdown(30);
  }, []);

  const startPairing = useCallback(
    (e: FormEvent) => {
      e.preventDefault();
      setError('');
      setPhase('connecting');
      setHostUrl(hostUrl);

      const ws = new WebSocket(hostUrl);
      wsRef.current = ws;

      ws.onopen = () => {
        setPhase('pairing');
        ws.send(
          JSON.stringify({
            type: 'rpc-request',
            request: {
              id: 1,
              method: 'session.pair',
              params: {
                publicKey: JSON.stringify({
                  kty: 'EC',
                  crv: 'P-256',
                  x: 'dev-client-x',
                  y: 'dev-client-y',
                }),
              },
            },
          }),
        );
      };

      ws.onmessage = (event) => {
        try {
          const raw = JSON.parse(event.data as string);
          if (!raw.type || !raw.response) return;
          const resp = raw.response;

          if (resp.id === 1) {
            if (resp.error) {
              setError(String(resp.error));
              setPhase('error');
              return;
            }
            const { totpIssuerUri } = resp.result as { totpIssuerUri: string };
            const secret = totpIssuerUri.split('secret=')[1]?.split('&')[0] ?? '';
            pairingRef.current = secret;
            setPairingCode(secret.slice(0, 8));
            setPhase('authenticating');
            setCountdown(30);
          } else if (resp.id === 2) {
            if (resp.error) {
              setError(String(resp.error));
              setPhase('error');
              return;
            }
            const { token } = resp.result as { token: string };
            setSessionToken(token);
            setPhase('connected');
          }
        } catch {
          // ignore
        }
      };

      ws.onerror = () => {
        setError('WebSocket connection failed');
        setPhase('error');
      };

      ws.onclose = () => {
        if (phase !== 'connected' && phase !== 'error') {
          setError('Connection closed');
          setPhase('error');
        }
      };
    },
    [hostUrl, phase],
  );

  const sendAuth = useCallback(
    async (e: FormEvent) => {
      e.preventDefault();
      const code = totpCode;
      if (!wsRef.current || wsRef.current.readyState !== 1) return;

      wsRef.current.send(
        JSON.stringify({
          type: 'rpc-request',
          request: { id: 2, method: 'session.authenticate', params: { code } },
        }),
      );
    },
    [totpCode],
  );

  return (
    <main style={S.container}>
      <h1 style={S.title}>NexusLink Host — Pairing</h1>

      {phase === 'idle' && !sessionToken && (
        <form onSubmit={startPairing} style={S.form}>
          <label style={S.label}>Server WebSocket URL</label>
          <input
            type="text"
            value={hostUrl}
            onChange={(e) => setHost(e.target.value)}
            style={S.input}
            placeholder="ws://localhost:45678/signal"
          />
          <button type="submit" style={S.btn}>
            Start Pairing
          </button>
        </form>
      )}

      {phase === 'connecting' && <p style={S.status}>Connecting to server...</p>}

      {phase === 'pairing' && <p style={S.status}>Generating pairing code...</p>}

      {phase === 'authenticating' && (
        <div style={S.tokenCard}>
          <p style={S.tokenLabel}>Pairing Token</p>
          <code style={S.token}>{pairingCode}</code>
          <p style={S.tokenHint}>Enter this code on the mobile client</p>
          <form onSubmit={sendAuth} style={S.authForm}>
            <label style={S.label}>TOTP Code</label>
            <input
              type="text"
              value={totpCode}
              onChange={(e) => setTotpCode(e.target.value)}
              style={{ ...S.input, maxWidth: 160, textAlign: 'center' }}
              placeholder="000000"
              maxLength={6}
              autoFocus
            />
            <button type="submit" disabled={totpCode.length !== 6} style={S.btn}>
              Authenticate
            </button>
          </form>
        </div>
      )}

      {phase === 'connected' && sessionToken && (
        <div style={S.connectedCard}>
          <span style={S.dot} />
          <span style={S.connectedText}>Connected</span>
          <div style={S.tokenDisplay}>
            <span style={S.tokenDisplayLabel}>Session</span>
            <code style={S.tokenSmall}>{sessionToken.slice(0, 16)}...</code>
          </div>
          <button onClick={reset} style={S.disconnectBtn}>
            Disconnect
          </button>
        </div>
      )}

      {phase === 'error' && (
        <div style={S.errorCard}>
          <p style={S.errorText}>{error}</p>
          <button onClick={reset} style={S.btn}>
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
  },
  title: {
    fontSize: 24,
    fontWeight: 700,
    color: '#fff',
    margin: '0 0 24px 0',
  },
  form: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: 12,
    width: '100%',
    maxWidth: 400,
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
  status: {
    fontSize: 14,
    color: '#888',
    margin: 0,
  },
  tokenCard: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: 16,
    padding: 24,
    background: '#141420',
    border: '1px solid #1e1e30',
    borderRadius: 12,
    maxWidth: 400,
    width: '100%',
  },
  tokenLabel: {
    fontSize: 13,
    color: '#888',
    margin: 0,
  },
  token: {
    fontSize: 32,
    fontWeight: 700,
    color: '#4ade80',
    letterSpacing: 4,
    background: '#0a0a0f',
    padding: '12px 24px',
    borderRadius: 8,
    border: '1px solid #1e1e30',
  },
  tokenHint: {
    fontSize: 12,
    color: '#555',
    margin: 0,
  },
  authForm: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: 12,
    width: '100%',
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
    maxWidth: 400,
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
  tokenDisplay: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: 4,
    margin: '8px 0',
  },
  tokenDisplayLabel: {
    fontSize: 11,
    color: '#555',
  },
  tokenSmall: {
    fontSize: 12,
    color: '#4ade80',
    background: '#0a0a0f',
    padding: '4px 8px',
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
    maxWidth: 400,
    width: '100%',
  },
  errorText: {
    color: '#e55',
    fontSize: 13,
    margin: 0,
    textAlign: 'center',
  },
};
