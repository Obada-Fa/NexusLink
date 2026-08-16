'use client';

// The phone-OS app viewport: streams an adopted host window (or the full desktop)
// and turns touch into direct manipulation. Auto-connects and auto-starts — the
// user never has to press "Start".

import { useEffect, useState, useCallback, useRef } from 'react';
import { useRouter } from 'next/navigation';
import { useConnectionStore } from '@/store/connection';
import ConnectionProvider from '@/components/ConnectionProvider';
import GestureOverlay, { type HostRegion } from '@/components/GestureOverlay';

type Phase = 'connecting' | 'launching' | 'adopting' | 'streaming' | 'error';

/** Binary frame header from the host: u32 magic 'NLF1' | u32 streamKey | f64 ts (LE). */
const FRAME_MAGIC = 0x4e4c4631;
const FRAME_HEADER_BYTES = 16;

interface MirrorTarget {
  windowId?: string;
  appId?: string;
  wmClass?: string;
  title?: string;
  /** Launch this app into a NEW virtual session sized to the phone. */
  virtualAppId?: string;
  /** Re-attach to an existing virtual session. */
  sessionId?: string;
}

/** "org.gnome.Calculator" → "orggnomecalculator" — dashes/dots vary in the wild. */
function normClass(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9]/g, '');
}

function parseTarget(): MirrorTarget {
  if (typeof window === 'undefined') return {};
  const p = new URLSearchParams(window.location.search);
  return {
    windowId: p.get('w') ?? undefined,
    appId: p.get('app') ?? undefined,
    wmClass: p.get('cls') ?? undefined,
    title: p.get('title') ?? undefined,
    virtualAppId: p.get('vapp') ?? undefined,
    sessionId: p.get('s') ?? undefined,
  };
}

