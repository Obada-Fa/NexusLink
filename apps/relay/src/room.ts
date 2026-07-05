import type { ServerWebSocket } from "bun";

export type PeerRole = "host" | "client";

export type WsData = { roomId: string };

export const ROOM_EXPIRY_MS = 30 * 60 * 1000;

type Peer = {
  ws: ServerWebSocket<WsData>;
  role: PeerRole;
};

export class Room {
  readonly id: string;
  readonly createdAt: number;
  private host: ServerWebSocket<WsData> | null = null;
  private client: ServerWebSocket<WsData> | null = null;
  private expiryTimer: ReturnType<typeof setTimeout>;

  constructor(id: string) {
    this.id = id;
    this.createdAt = Date.now();
    this.expiryTimer = setTimeout(() => {
      this.expire();
    }, ROOM_EXPIRY_MS);
  }

  get peers(): Peer[] {
    const result: Peer[] = [];
    if (this.host) result.push({ ws: this.host, role: "host" });
    if (this.client) result.push({ ws: this.client, role: "client" });
    return result;
  }

  get isEmpty(): boolean {
    return this.host === null && this.client === null;
  }

  get isFull(): boolean {
    return this.host !== null && this.client !== null;
  }

  addPeer(ws: ServerWebSocket<WsData>, role: PeerRole): boolean {
    if (role === "host") {
      if (this.host !== null) return false;
      this.host = ws;
    } else {
      if (this.client !== null) return false;
      this.client = ws;
    }
    this.resetExpiry();
    return true;
  }

  removePeer(ws: ServerWebSocket<WsData>): PeerRole | null {
    if (this.host === ws) {
      this.host = null;
      return "host";
    }
    if (this.client === ws) {
      this.client = null;
      return "client";
    }
    return null;
  }

  broadcast(
    sender: PeerRole | null,
    message: unknown,
    filter?: PeerRole
  ): void {
    const data = JSON.stringify(message);
    for (const peer of this.peers) {
      if (filter !== undefined && peer.role !== filter) continue;
      if (sender !== null && peer.role === sender) continue;
      if (peer.ws.readyState === 1) {
        peer.ws.send(data);
      }
    }
  }

  broadcastTo(
    message: unknown,
    role: PeerRole
  ): void {
    const target = role === "host" ? this.host : this.client;
    if (target && target.readyState === 1) {
      target.send(JSON.stringify(message));
    }
  }

  refresh(): void {
    this.resetExpiry();
  }

  expire(): void {
    clearTimeout(this.expiryTimer);
    const expiryMsg = { type: "room-expired", roomId: this.id };

    for (const peer of this.peers) {
      if (peer.ws.readyState === 1) {
        peer.ws.send(JSON.stringify(expiryMsg));
        peer.ws.close();
      }
    }

    this.host = null;
    this.client = null;
  }

  private resetExpiry(): void {
    clearTimeout(this.expiryTimer);
    this.expiryTimer = setTimeout(() => {
      this.expire();
    }, ROOM_EXPIRY_MS);
  }
}
