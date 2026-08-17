'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import '@xterm/xterm/css/xterm.css';
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import { useRouter } from 'next/navigation';
import type { AgentId, AgentInfo } from '@nexuslink/rpc-types';
import { useConnectionStore } from '@/store/connection';
import { AGENT_TOOLBAR_KEYS, AGENT_UI, agentUi } from '@/lib/agent-registry';

interface ChatMessage {
  id: string;
  role: 'user' | 'assistant' | 'system';
  text: string;
  streaming?: boolean;
}

function b64decode(str: string): string {
  try {
    return atob(str);
  } catch {
    return str;
  }
}

export default function AgentContent() {
  const client = useConnectionStore((s) => s.client);
  const status = useConnectionStore((s) => s.status);
  const connect = useConnectionStore((s) => s.connect);
  const hostUrl = useConnectionStore((s) => s.hostUrl);
  const router = useRouter();

  const [agents, setAgents] = useState<AgentInfo[]>([]);
  const [selectedId, setSelectedId] = useState<AgentId>('cursor');
  const [mode, setMode] = useState<'chat' | 'terminal'>('chat');
  const [cwd, setCwd] = useState('~');
  const [prompt, setPrompt] = useState('');
  const [continueSession, setContinueSession] = useState(false);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [running, setRunning] = useState(false);
  const [runId, setRunId] = useState<string | null>(null);
  const [loadError, setLoadError] = useState('');
  const [terminalReady, setTerminalReady] = useState(false);

  const termRef = useRef<Terminal | null>(null);
  const fitAddonRef = useRef<FitAddon | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const terminalIdRef = useRef<string | null>(null);
  const chatEndRef = useRef<HTMLDivElement>(null);
  const ctrlRef = useRef(false);
  const shiftRef = useRef(false);
  const [ctrlActive, setCtrlActive] = useState(false);
  const [shiftActive, setShiftActive] = useState(false);

  const selected = agentUi(selectedId);
  const selectedInfo = agents.find((a) => a.id === selectedId);
  const connected = status === 'connected' && !!client;

  const refreshAgents = useCallback(async () => {
    if (!client || status !== 'connected') return;
    setLoadError('');
    try {
      const list = (await client.request('agent.list')) as AgentInfo[];
      setAgents(list);
      const firstInstalled = list.find((a) => a.installed);
      if (firstInstalled && !list.find((a) => a.id === selectedId)?.installed) {
        setSelectedId(firstInstalled.id);
      }
    } catch (err) {
      setLoadError(err instanceof Error ? err.message : 'Failed to load agents');
    }
  }, [client, status, selectedId]);

  useEffect(() => {
    if (!connected || !client) return;
    void refreshAgents();
    client
      .request('system.getInfo')
      .then((info) => {
        const home = (info as { homeDir?: string }).homeDir;
        if (home) setCwd(home);
      })
      .catch(() => {});
  }, [connected, client, refreshAgents]);

  useEffect(() => {
    chatEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages]);

  useEffect(() => {
    if (selectedInfo && !selectedInfo.supportsChat && mode === 'chat') {
      setMode('terminal');
    }
  }, [selectedInfo, mode]);

  const handleReconnect = useCallback(async () => {
    if (!hostUrl) return;
    try {
      await connect(hostUrl);
    } catch {
      /* store handles */
    }
  }, [connect, hostUrl]);

  const appendAssistantChunk = useCallback((chunk: string) => {
    setMessages((prev) => {
      const next = [...prev];
      const last = next[next.length - 1];
      if (last?.role === 'assistant' && last.streaming) {
        next[next.length - 1] = { ...last, text: last.text + chunk };
        return next;
      }
      return [...next, { id: crypto.randomUUID(), role: 'assistant', text: chunk, streaming: true }];
    });
  }, []);

  const finishAssistant = useCallback((exitCode?: number) => {
    setMessages((prev) => {
      const next = [...prev];
      const last = next[next.length - 1];
      if (last?.role === 'assistant' && last.streaming) {
        const suffix =
          exitCode !== undefined && exitCode !== 0 ? `\n\n(exited with code ${exitCode})` : '';
        next[next.length - 1] = { ...last, text: last.text + suffix, streaming: false };
      }
      return next;
    });
    setRunning(false);
    setRunId(null);
  }, []);

  const sendChatPrompt = useCallback(
    async (text: string, useContinue = continueSession) => {
      if (!client || !text.trim() || running) return;
      const trimmed = text.trim();
      setPrompt('');
      setMessages((prev) => [
        ...prev,
        { id: crypto.randomUUID(), role: 'user', text: trimmed },
        { id: crypto.randomUUID(), role: 'assistant', text: '', streaming: true },
      ]);
      setRunning(true);
      try {
        const result = (await client.request('agent.run', {
          agentId: selectedId,
          prompt: trimmed,
          cwd: cwd === '~' ? undefined : cwd,
          continueSession: useContinue,
        })) as { runId: string };
        setRunId(result.runId);
      } catch (err) {
        finishAssistant(1);
        setMessages((prev) => {
          const next = [...prev];
          const last = next[next.length - 1];
          if (last?.role === 'assistant' && last.streaming) {
            next[next.length - 1] = {
              ...last,
              text: err instanceof Error ? err.message : 'Agent run failed',
              streaming: false,
            };
          }
          return next;
        });
      }
    },
    [client, running, selectedId, cwd, continueSession, finishAssistant],
  );

  useEffect(() => {
    if (!client || !runId) return;
    const unsub = client.subscribe('agent-output', (msg: unknown) => {
      const m = msg as { runId?: string; data?: string; done?: boolean; exitCode?: number };
      if (m.runId !== runId) return;
      if (m.data) appendAssistantChunk(m.data);
      if (m.done) finishAssistant(m.exitCode);
    });
    return unsub;
  }, [client, runId, appendAssistantChunk, finishAssistant]);

  const cancelRun = useCallback(async () => {
    if (!client || !runId) return;
    await client.request('agent.cancel', { runId }).catch(() => {});
    finishAssistant(130);
  }, [client, runId, finishAssistant]);

  const sendTerminalKey = useCallback(
    (code: string, isModifier?: boolean) => {
      const tid = terminalIdRef.current;
      if (!tid || !client) return;

      if (isModifier && code === 'CTRL') {
        const next = !ctrlRef.current;
        ctrlRef.current = next;
        setCtrlActive(next);
        return;
      }
      if (isModifier && code === 'SHIFT') {
        const next = !shiftRef.current;
        shiftRef.current = next;
        setShiftActive(next);
        return;
      }
      if (code === 'CTRL_D') {
        client.request('terminal.input', { terminalId: tid, data: '\x04' }).catch(() => {});
        return;
      }

      let data = code;
      if (ctrlRef.current) {
        if (data.length === 1) data = String.fromCharCode(data.charCodeAt(0) & 0x1f);
        ctrlRef.current = false;
        setCtrlActive(false);
      }
      if (shiftRef.current && data.length === 1 && data >= 'a' && data <= 'z') {
        data = data.toUpperCase();
        shiftRef.current = false;
        setShiftActive(false);
      }

      client.request('terminal.input', { terminalId: tid, data }).catch(() => {});
    },
    [client],
  );

  useEffect(() => {
    if (!connected || !client || mode !== 'terminal' || !containerRef.current) return;
    const c = client;
    let disposed = false;

    async function setupTerminal() {
      setTerminalReady(false);
      const term = new Terminal({
        cursorBlink: true,
        fontSize: 13,
        fontFamily: "'Cascadia Code', 'Fira Code', 'JetBrains Mono', monospace",
        theme: {
          background: '#0a0a0f',
          foreground: '#e8e8ef',
          cursor: selected.accent,
          selectionBackground: '#2a6aff44',
        },
      });
      const fitAddon = new FitAddon();
      term.loadAddon(fitAddon);
      termRef.current = term;
      fitAddonRef.current = fitAddon;

      if (containerRef.current) {
        term.open(containerRef.current);
        fitAddon.fit();
      }

      term.onData((data) => {
        const tid = terminalIdRef.current;
        if (!tid) return;
        c.request('terminal.input', { terminalId: tid, data }).catch(() => {});
      });

      try {
        const info = (await c.request('agent.list')) as AgentInfo[];
        const agent = info.find((a) => a.id === selectedId);
        if (!agent?.path) {
          term.write(`${selected.label} is not installed on your PC.\r\n`);
          term.write(`${agent?.installHint ?? selectedInfo?.installHint ?? ''}\r\n`);
          return;
        }

        const result = (await c.request('terminal.create', {
          cols: term.cols,
          rows: term.rows,
          command: agent.path,
          args: [],
          cwd: cwd === '~' ? undefined : cwd,
        })) as { terminalId: string };

        terminalIdRef.current = result.terminalId;
        setTerminalReady(true);

        const unsub = c.subscribe('terminal-output', (msg: unknown) => {
          if (disposed) return;
          const m = msg as { terminalId?: string; data?: string };
          if (m.terminalId !== result.terminalId || !m.data) return;
          term.write(b64decode(m.data));
        });

        return () => unsub();
      } catch (err) {
        term.write(`Failed to start ${selected.label}: ${err instanceof Error ? err.message : 'unknown error'}\r\n`);
      }
    }

    const cleanupPromise = setupTerminal();

    return () => {
      disposed = true;
      void cleanupPromise.then((cleanup) => cleanup?.());
      const tid = terminalIdRef.current;
      if (tid && c) c.request('terminal.kill', { terminalId: tid }).catch(() => {});
      terminalIdRef.current = null;
      termRef.current?.dispose();
      termRef.current = null;
      fitAddonRef.current = null;
      setTerminalReady(false);
    };
  }, [connected, client, mode, selectedId, cwd, selected.accent, selected.label, selectedInfo?.installHint]);

  useEffect(() => {
    if (!client || mode !== 'terminal') return;
    function handleResize() {
      setTimeout(() => {
        fitAddonRef.current?.fit();
        const tid = terminalIdRef.current;
        if (tid && termRef.current) {
          client!
            .request('terminal.resize', {
              terminalId: tid,
              cols: termRef.current.cols,
              rows: termRef.current.rows,
            })
            .catch(() => {});
        }
      }, 50);
    }
    const observer = new ResizeObserver(handleResize);
    const el = containerRef.current;
    if (el) observer.observe(el);
    window.addEventListener('orientationchange', handleResize);
    return () => {
      observer.disconnect();
      window.removeEventListener('orientationchange', handleResize);
    };
  }, [client, mode]);

  const launchQuickAction = useCallback(
    (actionId: string) => {
      const action = selected.quickActions?.find((a) => a.id === actionId);
      if (!action) return;
      if (action.externalUrl) {
        window.open(action.externalUrl, '_blank', 'noopener,noreferrer');
        return;
      }
      if (action.prompt) {
        void sendChatPrompt(action.prompt, action.id === 'continue');
        setMode('chat');
        return;
      }
      if (action.terminalCommand) {
        setMode('terminal');
        setTimeout(() => {
          const tid = terminalIdRef.current;
          if (tid && client) {
            client.request('terminal.input', { terminalId: tid, data: action.terminalCommand! }).catch(() => {});
          }
        }, 800);
      }
    },
    [selected.quickActions, sendChatPrompt, client],
  );

  if (!connected) {
    return (
      <div style={styles.wrapper}>
        <header style={styles.topBar}>
          <button onClick={() => router.back()} style={styles.backBtn}>← Back</button>
          <span style={styles.title}>Agents</span>
        </header>
        <div style={styles.centered}>
          <span style={{ fontSize: 36 }}>⌁</span>
          <p style={styles.muted}>Connect to your PC to use coding agents.</p>
          <button onClick={handleReconnect} style={styles.primaryBtn}>Reconnect</button>
        </div>
      </div>
    );
  }

  return (
    <div style={styles.wrapper}>
      <header style={styles.topBar}>
        <button onClick={() => router.back()} style={styles.backBtn}>← Back</button>
        <span style={styles.title}>Agents</span>
        <button onClick={() => void refreshAgents()} style={styles.iconBtn} aria-label="Refresh agents">↻</button>
      </header>

      <div style={styles.agentPicker}>
        {AGENT_UI.map((agent) => {
          const info = agents.find((a) => a.id === agent.id);
          const active = selectedId === agent.id;
          return (
            <button
              key={agent.id}
              style={{
                ...styles.agentChip,
                borderColor: active ? agent.accent : '#2a2a3a',
                background: active ? `${agent.accent}22` : '#12121c',
              }}
              onClick={() => setSelectedId(agent.id)}
            >
              <span style={{ color: agent.accent, fontSize: 16 }}>{agent.icon}</span>
              <span style={styles.chipLabel}>{agent.shortLabel}</span>
              <span
                style={{
                  ...styles.chipDot,
                  background: info?.installed ? '#4ade80' : '#ef4444',
                }}
              />
            </button>
          );
        })}
      </div>

      <div style={styles.metaRow}>
        <div style={styles.metaBlock}>
          <span style={styles.metaLabel}>Status</span>
          <span style={{ color: selectedInfo?.installed ? '#4ade80' : '#f87171', fontSize: 12, fontWeight: 600 }}>
            {selectedInfo?.installed ? 'Installed' : 'Not found'}
          </span>
        </div>
        <div style={{ ...styles.metaBlock, flex: 1 }}>
          <span style={styles.metaLabel}>Project</span>
          <input
            value={cwd}
            onChange={(e) => setCwd(e.target.value)}
            style={styles.cwdInput}
            spellCheck={false}
          />
        </div>
      </div>

      {!selectedInfo?.installed && (
        <div style={styles.installBanner}>
          <strong>{selected.label}</strong> is not on your PC PATH.
          <div style={{ marginTop: 6, fontSize: 12, color: '#cbd5e1' }}>
            {selectedInfo?.installHint}
          </div>
        </div>
      )}

      {loadError && <div style={styles.errorBanner}>{loadError}</div>}

      <div style={styles.modeRow}>
        {(['chat', 'terminal'] as const).map((m) => {
          const disabled = m === 'chat' && selectedInfo && !selectedInfo.supportsChat;
          return (
            <button
              key={m}
              disabled={!!disabled}
              style={{
                ...styles.modeBtn,
                opacity: disabled ? 0.35 : 1,
                background: mode === m ? selected.accent : '#151522',
                color: mode === m ? '#fff' : '#99a',
              }}
              onClick={() => setMode(m)}
            >
              {m === 'chat' ? 'Chat' : 'Terminal'}
            </button>
          );
        })}
      </div>

      <p style={styles.hint}>{mode === 'chat' ? selected.chatHint : selected.terminalHint}</p>

      {selected.quickActions && selected.quickActions.length > 0 && (
        <div style={styles.quickRow}>
          {selected.quickActions.map((action) => (
            <button key={action.id} style={styles.quickBtn} onClick={() => launchQuickAction(action.id)}>
              {action.label}
            </button>
          ))}
        </div>
      )}

      {mode === 'chat' ? (
        <>
          <div style={styles.chatPane}>
            {messages.length === 0 ? (
              <div style={styles.emptyChat}>
                <span style={{ fontSize: 28, color: selected.accent }}>{selected.icon}</span>
                <p style={styles.muted}>{selected.description}</p>
              </div>
            ) : (
              messages.map((msg) => (
                <div
                  key={msg.id}
                  style={{
                    ...styles.bubble,
                    alignSelf: msg.role === 'user' ? 'flex-end' : 'flex-start',
                    background: msg.role === 'user' ? `${selected.accent}33` : '#151522',
                    borderColor: msg.role === 'user' ? `${selected.accent}55` : '#252535',
                  }}
                >
                  <pre style={styles.bubbleText}>{msg.text || (msg.streaming ? '…' : '')}</pre>
                </div>
              ))
            )}
            <div ref={chatEndRef} />
          </div>

          <div style={styles.composer}>
            {selectedId === 'opencode' && (
              <label style={styles.continueToggle}>
                <input
                  type="checkbox"
                  checked={continueSession}
                  onChange={(e) => setContinueSession(e.target.checked)}
                />
                Continue session
              </label>
            )}
            <textarea
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
              placeholder={`Ask ${selected.shortLabel} to do something on your PC…`}
              style={styles.promptInput}
              rows={3}
              disabled={running || !selectedInfo?.installed}
            />
            <div style={styles.composerActions}>
              {running ? (
                <button onClick={() => void cancelRun()} style={styles.secondaryBtn}>Stop</button>
              ) : (
                <button
                  onClick={() => void sendChatPrompt(prompt)}
                  disabled={!prompt.trim() || !selectedInfo?.installed}
                  style={{ ...styles.primaryBtn, background: selected.accent }}
                >
                  Send
                </button>
              )}
            </div>
          </div>
        </>
      ) : (
        <>
          <div ref={containerRef} style={styles.termContainer} />
          <div style={styles.toolbar}>
            {AGENT_TOOLBAR_KEYS.map((k) => {
              const isActive =
                (k.modifier && k.code === 'CTRL' && ctrlActive) ||
                (k.modifier && k.code === 'SHIFT' && shiftActive);
              return (
                <button
                  key={k.label}
                  style={{
                    ...styles.keyBtn,
                    background: isActive ? selected.accent : '#1a1a28',
                    borderColor: isActive ? selected.accent : '#2a2a3a',
                    color: isActive ? '#fff' : '#aaa',
                  }}
                  onClick={() => sendTerminalKey(k.code, k.modifier)}
                  disabled={!terminalReady}
                >
                  {k.label}
                </button>
              );
            })}
          </div>
        </>
      )}
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  wrapper: {
    display: 'flex',
    flexDirection: 'column',
    height: '100dvh',
    background: '#0a0a0f',
    color: '#e0e0e0',
    fontFamily: 'system-ui, sans-serif',
    overflow: 'hidden',
  },
  topBar: {
    display: 'flex',
    alignItems: 'center',
    gap: 10,
    padding: '10px 12px',
    borderBottom: '1px solid #1e1e30',
    flexShrink: 0,
  },
  backBtn: {
    padding: '6px 12px',
    borderRadius: 6,
    border: '1px solid #333',
    background: 'transparent',
    color: '#888',
    fontSize: 12,
    cursor: 'pointer',
  },
  title: { fontSize: 14, fontWeight: 600, color: '#ccc', flex: 1 },
  iconBtn: {
    width: 32,
    height: 32,
    borderRadius: 8,
    border: '1px solid #2a2a3a',
    background: '#12121c',
    color: '#aaa',
    cursor: 'pointer',
  },
  centered: {
    flex: 1,
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 12,
    padding: 24,
    textAlign: 'center',
  },
  agentPicker: {
    display: 'flex',
    gap: 8,
    padding: '10px 12px 0',
    overflowX: 'auto',
    flexShrink: 0,
  },
  agentChip: {
    display: 'flex',
    alignItems: 'center',
    gap: 8,
    padding: '8px 12px',
    borderRadius: 12,
    border: '1px solid #2a2a3a',
    background: '#12121c',
    color: '#ddd',
    cursor: 'pointer',
    minWidth: 110,
  },
  chipLabel: { fontSize: 12, fontWeight: 600 },
  chipDot: { width: 7, height: 7, borderRadius: '50%', marginLeft: 'auto' },
  metaRow: {
    display: 'flex',
    gap: 10,
    padding: '10px 12px',
    flexShrink: 0,
  },
  metaBlock: { display: 'flex', flexDirection: 'column', gap: 4 },
  metaLabel: { fontSize: 10, color: '#667', textTransform: 'uppercase', letterSpacing: '0.06em' },
  cwdInput: {
    padding: '6px 8px',
    borderRadius: 8,
    border: '1px solid #252535',
    background: '#12121c',
    color: '#ddd',
    fontSize: 12,
    outline: 'none',
    width: '100%',
  },
  installBanner: {
    margin: '0 12px 8px',
    padding: '10px 12px',
    borderRadius: 10,
    background: '#2a1215',
    border: '1px solid #5a2020',
    color: '#fecaca',
    fontSize: 13,
  },
  errorBanner: {
    margin: '0 12px 8px',
    padding: '10px 12px',
    borderRadius: 10,
    background: '#2a1215',
    border: '1px solid #5a2020',
    color: '#fecaca',
    fontSize: 12,
  },
  modeRow: {
    display: 'flex',
    gap: 8,
    padding: '0 12px',
    flexShrink: 0,
  },
  modeBtn: {
    flex: 1,
    padding: '8px 10px',
    borderRadius: 10,
    border: 'none',
    fontSize: 12,
    fontWeight: 600,
    cursor: 'pointer',
  },
  hint: {
    margin: '8px 12px 0',
    fontSize: 11,
    color: '#667',
    flexShrink: 0,
  },
  quickRow: {
    display: 'flex',
    gap: 6,
    padding: '8px 12px 0',
    overflowX: 'auto',
    flexShrink: 0,
  },
  quickBtn: {
    padding: '6px 10px',
    borderRadius: 999,
    border: '1px solid #2a2a3a',
    background: '#151522',
    color: '#cbd5e1',
    fontSize: 11,
    whiteSpace: 'nowrap',
    cursor: 'pointer',
  },
  chatPane: {
    flex: 1,
    overflowY: 'auto',
    padding: '12px',
    display: 'flex',
    flexDirection: 'column',
    gap: 10,
    minHeight: 0,
  },
  emptyChat: {
    margin: 'auto',
    textAlign: 'center',
    maxWidth: 320,
    display: 'flex',
    flexDirection: 'column',
    gap: 10,
    alignItems: 'center',
  },
  bubble: {
    maxWidth: '92%',
    padding: '10px 12px',
    borderRadius: 12,
    border: '1px solid',
  },
  bubbleText: {
    margin: 0,
    whiteSpace: 'pre-wrap',
    wordBreak: 'break-word',
    fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
    fontSize: 12,
    lineHeight: 1.45,
  },
  composer: {
    padding: '10px 12px calc(10px + env(safe-area-inset-bottom))',
    borderTop: '1px solid #1e1e30',
    display: 'flex',
    flexDirection: 'column',
    gap: 8,
    flexShrink: 0,
  },
  continueToggle: {
    display: 'flex',
    alignItems: 'center',
    gap: 8,
    fontSize: 12,
    color: '#99a',
  },
  promptInput: {
    width: '100%',
    padding: '10px 12px',
    borderRadius: 10,
    border: '1px solid #2a2a3a',
    background: '#12121c',
    color: '#eee',
    fontSize: 14,
    resize: 'none',
    outline: 'none',
    boxSizing: 'border-box',
    fontFamily: 'inherit',
  },
  composerActions: { display: 'flex', justifyContent: 'flex-end' },
  primaryBtn: {
    padding: '10px 18px',
    borderRadius: 10,
    border: 'none',
    background: '#2a6aff',
    color: '#fff',
    fontSize: 13,
    fontWeight: 600,
    cursor: 'pointer',
  },
  secondaryBtn: {
    padding: '10px 18px',
    borderRadius: 10,
    border: '1px solid #5a2020',
    background: '#2a1215',
    color: '#fecaca',
    fontSize: 13,
    fontWeight: 600,
    cursor: 'pointer',
  },
  muted: { color: '#667', fontSize: 13, margin: 0 },
  termContainer: { flex: 1, overflow: 'hidden', padding: 4, minHeight: 0 },
  toolbar: {
    display: 'flex',
    gap: 6,
    padding: '8px 10px calc(8px + env(safe-area-inset-bottom))',
    borderTop: '1px solid #1e1e30',
    overflowX: 'auto',
    flexShrink: 0,
  },
  keyBtn: {
    padding: '10px 12px',
    borderRadius: 6,
    border: '1px solid #2a2a3a',
    background: '#1a1a28',
    color: '#aaa',
    fontSize: 12,
    fontWeight: 500,
    cursor: 'pointer',
    whiteSpace: 'nowrap',
    minWidth: 42,
  },
};