function MirrorView() {
  const status = useConnectionStore((s) => s.status);
  const client = useConnectionStore((s) => s.client);
  const router = useRouter();

  const [phase, setPhase] = useState<Phase>('connecting');
  const [errorMsg, setErrorMsg] = useState('');
  // null until the URL is parsed client-side — the session must not start before
  // then, or a ?w=/?app= target would be misread as a full-desktop session.
  const [target, setTarget] = useState<MirrorTarget | null>(null);
  const [region, setRegion] = useState<HostRegion | null>(null);
  const [fps, setFps] = useState(0);
  const [kbOpen, setKbOpen] = useState(false);

  const streamIdRef = useRef<string | null>(null);
  const windowIdRef = useRef<string | null>(null);
  const sessionIdRef = useRef<string | null>(null);
  const [sessionId, setSessionId] = useState<string | null>(null);
  const imgRef = useRef<HTMLImageElement | null>(null);
  const viewportRef = useRef<HTMLDivElement | null>(null);
  const unsubRef = useRef<(() => void) | null>(null);
  const frameCountRef = useRef(0);
  const startedRef = useRef(false);
  const kbRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    setTarget(parseTarget());
  }, []);

  // ---- session bring-up: (launch →) adopt → capture ------------------------
  useEffect(() => {
    if (status !== 'connected' || !client || !target || startedRef.current) return;
    startedRef.current = true;
    let cancelled = false;

    const begin = async () => {
      try {
        let windowId = target.windowId ?? null;

        // Virtual session flow: the app runs on its own headless display sized
        // EXACTLY like this phone — nothing moves on the PC's real desktop and
        // the stream is the full surface, 1:1. No adopt, no cropping possible.
        if (target.virtualAppId || target.sessionId) {
          setPhase('launching');
          let session: {
            sessionId: string;
            width: number;
            height: number;
            status: string;
          } | null = null;
          if (target.sessionId) {
            const list = (await client.request('appSession.list')) as Array<{
              sessionId: string;
              width: number;
              height: number;
              status: string;
            }>;
            session = list.find((s) => s.sessionId === target.sessionId && s.status === 'running') ?? null;
            if (!session) throw new Error('That app session has ended. Launch the app again.');
          } else {
            session = await client.request('appSession.create', {
              appId: target.virtualAppId,
              width: Math.round(window.innerWidth),
              height: Math.round(window.innerHeight),
              dpr: window.devicePixelRatio || 1,
            }, 20000) as {
              sessionId: string;
              width: number;
              height: number;
              status: string;
            } | null;
            if (!session?.sessionId) {
              throw new Error(
                'The PC host is out of date. On the PC, stop NexusLink, update the repo, and run bun run lan.',
              );
            }
          }
          if (cancelled) return;
          sessionIdRef.current = session.sessionId;
          setSessionId(session.sessionId);

          // Give the app a beat to draw its first window before streaming.
          if (target.virtualAppId) await new Promise((r) => setTimeout(r, 1200));

          const cap = (await client.request('screen.startCapture', {
            quality: 'medium',
            fps: 24,
            sessionId: session.sessionId,
          })) as { streamId: string; streamKey: number; region?: HostRegion };
          if (cancelled) {
            void client.request('screen.stopCapture', { streamId: cap.streamId }).catch(() => {});
            return;
          }
          streamIdRef.current = cap.streamId;
          setRegion(cap.region ?? { x: 0, y: 0, width: session.width, height: session.height });

          let lastUrl: string | null = null;
          const unsubFrames = client.subscribeBinary((buf: ArrayBuffer) => {
            if (buf.byteLength <= FRAME_HEADER_BYTES) return;
            const view = new DataView(buf);
            if (view.getUint32(0, true) !== FRAME_MAGIC) return;
            if (view.getUint32(4, true) !== cap.streamKey) return;
            frameCountRef.current++;
            if (imgRef.current) {
              const url = URL.createObjectURL(
                new Blob([new Uint8Array(buf, FRAME_HEADER_BYTES)], { type: 'image/jpeg' }),
              );
              imgRef.current.src = url;
              if (lastUrl) URL.revokeObjectURL(lastUrl);
              lastUrl = url;
            }
          });
          // If the app inside the session exits, bounce back to the launcher.
          const unsubSession = client.subscribe('app-session-update', (msg: unknown) => {
            const update = msg as { session?: { sessionId: string; status: string } };
            if (update.session?.sessionId === sessionIdRef.current && update.session.status === 'exited') {
              setErrorMsg('The app has exited.');
              setPhase('error');
            }
          });
          unsubRef.current = () => {
            unsubFrames();
            unsubSession();
          };
          setPhase('streaming');
          return;
        }

        // Launch flow: start the app on the PC, then wait for its window.
        if (!windowId && target.appId) {
          setPhase('launching');
          const launched = (await client.request('apps.launch', { appId: target.appId })) as {
            ok: boolean;
            wmClass?: string;
          };
          if (!launched.ok) throw new Error('The host could not launch this app.');
          const nCls = normClass(target.wmClass || launched.wmClass || target.appId || '');

          const deadline = Date.now() + 25000;
          while (!cancelled && Date.now() < deadline) {
            await new Promise((r) => setTimeout(r, 800));
            const wins = (await client.request('window.list')) as Array<{
              windowId: string;
              wmClass: string;
              appId?: string;
            }>;
            const hit = wins.find((w) => {
              if (w.appId && w.appId === target.appId) return true;
              const nWin = normClass(w.wmClass.split('.').pop() ?? '');
              return (
                nWin.length >= 4 && nCls.length >= 4 && (nCls.includes(nWin) || nWin.includes(nCls))
              );
            });
            if (hit) {
              windowId = hit.windowId;
              break;
            }
          }
          if (!windowId) throw new Error('The app started but no window appeared yet. Go back and tap it under "Open on your PC".');
        }
        if (cancelled) return;

        // Adopt: shape the window like a phone screen and focus it.
        let captureParams: Record<string, unknown> = { quality: 'medium', fps: 24 };
        if (windowId) {
          setPhase('adopting');
          windowIdRef.current = windowId;
          await client.request('window.adopt', {
            windowId,
            viewportW: Math.round(window.innerWidth),
            viewportH: Math.round(window.innerHeight),
          });
          captureParams = { ...captureParams, windowId };
        }
        if (cancelled) return;

        const cap = (await client.request('screen.startCapture', captureParams)) as {
          streamId: string;
          streamKey: number;
          region?: HostRegion;
        };
        if (cancelled) {
          void client.request('screen.stopCapture', { streamId: cap.streamId }).catch(() => {});
          return;
        }
        streamIdRef.current = cap.streamId;
        setRegion(cap.region ?? null);

        let lastUrl: string | null = null;
        const unsubFrames = client.subscribeBinary((buf: ArrayBuffer) => {
          if (buf.byteLength <= FRAME_HEADER_BYTES) return;
          const view = new DataView(buf);
          if (view.getUint32(0, true) !== FRAME_MAGIC) return;
          if (view.getUint32(4, true) !== cap.streamKey) return;
          frameCountRef.current++;
          if (imgRef.current) {
            const url = URL.createObjectURL(
              new Blob([new Uint8Array(buf, FRAME_HEADER_BYTES)], { type: 'image/jpeg' }),
            );
            imgRef.current.src = url;
            if (lastUrl) URL.revokeObjectURL(lastUrl);
            lastUrl = url;
          }
        });
        // The host re-grabs if the window moves/resizes; keep touch mapping aligned.
        const unsubRegion = client.subscribe('stream-region', (msg: unknown) => {
          const update = msg as { streamId: string; region: HostRegion };
          if (!update || update.streamId !== streamIdRef.current) return;
          setRegion(update.region);
        });
        unsubRef.current = () => {
          unsubFrames();
          unsubRegion();
        };
        setPhase('streaming');
      } catch (err) {
        if (!cancelled) {
          setErrorMsg(err instanceof Error ? err.message : 'Could not start the session.');
          setPhase('error');
        }
      }
    };

    void begin();
    return () => {
      cancelled = true;
    };
  }, [status, client, target]);

  // ---- teardown -------------------------------------------------------------
  const teardown = useCallback(
    (release: boolean) => {
      unsubRef.current?.();
      unsubRef.current = null;
      const streamId = streamIdRef.current;
      streamIdRef.current = null;
      if (streamId && client) {
        client.request('screen.stopCapture', { streamId }).catch(() => {});
      }
      const windowId = windowIdRef.current;
      if (release && windowId && client) {
        client.request('window.release', { windowId }).catch(() => {});
      }
    },
    [client],
  );

  useEffect(() => () => teardown(false), [teardown]);

  // Home keeps the virtual session alive on the PC (like backgrounding an app
  // on a phone); the launcher lists it for one-tap re-attach.
  const goHome = useCallback(() => {
    teardown(true);
    router.push('/');
  }, [teardown, router]);

  // Explicit close = quit the app: tear the whole virtual session down.
  const closeSession = useCallback(() => {
    teardown(false);
    const sid = sessionIdRef.current;
    if (sid && client) {
      client.request('appSession.close', { sessionId: sid }).catch(() => {});
    }
    router.push('/');
  }, [teardown, client, router]);

  // ---- FPS HUD ---------------------------------------------------------------
  useEffect(() => {
    if (phase !== 'streaming') return;
    const t = setInterval(() => {
      setFps(frameCountRef.current);
      frameCountRef.current = 0;
    }, 1000);
    return () => clearInterval(t);
  }, [phase]);

  // ---- phone keyboard → host ---------------------------------------------------
  const sendSpecialKey = useCallback(
    (key: string) => {
      const sid = sessionIdRef.current;
      client?.request('input.keyEvent', { key, ...(sid ? { sessionId: sid } : {}) }).catch(() => {});
    },
    [client],
  );

  const onKbInput = useCallback(() => {
    const el = kbRef.current;
    if (!el || !client) return;
    const text = el.value;
    if (text) {
      const sid = sessionIdRef.current;
      client.request('input.typeText', { text, ...(sid ? { sessionId: sid } : {}) }).catch(() => {});
      el.value = '';
    }
  }, [client]);

  const onKbKeyDown = useCallback(
    (e: React.KeyboardEvent<HTMLInputElement>) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        sendSpecialKey('Return');
      } else if (e.key === 'Backspace' && !kbRef.current?.value) {
        sendSpecialKey('BackSpace');
      }
    },
    [sendSpecialKey],
  );

  useEffect(() => {
    if (kbOpen) kbRef.current?.focus();
  }, [kbOpen]);

  const title = target?.title || (target?.windowId || target?.appId ? 'App' : 'Desktop');

  return (
    <div style={styles.wrapper}>
      <header style={styles.topBar}>
        <button onClick={goHome} style={styles.barBtn} aria-label="Home">
          {'⌂'}
        </button>
        <span style={styles.title}>
          {title}
          {phase === 'streaming' && fps > 0 ? ` · ${fps}fps` : ''}
        </span>
        <button
          onClick={() => setKbOpen((v) => !v)}
          style={{ ...styles.barBtn, color: kbOpen ? '#2a6aff' : '#888' }}
          aria-label="Keyboard"
        >
          {'⌨'}
        </button>
        {sessionId && (
          <button onClick={closeSession} style={styles.barBtn} aria-label="Close app">
            {'✕'}
          </button>
        )}
        {phase === 'streaming' && (
          <GestureOverlay
            viewportRef={viewportRef}
            region={region}
            sessionId={sessionId ?? undefined}
            showHud={false}
          />
        )}
      </header>

      <div style={styles.stage}>
        {phase === 'streaming' ? (
          <div ref={viewportRef} style={styles.viewport}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img ref={imgRef} alt="host screen" style={styles.frame} draggable={false} />
          </div>
        ) : phase === 'error' ? (
          <div style={styles.centerBox}>
            <span style={styles.bigIcon}>{'⚠'}</span>
            <p style={styles.centerText}>{errorMsg}</p>
            <button onClick={goHome} style={styles.primaryBtn}>
              Back to apps
            </button>
          </div>
        ) : status !== 'connected' && status !== 'connecting' ? (
          <div style={styles.centerBox}>
            <span style={styles.bigIcon}>{'⚠'}</span>
            <p style={styles.centerText}>Not connected to the PC.</p>
            <button onClick={goHome} style={styles.primaryBtn}>
              Back
            </button>
          </div>
        ) : (
          <div style={styles.centerBox}>
            <style dangerouslySetInnerHTML={{ __html: '@keyframes nl-spin{to{transform:rotate(360deg)}}' }} />
            <div style={styles.spinner} />
            <p style={styles.centerText}>
              {phase === 'launching'
                ? `Opening ${title} on your PC…`
                : phase === 'adopting'
                  ? 'Fitting the app to your screen…'
                  : 'Connecting…'}
            </p>
          </div>
        )}
      </div>

      {kbOpen && (
        <div style={styles.kbBar}>
          <input
            ref={kbRef}
            style={styles.kbInput}
            placeholder="Type here — sent to the PC"
            onInput={onKbInput}
            onKeyDown={onKbKeyDown}
            autoCapitalize="none"
            autoCorrect="off"
          />
          <button style={styles.kbKey} onClick={() => sendSpecialKey('BackSpace')}>⌫</button>
          <button style={styles.kbKey} onClick={() => sendSpecialKey('Return')}>⏎</button>
          <button style={styles.kbKey} onClick={() => sendSpecialKey('Escape')}>Esc</button>
        </div>
      )}
    </div>
  );
}

