'use client';

import { useEffect, useRef, useState, useCallback } from 'react';
import { GestureEngine, type GestureEvent } from '@nexuslink/gesture-engine';
import { useConnectionStore } from '@/store/connection';

/** RustDesk-style input paradigm for the mirror viewport. */
type InputMode = 'touch' | 'mouse';

export interface HostRegion {
  x: number;
  y: number;
  width: number;
  height: number;
}

export default function GestureOverlay({
  viewportRef,
  region,
  showHud = true,
}: {
  viewportRef: React.RefObject<HTMLDivElement | null>;
  /** Captured host region (adopted window). Touch coords map into this rect. */
  region?: HostRegion | null;
  showHud?: boolean;
}) {
  const client = useConnectionStore((s) => s.client);
  const status = useConnectionStore((s) => s.status);

  const engineRef = useRef<GestureEngine | null>(null);
  const regionRef = useRef<HostRegion | null>(region ?? null);
  regionRef.current = region ?? null;
  const [inputMode, setInputMode] = useState<InputMode>('touch');
  const [lastGesture, setLastGesture] = useState<string>('');

  const handleGesture = useCallback(
    (event: GestureEvent) => {
      if (!client || status !== 'connected') return;

      // Per-window capture: gesture x/y are in captured-region space; shift them
      // to absolute host coordinates before injection.
      const off = regionRef.current;
      const ox = off ? off.x : 0;
      const oy = off ? off.y : 0;

      // Fire-and-forget: input is latency-sensitive, so we never await the RPC.
      switch (event.type) {
        case 'mouse-move':
          setLastGesture(`move ${event.dx},${event.dy}`);
          client.request('input.mouseMove', { dx: event.dx, dy: event.dy }).catch(() => {});
          break;
        case 'mouse-click':
          setLastGesture(`${event.button} click`);
          client
            .request('input.mouseClick', { button: event.button, x: event.x + ox, y: event.y + oy })
            .catch(() => {});
          break;
        case 'mouse-dbl-click': {
          setLastGesture('dbl-click');
          const dx = event.x + ox;
          const dy = event.y + oy;
          // Two clicks 50ms apart so the host registers a native double-click.
          client.request('input.mouseClick', { button: 'left', x: dx, y: dy }).catch(() => {});
          setTimeout(() => {
            client.request('input.mouseClick', { button: 'left', x: dx, y: dy }).catch(() => {});
          }, 50);
          break;
        }
        case 'mouse-scroll':
          setLastGesture(`scroll ${event.deltaX},${event.deltaY}${event.inertial ? ' ~' : ''}`);
          client
            .request('input.mouseScroll', {
              deltaX: event.deltaX,
              deltaY: event.deltaY,
              // Mouse mode scrolls at the cursor; touch mode scrolls at fingers.
              ...(inputMode === 'touch' ? { x: event.x + ox, y: event.y + oy } : {}),
            })
            .catch(() => {});
          break;
        case 'drag-start':
          setLastGesture(`drag ${event.x},${event.y}`);
          client
            .request('input.buttonDown', { button: 'left', x: event.x + ox, y: event.y + oy })
            .catch(() => {});
          break;
        case 'drag-move':
          client.request('input.mouseMoveAbs', { x: event.x + ox, y: event.y + oy }).catch(() => {});
          break;
        case 'drag-end':
          setLastGesture('drag end');
          client
            .request('input.buttonUp', { button: 'left', x: event.x + ox, y: event.y + oy })
            .catch(() => {});
          break;
        case 'zoom':
          // Pinch-zoom → Ctrl+wheel at the pinch midpoint. scale is a signed
          // delta; positive = fingers apart = zoom in = wheel up (negative dy).
          setLastGesture(`zoom ${event.scale.toFixed(2)}`);
          client
            .request('input.mouseScroll', {
              deltaX: 0,
              deltaY: -event.scale * 400,
              x: event.x + ox,
              y: event.y + oy,
              modifiers: ['ctrl'],
            })
            .catch(() => {});
          break;
      }
    },
    [client, status, inputMode],
  );

  useEffect(() => {
    const el = viewportRef.current;
    if (!el) return;

    const callbacks = { onGesture: handleGesture };
    // RustDesk-style touch mode: one-finger pan = left drag at absolute coords.
    const engine = new GestureEngine(el, callbacks, { mode: 'touch' });
    engine.attach();
    engineRef.current = engine;

    // Adopted-window mode: touch space IS the captured region. Otherwise fall
    // back to full-screen metadata.
    if (region && region.width > 0 && region.height > 0) {
      engine.setHostDimensions(region.width, region.height);
    } else if (client && status === 'connected') {
      client
        .request('screen.getMetadata')
        .then((data: unknown) => {
          const meta = data as { width: number; height: number };
          if (meta.width && meta.height) {
            engine.setHostDimensions(meta.width, meta.height);
          }
        })
        .catch(() => {
          // Default 1920x1080 already set
        });
    }

    return () => {
      engine.detach();
      engineRef.current = null;
    };
  }, [viewportRef, handleGesture, client, status, region]);

  useEffect(() => {
    const engine = engineRef.current;
    if (!engine) return;
    // Touch ↔ Mouse mirrors RustDesk's touchMode toggle.
    engine.setMode(inputMode === 'touch' ? 'touch' : 'trackpad');
    engine.setPrecision(false);
  }, [inputMode]);

  const toggleInputMode = useCallback(() => {
    setInputMode((prev) => (prev === 'touch' ? 'mouse' : 'touch'));
  }, []);

  if (!showHud) return null;

  return (
    <>
      <button
        onClick={toggleInputMode}
        style={{
          ...styles.modeBtn,
          background: inputMode === 'touch' ? '#2a6aff' : 'transparent',
          color: inputMode === 'touch' ? '#fff' : '#888',
          borderColor: inputMode === 'touch' ? '#2a6aff' : '#333',
        }}
        aria-label={
          inputMode === 'touch'
            ? 'Touch mode: tap = click, drag = drag, 2 fingers = scroll'
            : 'Mouse mode: 1 finger moves the cursor, 2 fingers scroll'
        }
        title={
          inputMode === 'touch'
            ? 'Touch mode (tap/drag). Switch to Mouse.'
            : 'Mouse mode (relative cursor). Switch to Touch.'
        }
      >
        {inputMode === 'touch' ? 'Touch' : 'Mouse'}
      </button>

      {lastGesture ? (
        <span style={styles.gestureHint}>{lastGesture}</span>
      ) : null}
    </>
  );
}

const styles: Record<string, React.CSSProperties> = {
  modeBtn: {
    padding: '4px 10px',
    borderRadius: '4px',
    border: '1px solid',
    fontSize: '11px',
    fontWeight: 600,
    cursor: 'pointer',
    background: 'transparent',
    transition: 'background 0.15s, color 0.15s',
  },
  gestureHint: {
    fontSize: '10px',
    color: '#555',
    fontFamily: 'monospace',
    whiteSpace: 'nowrap',
    overflow: 'hidden',
    textOverflow: 'ellipsis',
    maxWidth: '140px',
  },
};
