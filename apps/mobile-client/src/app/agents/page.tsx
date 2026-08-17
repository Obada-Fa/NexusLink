'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useConnectionStore } from '@/store/connection';

interface AgentInfo {
  id: string;
  name: string;
  available: boolean;
}

interface AgentSessionInfo {
  agentSessionId: string;
  agent: string;
  cwd: string;
  title: string;
  busy: boolean;
  status: string;
}

interface AgentEvent {
  seq: number;
  ts: number;
  kind: string;
  text?: string;
  toolName?: string;
  toolInput?: string;
  toolOutput?: string;
  refId?: string;
}

export default function AgentsPage() {
  const client = useConnectionStore((s) => s.client);
  const status = useConnectionStore((s) => s.status);
  const router = useRouter();

  const [agents, setAgents] = useState<AgentInfo[]>([]);
  const [sessions, setSessions] = useState<AgentSessionInfo[]>([]);
  const [active, setActive] = useState<AgentSessionInfo | null>(null);
  const [events, setEvents] = useState<AgentEvent[]>([]);
  const [draft, setDraft] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [sendError, setSendError] = useState('');
  const listRef = useRef<HTMLDivElement | null>(null);
  const unsubRef = useRef<(() => void) | null>(null);
  const activeIdRef = useRef<string | null>(null);
  activeIdRef.current = active?.agentSessionId ?? null;

  useEffect(() => {
    if (status !== 'connected' || !client) return;
    let cancelled = false;
    (async () => {
      try {
        const [a, s] = await Promise.all([
          client.request('agent.list') as Promise<AgentInfo[]>,
          client.request('agent.listSessions') as Promise<AgentSessionInfo[]>,
        ]);
        if (!cancelled) {
          setAgents(a);
          setSessions(s);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : 'Could not list agents.');
      }
    })();
    unsubRef.current = client.subscribe('agent-event', (msg: unknown) => {
      const m = msg as { agentSessionId?: string; event?: AgentEvent };
      if (!m.event || m.agentSessionId !== activeIdRef.current) return;
      if (m.event.kind === 'user') setBusy(true);
      if (m.event.kind === 'result' || m.event.kind === 'error') setBusy(false);
      if (m.event.kind === 'result' && !(m.event.text || '').trim()) return;
      if (m.event.kind === 'status') return;
      setEvents((prev) => [...prev, m.event!]);
      if (m.event.kind === 'permission-request' && m.event.refId) {
        const allow = window.confirm(m.event.text || `Allow ${m.event.toolName || 'this tool'}?`);
        void client.request('agent.permission', {
          agentSessionId: m.agentSessionId,
          requestId: m.event.refId,
          allow,
        });
      }
    });
    return () => {
      cancelled = true;
      unsubRef.current?.();
    };
  }, [status, client]);

  useEffect(() => {
    listRef.current?.scrollTo({ top: listRef.current.scrollHeight, behavior: 'smooth' });
  }, [events.length]);

  const newChat = useCallback(
    async (agent: AgentInfo) => {
      if (!client) return;
      try {
        const created = (await client.request('agent.createSession', {
          agent: agent.id,
          title: agent.name,
        })) as AgentSessionInfo;
        setSessions((s) => [created, ...s]);
        setActive(created);
        setEvents([]);
        setBusy(false);
        setSendError('');
        setError('');
      } catch (e) {
        setError(e instanceof Error ? e.message : 'Could not start that agent.');
      }
    },
    [client],
  );

  const openSession = useCallback(
    async (s: AgentSessionInfo) => {
      if (!client) return;
      const history = (await client.request('agent.history', {
        agentSessionId: s.agentSessionId,
      })) as AgentEvent[];
      setActive(s);
      setEvents(history);
      setBusy(false);
      setSendError('');
    },
    [client],
  );

  const send = useCallback(async () => {
    const text = draft.trim();
    if (!text || !client || !active || busy) return;
    setDraft('');
    setBusy(true);
    setSendError('');
    try {
      await client.request('agent.prompt', {
        agentSessionId: active.agentSessionId,
        text,
      });
    } catch (e) {
      setBusy(false);
      setSendError(e instanceof Error ? e.message : 'Failed to send.');
    }
  }, [draft, client, active, busy]);

  return (
    <div style={styles.wrapper}>
      <header style={styles.topBar}>
        <button onClick={() => (active ? setActive(null) : router.push('/'))} style={styles.barBtn}>
          {active ? '←' : '⌂'}
        </button>
        <span style={styles.title}>{active?.title ?? 'Agents'}</span>
      </header>

      {status !== 'connected' ? (
        <p style={styles.center}>Not connected to the PC.</p>
      ) : error ? (
        <p style={styles.center}>{error}</p>
      ) : !active ? (
        <div style={styles.list}>
          <h2 style={styles.section}>New chat</h2>
          {agents.map((a) => (
            <button
              key={a.id}
              disabled={!a.available}
              onClick={() => newChat(a)}
              style={{ ...styles.row, opacity: a.available ? 1 : 0.4 }}
            >
              <strong>{a.name}</strong>
              <span style={styles.muted}>
                {a.available ? 'Runs on the PC — chat here' : 'CLI not installed on the PC'}
              </span>
            </button>
          ))}
          {sessions.length > 0 && <h2 style={styles.section}>Recent</h2>}
          {sessions.map((s) => (
            <button key={s.agentSessionId} onClick={() => openSession(s)} style={styles.row}>
              <strong>{s.title}</strong>
              <span style={styles.muted}>{s.cwd}</span>
            </button>
          ))}
        </div>
      ) : (
        <>
          <div ref={listRef} style={styles.chat}>
            {events.map((e, i) => (
              <Bubble key={`${e.seq}-${i}`} e={e} />
            ))}
            {busy && <div style={styles.thinking}>Working…</div>}
          </div>
          <form
            style={styles.composer}
            onSubmit={(ev) => {
              ev.preventDefault();
              void send();
            }}
          >
            <input
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              placeholder="Message the agent…"
              style={styles.input}
            />
            <button type="submit" style={styles.send} disabled={busy}>
              {busy ? '…' : 'Send'}
            </button>
          </form>
          {sendError && <div style={styles.err}>{sendError}</div>}
        </>
      )}
    </div>
  );
}

