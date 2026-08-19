'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useConnectionStore } from '@/store/connection';
import type { RpcClient } from '@/lib/rpc-client';
import {
  comparePathNames,
  folderDisplayName,
  loadRecentAgentCwds,
  saveLastAgentCwd,
} from '@/lib/last-cwd';
import { isThisPcPath, parentHostPath } from '@/lib/host-path';
import { chatListSubtitle } from '@/lib/agent-labels';
import { mergeAgentHistory } from '@/lib/agent-history';
import {
  applyComposerPrefs,
  loadComposerPrefs,
  modeLabel,
  modelLabel,
  resolveAgentCaps,
  saveComposerPrefs,
  thinkingLabel,
  workingTreeSubtitle,
  type AgentCapabilities,
  type AgentModelOption,
  type GitWorkingTree,
} from '@/lib/agent-composer';

interface AgentInfo {
  id: string;
  name: string;
  available: boolean;
  icon?: string;
  capabilities?: AgentCapabilities;
}

interface AgentSessionInfo {
  agentSessionId: string;
  agent: string;
  cwd: string;
  title: string;
  busy: boolean;
  status: string;
  hostChatId?: string;
  icon?: string;
}

interface AgentHostChat {
  agent: string;
  hostChatId: string;
  title: string;
  cwd: string;
  updatedAt: number;
  resumable: boolean;
  source: string;
  icon?: string;
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


function getAgentThemeBackground(agentId?: string): string {
  switch (agentId) {
    case 'cursor': return '#101014';
    case 'antigravity': return '#2d1b4e';
    case 'claude': return '#3d2b1f';
    case 'opencode': return '#1c3330';
    default: return '#151522';
  }
}

function getUserThemeBackground(agentId?: string): string {
  switch (agentId) {
    case 'cursor': return '#4b5563'; // gray
    case 'antigravity': return '#9333ea'; // purple
    case 'claude': return '#d97757'; // terracotta/orange
    case 'opencode': return '#0d9488'; // teal
    default: return '#2a6aff'; // default blue
  }
}

function AgentIcon({
  agentId,
  name,
  icon,
  size = 32,
}: {
  agentId: string;
  name: string;
  icon?: string;
  size?: number;
}) {
  if (icon && icon.startsWith('data:image/')) {
    return (
      <div
        style={{
          width: size,
          height: size,
          borderRadius: Math.round(size * 0.22),
          overflow: 'hidden',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          flexShrink: 0,
        }}
      >
        <img
          src={icon}
          alt={name}
          style={{ width: '100%', height: '100%', objectFit: 'contain' }}
        />
      </div>
    );
  }

  let outlinePath = null;
  switch (agentId) {
    case 'claude':
      outlinePath = (
        <path
          fill="currentColor"
          d="M12 2l2.4 7.6L22 12l-7.6 2.4L12 22l-2.4-7.6L2 12l7.6-2.4L12 2z"
        />
      );
      break;
    case 'cursor':
      outlinePath = (
        <path
          fill="currentColor"
          d="M19.5 2.5a.6.6 0 0 1 .6.7l-1.3 19.8a.6.6 0 0 1-.9.4l-5.6-7.3a.6.6 0 0 0-.3-.2l-9.1-1.2a.6.6 0 0 1-.4-.9l16.2-11.2a.6.6 0 0 1 .8-.1z"
        />
      );
      break;
    case 'opencode':
      outlinePath = (
        <>
          <polyline points="4 17 10 11 4 5" />
          <line x1="12" x2="20" y1="19" y2="19" />
        </>
      );
      break;
    case 'antigravity':
      outlinePath = (
        <path
          fill="currentColor"
          d="M5.39 18.3c-.18-.07-.25-.16-.25-.32 0-.22.12-.42.5-.83.8-.85 1.35-1.87 1.92-3.59.18-.54.3-.97.9-2.99.35-1.23.66-2.13.97-2.78.55-1.14 1.19-1.77 2.01-1.98.2-.05.29-.06.58-.06.74 0 1.23.21 1.77.77.28.3.52.64.76 1.13.36.71.66 1.57 1.08 3.04.13.47.33 1.18.44 1.57.55 1.94 1.04 3.16 1.64 4.08.22.34.39.55.72.9.32.34.43.53.43.75 0 .12-.01.15-.06.21-.18.22-.58.24-.96.06-.46-.22-1.23-.89-1.74-1.53-.3-.38-.69-.98-1.13-1.73-.86-1.48-1.25-1.93-1.92-2.24-.33-.16-.52-.19-1.04-.19-.48 0-.58.01-.9.13-.42.16-.79.43-1.14.87-.25.31-.41.56-.87 1.35-.45.77-.85 1.4-1.11 1.73-.65.84-1.54 1.58-2.06 1.71-.15.04-.46.04-.56 0z"
        />
      );
      break;
  }

  if (outlinePath) {
    return (
      <div style={{ width: size, height: size, display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
        <svg
          width={size * 0.75}
          height={size * 0.75}
          viewBox="0 0 24 24"
          fill="none"
          stroke={agentId === 'opencode' ? 'currentColor' : 'none'}
          strokeWidth="1.5"
          strokeLinecap="round"
          strokeLinejoin="round"
          style={{ opacity: 0.9 }}
        >
          {outlinePath}
        </svg>
      </div>
    );
  }

  const letter = (name || '?').trim().charAt(0).toUpperCase();
  const hue = (name.charCodeAt(0) * 47) % 360;
  return (
    <span
      style={{
        width: size,
        height: size,
        borderRadius: 8,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        fontSize: size * 0.45,
        fontWeight: 700,
        color: '#fff',
        background: `linear-gradient(135deg, hsl(${hue},45%,38%), hsl(${(hue + 40) % 360},50%,26%))`,
        flexShrink: 0,
      }}
    >
      {letter}
    </span>
  );
}

function parentUnixPath(path: string): string {
  return parentHostPath(path);
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
  const [composerOpen, setComposerOpen] = useState(false);
  const [composerView, setComposerView] = useState<'root' | 'model' | 'thinking' | 'mode' | 'agent'>('root');
  const [mode, setMode] = useState('agent');
  const [thinking, setThinking] = useState('medium');
  const [model, setModel] = useState<string | null>(null);
  const [liveModels, setLiveModels] = useState<AgentModelOption[]>([]);
  const [photos, setPhotos] = useState<{ name: string; mime: string; data: string }[]>([]);
  const [gitTree, setGitTree] = useState<GitWorkingTree | null>(null);
  const listRef = useRef<HTMLDivElement | null>(null);
  const photoRef = useRef<HTMLInputElement | null>(null);
  const unsubRef = useRef<(() => void) | null>(null);
  const activeIdRef = useRef<string | null>(null);
  const refreshLockRef = useRef(false);
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

  const refreshFromHost = useCallback(async (quiet = false) => {
    if (status !== 'connected' || !client || refreshLockRef.current) return;
    refreshLockRef.current = true;
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
      setAgents(a);
      setSessions(s);
      setHostChats(host);
      const activeId = activeIdRef.current;
      if (!activeId) return;
      const match = s.find((x) => x.agentSessionId === activeId);
      if (match) setActive(match);
      const history = (await client.request('agent.history', {
        agentSessionId: activeId,
      })) as AgentEvent[];
      setEvents((prev) => mergeAgentHistory(history, prev));
    } catch (e) {
      if (!quiet) setError(e instanceof Error ? e.message : 'Could not list agents.');
    } finally {
      refreshLockRef.current = false;
    }
  }, [status, client]);

  useEffect(() => {
    if (status !== 'connected' || !client) return;
    void refreshFromHost();
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
      for (const u of unsubs) u();
    };
  }, [status, client, refreshFromHost]);

  useEffect(() => {
    const onVisible = () => {
      if (document.visibilityState === 'visible') void refreshFromHost(true);
    };
    document.addEventListener('visibilitychange', onVisible);
    window.addEventListener('pageshow', onVisible);
    return () => {
      document.removeEventListener('visibilitychange', onVisible);
      window.removeEventListener('pageshow', onVisible);
    };
  }, [refreshFromHost]);

  useEffect(() => {
    listRef.current?.scrollTo({ top: listRef.current.scrollHeight, behavior: 'smooth' });
  }, [events.length]);

  const caps = resolveAgentCaps(
    active?.agent ?? '',
    agents.find((a) => a.id === active?.agent)?.capabilities,
    liveModels,
  );
  const prefsAgentRef = useRef<string | null>(null);

  useEffect(() => {
    if (!active) {
      setLiveModels([]);
      setGitTree(null);
      setPhotos([]);
      setComposerOpen(false);
      prefsAgentRef.current = null;
      return;
    }
    const next = applyComposerPrefs(
      resolveAgentCaps(active.agent, agents.find((a) => a.id === active.agent)?.capabilities),
      loadComposerPrefs(active.agent),
    );
    setMode(next.mode);
    setThinking(next.thinking);
    setModel(next.model);
    setPhotos([]);
    setLiveModels([]);
    prefsAgentRef.current = active.agent;
    if (!client) return;
    void client
      .request('agent.listModels', { agent: active.agent })
      .then((raw) => {
        if (Array.isArray(raw) && raw.length) setLiveModels(raw as AgentModelOption[]);
      })
      .catch(() => {});
  }, [active?.agentSessionId, active?.agent, client]);

  useEffect(() => {
    if (!active || prefsAgentRef.current !== active.agent) return;
    saveComposerPrefs(active.agent, { mode, thinking, model });
  }, [active, mode, thinking, model]);

  const refreshGit = useCallback(async () => {
    if (!client || !active?.cwd) {
      setGitTree(null);
      return;
    }
    try {
      const raw = await client.request('fs.gitStatus', { cwd: active.cwd });
      setGitTree(raw && typeof raw === 'object' ? (raw as GitWorkingTree) : null);
    } catch {
      setGitTree(null);
    }
  }, [client, active?.cwd]);

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
    if ((!text && photos.length === 0) || !client || !active) return;
    setDraft('');
    const attached = photos;
    setPhotos([]);
    const currentTitle = (active.title || '').trim();
    const isDefault =
      !currentTitle ||
      currentTitle === 'Agent' ||
      currentTitle === 'Host chat' ||
      agents.some((a) => a.name === currentTitle || a.id === currentTitle);
    if (isDefault && text) {
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
      ...(model && model !== 'auto' && model !== 'default' ? { model } : {}),
      ...(mode !== 'agent' ? { mode } : {}),
      ...(thinking ? { thinking } : {}),
      ...(attached.length ? { images: attached } : {}),
    });
  }, [draft, photos, client, active, agents, model, mode, thinking]);

  return (
    <div style={styles.wrapper}>
      <header style={styles.topBar}>
        <button onClick={() => (active ? setActive(null) : router.push('/'))} style={styles.barBtn}>
          {active ? '←' : '⌂'}
        </button>
        <div
          onClick={() => active && void renameSession(active)}
          style={{
            ...styles.title,
            cursor: active ? 'pointer' : 'default',
            display: 'flex',
            alignItems: 'center',
            gap: 8,
          }}
          title={active ? 'Click to rename' : undefined}
        >
          {active && (
            <AgentIcon
              agentId={active.agent}
              name={active.title}
              icon={active.icon}
              size={22}
            />
          )}
          <span>{active?.title ?? 'Agents'} {active ? '✎' : ''}</span>
        </div>
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
              <AgentIcon agentId={a.id} name={a.name} icon={a.icon} />
              <div style={{ flex: 1, display: 'flex', flexDirection: 'column' }}>
                <strong>{a.name}</strong>
                <span style={styles.muted}>
                  {a.available ? 'Runs on the PC — chat here' : 'CLI not installed on the PC'}
                </span>
                {a.available && <span style={styles.selectBtn}>Select</span>}
              </div>
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
                    <AgentIcon agentId={s.agent} name={s.title} icon={s.icon} />
                    <div style={{ flex: 1, display: 'flex', flexDirection: 'column' }}>
                      <strong>{s.title}</strong>
                      <span style={styles.muted}>
                        {chatListSubtitle({ agent: s.agent, cwd: s.cwd })}
                      </span>
                    </div>
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
                  <AgentIcon agentId={c.agent} name={c.title} icon={c.icon} />
                  <div style={{ flex: 1, display: 'flex', flexDirection: 'column' }}>
                    <strong>{c.title}</strong>
                    <span style={styles.muted}>
                      {chatListSubtitle({
                        agent: c.agent,
                        source: c.source,
                        cwd: c.cwd,
                        resumable: c.resumable,
                      })}
                    </span>
                  </div>
                </button>
              ));
            })()
          )}
        </div>
      ) : (
        <>
          <div ref={listRef} style={styles.chat}>
            {mergeToolEvents(events).map((e, i) => (
              <Bubble key={`${e.seq}-${i}`} e={e} agentId={active.agent} />
            ))}
          </div>
          <form
            style={styles.composerBox}
            onSubmit={(ev) => {
              ev.preventDefault();
              void send();
            }}
          >
            {photos.length > 0 && (
              <div style={styles.thumbs}>
                {photos.map((p, i) => (
                  <button
                    key={`${p.name}-${i}`}
                    type="button"
                    style={styles.thumb}
                    onClick={() => setPhotos((prev) => prev.filter((_, j) => j !== i))}
                    title="Remove photo"
                  >
                    {p.name}
                  </button>
                ))}
              </div>
            )}
            <input
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              placeholder={photos.length ? 'Add a note about the photo…' : 'Message the agent…'}
              style={styles.composerField}
            />
            <div style={styles.composerRow}>
              <button
                type="button"
                style={styles.plusBtn}
                title="Photo, model, thinking, folder…"
                onClick={() => {
                  setComposerView('root');
                  setComposerOpen(true);
                  void refreshGit();
                }}
              >
                +
              </button>
              <span style={{ flex: 1 }} />
              <button type="submit" style={styles.send}>
                Send
              </button>
            </div>
            <input
              ref={photoRef}
              type="file"
              accept="image/*"
              multiple
              hidden
              onChange={(e) => {
                const files = [...(e.target.files ?? [])].slice(0, 4 - photos.length);
                e.target.value = '';
                for (const file of files) {
                  const reader = new FileReader();
                  reader.onload = () => {
                    const result = String(reader.result || '');
                    const data = result.includes(',') ? result.slice(result.indexOf(',') + 1) : result;
                    if (!data) return;
                    setPhotos((prev) => [
                      ...prev,
                      { name: file.name || 'photo.jpg', mime: file.type || 'image/jpeg', data },
                    ].slice(0, 4));
                  };
                  reader.readAsDataURL(file);
                }
              }}
            />
          </form>
        </>
      )}

      {composerOpen && active && (
        <ComposerMenu
          view={composerView}
          setView={setComposerView}
          caps={caps}
          mode={mode}
          thinking={thinking}
          model={model}
          git={gitTree}
          cwd={active.cwd}
          agents={agents}
          activeAgent={active.agent}
          onClose={() => setComposerOpen(false)}
          onPhoto={() => {
            setComposerOpen(false);
            photoRef.current?.click();
          }}
          onFolder={() => {
            setComposerOpen(false);
            setPicking({ kind: 'folder', session: active });
          }}
          onMode={(v) => { setMode(v); setComposerView('root'); }}
          onThinking={(v) => { setThinking(v); setComposerView('root'); }}
          onModel={(v) => { setModel(v); setComposerView('root'); }}
          onAgent={(agent) => {
            setComposerOpen(false);
            if (agent.id === active.agent) return;
            setPicking(null);
            void (async () => {
              if (!client) return;
              const cwd = active.cwd;
              const created = (await client.request('agent.createSession', {
                agent: agent.id,
                title: agent.name,
                cwd,
              })) as AgentSessionInfo;
              setSessions((s) => [created, ...s.filter((x) => x.agentSessionId !== created.agentSessionId)]);
              setActive(created);
              setEvents([]);
            })();
          }}
        />
      )}

      {picking && client && (
        <CwdPicker
          client={client}
          hostUrl={hostUrl}
          onCancel={() => setPicking(null)}
          onPick={(cwd) => void applyPickedCwd(cwd)}
        />
      )}
    </div>
  );
}

