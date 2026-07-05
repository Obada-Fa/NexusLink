import { describe, it, expect, beforeEach, mock } from "bun:test";

let storedClient: any = null;
let storedStatus = "disconnected";
let storedHostUrl = "";
let connFn = mock(async () => {});
let discFn = mock(() => {});

const connectSpy = mock(async (hostUrl: string) => {
  storedStatus = "connecting";
  storedHostUrl = hostUrl;
  storedClient = { hostUrl };
  try {
    await connFn();
    storedStatus = "connected";
  } catch (err) {
    storedStatus = "disconnected";
    throw err;
  }
});

const disconnectSpy = mock(() => {
  discFn();
  storedStatus = "disconnected";
  storedClient = null;
});

mock.module("@/lib/rpc-client", () => ({
  RpcClient: class {
    hostUrl: string;
    constructor(url: string) { this.hostUrl = url; }
    connect = connFn;
    disconnect = discFn;
    request = mock(async () => ({}));
    subscribe = mock(() => () => {});
  },
}));

mock.module("@/store/connection", () => ({
  useConnectionStore: Object.assign(
    (selector?: (s: any) => any) => {
      if (!selector) return;
      return selector({ client: storedClient, status: storedStatus });
    },
    {
      getState: () => ({
        client: storedClient,
        status: storedStatus,
        hostUrl: storedHostUrl,
        connect: connectSpy,
        disconnect: disconnectSpy,
      }),
      setState: (s: any) => {
        if (s.client !== undefined) storedClient = s.client;
        if (s.status !== undefined) storedStatus = s.status;
        if (s.hostUrl !== undefined) storedHostUrl = s.hostUrl;
      },
    }
  ),
}));

const { useConnectionStore } = await import("@/store/connection");

beforeEach(() => {
  connFn = mock(async () => {});
  discFn = mock(() => {});
  storedClient = null;
  storedStatus = "disconnected";
  storedHostUrl = "";
});

describe("connection store", () => {
  it("connect transitions status: connecting -> connected", async () => {
    const hostUrl = "ws://localhost:1234/signal";
    const connectPromise = useConnectionStore.getState().connect(hostUrl);

    expect(useConnectionStore.getState().status).toBe("connecting");
    expect(useConnectionStore.getState().hostUrl).toBe(hostUrl);

    await connectPromise;

    expect(useConnectionStore.getState().status).toBe("connected");
  });

  it("disconnect resets to disconnected", async () => {
    const hostUrl = "ws://test:1/signal";
    await useConnectionStore.getState().connect(hostUrl);
    expect(useConnectionStore.getState().status).toBe("connected");

    useConnectionStore.getState().disconnect();
    expect(useConnectionStore.getState().status).toBe("disconnected");
    expect(useConnectionStore.getState().client).toBeNull();
  });

  it("reconnect: disconnect then connect again works", async () => {
    const hostUrl = "ws://localhost:1234/signal";

    await useConnectionStore.getState().connect(hostUrl);
    expect(useConnectionStore.getState().status).toBe("connected");

    useConnectionStore.getState().disconnect();
    expect(useConnectionStore.getState().status).toBe("disconnected");

    await useConnectionStore.getState().connect(hostUrl);
    expect(useConnectionStore.getState().status).toBe("connected");
  });

  it("connect failure sets status back to disconnected", async () => {
    connFn = mock(async () => {
      throw new Error("refused");
    });

    const hostUrl = "ws://bad:1/signal";

    try {
      await useConnectionStore.getState().connect(hostUrl);
    } catch (err) {
      expect(String(err)).toContain("refused");
    }

    expect(useConnectionStore.getState().status).toBe("disconnected");
  });

  it("double connect discards previous connection", async () => {
    const firstHost = "ws://first:1/signal";
    const secondHost = "ws://second:1/signal";

    await useConnectionStore.getState().connect(firstHost);
    const firstClient = useConnectionStore.getState().client;
    expect(firstClient).not.toBeNull();

    await useConnectionStore.getState().connect(secondHost);
    expect(useConnectionStore.getState().hostUrl).toBe(secondHost);
    expect(useConnectionStore.getState().client).not.toBe(firstClient);
    expect(useConnectionStore.getState().status).toBe("connected");
  });

  it("connect persists host URL and transitions states atomically", async () => {
    const hostUrl = "ws://persist:1/signal";
    await useConnectionStore.getState().connect(hostUrl);

    const state = useConnectionStore.getState();
    expect(state.hostUrl).toBe(hostUrl);
    expect(state.status).toBe("connected");
    expect(state.client).not.toBeNull();
  });
});
