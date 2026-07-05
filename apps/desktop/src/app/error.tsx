"use client";

import { useEffect } from "react";

export default function Error({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    console.error("[desktop error boundary]", error);
  }, [error]);

  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        height: "100dvh",
        background: "#0a0a0f",
        color: "#e0e0e0",
        fontFamily: "system-ui, sans-serif",
        flexDirection: "column",
        gap: "16px",
        padding: "24px",
        boxSizing: "border-box",
        textAlign: "center",
      }}
    >
      <div style={{ fontSize: "48px" }}>{'\u26A0'}</div>
      <h2 style={{ fontSize: "18px", fontWeight: 600, color: "#e55", margin: 0 }}>
        Something went wrong
      </h2>
      <p
        style={{
          fontSize: "13px",
          color: "#888",
          maxWidth: "400px",
          margin: 0,
          wordBreak: "break-word",
        }}
      >
        {error.message || "An unexpected error occurred"}
      </p>
      <button
        onClick={reset}
        style={{
          padding: "10px 24px",
          borderRadius: "8px",
          border: "none",
          background: "#2a6aff",
          color: "#fff",
          fontSize: "14px",
          fontWeight: 600,
          cursor: "pointer",
          marginTop: "8px",
        }}
      >
        Try again
      </button>
    </div>
  );
}
