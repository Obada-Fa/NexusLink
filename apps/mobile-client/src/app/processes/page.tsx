'use client';

import { useEffect, useState, useCallback, useRef } from 'react';
import { useRouter } from 'next/navigation';
import { useConnectionStore } from '@/store/connection';

interface ProcessEntry {
  pid: number;
  name: string;
  cpuPercent: number;
  memMb: number;
}

type SortKey = 'name' | 'cpuPercent' | 'memMb';

export default function ProcessesPage() {
  const client = useConnectionStore((s) => s.client);
  const status = useConnectionStore((s) => s.status);
  const router = useRouter();

  const [processes, setProcesses] = useState<ProcessEntry[]>([]);
  const [search, setSearch] = useState('');
  const [sortKey, setSortKey] = useState<SortKey>('cpuPercent');
  const [sortAsc, setSortAsc] = useState(true);
  const [selected, setSelected] = useState<ProcessEntry | null>(null);
  const [loading, setLoading] = useState(false);
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const toggleSort = useCallback(
    (key: SortKey) => {
      if (sortKey === key) {
        setSortAsc((p) => !p);
      } else {
        setSortKey(key);
        setSortAsc(false);
      }
    },
    [sortKey]
  );

  const fetchProcesses = useCallback(async () => {
    if (!client || status !== 'connected') return;
    try {
      const result = (await client.request('process.list', {})) as ProcessEntry[];
      setProcesses(result ?? []);
    } catch {
      // silent polling
    } finally {
      setLoading(false);
    }
  }, [client, status]);

  useEffect(() => {
    setLoading(true);
    fetchProcesses();
    intervalRef.current = setInterval(fetchProcesses, 3000);
    return () => {
      if (intervalRef.current) clearInterval(intervalRef.current);
    };
  }, [fetchProcesses]);

  const handleKill = useCallback(
    (_pid: number) => {
      alert('Force kill — not yet implemented');
    },
    []
  );

  const filtered = processes.filter((p) =>
    p.name.toLowerCase().includes(search.toLowerCase())
  );

  const sorted = [...filtered].sort((a, b) => {
    let cmp = 0;
    if (sortKey === 'name') {
      cmp = a.name.localeCompare(b.name);
    } else {
      cmp = a[sortKey] - b[sortKey];
    }
    return sortAsc ? cmp : -cmp;
  });

  const sortIndicator = (key: SortKey) => {
    if (sortKey !== key) return '';
    return sortAsc ? ' \u2191' : ' \u2193';
  };

  if (status !== 'connected' || !client) {
    return (
      <div style={styles.wrapper}>
        <header style={styles.topBar}>
          <button onClick={() => router.back()} style={styles.backBtn}>
            \u2190 Back
          </button>
          <span style={styles.title}>Processes</span>
        </header>
        <div style={styles.emptyState}>Not connected.</div>
      </div>
    );
  }

  return (
    <div style={styles.wrapper}>
      <header style={styles.topBar}>
        <button onClick={() => router.back()} style={styles.backBtn}>
          \u2190 Back
        </button>
        <span style={styles.title}>Processes</span>
        <span style={styles.countBadge}>{processes.length}</span>
      </header>

      <div style={styles.searchRow}>
        <input
          style={styles.searchInput}
          placeholder="Filter by name..."
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
      </div>

      <div style={styles.sortBar}>
        <button
          style={{
            ...styles.sortBtn,
            color: sortKey === 'name' ? '#4ade80' : '#666',
          }}
          onClick={() => toggleSort('name')}
        >
          Name{sortIndicator('name')}
        </button>
        <button
          style={{
            ...styles.sortBtn,
            color: sortKey === 'cpuPercent' ? '#4ade80' : '#666',
          }}
          onClick={() => toggleSort('cpuPercent')}
        >
          CPU{sortIndicator('cpuPercent')}
        </button>
        <button
          style={{
            ...styles.sortBtn,
            color: sortKey === 'memMb' ? '#4ade80' : '#666',
          }}
          onClick={() => toggleSort('memMb')}
        >
          Mem{sortIndicator('memMb')}
        </button>
      </div>

      <div style={styles.listArea}>
        {loading && processes.length === 0 ? (
          <div style={styles.emptyState}>Loading...</div>
        ) : sorted.length === 0 ? (
          <div style={styles.emptyState}>
            {search ? 'No matching processes' : 'No processes'}
          </div>
        ) : (
          sorted.map((p) => (
            <div
              key={p.pid}
              style={{
                ...styles.row,
                background: selected?.pid === p.pid ? '#1a2a1e' : 'transparent',
              }}
              onClick={() => setSelected(p)}
            >
              <span style={styles.rowPid}>{p.pid}</span>
              <span style={styles.rowName}>{p.name}</span>
              <span style={styles.rowCpu}>{p.cpuPercent.toFixed(1)}%</span>
              <span style={styles.rowMem}>{p.memMb.toFixed(0)} MB</span>
            </div>
          ))
        )}
      </div>

      {selected && (
        <div style={styles.sheetOverlay} onClick={() => setSelected(null)}>
          <div style={styles.sheet} onClick={(e) => e.stopPropagation()}>
            <div style={styles.sheetHandle} />
            <h3 style={styles.sheetTitle}>{selected.name}</h3>
            <div style={styles.sheetGrid}>
              <div style={styles.sheetField}>
                <span style={styles.sheetLabel}>PID</span>
                <span style={styles.sheetValue}>{selected.pid}</span>
              </div>
              <div style={styles.sheetField}>
                <span style={styles.sheetLabel}>CPU</span>
                <span style={styles.sheetValue}>{selected.cpuPercent.toFixed(1)}%</span>
              </div>
              <div style={styles.sheetField}>
                <span style={styles.sheetLabel}>Memory</span>
                <span style={styles.sheetValue}>{selected.memMb.toFixed(0)} MB</span>
              </div>
            </div>
            <div style={styles.sheetActions}>
              <button
                style={{ ...styles.sheetBtn, background: '#e55', color: '#fff', borderColor: '#e55' }}
                onClick={() => handleKill(selected.pid)}
              >
                Force Kill
              </button>
              <button style={styles.sheetBtn} onClick={() => setSelected(null)}>
                Close
              </button>
            </div>
          </div>
        </div>
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
  countBadge: {
    fontSize: '11px',
    color: '#666',
    fontWeight: 500,
  },
  searchRow: {
    padding: '8px 12px',
    flexShrink: 0,
  },
  searchInput: {
    width: '100%',
    padding: '8px 10px',
    borderRadius: '6px',
    border: '1px solid #2a2a3a',
    background: '#141420',
    color: '#e0e0e0',
    fontSize: '12px',
    outline: 'none',
    boxSizing: 'border-box',
  },
  sortBar: {
    display: 'flex',
    gap: '4px',
    padding: '0 12px 6px',
    flexShrink: 0,
  },
  sortBtn: {
    padding: '4px 10px',
    borderRadius: '4px',
    border: 'none',
    background: 'transparent',
    fontSize: '11px',
    cursor: 'pointer',
    fontWeight: 500,
  },
  listArea: {
    flex: 1,
    overflow: 'auto',
    padding: '0 12px 12px',
  },
  emptyState: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    flex: 1,
    color: '#555',
    fontSize: '14px',
    padding: '40px 0',
  },
  row: {
    display: 'flex',
    alignItems: 'center',
    gap: '8px',
    padding: '10px 8px',
    borderRadius: '8px',
    borderBottom: '1px solid #1e1e2877',
    cursor: 'pointer',
  },
  rowPid: {
    width: '50px',
    fontSize: '11px',
    color: '#666',
    fontFamily: 'monospace',
  },
  rowName: {
    flex: 1,
    fontSize: '13px',
    color: '#ccc',
    overflow: 'hidden',
    textOverflow: 'ellipsis',
    whiteSpace: 'nowrap',
  },
  rowCpu: {
    width: '55px',
    fontSize: '12px',
    color: '#f0c040',
    textAlign: 'right',
    fontFamily: 'monospace',
  },
  rowMem: {
    width: '55px',
    fontSize: '12px',
    color: '#60a5fa',
    textAlign: 'right',
    fontFamily: 'monospace',
  },
  sheetOverlay: {
    position: 'fixed',
    inset: 0,
    background: 'rgba(0,0,0,0.5)',
    display: 'flex',
    alignItems: 'flex-end',
    justifyContent: 'center',
    zIndex: 100,
  },
  sheet: {
    width: '100%',
    maxWidth: '500px',
    background: '#1a1a2e',
    borderRadius: '16px 16px 0 0',
    padding: '20px 20px 32px',
    paddingBottom: 'max(32px, env(safe-area-inset-bottom))',
    borderTop: '1px solid #2a2a3a',
  },
  sheetHandle: {
    width: '36px',
    height: '4px',
    borderRadius: '2px',
    background: '#444',
    margin: '0 auto 16px',
  },
  sheetTitle: {
    fontSize: '16px',
    fontWeight: 600,
    color: '#e0e0e0',
    margin: '0 0 16px',
    overflow: 'hidden',
    textOverflow: 'ellipsis',
    whiteSpace: 'nowrap',
  },
  sheetGrid: {
    display: 'grid',
    gridTemplateColumns: '1fr 1fr 1fr',
    gap: '8px',
    marginBottom: '20px',
  },
  sheetField: {
    display: 'flex',
    flexDirection: 'column',
    gap: '4px',
    background: '#141420',
    padding: '10px',
    borderRadius: '8px',
  },
  sheetLabel: {
    fontSize: '10px',
    color: '#666',
    textTransform: 'uppercase',
    fontWeight: 600,
  },
  sheetValue: {
    fontSize: '14px',
    color: '#ccc',
    fontFamily: 'monospace',
  },
  sheetActions: {
    display: 'flex',
    gap: '10px',
  },
  sheetBtn: {
    flex: 1,
    padding: '12px',
    borderRadius: '8px',
    border: '1px solid #333',
    background: '#141420',
    color: '#ccc',
    fontSize: '13px',
    cursor: 'pointer',
    fontWeight: 600,
  },
};
