'use client';

import { useEffect, useRef, useState, useCallback } from 'react';
import '@xterm/xterm/css/xterm.css';
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import { useRouter } from 'next/navigation';
import { useConnectionStore } from '@/store/connection';

function b64decode(str: string): string {
  try {
    return atob(str);
  } catch {
    return str;
  }
}

const TOOLBAR_KEYS = [
  { label: 'Tab', code: '\t' },
  { label: 'Esc', code: '\x1b' },
  { label: 'Ctrl', code: 'CTRL', modifier: true as const },
  { label: 'Alt', code: 'ALT', modifier: true as const },
  { label: '\u2190', code: '\x1b[D' },
  { label: '\u2191', code: '\x1b[A' },
  { label: '\u2193', code: '\x1b[B' },
  { label: '\u2192', code: '\x1b[C' },
];

export default function TerminalContent() {
  const client = useConnectionStore((s) => s.client);
  const status = useConnectionStore((s) => s.status);
  const router = useRouter();

  const termRef = useRef<Terminal | null>(null);
  const fitAddonRef = useRef<FitAddon | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const terminalIdRef = useRef<string | null>(null);

  const [ctrlActive, setCtrlActive] = useState(false);
  const [altActive, setAltActive] = useState(false);

  const ctrlRef = useRef(false);
  const altRef = useRef(false);

  useEffect(() => {
    if (status !== 'connected' || !client || !containerRef.current) return;
    const c = client;

    let disposed = false;

    async function setup() {
      const term = new Terminal({
        cursorBlink: true,
        fontSize: 14,
        fontFamily: "'Cascadia Code', 'Fira Code', 'JetBrains Mono', monospace",
        theme: {
          background: '#0a0a0f',
          foreground: '#e0e0e0',
          cursor: '#4ade80',
          selectionBackground: '#2a6aff44',
          black: '#1a1a2e',
          red: '#e55',
          green: '#4ade80',
          yellow: '#f0c040',
          blue: '#2a6aff',
          magenta: '#c084fc',
          cyan: '#22d3ee',
          white: '#e0e0e0',
          brightBlack: '#444',
          brightRed: '#f87171',
          brightGreen: '#6ee7b7',
          brightYellow: '#fbbf24',
          brightBlue: '#60a5fa',
          brightMagenta: '#d8b4fe',
          brightCyan: '#67e8f9',
          brightWhite: '#fff',
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
        if (!tid || !c) return;
        c.request('terminal.input', { terminalId: tid, data }).catch(() => {});
      });

      try {
        const result = (await c.request('terminal.create', {
          cols: term.cols,
          rows: term.rows,
        })) as { terminalId: string };
        terminalIdRef.current = result.terminalId;

        const unsub = c.subscribe('terminal-output', (msg: unknown) => {
          if (disposed) return;
          const m = msg as { terminalId?: string; data?: string };
          if (m.terminalId !== result.terminalId || !m.data) return;
          term.write(b64decode(m.data));
        });

        return () => {
          unsub();
        };
      } catch {
        term.write('Failed to create terminal session.\r\n');
      }
    }

    setup().catch(() => {});

    return () => {
      disposed = true;
      const tid = terminalIdRef.current;
      if (tid && c) {
        c.request('terminal.kill', { terminalId: tid }).catch(() => {});
      }
      termRef.current?.dispose();
      termRef.current = null;
      fitAddonRef.current = null;
    };
  }, [client, status]);

  useEffect(() => {
    if (!client) return;
    const c = client;

    function handleResize() {
      setTimeout(() => {
        if (!fitAddonRef.current || !c) return;
        fitAddonRef.current.fit();
        const tid = terminalIdRef.current;
        if (tid && termRef.current) {
          c
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
  }, [client]);

  const sendKey = useCallback(
    (code: string, isModifier?: boolean) => {
      const tid = terminalIdRef.current;
      if (!tid || !client) return;

      if (isModifier && code === 'CTRL') {
        const next = !ctrlRef.current;
        ctrlRef.current = next;
        setCtrlActive(next);
        return;
      }
      if (isModifier && code === 'ALT') {
        const next = !altRef.current;
        altRef.current = next;
        setAltActive(next);
        return;
      }

      let data = code;
      if (ctrlRef.current) {
        data = String.fromCharCode(code.charCodeAt(0) & 0x1f);
        ctrlRef.current = false;
        setCtrlActive(false);
      }
      if (altRef.current) {
        data = '\x1b' + data;
        altRef.current = false;
        setAltActive(false);
      }

      client!.request('terminal.input', { terminalId: tid, data }).catch(() => {});
    },
    [client]
  );

  const hasSession = status === 'connected' && client;

  return (
    <div style={styles.wrapper}>
      <header style={styles.topBar}>
        <button onClick={() => router.back()} style={styles.backBtn}>
          \u2190 Back
        </button>
        <span style={styles.title}>Terminal</span>
        {hasSession && (
          <span style={styles.sessionBadge}>
            {terminalIdRef.current ? 'live' : 'connecting...'}
          </span>
        )}
      </header>

      <div ref={containerRef} style={styles.termContainer} />

      <div style={styles.toolbar}>
        {TOOLBAR_KEYS.map((k) => {
          const isActive =
            (k.modifier && k.code === 'CTRL' && ctrlActive) ||
            (k.modifier && k.code === 'ALT' && altActive);
          return (
            <button
              key={k.label}
              style={{
                ...styles.keyBtn,
                background: isActive ? '#2a6aff' : '#1a1a28',
                color: isActive ? '#fff' : '#aaa',
                borderColor: isActive ? '#2a6aff' : '#2a2a3a',
              }}
              onClick={() => sendKey(k.code, k.modifier)}
              disabled={!hasSession}
            >
              {k.label}
            </button>
          );
        })}
      </div>
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
    gap: '10px',
    padding: '10px 12px',
    borderBottom: '1px solid #1e1e30',
    flexShrink: 0,
  },
  backBtn: {
    padding: '6px 12px',
    borderRadius: '6px',
    border: '1px solid #333',
    background: 'transparent',
    color: '#888',
    fontSize: '12px',
    cursor: 'pointer',
    fontWeight: 500,
  },
  title: {
    fontSize: '14px',
    fontWeight: 600,
    color: '#ccc',
    flex: 1,
  },
  sessionBadge: {
    fontSize: '11px',
    color: '#4ade80',
    fontWeight: 500,
  },
  termContainer: {
    flex: 1,
    overflow: 'hidden',
    padding: '4px',
  },
  toolbar: {
    display: 'flex',
    gap: '6px',
    padding: '8px 10px',
    paddingBottom: 'max(8px, env(safe-area-inset-bottom))',
    borderTop: '1px solid #1e1e30',
    flexShrink: 0,
    overflowX: 'auto',
    justifyContent: 'center',
  },
  keyBtn: {
    padding: '10px 14px',
    borderRadius: '6px',
    border: '1px solid #2a2a3a',
    background: '#1a1a28',
    color: '#aaa',
    fontSize: '13px',
    fontWeight: 500,
    cursor: 'pointer',
    whiteSpace: 'nowrap',
    minWidth: '38px',
    textAlign: 'center',
  },
};
