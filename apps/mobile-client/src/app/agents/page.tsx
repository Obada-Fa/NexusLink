'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useConnectionStore } from '@/store/connection';
import type { RpcClient } from '@/lib/rpc-client';
import {
  comparePathNames,
  folderDisplayName,
  loadLastAgentCwd,
  saveLastAgentCwd,
} from '@/lib/last-cwd';

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
  hostChatId?: string;
}

interface AgentHostChat {
  agent: string;
  hostChatId: string;
  title: string;
  cwd: string;
  updatedAt: number;
  resumable: boolean;
  source: string;
}

type Picking =
  | { kind: 'new'; agent: AgentInfo }
  | { kind: 'host'; chat: AgentHostChat }
  | { kind: 'folder'; session: AgentSessionInfo };

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

interface ProjectInfo {
  name: string;
  path: string;
}

interface DirEntry {
  name: string;
  path: string;
  isDirectory: boolean;
}

function parentUnixPath(path: string): string {
  if (!path || path === '/') return '/';
  const trimmed = path.endsWith('/') && path !== '/' ? path.slice(0, -1) : path;
  const i = trimmed.lastIndexOf('/');
  return i <= 0 ? '/' : trimmed.slice(0, i);
}

function mergeToolEvents(events: AgentEvent[]): AgentEvent[] {
  const mergedTools: AgentEvent[] = [];
  const startIdx = new Map<string, number>();

  for (const e of events) {
    const ref = e.refId ?? '';
    if (e.kind === 'tool-start' && ref) {
      startIdx.set(ref, mergedTools.length);
      mergedTools.push(e);
      continue;
    }
    if (e.kind === 'tool-end' && ref && startIdx.has(ref)) {
      const i = startIdx.get(ref)!;
      startIdx.delete(ref);
      const start = mergedTools[i]!;
      mergedTools[i] = {
        ...start,
        seq: e.seq,
        ts: e.ts,
        kind: 'tool-end',
        toolName: e.toolName ?? start.toolName,
        toolOutput: e.toolOutput,
      };
      continue;
    }
    mergedTools.push(e);
  }

  const out: AgentEvent[] = [];
  let i = 0;
  while (i < mergedTools.length) {
    const cur = mergedTools[i];
    if (cur.kind === 'text' || cur.kind === 'text-delta') {
      let combined = cur.text ?? '';
      let j = i + 1;
      while (
        j < mergedTools.length &&
        (mergedTools[j].kind === 'text' || mergedTools[j].kind === 'text-delta')
      ) {
        combined += mergedTools[j].text ?? '';
        j++;
      }
      out.push({ ...cur, kind: 'text', text: combined });
      i = j;
    } else {
      out.push(cur);
      i++;
    }
  }
  return out;
}

