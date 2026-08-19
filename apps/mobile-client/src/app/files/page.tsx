'use client';

import { useEffect, useState, useCallback, useRef } from 'react';
import { useRouter } from 'next/navigation';
import { useConnectionStore } from '@/store/connection';
import { hostPathCrumbs, isThisPcPath, normalizeGoPath } from '@/lib/host-path';

interface FileEntry {
  name: string;
  path: string;
  size: number;
  isDirectory: boolean;
  modifiedAt: string;
  mimeType: string;
}

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

function formatDate(iso: string): string {
  try {
    const d = new Date(iso);
    return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  } catch {
    return iso;
  }
}

type SortOption = 'name-asc' | 'name-desc' | 'date-desc' | 'date-asc' | 'size-desc' | 'size-asc';

function sortFileEntries(list: FileEntry[], sort: SortOption): FileEntry[] {
  return [...list].sort((a, b) => {
    if (a.isDirectory !== b.isDirectory) {
      return a.isDirectory ? -1 : 1;
    }
    switch (sort) {
      case 'name-asc':
        return a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' });
      case 'name-desc':
        return b.name.localeCompare(a.name, undefined, { numeric: true, sensitivity: 'base' });
      case 'date-desc':
        return b.modifiedAt.localeCompare(a.modifiedAt);
      case 'date-asc':
        return a.modifiedAt.localeCompare(b.modifiedAt);
      case 'size-desc':
        return b.size - a.size;
      case 'size-asc':
        return a.size - b.size;
      default:
        return 0;
    }
  });
}

