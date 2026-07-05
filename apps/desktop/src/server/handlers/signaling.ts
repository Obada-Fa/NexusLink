import type { WsMessage } from '@nexuslink/rpc-types';

type SendFn = (ws: WebSocket, msg: WsMessage) => void;

let sendFn: SendFn;
const peers = new Map<string, Set<WebSocket>>();

export function setSend(fn: SendFn) {
  sendFn = fn;
}

export function addPeer(roomId: string, ws: WebSocket): void {
  let room = peers.get(roomId);
  if (!room) {
    room = new Set();
    peers.set(roomId, room);
  }
  room.add(ws);
}

export function removePeer(roomId: string, ws: WebSocket): void {
  const room = peers.get(roomId);
  if (!room) return;
  room.delete(ws);
  if (room.size === 0) peers.delete(roomId);
}

export function broadcast(roomId: string, msg: WsMessage, exclude?: WebSocket): void {
  const room = peers.get(roomId);
  if (!room) return;
  room.forEach((ws) => {
    if (ws !== exclude && sendFn) sendFn(ws, msg);
  });
}