export default function AgentsPage() {
  const client = useConnectionStore((s) => s.client);
  const status = useConnectionStore((s) => s.status);
  const connect = useConnectionStore((s) => s.connect);
  const hostUrl = useConnectionStore((s) => s.hostUrl);
  const router = useRouter();

  const [agents, setAgents] = useState<AgentInfo[]>([]);
  const [sessions, setSessions] = useState<AgentSessionInfo[]>([]);
  const [hostChats, setHostChats] = useState<AgentHostChat[]>([]);
  const [active, setActive] = useState<AgentSessionInfo | null>(null);
  const [events, setEvents] = useState<AgentEvent[]>([]);
  const [draft, setDraft] = useState('');
  const [error, setError] = useState('');
  const [picking, setPicking] = useState<Picking | null>(null);
  const [menuTab, setMenuTab] = useState<'recent' | 'pc'>('recent');
  const [reconnecting, setReconnecting] = useState(false);
  const listRef = useRef<HTMLDivElement | null>(null);
  const unsubRef = useRef<(() => void) | null>(null);
  const activeIdRef = useRef<string | null>(null);
  activeIdRef.current = active?.agentSessionId ?? null;

  const handleReconnect = useCallback(async () => {
    if (!hostUrl) return;
    setReconnecting(true);
    setError('');
    try {
      await connect(hostUrl);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not reconnect.');
    } finally {
      setReconnecting(false);
    }
  }, [connect, hostUrl]);

  useEffect(() => {
    if (status !== 'connected' || !client) return;
    let cancelled = false;
    (async () => {
      try {
        const [a, s] = await Promise.all([
          client.request('agent.list') as Promise<AgentInfo[]>,
          client.request('agent.listSessions') as Promise<AgentSessionInfo[]>,
        ]);
        let host: AgentHostChat[] = [];
        try {
          host = (await client.request('agent.listHostChats')) as AgentHostChat[];
        } catch {
          host = [];
        }
        if (!cancelled) {
          setAgents(a);
          setSessions(s);
          setHostChats(host);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : 'Could not list agents.');
      }
    })();
    const unsubs: (() => void)[] = [];
    unsubs.push(
      client.subscribe('agent-event', (msg: unknown) => {
        const m = msg as { agentSessionId?: string; event?: AgentEvent };
        if (!m.event || m.agentSessionId !== activeIdRef.current) return;
        setEvents((prev) => [...prev, m.event!]);
        if (m.event.kind === 'permission-request' && m.event.refId) {
          const allow = window.confirm(m.event.text || `Allow ${m.event.toolName || 'this tool'}?`);
          void client.request('agent.permission', {
            agentSessionId: m.agentSessionId,
            requestId: m.event.refId,
            allow,
          });
        }
      }),
    );
    unsubs.push(
      client.subscribe('agent-session-update', (msg: unknown) => {
        const m = msg as { session?: AgentSessionInfo };
        if (!m.session) return;
        const updated = m.session;
        setSessions((prev) => {
          const idx = prev.findIndex((s) => s.agentSessionId === updated.agentSessionId);
          if (idx !== -1) {
            const next = [...prev];
            next[idx] = updated;
            return next;
          }
          return [updated, ...prev];
        });
        setActive((prev) => (prev?.agentSessionId === updated.agentSessionId ? updated : prev));
      }),
    );
    unsubs.push(
      client.subscribe('agent-session-deleted', (msg: unknown) => {
        const m = msg as { agentSessionId?: string };
        if (!m.agentSessionId) return;
        const id = m.agentSessionId;
        setSessions((prev) => prev.filter((s) => s.agentSessionId !== id));
        setActive((prev) => (prev?.agentSessionId === id ? null : prev));
      }),
    );
    return () => {
      cancelled = true;
      for (const u of unsubs) u();
    };
  }, [status, client]);

  useEffect(() => {
    listRef.current?.scrollTo({ top: listRef.current.scrollHeight, behavior: 'smooth' });
  }, [events.length]);

  const newChat = useCallback((agent: AgentInfo) => {
    setPicking({ kind: 'new', agent });
  }, []);

  const openSession = useCallback(
    async (s: AgentSessionInfo) => {
      if (!client) return;
      const history = (await client.request('agent.history', {
        agentSessionId: s.agentSessionId,
      })) as AgentEvent[];
      setActive(s);
      setEvents(history);
      setSessions((prev) => [s, ...prev.filter((x) => x.agentSessionId !== s.agentSessionId)]);
    },
    [client],
  );

  const openHostChatWithCwd = useCallback(
    async (chat: AgentHostChat, cwd: string) => {
      if (!client) return;
      const created = (await client.request('agent.openHostChat', {
        agent: chat.agent,
        hostChatId: chat.hostChatId,
        cwd,
        title: chat.title,
      })) as AgentSessionInfo;
      setSessions((prev) => [created, ...prev.filter((x) => x.agentSessionId !== created.agentSessionId)]);
      await openSession(created);
    },
    [client, openSession],
  );

  const applyPickedCwd = useCallback(
    async (cwd: string) => {
      const current = picking;
      if (!client || !current) return;
      setPicking(null);
      if (current.kind === 'new') {
        const created = (await client.request('agent.createSession', {
          agent: current.agent.id,
          title: current.agent.name,
          cwd,
        })) as AgentSessionInfo;
        setSessions((s) => [created, ...s]);
        setActive(created);
        setEvents([]);
        return;
      }
      if (current.kind === 'host') {
        await openHostChatWithCwd(current.chat, cwd);
        return;
      }
      const updated = (await client.request('agent.setSessionCwd', {
        agentSessionId: current.session.agentSessionId,
        cwd,
      })) as AgentSessionInfo;
      setSessions((prev) =>
        prev.map((s) => (s.agentSessionId === updated.agentSessionId ? updated : s)),
      );
      setActive((prev) =>
        prev?.agentSessionId === updated.agentSessionId ? updated : prev,
      );
    },
    [client, picking, openHostChatWithCwd],
  );

  const openHostChat = useCallback(
    async (chat: AgentHostChat) => {
      const cwd = chat.cwd.trim();
      if (!cwd) {
        setPicking({ kind: 'host', chat });
        return;
      }
      await openHostChatWithCwd(chat, cwd);
    },
    [openHostChatWithCwd],
  );

  const renameSession = useCallback(
    async (session: AgentSessionInfo) => {
      const next = window.prompt('Rename chat:', session.title);
      if (!next || !next.trim() || next.trim() === session.title) return;
      const clean = next.trim();
      const updated = { ...session, title: clean };
      if (active?.agentSessionId === session.agentSessionId) {
        setActive(updated);
      }
      setSessions((prev) =>
        prev.map((s) => (s.agentSessionId === session.agentSessionId ? updated : s)),
      );
      if (client) {
        try {
          await client.request('agent.renameSession', {
            agentSessionId: session.agentSessionId,
            title: clean,
          });
        } catch {}
      }
    },
    [active, client],
  );

  const send = useCallback(async () => {
    const text = draft.trim();
    if (!text || !client || !active) return;
    setDraft('');
    const currentTitle = (active.title || '').trim();
    const isDefault =
      !currentTitle ||
      currentTitle === 'Agent' ||
      currentTitle === 'Host chat' ||
      agents.some((a) => a.name === currentTitle || a.id === currentTitle);
    if (isDefault) {
      const summary = text.split('\n')[0].trim();
      const clipped = summary.length > 50 ? `${summary.slice(0, 47)}…` : summary;
      if (clipped) {
        const updated = { ...active, title: clipped };
        setActive(updated);
        setSessions((prev) =>
          prev.map((s) => (s.agentSessionId === active.agentSessionId ? updated : s)),
        );
      }
    }
    await client.request('agent.prompt', {
      agentSessionId: active.agentSessionId,
      text,
    });
  }, [draft, client, active, agents]);

  return (
    <div style={styles.wrapper}>
      <header style={styles.topBar}>
        <button onClick={() => (active ? setActive(null) : router.push('/'))} style={styles.barBtn}>
          {active ? '←' : '⌂'}
        </button>
        <span
          onClick={() => active && void renameSession(active)}
          style={{ ...styles.title, cursor: active ? 'pointer' : 'default' }}
          title={active ? 'Click to rename' : undefined}
        >
          {active?.title ?? 'Agents'} {active ? '✎' : ''}
        </span>
        {active ? (
          <button onClick={() => setActive(null)} style={styles.barBtn} title="Select agent">
            ☰
          </button>
        ) : (
          <span style={{ width: 34 }} />
        )}
      </header>

      {status !== 'connected' ? (
        <div style={styles.disconnected}>
          <p style={styles.center}>Not connected to the PC.</p>
          <button
            type="button"
            onClick={() => void handleReconnect()}
            disabled={reconnecting || !hostUrl}
            style={styles.reconnectBtnLarge}
          >
            {reconnecting ? 'Reconnecting…' : 'Reconnect'}
          </button>
        </div>
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
              {a.available && <span style={styles.selectBtn}>Select</span>}
            </button>
          ))}
          <div style={styles.tabContainer}>
            <button
              type="button"
              onClick={() => setMenuTab('recent')}
              style={{
                ...styles.tabButton,
                ...(menuTab === 'recent' ? styles.tabButtonActive : {}),
              }}
            >
              Recent {sessions.length > 0 ? `(${sessions.length})` : ''}
            </button>
            <button
              type="button"
              onClick={() => setMenuTab('pc')}
              style={{
                ...styles.tabButton,
                ...(menuTab === 'pc' ? styles.tabButtonActive : {}),
              }}
            >
              PC {hostChats.length > 0 ? `(${hostChats.length})` : ''}
            </button>
          </div>
          {menuTab === 'recent' ? (
            sessions.length === 0 ? (
              <p style={styles.emptyTabMessage}>No recent chats yet. Start a new chat above.</p>
            ) : (
              sessions.map((s) => (
                <div
                  key={s.agentSessionId}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 8,
                    marginBottom: 8,
                  }}
                >
                  <button
                    type="button"
                    onClick={() => openSession(s)}
                    style={{ ...styles.row, marginBottom: 0, flex: 1 }}
                  >
                    <strong>{s.title}</strong>
                    <span style={styles.muted}>{s.cwd}</span>
                  </button>
                  <button
                    type="button"
                    onClick={() => setPicking({ kind: 'folder', session: s })}
                    title="Change folder"
                    style={styles.barBtn}
                  >
                    📁
                  </button>
                  <button
                    type="button"
                    onClick={() => void renameSession(s)}
                    title="Rename chat"
                    style={styles.barBtn}
                  >
                    ✎
                  </button>
                </div>
              ))
            )
          ) : (
            (() => {
              const visible = hostChats.filter(
                (c) => !sessions.some((s) => s.hostChatId && s.hostChatId === c.hostChatId),
              );
              if (visible.length === 0) {
                return <p style={styles.emptyTabMessage}>No PC conversations found.</p>;
              }
              return visible.map((c) => (
                <button key={`${c.agent}-${c.hostChatId}`} onClick={() => openHostChat(c)} style={styles.row}>
                  <strong>{c.title}</strong>
                  <span style={styles.muted}>
                    {[c.source, c.cwd, !c.resumable ? 'view only' : '']
                      .filter(Boolean)
                      .join(' · ')}
                  </span>
                </button>
              ));
            })()
          )}
        </div>
      ) : (
        <>
          <div ref={listRef} style={styles.chat}>
            {mergeToolEvents(events).map((e, i) => (
              <Bubble key={`${e.seq}-${i}`} e={e} />
            ))}
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
            <button type="submit" style={styles.send}>
              Send
            </button>
          </form>
        </>
      )}

      {picking && client && (
        <CwdPicker
          client={client}
          onCancel={() => setPicking(null)}
          onPick={(cwd) => void applyPickedCwd(cwd)}
        />
      )}
    </div>
  );
}

