'use client';

import { useEffect, useRef, useState, useCallback } from 'react';
import '@xterm/xterm/css/xterm.css';
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import { useRouter } from 'next/navigation';
import { useConnectionStore } from '@/store/connection';
import {
  EXTRA_KEYS_ROW1,
  EXTRA_KEYS_ROW2,
  EXTRA_KEYS_ROW3,
  applyStickyModifiers,
  type ExtraKey,
} from '@/lib/extra-keys';

const FONT_MIN = 11;
const FONT_MAX = 22;
const FONT_KEY = 'nexuslink-term-font';

export default function TerminalContent() {
  const client = useConnectionStore((s) => s.client);
  const status = useConnectionStore((s) => s.status);
  const router = useRouter();
  const connect = useConnectionStore((s) => s.connect);
  const hostUrl = useConnectionStore((s) => s.hostUrl);

  const termRef = useRef<Terminal | null>(null);
  const fitAddonRef = useRef<FitAddon | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const terminalIdRef = useRef<string | null>(null);
  const unsubRef = useRef<(() => void) | null>(null);
  const wakeLockRef = useRef<{ release: () => Promise<void> } | null>(null);

  const [ctrlActive, setCtrlActive] = useState(false);
  const [altActive, setAltActive] = useState(false);
  const [fontSize, setFontSize] = useState(14);
  const [live, setLive] = useState(false);

  const ctrlRef = useRef(false);
  const altRef = useRef(false);
  ctrlRef.current = ctrlActive;
  altRef.current = altActive;

  const haptic = () => {
    try {
      navigator.vibrate?.(8);
    } catch {
      /* ignore */
    }
  };

  const sendData = useCallback(
    (raw: string) => {
      const tid = terminalIdRef.current;
      if (!tid || !client) return;
      const next = applyStickyModifiers(raw, ctrlRef.current, altRef.current);
      if (next.ctrl !== ctrlRef.current) setCtrlActive(next.ctrl);
      if (next.alt !== altRef.current) setAltActive(next.alt);
      client.request('terminal.input', { terminalId: tid, data: next.data }).catch(() => {});
    },
    [client],
  );

  const fitAndResize = useCallback(() => {
    const fit = fitAddonRef.current;
    const term = termRef.current;
    const tid = terminalIdRef.current;
    if (!fit || !term || !client) return;
    try {
      fit.fit();
    } catch {
      return;
    }
    if (tid) {
      client
        .request('terminal.resize', {
          terminalId: tid,
          cols: term.cols,
          rows: term.rows,
        })
        .catch(() => {});
    }
  }, [client]);

  // ---- session bring-up ----------------------------------------------------
  useEffect(() => {
    if (status !== 'connected' || !client || !containerRef.current) return;
    const c = client;
    let disposed = false;

    const stored = Number(localStorage.getItem(FONT_KEY) || '14');
    const initialFont = Number.isFinite(stored)
      ? Math.min(FONT_MAX, Math.max(FONT_MIN, stored))
      : 14;
    setFontSize(initialFont);

    const term = new Terminal({
      cursorBlink: true,
      cursorStyle: 'bar',
      fontSize: initialFont,
      fontFamily: "'Cascadia Code', 'Fira Code', 'JetBrains Mono', ui-monospace, monospace",
      theme: {
        background: '#0d0d12',
        foreground: '#e8e8ee',
        cursor: '#4ade80',
        cursorAccent: '#0d0d12',
        selectionBackground: '#2a6aff66',
        black: '#1a1a2e',
        red: '#f87171',
        green: '#4ade80',
        yellow: '#fbbf24',
        blue: '#60a5fa',
        magenta: '#c084fc',
        cyan: '#22d3ee',
        white: '#e8e8ee',
        brightBlack: '#555',
        brightRed: '#fca5a5',
        brightGreen: '#86efac',
        brightYellow: '#fde68a',
        brightBlue: '#93c5fd',
        brightMagenta: '#e9d5ff',
        brightCyan: '#a5f3fc',
        brightWhite: '#fff',
      },
      scrollback: 4000,
    });
    const fitAddon = new FitAddon();
    term.loadAddon(fitAddon);
    term.open(containerRef.current);
    try {
      fitAddon.fit();
    } catch {
      /* first layout can race */
    }
    term.focus();
    termRef.current = term;
    fitAddonRef.current = fitAddon;

    term.onData((data) => {
      if (disposed) return;
      sendData(data);
    });

    (async () => {
      try {
        const result = (await c.request('terminal.create', {
          cols: term.cols,
          rows: term.rows,
        })) as { terminalId: string };
        if (disposed) {
          void c.request('terminal.kill', { terminalId: result.terminalId }).catch(() => {});
          return;
        }
        terminalIdRef.current = result.terminalId;
        setLive(true);
        unsubRef.current = c.subscribe('terminal-output', (msg: unknown) => {
          if (disposed) return;
          const m = msg as { terminalId?: string; data?: string };
          if (m.terminalId !== result.terminalId || typeof m.data !== 'string') return;
          term.write(m.data);
        });
      } catch {
        term.write('\r\nFailed to create a terminal session on the PC.\r\n');
      }
    })();

    const nav = navigator as Navigator & {
      wakeLock?: { request: (type: 'screen') => Promise<{ release: () => Promise<void> }> };
    };
    nav.wakeLock
      ?.request('screen')
      .then((lock) => {
        if (disposed) void lock.release();
        else wakeLockRef.current = lock;
      })
      .catch(() => {});

    return () => {
      disposed = true;
      unsubRef.current?.();
      unsubRef.current = null;
      const tid = terminalIdRef.current;
      terminalIdRef.current = null;
      if (tid) void c.request('terminal.kill', { terminalId: tid }).catch(() => {});
      term.dispose();
      termRef.current = null;
      fitAddonRef.current = null;
      void wakeLockRef.current?.release().catch(() => {});
      wakeLockRef.current = null;
      setLive(false);
    };
    // sendData is stable enough for the session lifetime (client/status gated).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [client, status]);

  useEffect(() => {
    const onResize = () => fitAndResize();
    window.addEventListener('resize', onResize);
    window.addEventListener('orientationchange', onResize);
    const el = containerRef.current;
    const observer = el ? new ResizeObserver(onResize) : null;
    if (el) observer?.observe(el);
    return () => {
      window.removeEventListener('resize', onResize);
      window.removeEventListener('orientationchange', onResize);
      observer?.disconnect();
    };
  }, [fitAndResize]);

  const bumpFont = (delta: number) => {
    const next = Math.min(FONT_MAX, Math.max(FONT_MIN, fontSize + delta));
    setFontSize(next);
    localStorage.setItem(FONT_KEY, String(next));
    const term = termRef.current;
    if (term) {
      term.options.fontSize = next;
      requestAnimationFrame(fitAndResize);
    }
  };

  const onExtraKey = (k: ExtraKey) => {
    haptic();
    if (k.modifier === 'ctrl') {
      setCtrlActive((v) => !v);
      return;
    }
    if (k.modifier === 'alt') {
      setAltActive((v) => !v);
      return;
    }
    sendData(k.code);
    termRef.current?.focus();
  };

  const paste = async () => {
    haptic();
    try {
      const text = await navigator.clipboard.readText();
      if (text) sendData(text);
    } catch {
      /* permission denied */
    }
    termRef.current?.focus();
  };

  const handleReconnect = useCallback(async () => {
    if (!hostUrl) return;
    try {
      await connect(hostUrl);
    } catch {
      /* store handles it */
    }
  }, [connect, hostUrl]);

  const hasSession = status === 'connected' && !!client;

  return (
    <div style={styles.wrapper}>
      <header style={styles.topBar}>
        <button onClick={() => router.push('/')} style={styles.iconBtn} aria-label="Home">
          ⌂
        </button>
        <span style={styles.title}>
          Terminal
          {live ? <span style={styles.live}> · live</span> : null}
        </span>
        <button onClick={() => bumpFont(-1)} style={styles.iconBtn} aria-label="Smaller font">
          A−
        </button>
        <button onClick={() => bumpFont(1)} style={styles.iconBtn} aria-label="Larger font">
          A+
        </button>
        <button onClick={() => void paste()} style={styles.iconBtn} aria-label="Paste">
          📋
        </button>
        {status !== 'connected' && (
          <button onClick={() => void handleReconnect()} style={styles.reconnectBtn}>
            Reconnect
          </button>
        )}
      </header>

      {!hasSession ? (
        <div style={styles.disconnectedOverlay}>
          <span style={styles.disconnectedText}>Not connected to the PC.</span>
          <button onClick={() => void handleReconnect()} style={styles.reconnectBtnLarge}>
            Reconnect
          </button>
        </div>
      ) : (
        <div
          ref={containerRef}
          style={styles.termContainer}
          onClick={() => termRef.current?.focus()}
        />
      )}

      <div style={styles.keyboardChrome}>
        <KeyRow keys={EXTRA_KEYS_ROW1} ctrl={ctrlActive} alt={altActive} onKey={onExtraKey} disabled={!hasSession} />
        <KeyRow keys={EXTRA_KEYS_ROW2} ctrl={ctrlActive} alt={altActive} onKey={onExtraKey} disabled={!hasSession} />
        <KeyRow keys={EXTRA_KEYS_ROW3} ctrl={ctrlActive} alt={altActive} onKey={onExtraKey} disabled={!hasSession} />
      </div>
    </div>
  );
}

function KeyRow({
  keys,
  ctrl,
  alt,
  onKey,
  disabled,
}: {
  keys: ExtraKey[];
  ctrl: boolean;
  alt: boolean;
  onKey: (k: ExtraKey) => void;
  disabled: boolean;
}) {
  return (
    <div style={styles.keyRow}>
      {keys.map((k) => {
        const active =
          (k.modifier === 'ctrl' && ctrl) || (k.modifier === 'alt' && alt);
        return (
          <button
            key={k.label}
            disabled={disabled}
            onClick={() => onKey(k)}
            style={{
              ...styles.keyBtn,
              background: active ? '#2a6aff' : '#1a1a28',
              color: active ? '#fff' : '#c8c8d8',
              borderColor: active ? '#2a6aff' : '#2a2a3a',
            }}
          >
            {k.label}
          </button>
        );
      })}
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  wrapper: {
    display: 'flex',
    flexDirection: 'column',
    height: '100dvh',
    background: '#0d0d12',
    color: '#e8e8ee',
    fontFamily: 'system-ui, sans-serif',
    overflow: 'hidden',
  },
  topBar: {
    display: 'flex',
    alignItems: 'center',
    gap: 6,
    padding: '8px 8px 8px 10px',
    borderBottom: '1px solid #1e1e30',
    flexShrink: 0,
  },
  title: { fontSize: 14, fontWeight: 600, color: '#ccc', flex: 1 },
  live: { color: '#4ade80', fontWeight: 500, fontSize: 12 },
  iconBtn: {
    minWidth: 36,
    height: 32,
    padding: '0 8px',
    borderRadius: 8,
    border: '1px solid #2a2a3a',
    background: '#141420',
    color: '#bbb',
    fontSize: 13,
    fontWeight: 600,
    cursor: 'pointer',
  },
  reconnectBtn: {
    padding: '4px 10px',
    borderRadius: 6,
    border: '1px solid #2a3a6a',
    background: '#141420',
    color: '#2a6aff',
    fontSize: 11,
    fontWeight: 600,
    cursor: 'pointer',
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
  disconnectedOverlay: {
    flex: 1,
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 12,
  },
  disconnectedText: { fontSize: 14, color: '#667' },
  termContainer: {
    flex: 1,
    overflow: 'hidden',
    padding: '6px 8px 0',
    minHeight: 0,
  },
  keyboardChrome: {
    flexShrink: 0,
    borderTop: '1px solid #1e1e30',
    background: '#0a0a10',
    padding: '6px 6px max(8px, env(safe-area-inset-bottom))',
    display: 'flex',
    flexDirection: 'column',
    gap: 4,
  },
  keyRow: {
    display: 'flex',
    gap: 4,
    overflowX: 'auto',
    WebkitOverflowScrolling: 'touch',
  },
  keyBtn: {
    flex: '1 0 auto',
    minWidth: 36,
    padding: '10px 8px',
    borderRadius: 8,
    border: '1px solid #2a2a3a',
    background: '#1a1a28',
    color: '#c8c8d8',
    fontSize: 12,
    fontWeight: 600,
    cursor: 'pointer',
    fontFamily: 'ui-monospace, monospace',
  },
};
