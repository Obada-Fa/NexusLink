export default function Loading() {
  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        height: "100dvh",
        background: "#0a0a0f",
        color: "#555",
        fontFamily: "system-ui, sans-serif",
        fontSize: "14px",
        flexDirection: "column",
        gap: "12px",
      }}
    >
      <div
        style={{
          width: "24px",
          height: "24px",
          border: "2px solid #1e1e30",
          borderTopColor: "#2a6aff",
          borderRadius: "50%",
          animation: "spin 0.8s linear infinite",
        }}
      />
      <span>NexusLink — Loading...</span>
      <style>{`@keyframes spin { to { transform: rotate(360deg); } }`}</style>
    </div>
  );
}