function CwdPicker({
  client,
  onPick,
  onCancel,
}: {
  client: RpcClient;
  onPick: (cwd: string) => void;
  onCancel: () => void;
}) {
  const [browse, setBrowse] = useState(false);
  const [home, setHome] = useState('/');
  const [cwd, setCwd] = useState('/');
  const [recentPath, setRecentPath] = useState<string | null>(null);
  const [projects, setProjects] = useState<ProjectInfo[]>([]);
  const [dirs, setDirs] = useState<DirEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [typed, setTyped] = useState('');
  const [entering, setEntering] = useState(false);

  const pick = useCallback(
    (path: string) => {
      saveLastAgentCwd(path);
      onPick(path);
    },
    [onPick],
  );

  useEffect(() => {
    let cancelled = false;
    (async () => {
      let homeDir = '/';
      try {
        const info = (await client.request('system.getInfo')) as { homeDir?: string };
        if (info.homeDir) homeDir = info.homeDir;
      } catch { /* keep / */ }
      const recent = loadLastAgentCwd();
      const seen = new Set<string>();
      const hints: ProjectInfo[] = [{ name: 'Home', path: homeDir }];
      seen.add(homeDir);
      if (recent) seen.add(recent);
      try {
        const listed = (await client.request('fs.listProjects')) as ProjectInfo[];
        for (const p of listed) {
          if (!p.path || seen.has(p.path)) continue;
          seen.add(p.path);
          hints.push(p);
        }
      } catch { /* suggestions optional */ }
      const sorted = [
        hints[0],
        ...hints.slice(1).sort((a, b) => comparePathNames(a.name, b.name)),
      ];
      if (!cancelled) {
        setHome(homeDir);
        setCwd(homeDir);
        setRecentPath(recent);
        setProjects(sorted);
        setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [client]);

  const listDir = useCallback(
    async (path: string) => {
      setLoading(true);
      setError('');
      setCwd(path);
      try {
        const entries = (await client.request('fs.list', { path })) as DirEntry[];
        setDirs(
          entries
            .filter((e) => e.isDirectory)
            .sort((a, b) => comparePathNames(a.name, b.name)),
        );
      } catch (e) {
        setDirs([]);
        setError(e instanceof Error ? e.message : 'Could not list folder');
      } finally {
        setLoading(false);
      }
    },
    [client],
  );

  const openBrowse = () => {
    setBrowse(true);
    void listDir(home);
  };

  return (
    <div style={styles.overlay} onClick={onCancel}>
      <div style={styles.sheet} onClick={(e) => e.stopPropagation()}>
        <div style={styles.sheetHead}>
          {browse ? (
            <button type="button" onClick={() => { setBrowse(false); setError(''); }} style={styles.barBtn}>
              ←
            </button>
          ) : (
            <span style={{ width: 34 }} />
          )}
          <strong>{browse ? 'Browse folders' : 'Working directory'}</strong>
          {browse ? (
            <button type="button" onClick={() => pick(cwd)} style={styles.selectBtn}>
              Use this folder
            </button>
          ) : (
            <button type="button" onClick={onCancel} style={styles.barBtn}>
              ✕
            </button>
          )}
        </div>
        {browse && (
          <div style={styles.pathRow}>
            <button
              type="button"
              disabled={cwd === '/'}
              onClick={() => void listDir(parentUnixPath(cwd))}
              style={styles.barBtn}
            >
              ↑
            </button>
            <span style={styles.pathText}>{cwd}</span>
          </div>
        )}
        <div style={styles.sheetBody}>
          {loading ? (
            <p style={styles.center}>Loading…</p>
          ) : error ? (
            <p style={styles.center}>{error}</p>
          ) : browse ? (
            dirs.length === 0 ? (
              <p style={styles.center}>No subfolders — use this folder, or go up.</p>
            ) : (
              dirs.map((d) => (
                <button key={d.path} type="button" onClick={() => void listDir(d.path)} style={styles.row}>
                  <strong>{d.name}</strong>
                </button>
              ))
            )
          ) : entering ? (
            <form
              onSubmit={(e) => {
                e.preventDefault();
                const path = typed.trim();
                if (path) pick(path);
              }}
            >
              <input
                autoFocus
                value={typed}
                onChange={(e) => setTyped(e.target.value)}
                placeholder="/home/you/project or ~/code"
                style={{ ...styles.input, width: '100%', marginBottom: 8 }}
              />
              <button type="submit" style={styles.send}>
                Use folder
              </button>
            </form>
          ) : (
            <>
              <button type="button" onClick={openBrowse} style={styles.row}>
                <strong>Browse folders</strong>
                <span style={styles.muted}>Any directory on the PC</span>
              </button>
              <button
                type="button"
                onClick={() => {
                  setEntering(true);
                  setTyped(home);
                }}
                style={styles.row}
              >
                <strong>Enter path</strong>
                <span style={styles.muted}>Type or paste a folder path</span>
              </button>
              <h2 style={styles.section}>Suggestions</h2>
              {recentPath && (
                <button
                  key={`recent-${recentPath}`}
                  type="button"
                  onClick={() => pick(recentPath)}
                  style={styles.row}
                >
                  <strong>{folderDisplayName(recentPath)}</strong>
                  <span style={styles.muted}>{recentPath}</span>
                </button>
              )}
              {projects
                .filter((p) => p.path !== recentPath)
                .map((p) => (
                  <button key={p.path} type="button" onClick={() => pick(p.path)} style={styles.row}>
                    <strong>{p.name}</strong>
                    <span style={styles.muted}>{p.path}</span>
                  </button>
                ))}
            </>
          )}
        </div>
      </div>
    </div>
  );
}

function Bubble({ e }: { e: AgentEvent }) {
  const [copied, setCopied] = useState(false);

  const handleCopy = () => {
    if (!e.text) return;
    let textToCopy = e.text;
    const fenceMatch = textToCopy.trim().match(/^```[a-zA-Z0-9_\-\.]*\r?\n([\s\S]*?)\r?\n?```$/);
    if (fenceMatch && fenceMatch[1] !== undefined) {
      textToCopy = fenceMatch[1].trim();
    }
    void navigator.clipboard.writeText(textToCopy);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  if (e.kind === 'user') {
    return <div style={{ ...styles.bubble, ...styles.user, userSelect: 'text', WebkitUserSelect: 'text' }}>{e.text}</div>;
  }
  if (e.kind === 'text' || (e.kind === 'result' && e.text)) {
    return (
      <div style={{ ...styles.bubble, ...styles.assistant, userSelect: 'text', WebkitUserSelect: 'text' }}>
        <pre style={{ margin: 0, whiteSpace: 'pre-wrap', wordBreak: 'break-word', fontFamily: 'inherit', userSelect: 'text', WebkitUserSelect: 'text' }}>
          {e.text}
        </pre>
        <div style={{ display: 'flex', justifyContent: 'flex-end', marginTop: 4 }}>
          <button
            type="button"
            onClick={handleCopy}
            title="Copy message"
            style={{
              background: 'transparent',
              border: 'none',
              color: copied ? '#4ade80' : '#888899',
              cursor: 'pointer',
              fontSize: 12,
              padding: '2px 6px',
              borderRadius: 4,
            }}
          >
            {copied ? '✓ Copied' : '📋 Copy'}
          </button>
        </div>
      </div>
    );
  }
  if (e.kind === 'thinking' || e.kind === 'status') {
    return <div style={styles.thinking}>{e.text || 'Thinking…'}</div>;
  }
  if (e.kind === 'tool-start' || e.kind === 'tool-end') {
    const detail = e.toolInput?.trim();
    const output = e.toolOutput?.trim();
    const running = e.kind === 'tool-start';
    return (
      <div style={styles.tool}>
        <strong>
          {running ? '▶' : '✓'} {e.toolName || 'tool'}
        </strong>
        {detail && detail !== e.toolName && <span style={styles.muted}>{detail}</span>}
        {!running && output && <pre style={styles.out}>{output}</pre>}
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
  disconnected: {
    flex: 1,
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 16,
    padding: 24,
  },
  reconnectBtnLarge: {
    padding: '10px 24px',
    borderRadius: 8,
    border: 'none',
    background: '#2a6aff',
    color: '#fff',
    fontSize: 13,
    fontWeight: 600,
    cursor: 'pointer',
  },
  list: { padding: 16, overflowY: 'auto' },
  tabContainer: {
    display: 'flex',
    gap: 4,
    background: '#151522',
    border: '1px solid #22223a',
    borderRadius: 10,
    padding: 3,
    margin: '16px 0 12px',
  },
  tabButton: {
    flex: 1,
    padding: '8px 12px',
    background: 'transparent',
    border: 'none',
    borderRadius: 8,
    color: '#888899',
    fontSize: 13,
    fontWeight: 500,
    cursor: 'pointer',
    textAlign: 'center',
  },
  tabButtonActive: {
    background: '#2a6aff',
    color: '#ffffff',
    fontWeight: 600,
  },
  emptyTabMessage: {
    textAlign: 'center',
    color: '#666677',
    fontSize: 13,
    margin: '24px 0',
  },
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
  selectBtn: {
    marginTop: 8,
    padding: '6px 12px',
    borderRadius: 8,
    background: '#2a6aff',
    color: '#fff',
    fontSize: 12,
    fontWeight: 600,
    alignSelf: 'flex-start',
  },
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
  overlay: {
    position: 'fixed',
    inset: 0,
    background: 'rgba(0,0,0,0.55)',
    display: 'flex',
    alignItems: 'flex-end',
    zIndex: 20,
  },
  sheet: {
    width: '100%',
    maxHeight: '78dvh',
    background: '#151522',
    borderTopLeftRadius: 16,
    borderTopRightRadius: 16,
    display: 'flex',
    flexDirection: 'column',
  },
  sheetHead: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 8,
    padding: '10px 12px',
    borderBottom: '1px solid #22223a',
  },
  pathRow: {
    display: 'flex',
    alignItems: 'center',
    gap: 8,
    padding: '6px 12px',
    borderBottom: '1px solid #1c1c30',
  },
  pathText: {
    fontSize: 12,
    fontFamily: 'ui-monospace, monospace',
    color: '#89a',
    overflow: 'hidden',
    textOverflow: 'ellipsis',
    whiteSpace: 'nowrap',
  },
  sheetBody: { overflowY: 'auto', padding: 12 },
};
