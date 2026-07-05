import { describe, it, expect, beforeEach, mock } from "bun:test";

let storeClient: any = null;
let storeStatus: string = "disconnected";
let realRequest = mock(async () => ({}));
let realSubscribe = mock(() => () => {});

class MockRpcClient {
  request: any;
  subscribe: any;
  constructor() {
    this.request = realRequest;
    this.subscribe = realSubscribe;
  }
}

mock.module("@/lib/rpc-client", () => ({
  RpcClient: MockRpcClient,
}));

mock.module("@/store/connection", () => ({
  useConnectionStore: Object.assign(
    (selector?: (s: any) => any) => {
      if (!selector) return;
      return selector({ client: storeClient, status: storeStatus });
    },
    {
      getState: () => ({ client: storeClient, status: storeStatus }),
      setState: (s: any) => {
        if (s.client !== undefined) storeClient = s.client;
        if (s.status !== undefined) storeStatus = s.status;
      },
    }
  ),
}));

beforeEach(() => {
  realRequest = mock(async () => ({}));
  realSubscribe = mock(() => () => {});
  storeClient = null;
  storeStatus = "disconnected";
});

describe("terminal smoke tests", () => {
  it("mount: terminal.create is called when client connected", async () => {
    const terminalResult = { terminalId: "term-1" };
    realRequest = mock(async () => terminalResult);
    realSubscribe = mock(() => () => {});

    storeStatus = "connected";
    storeClient = new MockRpcClient();

    const client = storeClient;
    const result = await client.request("terminal.create", { cols: 80, rows: 24 });

    expect(result).toEqual(terminalResult);
    expect(realRequest).toHaveBeenCalledTimes(1);
  });

  it("rpc call: terminal.input sends data to terminal", async () => {
    const createResult = { terminalId: "term-1" };
    realRequest = mock(async () => createResult);

    storeStatus = "connected";
    storeClient = new MockRpcClient();

    await storeClient.request("terminal.create", { cols: 80, rows: 24 });

    realRequest = mock(async () => undefined);
    storeClient = new MockRpcClient();

    await storeClient.request("terminal.input", {
      terminalId: "term-1",
      data: "ls -la\n",
    });

    expect(realRequest).toHaveBeenCalledWith("terminal.input", {
      terminalId: "term-1",
      data: "ls -la\n",
    });
  });

  it("data render: terminal-output subscription receives data", () => {
    let storedCallback: ((data: unknown) => void) | null = null;

    const createResult = { terminalId: "term-1" };
    realRequest = mock(async () => createResult);
    realSubscribe = mock((_event: string, cb: (data: unknown) => void) => {
      storedCallback = cb;
      return () => {};
    });

    storeStatus = "connected";
    storeClient = new MockRpcClient();

    const unsub = storeClient.subscribe("terminal-output", (msg: unknown) => {
      const m = msg as { terminalId?: string; data?: string };
      void m.terminalId;
    });

    if (storedCallback) {
      storedCallback({ terminalId: "term-1", data: "bGVz" });
    }

    expect(realSubscribe).toHaveBeenCalledTimes(1);
    expect(typeof unsub).toBe("function");
  });

  it("unmount: terminal.kill is called on cleanup", async () => {
    const createResult = { terminalId: "term-2" };
    realRequest = mock(async () => createResult);

    storeStatus = "connected";
    storeClient = new MockRpcClient();

    await storeClient.request("terminal.create", { cols: 80, rows: 24 });

    realRequest = mock(async () => undefined);
    storeClient = new MockRpcClient();

    await storeClient.request("terminal.kill", { terminalId: "term-2" });

    expect(realRequest).toHaveBeenCalledWith("terminal.kill", {
      terminalId: "term-2",
    });
  });
});
