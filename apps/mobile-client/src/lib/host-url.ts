// Zero-config host discovery: the mobile client is served *by the host*, so the
// browser already knows the host address (window.location). We derive the RPC
// WebSocket URL from it instead of asking the user to type an IP.

export const DEFAULT_RPC_PORT = '45678';

/**
 * Derive the host RPC WebSocket URL from the page origin.
 * - Served by the unified host server (same port as RPC) → reuse that origin.
 * - Served by a separate web dev server → target the RPC port on the same host.
 * Returns '' during SSR (no window).
 */
export function deriveHostWsUrl(): string {
  if (typeof window === 'undefined') return '';
  const { protocol, hostname, port } = window.location;
  const wsProto = protocol === 'https:' ? 'wss:' : 'ws:';
  const rpcPort =
    (typeof process !== 'undefined' && process.env?.NEXT_PUBLIC_RPC_PORT) || port || DEFAULT_RPC_PORT;
  return `${wsProto}//${hostname}:${rpcPort}/rpc`;
}

/** Human-friendly label for the host we'll auto-connect to (e.g. "this PC (192.168.2.30)"). */
export function describeHost(): string {
  if (typeof window === 'undefined') return 'the host';
  const host = window.location.hostname;
  if (host === 'localhost' || host === '127.0.0.1') return 'this PC';
  return host;
}
