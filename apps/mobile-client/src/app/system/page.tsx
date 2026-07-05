'use client';

import { useEffect, useState, useRef, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { useConnectionStore } from '@/store/connection';
import { Sparkline } from '@nexuslink/ui-components';

interface SystemInfo {
  os: string;
  hostname: string;
  cpuModel: string;
  totalRamGb: number;
  uptimeSeconds: number;
  username: string;
  homeDir: string;
}

interface PerfSnapshot {
  cpuPercent: number;
  ramPercent: number;
  ramUsedGb: number;
  netInKBs: number;
  netOutKBs: number;
  diskReadMBs: number;
  diskWriteMBs: number;
}

function formatUptime(seconds: number): string {
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d > 0) return `${d}d ${h}h ${m}m`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

function formatNet(kbs: number): string {
  if (kbs < 1024) return `${kbs.toFixed(0)} KB/s`;
  return `${(kbs / 1024).toFixed(1)} MB/s`;
}

export default function SystemPage() {
  const client = useConnectionStore((s) => s.client);
  const status = useConnectionStore((s) => s.status);
  const router = useRouter();

  const [info, setInfo] = useState<SystemInfo | null>(null);
  const [perf, setPerf] = useState<PerfSnapshot | null>(null);
  const [cpuHistory, setCpuHistory] = useState<number[]>([]);
  const [ramHistory, setRamHistory] = useState<number[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  const maxHistory = 40;

  const addCpu = useCallback((val: number) => {
    setCpuHistory((prev) => {
      const next = [...prev, val];
      return next.length > maxHistory ? next.slice(next.length - maxHistory) : next;
    });
  }, []);

  const addRam = useCallback((val: number) => {
    setRamHistory((prev) => {
      const next = [...prev, val];
      return next.length > maxHistory ? next.slice(next.length - maxHistory) : next;
    });
  }, []);

  useEffect(() => {
    if (status !== 'connected' || !client) return;
    let disposed = false;

    async function load() {
      try {
        const [infoResult, perfResult] = await Promise.all([
          client!.request('system.getInfo', {}),
          client!.request('system.getPerf', {}),
        ]);
        if (disposed) return;
        setInfo(infoResult as SystemInfo);
        const p = perfResult as PerfSnapshot;
        setPerf(p);
        addCpu(p.cpuPercent);
        addRam(p.ramPercent);
      } catch (err) {
        if (!disposed) {
          setError(err instanceof Error ? err.message : 'Failed to fetch system data');
        }
      } finally {
        if (!disposed) setLoading(false);
      }
    }

    load();

    const unsub = client.subscribe('perf-update', (msg: unknown) => {
      if (disposed) return;
      const m = msg as { data?: PerfSnapshot };
      const data = m.data;
      if (!data) return;
      setPerf(data);
      addCpu(data.cpuPercent);
      addRam(data.ramPercent);
    });

    return () => {
      disposed = true;
      unsub();
    };
  }, [client, status, addCpu, addRam]);

  if (status !== 'connected' || !client) {
    return (
      <div style={styles.wrapper}>
        <header style={styles.topBar}>
          <button onClick={() => router.back()} style={styles.backBtn}>
            \u2190 Back
          </button>
          <span style={styles.title}>System</span>
        </header>
        <div style={styles.emptyState}>Not connected.</div>
      </div>
    );
  }

  if (loading) {
    return (
      <div style={styles.wrapper}>
        <header style={styles.topBar}>
          <button onClick={() => router.back()} style={styles.backBtn}>
            \u2190 Back
          </button>
          <span style={styles.title}>System</span>
        </header>
        <div style={styles.emptyState}>Loading...</div>
      </div>
    );
  }

  return (
    <div style={styles.wrapper}>
      <header style={styles.topBar}>
        <button onClick={() => router.back()} style={styles.backBtn}>
          \u2190 Back
        </button>
        <span style={styles.title}>System</span>
        {perf && (
          <span style={styles.liveBadge}>LIVE</span>
        )}
      </header>

      <div style={styles.scrollArea}>
        {error && <div style={styles.errorBanner}>{error}</div>}

        {info && (
          <section style={styles.section}>
            <h3 style={styles.sectionTitle}>Info</h3>
            <div style={styles.cardGrid}>
              <div style={styles.infoCard}>
                <span style={styles.cardLabel}>Hostname</span>
                <span style={styles.cardValue}>{info.hostname}</span>
              </div>
              <div style={styles.infoCard}>
                <span style={styles.cardLabel}>OS</span>
                <span style={styles.cardValue}>{info.os}</span>
              </div>
              <div style={styles.infoCard}>
                <span style={styles.cardLabel}>CPU</span>
                <span style={styles.cardValueSmall}>{info.cpuModel}</span>
              </div>
              <div style={styles.infoCard}>
                <span style={styles.cardLabel}>RAM Total</span>
                <span style={styles.cardValue}>{info.totalRamGb.toFixed(1)} GB</span>
              </div>
              <div style={styles.infoCard}>
                <span style={styles.cardLabel}>Uptime</span>
                <span style={styles.cardValue}>{formatUptime(info.uptimeSeconds)}</span>
              </div>
              <div style={styles.infoCard}>
                <span style={styles.cardLabel}>User</span>
                <span style={styles.cardValue}>{info.username}</span>
              </div>
            </div>
          </section>
        )}

        {perf && (
          <section style={styles.section}>
            <h3 style={styles.sectionTitle}>Performance</h3>
            <div style={styles.cardGrid}>
              <div style={styles.perfCard}>
                <div style={styles.perfCardTop}>
                  <span style={styles.cardLabel}>CPU</span>
                  <span style={styles.perfValue}>{perf.cpuPercent.toFixed(1)}%</span>
                </div>
                <Sparkline data={cpuHistory} color="#f0c040" />
                <div style={styles.perfBarBg}>
                  <div
                    style={{
                      ...styles.perfBarFill,
                      width: `${Math.min(perf.cpuPercent, 100)}%`,
                      background: perf.cpuPercent > 80 ? '#e55' : '#f0c040',
                    }}
                  />
                </div>
              </div>

              <div style={styles.perfCard}>
                <div style={styles.perfCardTop}>
                  <span style={styles.cardLabel}>RAM</span>
                  <span style={styles.perfValue}>{perf.ramPercent.toFixed(1)}%</span>
                </div>
                <Sparkline data={ramHistory} color="#60a5fa" />
                <div style={styles.perfBarBg}>
                  <div
                    style={{
                      ...styles.perfBarFill,
                      width: `${Math.min(perf.ramPercent, 100)}%`,
                      background: perf.ramPercent > 80 ? '#e55' : '#60a5fa',
                    }}
                  />
                </div>
                <span style={styles.perfSub}>
                  {perf.ramUsedGb.toFixed(1)} / {info?.totalRamGb.toFixed(1)} GB
                </span>
              </div>

              <div style={styles.perfCard}>
                <div style={styles.perfCardTop}>
                  <span style={styles.cardLabel}>Network \u2193</span>
                  <span style={styles.perfValue}>{formatNet(perf.netInKBs)}</span>
                </div>
              </div>

              <div style={styles.perfCard}>
                <div style={styles.perfCardTop}>
                  <span style={styles.cardLabel}>Network \u2191</span>
                  <span style={styles.perfValue}>{formatNet(perf.netOutKBs)}</span>
                </div>
              </div>

              <div style={styles.perfCard}>
                <div style={styles.perfCardTop}>
                  <span style={styles.cardLabel}>Disk Read</span>
                  <span style={styles.perfValue}>
                    {perf.diskReadMBs < 1
                      ? `${(perf.diskReadMBs * 1024).toFixed(0)} KB/s`
                      : `${perf.diskReadMBs.toFixed(1)} MB/s`}
                  </span>
                </div>
              </div>

              <div style={styles.perfCard}>
                <div style={styles.perfCardTop}>
                  <span style={styles.cardLabel}>Disk Write</span>
                  <span style={styles.perfValue}>
                    {perf.diskWriteMBs < 1
                      ? `${(perf.diskWriteMBs * 1024).toFixed(0)} KB/s`
                      : `${perf.diskWriteMBs.toFixed(1)} MB/s`}
                  </span>
                </div>
              </div>
            </div>
          </section>
        )}
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
  liveBadge: {
    fontSize: '10px',
    fontWeight: 700,
    color: '#4ade80',
    background: '#1a2a1e',
    padding: '3px 8px',
    borderRadius: '4px',
  },
  scrollArea: {
    flex: 1,
    overflow: 'auto',
    padding: '12px',
  },
  emptyState: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    flex: 1,
    color: '#555',
    fontSize: '14px',
  },
  errorBanner: {
    padding: '8px 12px',
    marginBottom: '12px',
    borderRadius: '6px',
    background: '#2a1010',
    color: '#e55',
    fontSize: '12px',
    border: '1px solid #3a1a1a',
  },
  section: {
    marginBottom: '20px',
  },
  sectionTitle: {
    fontSize: '13px',
    fontWeight: 600,
    color: '#666',
    textTransform: 'uppercase',
    letterSpacing: '0.5px',
    margin: '0 0 10px',
  },
  cardGrid: {
    display: 'grid',
    gridTemplateColumns: 'repeat(2, 1fr)',
    gap: '8px',
  },
  infoCard: {
    display: 'flex',
    flexDirection: 'column',
    gap: '4px',
    padding: '12px',
    background: '#141420',
    borderRadius: '10px',
    border: '1px solid #1e1e30',
  },
  cardLabel: {
    fontSize: '10px',
    color: '#666',
    textTransform: 'uppercase',
    fontWeight: 600,
  },
  cardValue: {
    fontSize: '14px',
    color: '#ccc',
    fontWeight: 500,
  },
  cardValueSmall: {
    fontSize: '11px',
    color: '#aaa',
    fontWeight: 500,
    overflow: 'hidden',
    textOverflow: 'ellipsis',
    whiteSpace: 'nowrap',
  },
  perfCard: {
    display: 'flex',
    flexDirection: 'column',
    gap: '8px',
    padding: '12px',
    background: '#141420',
    borderRadius: '10px',
    border: '1px solid #1e1e30',
  },
  perfCardTop: {
    display: 'flex',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  perfValue: {
    fontSize: '14px',
    color: '#e0e0e0',
    fontWeight: 600,
    fontFamily: 'monospace',
  },
  perfBarBg: {
    height: '4px',
    borderRadius: '2px',
    background: '#1e1e30',
    overflow: 'hidden',
  },
  perfBarFill: {
    height: '100%',
    borderRadius: '2px',
    transition: 'width 0.6s ease',
  },
  perfSub: {
    fontSize: '10px',
    color: '#555',
  },
};