function Bubble({ e }: { e: AgentEvent }) {
  if (e.kind === 'user') {
    return <div style={{ ...styles.bubble, ...styles.user }}>{e.text}</div>;
  }
  if (e.kind === 'text' || (e.kind === 'result' && e.text)) {
    return <pre style={{ ...styles.bubble, ...styles.assistant }}>{e.text}</pre>;
  }
  if (e.kind === 'thinking') {
    return <div style={styles.thinking}>{e.text || 'Thinking…'}</div>;
  }
  if (e.kind === 'tool-start' || e.kind === 'tool-end') {
    return (
      <div style={styles.tool}>
        <strong>
          {e.kind === 'tool-end' ? '✓' : '▶'} {e.toolName || 'tool'}
        </strong>
        {e.toolInput && <pre style={styles.code}>{e.toolInput}</pre>}
        {e.kind === 'tool-end' && e.toolOutput && <pre style={styles.out}>{e.toolOutput}</pre>}
      </div>
    );
  }
  if (e.kind === 'error') return <div style={styles.err}>{e.text}</div>;
  return null;
}

const styles: Record<string, React.CSSProperties> = {
  wrapper: {
    display: 'flex',
    flexDirection: 'column',
    height: '100dvh',
    background: '#0a0a0f',
    color: '#e0e0e0',
    fontFamily: 'system-ui, sans-serif',
  },
  topBar: {
    display: 'flex',
    alignItems: 'center',
    gap: 8,
    padding: '8px 10px',
    borderBottom: '1px solid #16162a',
  },
  barBtn: {
    width: 34,
    height: 30,
    borderRadius: 8,
    border: '1px solid #22223a',
    background: 'transparent',
    color: '#888',
    cursor: 'pointer',
  },
  title: { flex: 1, textAlign: 'center', fontWeight: 600, fontSize: 14 },
  center: { textAlign: 'center', color: '#889', marginTop: 40 },
  list: { padding: 16, overflowY: 'auto' },
  section: {
    fontSize: 11,
    textTransform: 'uppercase',
    letterSpacing: '0.08em',
    color: '#556',
    margin: '16px 0 8px',
  },
  row: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'flex-start',
    gap: 4,
    width: '100%',
    padding: '12px 14px',
    marginBottom: 8,
    background: '#151522',
    border: '1px solid #22223a',
    borderRadius: 12,
    color: '#eee',
    cursor: 'pointer',
    textAlign: 'left',
  },
  muted: { fontSize: 12, color: '#778' },
  chat: { flex: 1, overflowY: 'auto', padding: 12 },
  bubble: {
    maxWidth: '85%',
    padding: '8px 12px',
    borderRadius: 14,
    margin: '6px 0',
    whiteSpace: 'pre-wrap',
    fontSize: 14,
  },
  user: { marginLeft: 'auto', background: '#2a6aff', color: '#fff' },
  assistant: {
    background: '#151522',
    fontFamily: 'system-ui, sans-serif',
    margin: '6px 0',
  },
  thinking: { fontSize: 12, color: '#667', fontStyle: 'italic', margin: '4px 8px' },
  tool: {
    background: '#12121c',
    border: '1px solid #22223a',
    borderRadius: 10,
    padding: 10,
    margin: '6px 0',
    fontSize: 12,
  },
  code: { color: '#aab', fontSize: 11, whiteSpace: 'pre-wrap', margin: '6px 0 0' },
  out: { color: '#6ee7b7', fontSize: 11, whiteSpace: 'pre-wrap', margin: '6px 0 0' },
  err: { color: '#e55', fontSize: 13, margin: 8 },
  composer: {
    display: 'flex',
    gap: 8,
    padding: '8px 10px calc(8px + env(safe-area-inset-bottom))',
    borderTop: '1px solid #1c1c30',
  },
  input: {
    flex: 1,
    padding: '10px 12px',
    borderRadius: 10,
    border: '1px solid #26263e',
    background: '#161624',
    color: '#eee',
    fontSize: 14,
    outline: 'none',
  },
  send: {
    padding: '0 16px',
    borderRadius: 10,
    border: 'none',
    background: '#2a6aff',
    color: '#fff',
    fontWeight: 600,
    cursor: 'pointer',
  },
};