export default function MirrorPage() {
  return (
    <ConnectionProvider>
      <MirrorView />
    </ConnectionProvider>
  );
}

const styles: Record<string, React.CSSProperties> = {
  wrapper: {
    display: 'flex',
    flexDirection: 'column',
    height: '100dvh',
    background: '#000',
    color: '#e0e0e0',
    fontFamily: 'system-ui, sans-serif',
    overflow: 'hidden',
  },
  topBar: {
    display: 'flex',
    alignItems: 'center',
    gap: 8,
    padding: '6px 10px',
    background: '#0a0a0f',
    borderBottom: '1px solid #16162a',
    flexShrink: 0,
  },
  barBtn: {
    width: 34,
    height: 30,
    borderRadius: 8,
    border: '1px solid #22223a',
    background: 'transparent',
    color: '#888',
    fontSize: 16,
    cursor: 'pointer',
    lineHeight: 1,
  },
  title: {
    fontSize: 13,
    fontWeight: 600,
    color: '#ccc',
    flex: 1,
    textAlign: 'center',
    whiteSpace: 'nowrap',
    overflow: 'hidden',
    textOverflow: 'ellipsis',
  },
  stage: { flex: 1, display: 'flex', minHeight: 0, background: '#000' },
  viewport: {
    position: 'relative',
    width: '100%',
    height: '100%',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    touchAction: 'none',
    userSelect: 'none',
    WebkitUserSelect: 'none',
    background: '#000',
  },
  frame: {
    maxWidth: '100%',
    maxHeight: '100%',
    width: '100%',
    height: '100%',
    objectFit: 'contain',
    pointerEvents: 'none',
    display: 'block',
  },
  centerBox: {
    flex: 1,
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 14,
    padding: 24,
    textAlign: 'center',
  },
  bigIcon: { fontSize: 36 },
  centerText: { fontSize: 14, color: '#889', margin: 0, maxWidth: 280 },
  primaryBtn: {
    padding: '10px 24px',
    borderRadius: 8,
    border: 'none',
    background: '#2a6aff',
    color: '#fff',
    fontSize: 13,
    fontWeight: 600,
    cursor: 'pointer',
  },
  spinner: {
    width: 32,
    height: 32,
    borderRadius: '50%',
    border: '3px solid #1e2a4a',
    borderTopColor: '#2a6aff',
    animation: 'nl-spin 0.8s linear infinite',
  },
  kbBar: {
    display: 'flex',
    gap: 6,
    padding: '8px 10px calc(8px + env(safe-area-inset-bottom))',
    background: '#0f0f1a',
    borderTop: '1px solid #1c1c30',
    flexShrink: 0,
  },
  kbInput: {
    flex: 1,
    padding: '8px 12px',
    borderRadius: 8,
    border: '1px solid #26263e',
    background: '#161624',
    color: '#eee',
    fontSize: 14,
    outline: 'none',
  },
  kbKey: {
    padding: '0 12px',
    borderRadius: 8,
    border: '1px solid #26263e',
    background: '#161624',
    color: '#aab',
    fontSize: 14,
    cursor: 'pointer',
  },
};
