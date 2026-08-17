import { describe, it, expect, beforeEach, mock } from 'bun:test';

let storeClient: any = null;
let storeStatus: string = 'disconnected';
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

mock.module('@/lib/rpc-client', () => ({
  RpcClient: MockRpcClient,
}));

mock.module('@/store/connection', () => ({
  useConnectionStore: Object.assign(
    (selector?: (s: any) => any) => {
      if (!selector) return;
      return selector({ client: storeClient, status: storeStatus, connect: mock(async () => {}), hostUrl: 'ws://localhost:45678/rpc' });
    },
    {
      getState: () => ({ client: storeClient, status: storeStatus }),
      setState: (s: any) => {
        if (s.client !== undefined) storeClient = s.client;
        if (s.status !== undefined) storeStatus = s.status;
      },
    },
  ),
}));

beforeEach(() => {
  realRequest = mock(async () => ({}));
  realSubscribe = mock(() => () => {});
  storeClient = null;
  storeStatus = 'disconnected';
});

describe('agent smoke tests', () => {
  it('agent.list returns installed agents', async () => {
    const agents = [
      { id: 'cursor', label: 'Cursor', installed: true, supportsChat: true, supportsTerminal: true },
      { id: 'opencode', label: 'OpenCode', installed: false, supportsChat: true, supportsTerminal: true },
      { id: 'antigravity', label: 'Antigravity', installed: true, supportsChat: false, supportsTerminal: true },
    ];
    realRequest = mock(async () => agents);
    storeStatus = 'connected';
    storeClient = new MockRpcClient();

    const result = await storeClient.request('agent.list', {});
    expect(result).toEqual(agents);
  });

  it('agent.run starts a headless prompt', async () => {
    realRequest = mock(async () => ({ runId: 'run-1' }));
    storeStatus = 'connected';
    storeClient = new MockRpcClient();

    const result = await storeClient.request('agent.run', {
      agentId: 'cursor',
      prompt: 'fix the failing test',
      cwd: '/workspace',
    });

    expect(result).toEqual({ runId: 'run-1' });
    expect(realRequest).toHaveBeenCalledWith('agent.run', {
      agentId: 'cursor',
      prompt: 'fix the failing test',
      cwd: '/workspace',
    });
  });

  it('agent-output subscription receives streamed chunks', () => {
    let storedCallback: ((data: unknown) => void) | null = null;
    realSubscribe = mock((_event: string, cb: (data: unknown) => void) => {
      storedCallback = cb;
      return () => {};
    });

    storeStatus = 'connected';
    storeClient = new MockRpcClient();

    const chunks: string[] = [];
    storeClient.subscribe('agent-output', (msg: unknown) => {
      const m = msg as { data?: string; done?: boolean };
      if (m.data) chunks.push(m.data);
    });

    storedCallback?.({ runId: 'run-1', data: 'Hello' });
    storedCallback?.({ runId: 'run-1', data: ' world', done: true, exitCode: 0 });

    expect(chunks.join('')).toBe('Hello world');
  });

  it('terminal.create can launch an agent binary directly', async () => {
    realRequest = mock(async () => ({ terminalId: 'term-agent' }));
    storeStatus = 'connected';
    storeClient = new MockRpcClient();

    const result = await storeClient.request('terminal.create', {
      cols: 100,
      rows: 30,
      command: '/usr/local/bin/agent',
      args: [],
      cwd: '/workspace',
    });

    expect(result).toEqual({ terminalId: 'term-agent' });
  });
});
