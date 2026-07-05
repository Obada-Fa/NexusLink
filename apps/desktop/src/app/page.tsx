"use client";

import { useState, useEffect, useCallback } from "react";
import { useRouter } from "next/navigation";

function getConnectionStatus() {
  if (typeof window === "undefined") return "loading";
  try {
    const url = localStorage.getItem("nexuslink-host-url");
    return url ? "configured" : "idle";
  } catch {
    return "idle";
  }
}

export default function Page() {
  const router = useRouter();
  const [status, setStatus] = useState<string>("loading");
  const [wsState, setWsState] = useState<number | null>(null);
  const [checking, setChecking] = useState(false);

  useEffect(() => {
    setStatus(getConnectionStatus());
  }, []);

  const checkServer = useCallback(async () => {
    setChecking(true);
    try {
      const url = localStorage.getItem("nexuslink-host-url") ?? "ws://localhost:45678/signal";
      const ws = new WebSocket(url);
      const timeout = setTimeout(() => {
        ws.close();
        setWsState(3);
        setChecking(false);
      }, 2000);

      ws.onopen = () => {
        clearTimeout(timeout);
        setWsState(1);
        setChecking(false);
        ws.close();
      };
      ws.onerror = () => {
        clearTimeout(timeout);
        setWsState(3);
        setChecking(false);
      };
    } catch {
      setWsState(3);
      setChecking(false);
    }
  }, []);

  return (
    <main style={S.container}>
      <header style={S.header}>
        <div style={S.headerLeft}>
          <div
            style={{
              ...S.statusDot,
              background: wsState === 1 ? "#4ade80" : wsState === 3 ? "#e55" : "#888",
            }}
          />
          <span style={S.headerTitle}>NexusLink Host</span>
        </div>
        <div style={S.headerRight}>
          <span style={S.statusBadge}>
            {wsState === 1 ? "Connected" : wsState === 3 ? "Unreachable" : "Unknown"}
          </span>
        </div>
      </header>

      <section style={S.content}>
        <div style={S.card}>
          <h2 style={S.cardTitle}>Connection Status</h2>
          <div style={S.statRow}>
            <span style={S.statLabel}>Config</span>
            <span style={S.statValue}>{status === "configured" ? "Saved" : "Not configured"}</span>
          </div>
          <div style={S.statRow}>
            <span style={S.statLabel}>Server</span>
            <span style={S.statValue}>
              {wsState === 1 ? "Online" : wsState === 3 ? "Offline" : checking ? "Checking..." : "Unknown"}
            </span>
          </div>
          <div style={S.actions}>
            <button onClick={checkServer} disabled={checking} style={S.btn}>
              {checking ? "Checking..." : "Check Server"}
            </button>
            <button onClick={() => router.push("/pair")} style={S.btnOutline}>
              Open Pairing
            </button>
          </div>
        </div>
      </section>
    </main>
  );
}

const S: Record<string, React.CSSProperties> = {
  container: {
    display: "flex",
    flexDirection: "column",
    minHeight: "100dvh",
    background: "#0a0a0f",
    color: "#e0e0e0",
    fontFamily: "system-ui, sans-serif",
  },
  header: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    padding: "12px 20px",
    borderBottom: "1px solid #1e1e30",
    background: "#0c0c14",
    flexShrink: 0,
  },
  headerLeft: {
    display: "flex",
    alignItems: "center",
    gap: "10px",
  },
  statusDot: {
    width: "10px",
    height: "10px",
    borderRadius: "50%",
    flexShrink: 0,
    transition: "background 0.3s",
  },
  headerTitle: {
    fontSize: "16px",
    fontWeight: 700,
    color: "#fff",
  },
  headerRight: {
    display: "flex",
    alignItems: "center",
    gap: "10px",
  },
  statusBadge: {
    fontSize: "12px",
    color: "#888",
    fontWeight: 500,
  },
  content: {
    flex: 1,
    display: "flex",
    alignItems: "flex-start",
    justifyContent: "center",
    padding: "40px 20px",
    boxSizing: "border-box",
  },
  card: {
    display: "flex",
    flexDirection: "column",
    gap: "16px",
    padding: "24px",
    background: "#141420",
    border: "1px solid #1e1e30",
    borderRadius: "12px",
    maxWidth: "480px",
    width: "100%",
  },
  cardTitle: {
    fontSize: "18px",
    fontWeight: 600,
    color: "#fff",
    margin: 0,
  },
  statRow: {
    display: "flex",
    justifyContent: "space-between",
    padding: "8px 0",
    borderBottom: "1px solid #1e1e2877",
  },
  statLabel: {
    fontSize: "13px",
    color: "#666",
  },
  statValue: {
    fontSize: "13px",
    color: "#aaa",
    fontFamily: "monospace",
  },
  actions: {
    display: "flex",
    gap: "10px",
    marginTop: "8px",
  },
  btn: {
    flex: 1,
    padding: "10px",
    borderRadius: "8px",
    border: "none",
    background: "#2a6aff",
    color: "#fff",
    fontSize: "13px",
    fontWeight: 600,
    cursor: "pointer",
  },
  btnOutline: {
    flex: 1,
    padding: "10px",
    borderRadius: "8px",
    border: "1px solid #2a2a3a",
    background: "transparent",
    color: "#aaa",
    fontSize: "13px",
    fontWeight: 600,
    cursor: "pointer",
  },
};
