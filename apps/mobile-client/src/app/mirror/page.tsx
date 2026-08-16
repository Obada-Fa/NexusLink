'use client';

// The phone-OS app viewport: streams an adopted host window (or the full desktop)
// edge-to-edge (no letterbox bars). Chrome overlays the stream so adopt uses the
// real stage size — matching the Flutter client's immersive layout.

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
  };
}

/** Stage size for adopt — never the full window (chrome must not skew aspect). */
function readStageSize(el: HTMLElement | null): { w: number; h: number } {
  if (el) {
    const r = el.getBoundingClientRect();
    if (r.width >= 32 && r.height >= 32) {
      return { w: Math.round(r.width), h: Math.round(r.height) };
    }
  }
  // Fallback before first layout: visualViewport tracks mobile browser chrome.
  const vv = typeof window !== 'undefined' ? window.visualViewport : null;
  return {
    w: Math.round(vv?.width ?? window.innerWidth),
    h: Math.round(vv?.height ?? window.innerHeight),
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
  const [chromeVisible, setChromeVisible] = useState(true);

  const streamIdRef = useRef<string | null>(null);
  const windowIdRef = useRef<string | null>(null);
  const imgRef = useRef<HTMLImageElement | null>(null);
  const viewportRef = useRef<HTMLDivElement | null>(null);
  const unsubRef = useRef<(() => void) | null>(null);
  const frameCountRef = useRef(0);
  const startedRef = useRef(false);
  const kbRef = useRef<HTMLInputElement | null>(null);
  const lastAdoptRef = useRef<{ w: number; h: number } | null>(null);
  const chromeHideTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    setTarget(parseTarget());
  }, []);

  // Soft-hide chrome a few seconds after streaming starts (tap top edge to reveal).
  useEffect(() => {
    if (phase !== 'streaming') return;
    if (chromeHideTimer.current) clearTimeout(chromeHideTimer.current);
    chromeHideTimer.current = setTimeout(() => setChromeVisible(false), 2500);
    return () => {
      if (chromeHideTimer.current) clearTimeout(chromeHideTimer.current);
    };
  }, [phase]);

  const bumpChrome = useCallback(() => {
    setChromeVisible(true);
    if (chromeHideTimer.current) clearTimeout(chromeHideTimer.current);
    chromeHideTimer.current = setTimeout(() => setChromeVisible(false), 3000);
  }, []);

  // Re-shape the host window whenever the stage size changes (rotate, keyboard).
  const syncAdopt = useCallback(
    async (force = false) => {
      const windowId = windowIdRef.current;
      if (!windowId || !client || status !== 'connected') return;
      const { w, h } = readStageSize(viewportRef.current);
      const prev = lastAdoptRef.current;
      if (
        !force &&
        prev &&
        Math.abs(prev.w - w) < 8 &&
        Math.abs(prev.h - h) < 8
      ) {
        return;
      }
      lastAdoptRef.current = { w, h };
      try {
        const res = (await client.request('window.adopt', {
          windowId,
          viewportW: w,
          viewportH: h,
        })) as { region?: HostRegion };
        if (res?.region) setRegion(res.region);
      } catch {
        // WM may reject mid-drag; next resize will retry.
      }
    },
    [client, status],
  );

  // ---- session bring-up: (launch →) adopt → capture ------------------------
  useEffect(() => {
    if (status !== 'connected' || !client || !target || startedRef.current) return;
    startedRef.current = true;
    let cancelled = false;

    const begin = async () => {
      try {
        let windowId = target.windowId ?? null;

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
          if (!windowId) {
            throw new Error(
              'The app started but no window appeared yet. Go back and tap it under "Open on your PC".',
            );
          }
        }
        if (cancelled) return;

        // Wait one frame so the full-bleed stage has a real layout size.
        await new Promise<void>((r) => requestAnimationFrame(() => r()));
        if (cancelled) return;

        // Adopt: shape the window to the stage aspect (not the full window —
        // overlay chrome must not introduce letterboxing).
        let captureParams: Record<string, unknown> = { quality: 'medium', fps: 24 };
        if (windowId) {
          setPhase('adopting');
          windowIdRef.current = windowId;
          const { w, h } = readStageSize(viewportRef.current);
          lastAdoptRef.current = { w, h };
          await client.request('window.adopt', {
            windowId,
            viewportW: w,
            viewportH: h,
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
          if (lastUrl) URL.revokeObjectURL(lastUrl);
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

  // Keep host window aspect locked to the stage (rotate / keyboard / resize).
  useEffect(() => {
    if (phase !== 'streaming' || !windowIdRef.current) return;
    const el = viewportRef.current;
    if (!el || typeof ResizeObserver === 'undefined') return;
    let debounce: ReturnType<typeof setTimeout> | null = null;
    const ro = new ResizeObserver(() => {
      if (debounce) clearTimeout(debounce);
      debounce = setTimeout(() => {
        void syncAdopt(false);
      }, 120);
    });
    ro.observe(el);
    return () => {
      ro.disconnect();
      if (debounce) clearTimeout(debounce);
    };
  }, [phase, syncAdopt]);

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

  const goHome = useCallback(() => {
    teardown(true);
    router.push('/');
  }, [teardown, router]);

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
      client?.request('input.keyEvent', { key }).catch(() => {});
    },
    [client],
  );

  const onKbInput = useCallback(() => {
    const el = kbRef.current;
    if (!el || !client) return;
    const text = el.value;
    if (text) {
      client.request('input.typeText', { text }).catch(() => {});
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
    if (kbOpen) {
      kbRef.current?.focus();
      bumpChrome();
    } else {
      void syncAdopt(true);
    }
  }, [kbOpen, bumpChrome, syncAdopt]);

  const title = target?.title || (target?.windowId || target?.appId ? 'App' : 'Desktop');
  const streaming = phase === 'streaming';

  return (
    <div style={styles.wrapper}>
      {/* Full-bleed stage — always mounted so adopt can measure it. */}
      <div
        ref={viewportRef}
        style={styles.viewport}
        onPointerDown={(e) => {
          // Tap near the top edge reveals chrome without stealing gestures mid-drag.
          if (e.clientY < 48) bumpChrome();
        }}
      >
        {streaming ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img ref={imgRef} alt="host screen" style={styles.frame} draggable={false} />
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
            <style
              dangerouslySetInnerHTML={{
                __html: '@keyframes nl-spin{to{transform:rotate(360deg)}}',
              }}
            />
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
        {streaming && (
          <GestureOverlay viewportRef={viewportRef} region={region} showHud={chromeVisible} />
        )}
      </div>

      {/* Overlay chrome — does not shrink the stage / adopt aspect. */}
      <header
        style={{
          ...styles.topBar,
          opacity: chromeVisible || !streaming ? 1 : 0,
          pointerEvents: chromeVisible || !streaming ? 'auto' : 'none',
          transform: chromeVisible || !streaming ? 'translateY(0)' : 'translateY(-8px)',
        }}
      >
        <button onClick={goHome} style={styles.barBtn} aria-label="Home">
          {'⌂'}
        </button>
        <span style={styles.title}>
          {title}
          {streaming && fps > 0 ? ` · ${fps}fps` : ''}
        </span>
        <button
          onClick={() => {
            bumpChrome();
            setKbOpen((v) => !v);
          }}
          style={{ ...styles.barBtn, color: kbOpen ? '#2a6aff' : '#e8e8f0' }}
          aria-label="Keyboard"
        >
          {'⌨'}
        </button>
      </header>

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
          <button style={styles.kbKey} onClick={() => sendSpecialKey('BackSpace')}>
            ⌫
          </button>
          <button style={styles.kbKey} onClick={() => sendSpecialKey('Return')}>
            ⏎
          </button>
          <button style={styles.kbKey} onClick={() => sendSpecialKey('Escape')}>
            Esc
          </button>
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
    position: 'relative',
    height: '100dvh',
    width: '100%',
    background: '#000',
    color: '#e0e0e0',
    fontFamily: 'system-ui, sans-serif',
    overflow: 'hidden',
  },
  viewport: {
    position: 'absolute',
    inset: 0,
    touchAction: 'none',
    userSelect: 'none',
    WebkitUserSelect: 'none',
    background: '#000',
    overflow: 'hidden',
  },
  frame: {
    // Edge-to-edge: cover the stage. Adopt matches stage aspect so crop is tiny;
    // residual WM rounding is cropped rather than letterboxed (no black bars).
    position: 'absolute',
    inset: 0,
    width: '100%',
    height: '100%',
    objectFit: 'cover',
    objectPosition: 'center',
    pointerEvents: 'none',
    display: 'block',
  },
  topBar: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    zIndex: 5,
    display: 'flex',
    alignItems: 'center',
    gap: 8,
    padding: 'calc(6px + env(safe-area-inset-top)) 10px 6px',
    background: 'linear-gradient(to bottom, rgba(0,0,0,0.72), rgba(0,0,0,0.28), transparent)',
    transition: 'opacity 0.25s ease, transform 0.25s ease',
  },
  barBtn: {
    width: 34,
    height: 30,
    borderRadius: 8,
    border: '1px solid rgba(255,255,255,0.18)',
    background: 'rgba(0,0,0,0.35)',
    color: '#e8e8f0',
    fontSize: 16,
    cursor: 'pointer',
    lineHeight: 1,
  },
  title: {
    fontSize: 13,
    fontWeight: 600,
    color: '#f0f0f5',
    flex: 1,
    textAlign: 'center',
    whiteSpace: 'nowrap',
    overflow: 'hidden',
    textOverflow: 'ellipsis',
    textShadow: '0 1px 2px rgba(0,0,0,0.8)',
  },
  centerBox: {
    position: 'absolute',
    inset: 0,
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
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    zIndex: 6,
    display: 'flex',
    gap: 6,
    padding: '8px 10px calc(8px + env(safe-area-inset-bottom))',
    background: 'rgba(15,15,26,0.94)',
    borderTop: '1px solid #1c1c30',
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
