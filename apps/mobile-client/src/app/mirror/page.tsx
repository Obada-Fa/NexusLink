'use client';

import { useEffect, useState, useCallback, useRef } from 'react';
import { useRouter } from 'next/navigation';
import { useConnectionStore } from '@/store/connection';
import GestureOverlay from '@/components/GestureOverlay';

export default function MirrorPage() {
  const status = useConnectionStore((s) => s.status);
  const client = useConnectionStore((s) => s.client);
  const connect = useConnectionStore((s) => s.connect);
  const hostUrl = useConnectionStore((s) => s.hostUrl);
  const router = useRouter();

  const handleReconnect = useCallback(async () => {
    if (!hostUrl) return;
    try { await connect(hostUrl); } catch { /* handled by store */ }
  }, [connect, hostUrl]);

  const [mirrorActive, setMirrorActive] = useState(false);
  const [streamId, setStreamId] = useState<string | null>(null);
  const viewportRef = useRef<HTMLDivElement | null>(null);

  const startMirror = useCallback(async () => {
    if (!client || status !== 'connected') return;
    try {
      const result = (await client.request('screen.startCapture', {
        quality: 'medium',
        fps: 15,
      })) as { streamId: string };
      setStreamId(result.streamId);
      setMirrorActive(true);

      client.subscribe('stream-frame', (_msg: unknown) => {
        // placeholder: frames would be rendered to canvas
      });
    } catch {
      // screen capture not available on this host
      setMirrorActive(true);
    }
  }, [client, status]);

  const stopMirror = useCallback(async () => {
    if (streamId && client) {
      try {
        await client.request('screen.stopCapture', { streamId });
      } catch {
        // ignore
      }
    }
    setStreamId(null);
    setMirrorActive(false);
  }, [client, streamId]);

  useEffect(() => {
    return () => {
      if (streamId && client) {
        client.request('screen.stopCapture', { streamId }).catch(() => {});
      }
    };
  }, [streamId, client]);

  return (
    <div style={styles.wrapper}>
      <header style={styles.topBar}>
        <button onClick={() => router.back()} style={styles.backBtn}>
          \u2190 Back
        </button>
        <span style={styles.title}>Mirror</span>
        {status === 'connected' ? (
          <>
            {mirrorActive ? <GestureOverlay viewportRef={viewportRef} /> : null}
            <button
              onClick={() => {
                if (mirrorActive) stopMirror();
                else startMirror();
              }}
              style={{
                ...styles.toggleBtn,
                background: mirrorActive ? '#2a6aff' : '#1a2a1e',
                color: mirrorActive ? '#fff' : '#4ade80',
                borderColor: mirrorActive ? '#2a6aff' : '#1e3a1e',
              }}
            >
              {mirrorActive ? 'Stop' : 'Start'}
            </button>
          </>
        ) : (
          <button onClick={handleReconnect} style={styles.reconnectBtn}>
            Reconnect
          </button>
        )}
      </header>

      {status !== 'connected' || !client ? (
        <div style={styles.disconnectedOverlay}>
          <span style={styles.disconnectedIcon}>{'\u26A0'}</span>
          <span style={styles.disconnectedText}>Not connected.</span>
          <button onClick={handleReconnect} style={styles.reconnectBtnLarge}>
            Reconnect
          </button>
        </div>
      ) : (
        <div style={styles.stage}>
          {!mirrorActive ? (
            <div style={styles.placeholder}>
              <span style={styles.placeholderIcon}>{'\u{1F4FA}'}</span>
              <p style={styles.placeholderText}>Screen mirror inactive</p>
              <p style={styles.placeholderHint}>
                Tap Start to begin screen capture
              </p>
            </div>
          ) : (
            <div style={styles.videoPlaceholder}>
              <span style={styles.placeholderIcon}>{'\u{1F4FA}'}</span>
              <p style={styles.placeholderText}>Screen streaming active</p>
              <p style={styles.placeholderHint}>
                {streamId ? `Stream: ${streamId.slice(0, 8)}...` : 'Connecting...'}
              </p>
              <div ref={viewportRef} style={styles.videoFrame}>
                <p style={styles.videoFrameText}>Video frames render here</p>
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  disconnectedOverlay: {
    flex: 1,
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    justifyContent: 'center',
    gap: '12px',
  },
  disconnectedIcon: {
    fontSize: '36px',
  },
  disconnectedText: {
    fontSize: '14px',
    color: '#555',
  },
  reconnectBtn: {
    padding: '4px 10px',
    borderRadius: '6px',
    border: '1px solid #2a3a6a',
    background: '#141420',
    color: '#2a6aff',
    fontSize: '11px',
    fontWeight: 600,
    cursor: 'pointer',
  },
  reconnectBtnLarge: {
    padding: '10px 24px',
    borderRadius: '8px',
    border: 'none',
    background: '#2a6aff',
    color: '#fff',
    fontSize: '13px',
    fontWeight: 600,
    cursor: 'pointer',
  },
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
  toggleBtn: {
    padding: '6px 14px',
    borderRadius: '6px',
    border: '1px solid',
    fontSize: '12px',
    fontWeight: 600,
    cursor: 'pointer',
  },
  stage: {
    flex: 1,
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
  },
  placeholder: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: '12px',
    color: '#444',
  },
  placeholderIcon: {
    fontSize: '48px',
  },
  placeholderText: {
    fontSize: '16px',
    fontWeight: 500,
    color: '#555',
    margin: 0,
  },
  placeholderHint: {
    fontSize: '12px',
    color: '#444',
    margin: 0,
  },
  videoPlaceholder: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: '12px',
    width: '100%',
    height: '100%',
    padding: '20px',
    boxSizing: 'border-box',
  },
  videoFrame: {
    width: '100%',
    flex: 1,
    background: '#111118',
    borderRadius: '8px',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    border: '1px solid #1e1e30',
  },
  videoFrameText: {
    color: '#333',
    fontSize: '14px',
    margin: 0,
  },
};
