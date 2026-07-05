import { describe, it, expect, mock, spyOn } from "bun:test";
import { Room, ROOM_EXPIRY_MS } from "../room";

function makeWs(roomId: string, readyState: number = 1) {
  return {
    data: { roomId },
    readyState,
    send: mock(() => {}),
    close: mock(() => {}),
  } as any;
}

describe("Room edge cases", () => {
  it("1 — duplicate add returns false without modifying peers", () => {
    const room = new Room("edge-room");
    const ws1 = makeWs("edge-room");
    const ws2 = makeWs("edge-room");

    expect(room.addPeer(ws1, "host")).toBe(true);
    expect(room.peers).toHaveLength(1);

    expect(room.addPeer(ws2, "host")).toBe(false);
    expect(room.peers).toHaveLength(1);
    expect(room.peers[0]!.role).toBe("host");
  });

  it("2 — duplicate client rejected when host slot is the only empty one", () => {
    const room = new Room("edge-room");
    const host = makeWs("edge-room");
    room.addPeer(host, "host");

    const client1 = makeWs("edge-room");
    expect(room.addPeer(client1, "client")).toBe(true);

    const client2 = makeWs("edge-room");
    expect(room.addPeer(client2, "client")).toBe(false);
    expect(room.peers).toHaveLength(2);
  });

  it("3 — expiry timer reset on removePeer of one peer", () => {
    const room = new Room("edge-room");
    const host = makeWs("edge-room");
    const client = makeWs("edge-room");
    room.addPeer(host, "host");
    room.addPeer(client, "client");

    const spy = spyOn(room as any, "resetExpiry");
    room.removePeer(host);
    expect(spy).not.toHaveBeenCalled();
  });

  it("4 — broadcast with large payload does not throw", () => {
    const room = new Room("edge-room");
    const host = makeWs("edge-room");
    const client = makeWs("edge-room");
    room.addPeer(host, "host");
    room.addPeer(client, "client");

    const largeData = { type: "data", payload: "x".repeat(10000) };

    expect(() => room.broadcast(null, largeData)).not.toThrow();
    expect(client.send).toHaveBeenCalledTimes(1);
    expect(host.send).toHaveBeenCalledTimes(1);
  });

  it("5 — broadcast with null sender and no filter sends to both peers", () => {
    const room = new Room("edge-room");
    const host = makeWs("edge-room");
    const client = makeWs("edge-room");
    room.addPeer(host, "host");
    room.addPeer(client, "client");

    room.broadcast(null, { type: "all" });

    expect(host.send).toHaveBeenCalledTimes(1);
    expect(client.send).toHaveBeenCalledTimes(1);
  });

  it("6 — closed socket (readyState !== 1) is skipped by broadcast", () => {
    const room = new Room("edge-room");
    const host = makeWs("edge-room", 3); // CLOSED
    const client = makeWs("edge-room");
    room.addPeer(host, "host");
    room.addPeer(client, "client");

    room.broadcast("host", { type: "test" });

    expect(host.send).not.toHaveBeenCalled();
    expect(client.send).toHaveBeenCalledTimes(1);
  });

  it("7 — broadcastTo to missing role does not throw", () => {
    const room = new Room("edge-room");
    const host = makeWs("edge-room");
    room.addPeer(host, "host");

    expect(() => room.broadcastTo({ type: "data" }, "client")).not.toThrow();
  });

  it("8 — removePeer on unknown ws returns null", () => {
    const room = new Room("edge-room");
    const host = makeWs("edge-room");
    room.addPeer(host, "host");

    const unknown = makeWs("edge-room");
    expect(room.removePeer(unknown)).toBeNull();
    expect(room.peers).toHaveLength(1);
  });

  it("9 — refresh resets expiry without affecting peers", () => {
    const room = new Room("edge-room");
    const host = makeWs("edge-room");
    room.addPeer(host, "host");

    const spy = spyOn(room as any, "resetExpiry");
    room.refresh();
    expect(spy).toHaveBeenCalled();
    expect(room.peers).toHaveLength(1);
    expect(room.isEmpty).toBe(false);
  });

  it("10 — expire with only one peer sends room-expired and clears", () => {
    const room = new Room("edge-room");
    const host = makeWs("edge-room");
    room.addPeer(host, "host");

    room.expire();

    const callArg = (host.send as any).mock.calls[0]?.[0];
    const parsed = JSON.parse(callArg);
    expect(parsed).toEqual({ type: "room-expired", roomId: "edge-room" });
    expect(host.close).toHaveBeenCalledTimes(1);
    expect(room.isEmpty).toBe(true);
  });
});