export default function FilesPage() {
  const client = useConnectionStore((s) => s.client);
  const status = useConnectionStore((s) => s.status);
  const connect = useConnectionStore((s) => s.connect);
  const hostUrl = useConnectionStore((s) => s.hostUrl);
  const router = useRouter();

  const handleReconnect = useCallback(async () => {
    if (!hostUrl) return;
    try { await connect(hostUrl); } catch { /* handled by store */ }
  }, [connect, hostUrl]);

  const [cwd, setCwd] = useState<string | null>(null);
  const [entries, setEntries] = useState<FileEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [viewMode, setViewMode] = useState<'list' | 'grid'>('list');
  const [sortBy, setSortBy] = useState<SortOption>('name-asc');
  const [deleteTarget, setDeleteTarget] = useState<FileEntry | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  const fetchEntries = useCallback(
    async (path: string) => {
      if (!client || status !== 'connected') return;
      setLoading(true);
      setError('');
      try {
        const result = (await client.request('fs.list', { path })) as FileEntry[];
        setEntries(sortFileEntries(result, sortBy));
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Failed to list files');
        setEntries([]);
      } finally {
        setLoading(false);
        setRefreshing(false);
      }
    },
    [client, status, sortBy]
  );

  useEffect(() => {
    if (!client || status !== 'connected') return;
    let cancelled = false;
    (async () => {
      try {
        const info = (await client.request('system.getInfo')) as { homeDir?: string };
        if (!cancelled) setCwd(info.homeDir?.trim() || '/');
      } catch {
        if (!cancelled) setCwd('/');
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [client, status]);

  useEffect(() => {
    if (cwd) fetchEntries(cwd);
  }, [cwd, fetchEntries]);

  const navigate = useCallback((path: string) => {
    setCwd(path);
  }, []);

  const handleEntryClick = useCallback(
    (entry: FileEntry) => {
      if (entry.isDirectory) {
        navigate(entry.path);
      }
    },
    [navigate]
  );

  const handleRefresh = useCallback(() => {
    if (!cwd) return;
    setRefreshing(true);
    fetchEntries(cwd);
  }, [cwd, fetchEntries]);

  const handleDelete = useCallback(
    async (entry: FileEntry) => {
      if (!client) return;
      try {
        await client.request('fs.delete', { path: entry.path });
        setDeleteTarget(null);
        if (cwd) fetchEntries(cwd);
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Delete failed');
        setDeleteTarget(null);
      }
    },
    [client, cwd, fetchEntries]
  );

  const handleCopy = useCallback(
    (_entry: FileEntry) => {
      alert('Copy — not yet implemented');
    },
    []
  );

  const handleMove = useCallback(
    (_entry: FileEntry) => {
      alert('Move — not yet implemented');
    },
    []
  );

  const breadcrumbs = hostPathCrumbs(cwd ?? '/');

  const goToPath = useCallback(() => {
    const val = inputRef.current?.value;
    if (val) {
      setCwd(normalizeGoPath(val));
    }
  }, []);

  if (status !== 'connected' || !client) {
    return (
      <div style={styles.wrapper}>
        <header style={styles.topBar}>
          <button onClick={() => router.back()} style={styles.backBtn}>
            \u2190 Back
          </button>
          <span style={styles.title}>Files</span>
          <button onClick={handleReconnect} style={styles.reconnectBtn}>
            Reconnect
          </button>
        </header>
        <div style={styles.emptyState}>
          <span>Not connected.</span>
          <button onClick={handleReconnect} style={styles.reconnectBtnLarge}>
            Reconnect
          </button>
        </div>
      </div>
    );
  }

  return (
    <div style={styles.wrapper}>
      <header style={styles.topBar}>
        <button onClick={() => router.back()} style={styles.backBtn}>
          \u2190 Back
        </button>
        <span style={styles.title}>Files</span>
        <div style={styles.headerActions}>
          <select
            value={sortBy}
            onChange={(e) => {
              const s = e.target.value as SortOption;
              setSortBy(s);
              setEntries((prev) => sortFileEntries(prev, s));
            }}
            style={styles.sortSelect}
          >
            <option value="name-asc">A → Z</option>
            <option value="name-desc">Z → A</option>
            <option value="date-desc">Newest</option>
            <option value="date-asc">Oldest</option>
            <option value="size-desc">Largest</option>
            <option value="size-asc">Smallest</option>
          </select>
          <button
            style={{
              ...styles.actionBtn,
              background: viewMode === 'list' ? '#2a6aff' : 'transparent',
              color: viewMode === 'list' ? '#fff' : '#888',
              borderColor: viewMode === 'list' ? '#2a6aff' : '#333',
            }}
            onClick={() => setViewMode('list')}
          >
            List
          </button>
          <button
            style={{
              ...styles.actionBtn,
              background: viewMode === 'grid' ? '#2a6aff' : 'transparent',
              color: viewMode === 'grid' ? '#fff' : '#888',
              borderColor: viewMode === 'grid' ? '#2a6aff' : '#333',
            }}
            onClick={() => setViewMode('grid')}
          >
            Grid
          </button>
        </div>
      </header>

      <div style={styles.navRow}>
        <div style={styles.breadcrumb}>
          {breadcrumbs.map((crumb, i) => (
            <span key={`${crumb.path}-${i}`} style={styles.breadcrumbItem}>
              {i > 0 && <span style={styles.breadcrumbSep}>{'\u203A'}</span>}
              <button
                style={styles.breadcrumbBtn}
                onClick={() => navigate(crumb.path)}
              >
                {crumb.label}
              </button>
            </span>
          ))}
        </div>
        <button
          onClick={handleRefresh}
          style={{
            ...styles.actionBtn,
            opacity: refreshing ? 0.5 : 1,
          }}
          disabled={refreshing}
        >
          {refreshing ? '...' : '\u21BB'}
        </button>
      </div>

      <div style={styles.pathInputRow}>
        <input
          ref={inputRef}
          style={styles.pathInput}
          key={cwd ?? 'pending'}
          defaultValue={cwd ?? ''}
          placeholder="C:/Users or D:/projects"
          onKeyDown={(e) => {
            if (e.key === 'Enter') goToPath();
          }}
        />
        <button style={styles.goBtn} onClick={goToPath}>
          Go
        </button>
      </div>

      {error && <div style={styles.errorBanner}>{error}</div>}

      <div style={{ ...styles.content, flexDirection: viewMode === 'grid' ? 'row' : 'column' }}>
        {loading && !refreshing ? (
          <div style={styles.emptyState}>Loading...</div>
        ) : entries.length === 0 ? (
          <div style={styles.emptyState}>
            <p>Empty directory</p>
            <p style={styles.pullHint}>Pull down to refresh</p>
          </div>
        ) : viewMode === 'list' ? (
          <div style={styles.listView}>
            {entries.map((entry) => (
              <div
                key={entry.path}
                style={{
                  ...styles.listRow,
                  cursor: entry.isDirectory ? 'pointer' : 'default',
                }}
                onClick={() => handleEntryClick(entry)}
              >
                <span style={styles.entryIcon}>
                  {entry.isDirectory ? '\u{1F4C1}' : '\u{1F4C4}'}
                </span>
                <div style={styles.entryInfo}>
                  <span style={styles.entryName}>{entry.name}</span>
                  <span style={styles.entryMeta}>
                    {entry.isDirectory ? '--' : formatSize(entry.size)}
                    {' \u00B7 '}
                    {formatDate(entry.modifiedAt)}
                  </span>
                </div>
                <div style={styles.entryActions}>
                  <button
                    style={styles.entryActionBtn}
                    onClick={(e) => {
                      e.stopPropagation();
                      handleCopy(entry);
                    }}
                    title="Copy"
                  >
                    Copy
                  </button>
                  <button
                    style={styles.entryActionBtn}
                    onClick={(e) => {
                      e.stopPropagation();
                      handleMove(entry);
                    }}
                    title="Move"
                  >
                    Move
                  </button>
                  <button
                    style={{ ...styles.entryActionBtn, color: '#e55' }}
                    onClick={(e) => {
                      e.stopPropagation();
                      setDeleteTarget(entry);
                    }}
                    title="Delete"
                  >
                    Del
                  </button>
                </div>
              </div>
            ))}
          </div>
        ) : (
          <div style={styles.gridView}>
            {entries.map((entry) => (
              <button
                key={entry.path}
                style={{
                  ...styles.gridTile,
                  cursor: entry.isDirectory ? 'pointer' : 'default',
                }}
                onClick={() => handleEntryClick(entry)}
              >
                <span style={styles.gridIcon}>
                  {entry.isDirectory ? '\u{1F4C1}' : '\u{1F4C4}'}
                </span>
                <span style={styles.gridName}>{entry.name}</span>
              </button>
            ))}
          </div>
        )}
      </div>

      {deleteTarget && (
        <div style={styles.modalOverlay} onClick={() => setDeleteTarget(null)}>
          <div style={styles.modal} onClick={(e) => e.stopPropagation()}>
            <p style={styles.modalText}>
              Delete <strong>{deleteTarget.name}</strong>?
            </p>
            <div style={styles.modalActions}>
              <button
                style={{ ...styles.modalBtn, background: '#e55', color: '#fff' }}
                onClick={() => handleDelete(deleteTarget)}
              >
                Delete
              </button>
              <button
                style={styles.modalBtn}
                onClick={() => setDeleteTarget(null)}
              >
                Cancel
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
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
  headerActions: {
    display: 'flex',
    gap: '6px',
  },
  actionBtn: {
    padding: '6px 10px',
    borderRadius: '6px',
    border: '1px solid #333',
    background: 'transparent',
    color: '#888',
    fontSize: '11px',
    fontWeight: 500,
    cursor: 'pointer',
  },
  sortSelect: {
    padding: '4px 8px',
    borderRadius: '6px',
    border: '1px solid #333',
    background: '#141420',
    color: '#ccc',
    fontSize: '11px',
    outline: 'none',
    cursor: 'pointer',
  },
  navRow: {
    display: 'flex',
    alignItems: 'center',
    padding: '6px 12px',
    gap: '8px',
    flexShrink: 0,
  },
  breadcrumb: {
    display: 'flex',
    alignItems: 'center',
    flexWrap: 'wrap',
    gap: '2px',
    flex: 1,
    overflowX: 'auto',
  },
  breadcrumbItem: {
    display: 'flex',
    alignItems: 'center',
  },
  breadcrumbSep: {
    color: '#555',
    fontSize: '14px',
    margin: '0 2px',
  },
  breadcrumbBtn: {
    padding: '4px 8px',
    borderRadius: '4px',
    border: 'none',
    background: 'transparent',
    color: '#aaa',
    fontSize: '12px',
    cursor: 'pointer',
    fontWeight: 500,
    whiteSpace: 'nowrap',
  },
  pathInputRow: {
    display: 'flex',
    gap: '6px',
    padding: '0 12px 6px',
    flexShrink: 0,
  },
  pathInput: {
    flex: 1,
    padding: '8px 10px',
    borderRadius: '6px',
    border: '1px solid #2a2a3a',
    background: '#141420',
    color: '#e0e0e0',
    fontSize: '12px',
    outline: 'none',
    boxSizing: 'border-box',
  },
  goBtn: {
    padding: '8px 14px',
    borderRadius: '6px',
    border: '1px solid #333',
    background: '#1a1a28',
    color: '#aaa',
    fontSize: '12px',
    cursor: 'pointer',
    fontWeight: 500,
  },
  errorBanner: {
    padding: '8px 12px',
    margin: '0 12px 6px',
    borderRadius: '6px',
    background: '#2a1010',
    color: '#e55',
    fontSize: '12px',
    border: '1px solid #3a1a1a',
  },
  content: {
    flex: 1,
    overflow: 'auto',
    padding: '0 12px 12px',
  },
  emptyState: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    justifyContent: 'center',
    flex: 1,
    color: '#555',
    fontSize: '14px',
    padding: '40px 0',
    gap: '4px',
  },
  pullHint: {
    fontSize: '12px',
    color: '#444',
    margin: 0,
  },
  listView: {
    display: 'flex',
    flexDirection: 'column',
    gap: '2px',
  },
  listRow: {
    display: 'flex',
    alignItems: 'center',
    padding: '10px 10px',
    borderRadius: '8px',
    gap: '10px',
    borderBottom: '1px solid #1e1e2877',
  },
  entryIcon: {
    fontSize: '20px',
    flexShrink: 0,
  },
  entryInfo: {
    display: 'flex',
    flexDirection: 'column',
    flex: 1,
    minWidth: 0,
  },
  entryName: {
    fontSize: '13px',
    fontWeight: 500,
    color: '#ccc',
    overflow: 'hidden',
    textOverflow: 'ellipsis',
    whiteSpace: 'nowrap',
  },
  entryMeta: {
    fontSize: '11px',
    color: '#666',
  },
  entryActions: {
    display: 'flex',
    gap: '4px',
    flexShrink: 0,
  },
  entryActionBtn: {
    padding: '4px 8px',
    borderRadius: '4px',
    border: '1px solid #2a2a3a',
    background: 'transparent',
    color: '#777',
    fontSize: '10px',
    cursor: 'pointer',
    fontWeight: 500,
  },
  gridView: {
    display: 'grid',
    gridTemplateColumns: 'repeat(auto-fill, minmax(90px, 1fr))',
    gap: '8px',
    paddingTop: '4px',
  },
  gridTile: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: '6px',
    padding: '14px 6px',
    background: '#141420',
    border: '1px solid #1e1e30',
    borderRadius: '10px',
    color: '#ccc',
    fontSize: '12px',
  },
  gridIcon: {
    fontSize: '28px',
  },
  gridName: {
    fontSize: '11px',
    color: '#aaa',
    overflow: 'hidden',
    textOverflow: 'ellipsis',
    whiteSpace: 'nowrap',
    maxWidth: '100%',
    textAlign: 'center',
  },
  modalOverlay: {
    position: 'fixed',
    inset: 0,
    background: 'rgba(0,0,0,0.6)',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    zIndex: 100,
  },
  modal: {
    background: '#1a1a2e',
    borderRadius: '12px',
    padding: '24px',
    minWidth: '280px',
    border: '1px solid #2a2a3a',
  },
  modalText: {
    fontSize: '14px',
    color: '#ccc',
    margin: '0 0 16px',
    textAlign: 'center',
  },
  modalActions: {
    display: 'flex',
    gap: '10px',
    justifyContent: 'center',
  },
  modalBtn: {
    padding: '8px 20px',
    borderRadius: '8px',
    border: '1px solid #333',
    background: '#141420',
    color: '#ccc',
    fontSize: '13px',
    cursor: 'pointer',
    fontWeight: 500,
  },
};