function ComposerMenu({
  view,
  setView,
  caps,
  mode,
  thinking,
  model,
  git,
  cwd,
  agents,
  activeAgent,
  onClose,
  onPhoto,
  onFolder,
  onMode,
  onThinking,
  onModel,
  onAgent,
}: {
  view: 'root' | 'model' | 'thinking' | 'mode' | 'agent';
  setView: (v: 'root' | 'model' | 'thinking' | 'mode' | 'agent') => void;
  caps: ReturnType<typeof resolveAgentCaps>;
  mode: string;
  thinking: string;
  model: string | null;
  git: GitWorkingTree | null;
  cwd: string;
  agents: AgentInfo[];
  activeAgent: string;
  onClose: () => void;
  onPhoto: () => void;
  onFolder: () => void;
  onMode: (v: string) => void;
  onThinking: (v: string) => void;
  onModel: (v: string) => void;
  onAgent: (agent: AgentInfo) => void;
}) {
  const title =
    view === 'model' ? 'Model'
    : view === 'thinking' ? 'Thinking'
    : view === 'mode' ? 'Mode'
    : view === 'agent' ? 'Agent'
    : 'Add to this turn';
  return (
    <div style={styles.overlay} onClick={onClose}>
      <div style={styles.sheet} onClick={(e) => e.stopPropagation()}>
        <div style={styles.sheetHead}>
          {view === 'root' ? (
            <span style={{ width: 34 }} />
          ) : (
            <button type="button" onClick={() => setView('root')} style={styles.barBtn}>←</button>
          )}
          <strong>{title}</strong>
          <button type="button" onClick={onClose} style={styles.barBtn}>✕</button>
        </div>
        <div style={styles.sheetBody}>
          {view === 'root' && (
            <>
              <button type="button" style={styles.menuRow} onClick={onPhoto}>
                <strong>Photo</strong>
                <span style={styles.menuSub}>Attach from this phone</span>
              </button>
              {cwd.trim() ? (
                <button type="button" style={styles.menuRow} onClick={onFolder}>
                  <strong>{git ? `Working tree · ${folderDisplayName(cwd)}` : folderDisplayName(cwd)}</strong>
                  <span style={styles.menuSub}>{git ? workingTreeSubtitle(git) : cwd}</span>
                  {git?.files.slice(0, 4).map((f) => (
                    <span key={f} style={styles.menuFile}>{f}</span>
                  ))}
                </button>
              ) : null}
              <button type="button" style={styles.menuRow} onClick={() => setView('model')}>
                <strong>Model</strong>
                <span style={styles.menuSub}>{modelLabel(model, caps.models)}</span>
              </button>
              <button type="button" style={styles.menuRow} onClick={() => setView('thinking')}>
                <strong>Thinking</strong>
                <span style={styles.menuSub}>{thinkingLabel(thinking)}</span>
              </button>
              {caps.modes.length > 1 ? (
                <button type="button" style={styles.menuRow} onClick={() => setView('mode')}>
                  <strong>Mode</strong>
                  <span style={styles.menuSub}>{modeLabel(mode)}</span>
                </button>
              ) : null}
              <button type="button" style={styles.menuRow} onClick={() => setView('agent')}>
                <strong>Agent</strong>
                <span style={styles.menuSub}>
                  {agents.find((a) => a.id === activeAgent)?.name ?? 'Switch agent'}
                </span>
              </button>
            </>
          )}
          {view === 'model' && caps.models.map((m) => (
            <button key={m.id} type="button" style={styles.menuRow} onClick={() => onModel(m.id)}>
              <strong>{m.name}</strong>
              <span style={styles.menuSub}>{m.id}{m.id === model ? ' · selected' : ''}</span>
            </button>
          ))}
          {view === 'thinking' && caps.thinkingLevels.map((level) => (
            <button key={level} type="button" style={styles.menuRow} onClick={() => onThinking(level)}>
              <strong>{thinkingLabel(level)}</strong>
              {level === thinking ? <span style={styles.menuSub}>selected</span> : null}
            </button>
          ))}
          {view === 'mode' && caps.modes.map((m) => (
            <button key={m} type="button" style={styles.menuRow} onClick={() => onMode(m)}>
              <strong>{modeLabel(m)}</strong>
              {m === mode ? <span style={styles.menuSub}>selected</span> : null}
            </button>
          ))}
          {view === 'agent' && agents.map((a) => (
            <button
              key={a.id}
              type="button"
              disabled={!a.available}
              style={styles.menuRow}
              onClick={() => onAgent(a)}
            >
              <strong>{a.name}</strong>
              <span style={styles.menuSub}>
                {a.id === activeAgent ? 'This chat' : a.available ? 'New chat in this folder' : 'Not installed on the PC'}
              </span>
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

function CwdPicker({
  client,
  hostUrl,
  onPick,
  onCancel,
}: {
  client: RpcClient;
  hostUrl: string;
  onPick: (cwd: string) => void;
  onCancel: () => void;
}) {
  const [browse, setBrowse] = useState(false);
  const [home, setHome] = useState('/');
  const [cwd, setCwd] = useState('/');
  const [recentPaths, setRecentPaths] = useState<string[]>([]);
  const [projects, setProjects] = useState<ProjectInfo[]>([]);
  const [dirs, setDirs] = useState<DirEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [typed, setTyped] = useState('');
  const [entering, setEntering] = useState(false);

  const pick = useCallback(
    (path: string) => {
      saveLastAgentCwd(path, hostUrl);
      onPick(path);
    },
    [onPick, hostUrl],
  );

  useEffect(() => {
    let cancelled = false;
    (async () => {
      let homeDir = '/';
      try {
        const info = (await client.request('system.getInfo')) as { homeDir?: string };
        if (info.homeDir) homeDir = info.homeDir;
      } catch { /* keep / */ }
      const recent = loadRecentAgentCwds(hostUrl);
      const seen = new Set<string>();
      const hints: ProjectInfo[] = [];
      seen.add(homeDir);
      for (const path of recent) seen.add(path);
      try {
        const listed = (await client.request('fs.listProjects')) as ProjectInfo[];
        for (const p of listed) {
          if (!p.path || seen.has(p.path)) continue;
          seen.add(p.path);
          hints.push(p);
        }
      } catch { /* suggestions optional */ }
      const sorted: ProjectInfo[] = [
        ...hints.slice().sort((a, b) => comparePathNames(a.name, b.name)),
        { name: 'Home', path: homeDir },
      ];
      if (!cancelled) {
        setHome(homeDir);
        setCwd(homeDir);
        setRecentPaths(recent);
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
              disabled={isThisPcPath(cwd)}
              onClick={() => void listDir(parentHostPath(cwd))}
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
                placeholder="D:/projects/foo or ~/code"
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
              <button type="button" onClick={() => { setBrowse(true); void listDir('/'); }} style={styles.row}>
                <strong>This PC</strong>
                <span style={styles.muted}>C:/, D:/ and other drives</span>
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
              {recentPaths.length > 0 && (
                <>
                  <h2 style={styles.section}>Recent</h2>
                  {recentPaths.map((path) => (
                    <button
                      key={`recent-${path}`}
                      type="button"
                      onClick={() => pick(path)}
                      style={styles.row}
                    >
                      <strong>{folderDisplayName(path)}</strong>
                      <span style={styles.muted}>{path}</span>
                    </button>
                  ))}
                </>
              )}
              <h2 style={styles.section}>Suggestions</h2>
              {projects
                .filter((p) => !recentPaths.includes(p.path))
                .map((p) => (
                  <button key={p.path} type="button" onClick={() => pick(p.path)} style={styles.row}>
                    <strong>{p.name}</strong>
                    <span style={styles.muted}>
                      {p.path === home ? 'Your user folder — not a project' : p.path}
                    </span>
                  </button>
                ))}
            </>
          )}
        </div>
      </div>
    </div>
  );
}

function Bubble({ e, agentId }: { e: AgentEvent; agentId?: string }) {
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
    return <div style={{ ...styles.bubble, ...styles.user, background: getUserThemeBackground(agentId), userSelect: 'text', WebkitUserSelect: 'text' }}>{e.text}</div>;
  }
  if (e.kind === 'text' || (e.kind === 'result' && e.text)) {
    return (
      <div style={{ ...styles.bubble, ...styles.assistant, background: getAgentThemeBackground(agentId), userSelect: 'text', WebkitUserSelect: 'text' }}>
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
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
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
  user: { marginLeft: 'auto', background: '#9333ea', color: '#fff' },
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
  composerBox: {
    display: 'flex',
    flexDirection: 'column',
    gap: 4,
    margin: '8px 10px calc(8px + env(safe-area-inset-bottom))',
    padding: '8px 8px 6px',
    borderRadius: 16,
    border: '1px solid #2a2a40',
    background: '#151522',
  },
  composerField: {
    width: '100%',
    padding: '8px',
    border: 'none',
    background: 'transparent',
    color: '#eee',
    fontSize: 14,
    outline: 'none',
  },
  composerRow: {
    display: 'flex',
    alignItems: 'center',
    gap: 8,
  },
  plusBtn: {
    width: 36,
    height: 36,
    borderRadius: 18,
    border: '1px solid #2a2a40',
    background: '#1c1c2a',
    color: '#eee',
    fontSize: 22,
    lineHeight: '32px',
    cursor: 'pointer',
  },
  thumbs: { display: 'flex', gap: 8, padding: '0 4px 4px', flexWrap: 'wrap' },
  thumb: {
    fontSize: 11,
    color: '#ccc',
    background: '#1c1c2a',
    border: '1px solid #2a2a40',
    borderRadius: 8,
    padding: '6px 8px',
    cursor: 'pointer',
  },
  menuRow: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'flex-start',
    gap: 2,
    width: '100%',
    padding: '12px 14px',
    border: 'none',
    borderBottom: '1px solid #1c1c30',
    background: 'transparent',
    color: '#eee',
    textAlign: 'left',
    cursor: 'pointer',
  },
  menuSub: { fontSize: 12, color: '#889' },
  menuFile: { fontSize: 11, color: '#8a8a9a', fontFamily: 'ui-monospace, monospace' },
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
