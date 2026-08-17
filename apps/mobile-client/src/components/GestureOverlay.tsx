'use client';

import { useEffect, useRef, useState, useCallback } from 'react';
import { GestureEngine, type GestureEvent } from '@nexuslink/gesture-engine';
import { useConnectionStore } from '@/store/connection';

type PrecisionMode = 'normal' | 'precision';

export interface HostRegion {
  x: number;
  y: number;
  width: number;
  height: number;
}

export default function GestureOverlay({
  viewportRef,
  region,
  sessionId,
  showHud = true,
}: {
  viewportRef: React.RefObject<HTMLDivElement | null>;
  /** Captured host region (adopted window). Touch coords map into this rect. */
  region?: HostRegion | null;
  /** Virtual app session: inputs inject into that session's own display. */
  sessionId?: string;
  showHud?: boolean;
}) {
  const client = useConnectionStore((s) => s.client);
  const status = useConnectionStore((s) => s.status);

  const engineRef = useRef<GestureEngine | null>(null);
  const regionRef = useRef<HostRegion | null>(region ?? null);
  regionRef.current = region ?? null;
  const [precision, setPrecision] = useState<PrecisionMode>('normal');
  const [lastGesture, setLastGesture] = useState<string>('');

  const handleGesture = useCallback(
    (event: GestureEvent) => {
      if (!client || status !== 'connected') return;

      // Per-window capture: gesture x/y are in captured-region space; shift them
      // to absolute host coordinates before injection. Virtual sessions map 1:1
      // (region origin is always 0,0) and carry their sessionId instead.
      const off = regionRef.current;
      const ox = off ? off.x : 0;
      const oy = off ? off.y : 0;
      const sid = sessionId ? { sessionId } : {};

      // Fire-and-forget: input is latency-sensitive, so we never await the RPC.
      switch (event.type) {
        case 'mouse-move':
          setLastGesture(`move ${event.dx},${event.dy}`);
          client.request('input.mouseMove', { dx: event.dx, dy: event.dy, ...sid }).catch(() => {});
          break;
        case 'mouse-click':
          setLastGesture(`${event.button} click`);
          client
            .request('input.mouseClick', { button: event.button, x: event.x + ox, y: event.y + oy, ...sid })
            .catch(() => {});
          break;
        case 'mouse-dbl-click': {
          setLastGesture('dbl-click');
          const dx = event.x + ox;
          const dy = event.y + oy;
          // Two clicks 50ms apart so the host registers a native double-click.
          client.request('input.mouseClick', { button: 'left', x: dx, y: dy, ...sid }).catch(() => {});
          setTimeout(() => {
            client.request('input.mouseClick', { button: 'left', x: dx, y: dy, ...sid }).catch(() => {});
          }, 50);
          break;
        }
        case 'mouse-scroll':
          setLastGesture(`scroll ${event.deltaX},${event.deltaY}${event.inertial ? ' ~' : ''}`);
          client
            .request('input.mouseScroll', {
              deltaX: event.deltaX,
              deltaY: event.deltaY,
              x: event.x + ox,
              y: event.y + oy,
              ...sid,
            })
            .catch(() => {});
          break;
        case 'drag-start':
          setLastGesture(`drag ${event.x},${event.y}`);
          client
            .request('input.buttonDown', { button: 'left', x: event.x + ox, y: event.y + oy, ...sid })
            .catch(() => {});
          break;
        case 'drag-move':
          client.request('input.mouseMoveAbs', { x: event.x + ox, y: event.y + oy, ...sid }).catch(() => {});
          break;
        case 'drag-end':
          setLastGesture('drag end');
          client
            .request('input.buttonUp', { button: 'left', x: event.x + ox, y: event.y + oy, ...sid })
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
              ...sid,
            })
            .catch(() => {});
          break;
      }
    },
    [client, status, sessionId],
  );

  useEffect(() => {
    const el = viewportRef.current;
    if (!el) return;

    const callbacks = { onGesture: handleGesture };
    // Native touch: tap/drag at the finger. Trackpad is the Precision toggle.
    const engine = new GestureEngine(el, callbacks, { mode: 'direct' });
    engine.attach();
    if (sessionId) engine.setFit('fill');
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
  }, [viewportRef, handleGesture, client, status, region, sessionId]);

  useEffect(() => {
    const engine = engineRef.current;
    if (!engine) return;
    // Precision mode switches the engine to relative-cursor control with reduced
    // sensitivity for fine targeting (architecture.md Module C2).
    engine.setPrecision(precision === 'precision');
  }, [precision]);

  const togglePrecision = useCallback(() => {
    setPrecision((prev) => (prev === 'normal' ? 'precision' : 'normal'));
  }, []);

  if (!showHud) return null;

  return (
    <>
      <button
        onClick={togglePrecision}
        style={{
          ...styles.precisionBtn,
          background: precision === 'precision' ? '#2a6aff' : 'transparent',
          color: precision === 'precision' ? '#fff' : '#888',
          borderColor: precision === 'precision' ? '#2a6aff' : '#333',
        }}
        aria-label={`Precision mode: ${precision}`}
      >
        {precision === 'precision' ? 'Mouse' : 'Touch'}
      </button>

      {lastGesture ? (
        <span style={styles.gestureHint}>{lastGesture}</span>
      ) : null}
    </>
  );
}

const styles: Record<string, React.CSSProperties> = {
  precisionBtn: {
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
