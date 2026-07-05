import { describe, it, expect, beforeEach, mock, spyOn } from "bun:test";
import { Room, ROOM_EXPIRY_MS } from "../room";

function makeWs(roomId: string, readyState: number = 1) {
  const ws = {
    data: { roomId },
    readyState,
    send: mock(() => {}),
    close: mock(() => {}),
  } as any;
  return ws;
}

describe("Room", () => {
  let room: Room;

  beforeEach(() => {
    room = new Room("test-room");
  });

  it("creates room with id and createdAt", () => {
    expect(room.id).toBe("test-room");
    expect(room.createdAt).toBeGreaterThan(0);
    expect(room.isEmpty).toBe(true);
    expect(room.isFull).toBe(false);
  });

  it("addPeer adds host", () => {
    const ws = makeWs("test-room");
    const ok = room.addPeer(ws, "host");
    expect(ok).toBe(true);
    expect(room.isEmpty).toBe(false);
    expect(room.isFull).toBe(false);
    expect(room.peers).toHaveLength(1);
    expect(room.peers[0]!.role).toBe("host");
  });

  it("addPeer adds client after host", () => {
    const hostWs = makeWs("test-room");
    const clientWs = makeWs("test-room");
    room.addPeer(hostWs, "host");
    const ok = room.addPeer(clientWs, "client");
    expect(ok).toBe(true);
    expect(room.isFull).toBe(true);
    expect(room.peers).toHaveLength(2);
  });

  it("addPeer rejects duplicate host", () => {
    const ws1 = makeWs("test-room");
    const ws2 = makeWs("test-room");
    room.addPeer(ws1, "host");
    const ok = room.addPeer(ws2, "host");
    expect(ok).toBe(false);
    expect(room.peers).toHaveLength(1);
  });

  it("addPeer rejects duplicate client", () => {
    const client1 = makeWs("test-room");
    const client2 = makeWs("test-room");
    room.addPeer(client1, "client");
    const ok = room.addPeer(client2, "client");
    expect(ok).toBe(false);
    expect(room.peers).toHaveLength(1);
  });

  it("removePeer removes host and returns role", () => {
    const ws = makeWs("test-room");
    room.addPeer(ws, "host");
    const role = room.removePeer(ws);
    expect(role).toBe("host");
    expect(room.isEmpty).toBe(true);
    expect(room.peers).toHaveLength(0);
  });

  it("removePeer removes client and returns role", () => {
    const hostWs = makeWs("test-room");
    const clientWs = makeWs("test-room");
    room.addPeer(hostWs, "host");
    room.addPeer(clientWs, "client");
    const role = room.removePeer(clientWs);
    expect(role).toBe("client");
    expect(room.isFull).toBe(false);
    expect(room.peers).toHaveLength(1);
  });

  it("removePeer returns null for unknown ws", () => {
    const ws = makeWs("test-room");
    const role = room.removePeer(ws);
    expect(role).toBeNull();
  });

  it("broadcast sends to all peers except sender", () => {
    const hostWs = makeWs("test-room");
    const clientWs = makeWs("test-room");
    room.addPeer(hostWs, "host");
    room.addPeer(clientWs, "client");

    room.broadcast("host", { type: "test", payload: 1 });

    expect(hostWs.send).not.toHaveBeenCalled();
    expect(clientWs.send).toHaveBeenCalledTimes(1);
    expect(clientWs.send).toHaveBeenCalledWith(
      JSON.stringify({ type: "test", payload: 1 })
    );
  });

  it("broadcast filters by role", () => {
    const hostWs = makeWs("test-room");
    const clientWs = makeWs("test-room");
    room.addPeer(hostWs, "host");
    room.addPeer(clientWs, "client");

    room.broadcast(null, { type: "alert" }, "host");

    expect(hostWs.send).toHaveBeenCalledTimes(1);
    expect(clientWs.send).not.toHaveBeenCalled();
  });

  it("broadcast sends to all when sender is null and no filter", () => {
    const hostWs = makeWs("test-room");
    const clientWs = makeWs("test-room");
    room.addPeer(hostWs, "host");
    room.addPeer(clientWs, "client");

    room.broadcast(null, { type: "all" });

    expect(hostWs.send).toHaveBeenCalledTimes(1);
    expect(clientWs.send).toHaveBeenCalledTimes(1);
  });

  it("broadcast skips closed peers", () => {
    const hostWs = makeWs("test-room", 3); // CLOSED
    const clientWs = makeWs("test-room");
    room.addPeer(hostWs, "host");
    room.addPeer(clientWs, "client");

    room.broadcast(null, { type: "data" });

    expect(hostWs.send).not.toHaveBeenCalled();
    expect(clientWs.send).toHaveBeenCalledTimes(1);
  });

  it("broadcastTo sends to specific role", () => {
    const hostWs = makeWs("test-room");
    const clientWs = makeWs("test-room");
    room.addPeer(hostWs, "host");
    room.addPeer(clientWs, "client");

    room.broadcastTo({ type: "private" }, "host");

    expect(hostWs.send).toHaveBeenCalledTimes(1);
    expect(clientWs.send).not.toHaveBeenCalled();
  });

  it("expire closes all peers and clears them", () => {
    const hostWs = makeWs("test-room");
    const clientWs = makeWs("test-room");
    room.addPeer(hostWs, "host");
    room.addPeer(clientWs, "client");

    room.expire();

    expect(hostWs.send).toHaveBeenCalledTimes(1);
    expect(hostWs.close).toHaveBeenCalledTimes(1);
    expect(clientWs.send).toHaveBeenCalledTimes(1);
    expect(clientWs.close).toHaveBeenCalledTimes(1);
    expect(room.isEmpty).toBe(true);
  });

  it("expire sends room-expired message", () => {
    const hostWs = makeWs("test-room");
    room.addPeer(hostWs, "host");

    room.expire();

    const callArg = (hostWs.send as any).mock.calls[0]?.[0];
    const parsed = JSON.parse(callArg);
    expect(parsed).toEqual({ type: "room-expired", roomId: "test-room" });
  });

  it("expire is idempotent", () => {
    const ws = makeWs("test-room");
    room.addPeer(ws, "host");
    room.expire();
    room.expire();
    expect(ws.send).toHaveBeenCalledTimes(1);
    expect(room.isEmpty).toBe(true);
  });

  it("room expiry timer set to 30 minutes", () => {
    expect(ROOM_EXPIRY_MS).toBe(30 * 60 * 1000);
  });

  it("addPeer resets expiry timer", () => {
    const spy = spyOn(room as any, "resetExpiry");
    const ws = makeWs("test-room");
    room.addPeer(ws, "host");
    expect(spy).toHaveBeenCalled();
  });

  it("removePeer after both leave results in empty room", () => {
    const hostWs = makeWs("test-room");
    const clientWs = makeWs("test-room");
    room.addPeer(hostWs, "host");
    room.addPeer(clientWs, "client");
    room.removePeer(hostWs);
    room.removePeer(clientWs);
    expect(room.isEmpty).toBe(true);
  });
});
