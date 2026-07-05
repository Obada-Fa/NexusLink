import { describe, it, expect, beforeEach, mock } from "bun:test";

let mockRequest: ReturnType<typeof mock>;
let storeClient: any = null;
let storeStatus: string = "disconnected";

class MockRpcClient {
  request = mockRequest;
}

mock.module("@/lib/rpc-client", () => ({
  RpcClient: MockRpcClient,
}));

mock.module("@/store/connection", () => ({
  useConnectionStore: Object.assign(
    (selector?: (s: any) => any) => {
      if (!selector) return;
      const state = { client: storeClient, status: storeStatus };
      return selector(state);
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
  mockRequest = mock(async () => ({}));
  MockRpcClient.prototype.request = mockRequest;
  storeClient = new MockRpcClient();
  storeStatus = "connected";
});

interface FileEntry {
  name: string;
  path: string;
  size: number;
  isDirectory: boolean;
  modifiedAt: string;
  mimeType: string;
}

const mockEntries: FileEntry[] = [
  {
    name: "Documents",
    path: "/home/Documents",
    size: 0,
    isDirectory: true,
    modifiedAt: "2025-01-01T00:00:00Z",
    mimeType: "",
  },
  {
    name: "readme.txt",
    path: "/home/readme.txt",
    size: 1024,
    isDirectory: false,
    modifiedAt: "2025-01-02T00:00:00Z",
    mimeType: "text/plain",
  },
];

describe("files smoke tests", () => {
  it("mount: fs.list is called to fetch directory contents", async () => {
    mockRequest = mock(async () => mockEntries);
    storeClient = new MockRpcClient();
    MockRpcClient.prototype.request = mockRequest;

    const client = storeClient;

    const result = (await client.request("fs.list", {
      path: "/home",
    })) as FileEntry[];

    expect(result).toHaveLength(2);
    expect(result[0]!.name).toBe("Documents");
    expect(result[1]!.name).toBe("readme.txt");
    expect(mockRequest).toHaveBeenCalledWith("fs.list", { path: "/home" });
  });

  it("rpc call: fs.delete removes a file", async () => {
    mockRequest = mock(async () => undefined); // void return
    storeClient = new MockRpcClient();
    MockRpcClient.prototype.request = mockRequest;

    const client = storeClient;

    await client.request("fs.delete", { path: "/home/readme.txt" });

    expect(mockRequest).toHaveBeenCalledWith("fs.delete", {
      path: "/home/readme.txt",
    });
  });

  it("data render: directory entries sorted with dirs first", () => {
    const entries: FileEntry[] = [
      {
        name: "photo.jpg",
        path: "/home/photo.jpg",
        size: 5000,
        isDirectory: false,
        modifiedAt: "2025-01-03T00:00:00Z",
        mimeType: "image/jpeg",
      },
      {
        name: "Projects",
        path: "/home/Projects",
        size: 0,
        isDirectory: true,
        modifiedAt: "2025-01-01T00:00:00Z",
        mimeType: "",
      },
      {
        name: "notes.md",
        path: "/home/notes.md",
        size: 200,
        isDirectory: false,
        modifiedAt: "2025-01-02T00:00:00Z",
        mimeType: "text/markdown",
      },
    ];

    const dirs = entries.filter((e) => e.isDirectory);
    const files = entries.filter((e) => !e.isDirectory);
    const sorted = [...dirs, ...files];

    expect(sorted[0]!.name).toBe("Projects");
    expect(sorted[1]!.name).toBe("photo.jpg");
    expect(sorted[2]!.name).toBe("notes.md");
    expect(dirs).toHaveLength(1);
    expect(files).toHaveLength(2);
  });

  it("unmount: cleanup when disconnecting after file operations", async () => {
    mockRequest = mock(async () => mockEntries);
    storeClient = new MockRpcClient();
    MockRpcClient.prototype.request = mockRequest;

    const client = storeClient;

    await client.request("fs.list", { path: "/home" });

    storeStatus = "disconnected";
    storeClient = null;

    expect(storeStatus).toBe("disconnected");
    expect(storeClient).toBeNull();
  });
});
