import type { ServerWebSocket } from 'bun';

const ROOM_EXPIRY_MS = 30 * 60 * 1000;
const ROOM_CLEANUP_MS = 5 * 60 * 1000;

type PeerRole = 'host' | 'client';

type WsData = { roomId: string };

type Room = {
  id: string;
  host: ServerWebSocket<WsData> | null;
  client: ServerWebSocket<WsData> | null;
  createdAt: number;
  expiryTimer: ReturnType<typeof setTimeout>;
};

type RoomMessage =
  | { type: 'peer-joined'; role: PeerRole; roomId: string }
  | { type: 'peer-disconnected'; role: PeerRole; roomId: string }
  | { type: 'relay-message'; from: PeerRole; payload: unknown }
  | { type: 'room-expired'; roomId: string }
  | { type: 'pong' }
  | { type: 'error'; message: string };

const rooms = new Map<string, Room>();

function send(ws: ServerWebSocket<WsData>, msg: RoomMessage): void {
  ws.send(JSON.stringify(msg));
}

function notifyPeer(room: Room, from: PeerRole, msg: RoomMessage): void {
  const target = from === 'host' ? room.client : room.host;
  if (target && target.readyState === 1) {
    target.send(JSON.stringify(msg));
  }
}

function resetRoomExpiry(room: Room): void {
  clearTimeout(room.expiryTimer);
  room.expiryTimer = setTimeout(() => {
    expireRoom(room.id);
  }, ROOM_EXPIRY_MS);
}

function expireRoom(roomId: string): void {
  const room = rooms.get(roomId);
  if (!room) return;

  const expiryMsg: RoomMessage = { type: 'room-expired', roomId };

  if (room.host && room.host.readyState === 1) {
    send(room.host, expiryMsg);
    room.host.close();
  }

  if (room.client && room.client.readyState === 1) {
    send(room.client, expiryMsg);
    room.client.close();
  }

  clearTimeout(room.expiryTimer);
  rooms.delete(roomId);
  console.log(`[relay] room ${roomId} expired`);
}

function handleJoin(roomId: string, ws: ServerWebSocket<WsData>): PeerRole {
  let room = rooms.get(roomId);

  if (!room) {
    room = {
      id: roomId,
      host: ws,
      client: null,
      createdAt: Date.now(),
      expiryTimer: setTimeout(() => expireRoom(roomId), ROOM_EXPIRY_MS),
    };
    rooms.set(roomId, room);
    console.log(`[relay] room ${roomId} created, peer joined as host`);
    return 'host';
  }

  if (room.host === null) {
    room.host = ws;
    resetRoomExpiry(room);
    console.log(`[relay] room ${roomId} host joined (reconnect)`);
    return 'host';
  }

  if (room.client === null) {
    room.client = ws;
    resetRoomExpiry(room);
    console.log(`[relay] room ${roomId} client joined`);
    return 'client';
  }

  const errorMsg: RoomMessage = { type: 'error', message: 'Room is full' };
  send(ws, errorMsg);
  ws.close();
  throw new Error(`Room ${roomId} is full`);
}

function handleMessage(ws: ServerWebSocket<WsData>, room: Room, role: PeerRole, raw: string): void {
  try {
    const data: Record<string, unknown> = JSON.parse(raw);
    if (data.type === 'ping') {
      send(ws, { type: 'pong' });
      return;
    }

    resetRoomExpiry(room);

    const relay: RoomMessage = {
      type: 'relay-message',
      from: role,
      payload: data,
    };
    notifyPeer(room, role, relay);
  } catch {
    const errorMsg: RoomMessage = { type: 'error', message: 'Invalid message format' };
    send(ws, errorMsg);
  }
}

function handleDisconnect(ws: ServerWebSocket<WsData>): void {
  for (const [roomId, room] of rooms) {
    let disconnectedRole: PeerRole | null = null;

    if (room.host === ws) {
      disconnectedRole = 'host';
      room.host = null;
    } else if (room.client === ws) {
      disconnectedRole = 'client';
      room.client = null;
    }

    if (disconnectedRole) {
      const dcMsg: RoomMessage = {
        type: 'peer-disconnected',
        role: disconnectedRole,
        roomId,
      };
      notifyPeer(room, disconnectedRole, dcMsg);

      console.log(`[relay] ${disconnectedRole} left room ${roomId}`);

      if (room.host === null && room.client === null) {
        expireRoom(roomId);
      }
    }
  }
}

function cleanupExpired(): void {
  const now = Date.now();
  for (const [roomId, room] of rooms) {
    const age = now - room.createdAt;
    if (age >= ROOM_EXPIRY_MS) {
      expireRoom(roomId);
    }
  }
}

const port = parseInt(Bun.env.RELAY_PORT ?? '3033', 10);

Bun.serve<WsData>({
  port,
  fetch(req, server) {
    const url = new URL(req.url);
    const path = url.pathname;

    if (path === '/health') {
      return new Response(JSON.stringify({ ok: true, rooms: rooms.size }), {
        headers: { 'content-type': 'application/json' },
      });
    }

    const match = path.match(/^\/room\/([a-zA-Z0-9_-]+)$/);
    if (match && match[1]) {
      const roomId = match[1];
      if (server.upgrade(req, { data: { roomId } })) {
        return;
      }
      return new Response('Upgrade failed', { status: 500 });
    }

    return new Response('NexusLink Relay — connect at /room/<roomId>', {
      status: 200,
    });
  },

  websocket: {
    open(ws) {
      const { roomId } = ws.data;

      try {
        const role = handleJoin(roomId, ws);
        const room = rooms.get(roomId);

        const joinedMsg: RoomMessage = { type: 'peer-joined', role, roomId };
        send(ws, joinedMsg);

        if (room) {
          notifyPeer(room, role, joinedMsg);
        }
      } catch (err) {
        console.error(`[relay] join error for room ${roomId}:`, err);
      }
    },

    message(ws, raw) {
      const { roomId } = ws.data;
      const room = rooms.get(roomId);
      if (!room) return;

      const role: PeerRole = room.host === ws ? 'host' : 'client';
      const text = typeof raw === 'string' ? raw : Buffer.from(raw).toString();
      handleMessage(ws, room, role, text);
    },

    close(ws) {
      handleDisconnect(ws);
    },
  },
});

console.log(`[relay] listening on ws://localhost:${port}`);
console.log(`[relay] connect at ws://localhost:${port}/room/<roomId>`);

setInterval(cleanupExpired, ROOM_CLEANUP_MS);
