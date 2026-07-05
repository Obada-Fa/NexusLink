export function createId(): string {
  if (typeof crypto !== "undefined" && crypto.randomUUID) {
    return crypto.randomUUID();
  }
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === "x" ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

export interface RpcEnvelope {
  type: string;
  request?: { id: string | number; method: string; params?: unknown };
  response?: { id: string | number; result?: unknown; error?: string };
  streamId?: string;
  data?: unknown;
  timestamp?: number;
  terminalId?: string;
}

export function assertRpcEnvelope(
  value: unknown
): value is RpcEnvelope {
  if (typeof value !== "object" || value === null) return false;
  const obj = value as Record<string, unknown>;
  if (typeof obj.type !== "string") return false;
  if ("request" in obj) {
    const req = obj.request as Record<string, unknown> | undefined;
    if (!req || typeof req.id === "undefined" || typeof req.method !== "string")
      return false;
  }
  if ("response" in obj) {
    const resp = obj.response as Record<string, unknown> | undefined;
    if (!resp || typeof resp.id === "undefined") return false;
  }
  return true;
}
