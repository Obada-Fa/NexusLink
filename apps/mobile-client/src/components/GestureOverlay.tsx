'use client';

import { useEffect, useRef, useState, useCallback } from 'react';
import { GestureEngine, type GestureEvent } from '@nexuslink/gesture-engine';
import { useConnectionStore } from '@/store/connection';

type PrecisionMode = 'normal' | 'precision';

export default function GestureOverlay({
  viewportRef,
}: {
  viewportRef: React.RefObject<HTMLDivElement | null>;
}) {
  const client = useConnectionStore((s) => s.client);
  const status = useConnectionStore((s) => s.status);

  const engineRef = useRef<GestureEngine | null>(null);
  const [precision, setPrecision] = useState<PrecisionMode>('normal');
  const [lastGesture, setLastGesture] = useState<string>('');

  const handleGesture = useCallback(
    (event: GestureEvent) => {
      if (!client || status !== 'connected') return;

      switch (event.type) {
        case 'mouse-move':
          setLastGesture(`move ${event.dx},${event.dy}`);
          client.request('input.mouseMove', { dx: event.dx, dy: event.dy }).catch(() => {});
          break;
        case 'mouse-click':
          setLastGesture(`${event.button} click`);
          client
            .request('input.mouseClick', {
              button: event.button,
              x: event.x,
              y: event.y,
            })
            .catch(() => {});
          break;
        case 'mouse-dbl-click':
          setLastGesture('dbl-click');
          client
            .request('input.mouseClick', {
              button: 'left',
              x: event.x,
              y: event.y,
            })
            .catch(() => {});
          break;
        case 'mouse-scroll':
          setLastGesture(`scroll ${event.deltaX},${event.deltaY}`);
          client
            .request('input.mouseScroll', {
              deltaX: event.deltaX,
              deltaY: event.deltaY,
              x: event.x,
              y: event.y,
            })
            .catch(() => {});
          break;
      }
    },
    [client, status],
  );

  useEffect(() => {
    const el = viewportRef.current;
    if (!el) return;

    const callbacks = { onGesture: handleGesture };
    const engine = new GestureEngine(el, callbacks);
    engine.attach();
    engineRef.current = engine;

    // Fetch host dimensions from screen metadata
    if (client && status === 'connected') {
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
  }, [viewportRef, handleGesture, client, status]);

  useEffect(() => {
    const engine = engineRef.current;
    if (!engine) return;

    void engine;

    // Precision mode handled via CSS cursor and visual indicator
    // Actual sensitivity change would be in a gesture config update
  }, [precision]);

  const togglePrecision = useCallback(() => {
    setPrecision((prev) => (prev === 'normal' ? 'precision' : 'normal'));
  }, []);

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
        {precision === 'precision' ? 'Precision: ON' : 'Precision: OFF'}
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
