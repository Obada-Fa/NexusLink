declare var Bun: {
  file(path: string): {
    text(): Promise<string>;
    arrayBuffer(): Promise<ArrayBuffer>;
    exists(): Promise<boolean>;
    stream(): ReadableStream;
    readonly size: number;
    readonly type: string;
  };
  write(path: string, data: string | ArrayBuffer | Uint8Array): Promise<number>;
  sleep(ms: number): Promise<void>;
  env: Record<string, string>;
  serve(opts: {
    hostname?: string;
    port: number;
    fetch(req: Request, server: { upgrade(req: Request): boolean }): Response | undefined | Promise<Response | undefined>;
    websocket?: {
      open?(ws: WebSocket): void;
      message?(ws: WebSocket, data: unknown): void | Promise<void>;
      close?(ws: WebSocket): void;
    };
  }): { port: number };
  spawn(cmd: string[], opts?: {
    stdin?: 'pipe' | 'inherit' | null;
    stdout?: 'pipe' | 'inherit' | null;
    stderr?: 'pipe' | 'inherit' | null;
    env?: Record<string, string>;
  }): {
    stdin: { write(data: Uint8Array): number };
    stdout: AsyncIterable<Uint8Array>;
    stderr: AsyncIterable<Uint8Array>;
    kill(signal?: string): void;
    exited: Promise<number>;
    exitCode?: number | null;
    killed?: boolean;
    pid?: number;
  };
  spawnSync(cmd: string[], opts?: Record<string, unknown>): {
    stdout: { toString(enc?: string): string };
    stderr: { toString(enc?: string): string };
    exitCode: number;
  };
};
