'use client';
import { useState, FormEvent } from 'react';
import { useConnectionStore } from '@/store/connection';
export default function PairPage() {
  const [host, setHost] = useState('ws://localhost:45678/rpc');
  const [code,setCode]=useState('');
  const [error,setError]=useState('');
  const {connect,disconnect,status}=useConnectionStore();
  async function submit(e:FormEvent){e.preventDefault();setError('');try{await connect(host,code || undefined);}catch(e){setError(String(e));}}
  return <main style={S.container}><h1>Pair with PC</h1><p>Run <code>bun run host:pair</code> on your PC. Enter its one-use eight-digit code.</p>
    <form onSubmit={submit} style={S.form}><label>PC WebSocket URL</label><input style={S.input} value={host} onChange={e=>setHost(e.target.value)} />
    <label>Pairing code</label><input style={S.input} inputMode="numeric" maxLength={8} value={code} onChange={e=>setCode(e.target.value.replace(/\D/g,''))} />
    <button style={S.btn} disabled={status==='connecting'}>Connect</button></form>
    {error && <p role="alert">{error}</p>}{status==='connected' && <><p>PC connected</p><a href="/">Open workspace</a><button onClick={disconnect}>Disconnect</button></>}
  </main>;
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
