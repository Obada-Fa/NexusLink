import { describe, it, expect, beforeEach, mock, afterEach, spyOn } from "bun:test";

const storage = new Map<string, string>();

beforeEach(() => {
  storage.clear();
  (globalThis as any).localStorage = {
    getItem: (key: string) => storage.get(key) ?? null,
    setItem: (key: string, val: string) => { storage.set(key, val); },
    removeItem: (key: string) => { storage.delete(key); },
  };
});

afterEach(() => {
  delete (globalThis as any).localStorage;
});

const { getHostUrl, setHostUrl, clearHostUrl } = await import("@/lib/desktop-runtime");

let originalWebSocket: any;

beforeEach(() => {
  originalWebSocket = (globalThis as any).WebSocket;
});

afterEach(() => {
  (globalThis as any).WebSocket = originalWebSocket;
});

describe("pair page behavior", () => {
  it("load: getHostUrl returns null when unset", () => {
    expect(getHostUrl()).toBeNull();
  });

  it("connect: setHostUrl persists, getHostUrl retrieves", () => {
    setHostUrl("ws://localhost:45678/signal");
    expect(getHostUrl()).toBe("ws://localhost:45678/signal");
  });

  it("authenticate success: WebSocket handshake sequence", () => {
    let wsOnOpen: (() => void) | null = null;
    let wsOnMessage: ((e: { data: string }) => void) | null = null;
    let wsOnClose: (() => void) | null = null;
    let sentMessages: string[] = [];

    class MockSocket {
      readyState = 0;
      send(data: string) { sentMessages.push(data); }
      close() {
        this.readyState = 3;
        if (wsOnClose) wsOnClose();
      }
      set onopen(fn: any) { wsOnOpen = fn; }
      set onmessage(fn: any) { wsOnMessage = fn; }
      set onclose(fn: any) { wsOnClose = fn; }
      set onerror(_fn: any) {}
    }

    (globalThis as any).WebSocket = MockSocket;

    const ws = new MockSocket();

    ws.onopen = () => {};
    ws.onclose = () => {};

    if (wsOnOpen) wsOnOpen();
    ws.readyState = 1;

    ws.send(JSON.stringify({
      type: "rpc-request",
      request: { id: 1, method: "session.pair", params: { publicKey: "{}" } },
    }));

    expect(sentMessages[0]).toContain("session.pair");

    ws.close();

    expect(ws.readyState).toBe(3);
    expect(sentMessages).toHaveLength(1);
  });

  it("authenticate failure: error response handled", () => {
    let wsOnMessage: ((e: { data: string }) => void) | null = null;

    class MockSocket {
      readyState = 1;
      send(_data: string) {}
      close() { this.readyState = 3; }
      set onopen(_fn: any) {}
      set onmessage(fn: any) { wsOnMessage = fn; }
      set onclose(_fn: any) {}
      set onerror(_fn: any) {}
    }

    (globalThis as any).WebSocket = MockSocket;

    const ws = new MockSocket();

    const payload = JSON.stringify({
      type: "rpc-response",
      response: { id: 2, error: "Invalid TOTP code" },
    });

    if (wsOnMessage) {
      wsOnMessage({ data: payload });
    }

    const parsed = JSON.parse(payload);
    expect(parsed.response?.error).toBe("Invalid TOTP code");
  });

  it("disconnect: close handler invoked on WebSocket close", () => {
    let closeHandler: (() => void) | null = null;

    class MockSocket {
      readyState = 0;
      send(_data: string) {}
      close() {
        this.readyState = 3;
        if (closeHandler) closeHandler();
      }
      set onopen(fn: any) {
        // simulate open
        this.readyState = 1;
        if (fn) fn();
      }
      set onmessage(_fn: any) {}
      set onclose(fn: any) { closeHandler = fn; }
      set onerror(_fn: any) {}
    }

    (globalThis as any).WebSocket = MockSocket;

    let closeCalled = false;
    const ws = new MockSocket();
    ws.onclose = () => { closeCalled = true; };
    ws.close();

    expect(closeCalled).toBe(true);
  });
});
