type JsonRpcRequest = {
  jsonrpc: '2.0';
  id: string;
  method: string;
  params?: unknown;
};

type JsonRpcResponse = {
  jsonrpc: '2.0';
  id: string;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
};

type JsonRpcNotification = {
  jsonrpc: '2.0';
  method: string;
  params?: unknown;
};

type PendingRequest = {
  resolve: (value: unknown) => void;
  reject: (reason: unknown) => void;
  timer: ReturnType<typeof setTimeout>;
};

export class RpcClient {
  private ws: WebSocket | null = null;
  private pending = new Map<string, PendingRequest>();
  private subscribers = new Map<string, Set<(data: unknown) => void>>();
  private binarySubscribers = new Set<(data: ArrayBuffer) => void>();
  private reconnectAttempts = 0;
  private maxReconnectDelay = 30000;
  private baseDelay = 1000;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private wsUrl: string;
  private idCounter = 0;
  private closed = false;

  token: string | null = null;
  private generation = 0;
  private connecting: Promise<void> | null = null;
  constructor(wsUrl: string, private authenticate?: (client: RpcClient) => Promise<void>, private statusChanged?: (status: 'connecting' | 'connected' | 'disconnected') => void) {
    this.wsUrl = wsUrl;
  }

  private generateId(): string {
    this.idCounter++;
    return `${Date.now()}-${this.idCounter}`;
  }

  connect(): Promise<void> {
    if(this.connecting) return this.connecting;
    const run=this.open(); this.connecting=run;
    return run.finally(()=>{if(this.connecting===run)this.connecting=null;});
  }
  private open(): Promise<void> {
    this.closed=false;
    const generation=++this.generation;
    if(this.reconnectTimer)clearTimeout(this.reconnectTimer);
    this.stopHeartbeat();this.failPending('Connection replaced');this.ws?.close();
    this.statusChanged?.('connecting');
    return new Promise((resolve,reject)=>{
      const ws=new WebSocket(this.wsUrl);this.ws=ws;ws.binaryType='arraybuffer';
      const timer=setTimeout(()=>{ws.close();reject(new Error('Connection timeout'));},10000);
      ws.onopen=async()=>{
        clearTimeout(timer);
        try {
          await this.authenticate?.(this);
          if(this.closed || generation!==this.generation)throw new Error('Connection superseded');
          this.reconnectAttempts=0;this.startHeartbeat();this.statusChanged?.('connected');resolve();
        } catch(error){reject(error);ws.close();}
      };
      ws.onmessage=event=>{if(generation===this.generation)this.handleMessage(event);};
      ws.onclose=()=>{
        clearTimeout(timer);reject(new Error('Connection closed'));
        if(generation!==this.generation)return;
        this.stopHeartbeat();this.ws=null;this.failPending('Connection closed');this.statusChanged?.('disconnected');
        if(!this.closed)this.reconnect();
      };
      ws.onerror=()=>{clearTimeout(timer);reject(new Error('WebSocket error'));};
    });
  }

  disconnect(): void {
    this.closed = true;
    ++this.generation;
    this.stopHeartbeat();
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.failPending('Disconnected');
    this.ws?.close();
    this.ws = null;
  }

  async request(method: string, params?: unknown, timeoutMs = 10000): Promise<unknown> {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      throw new Error('Not connected');
    }

    const id = this.generateId();
    const req: JsonRpcRequest = { jsonrpc: '2.0', id, method, params };

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Request timeout: ${method}`));
      }, timeoutMs);

      this.pending.set(id, { resolve, reject, timer });

      try {
        this.ws!.send(JSON.stringify({ type: 'rpc-request', request: req }));
      } catch (err) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(err);
      }
    });
  }

  /** Subscribe to raw binary WS messages (mirror frames). */
  subscribeBinary(callback: (data: ArrayBuffer) => void): () => void {
    this.binarySubscribers.add(callback);
    return () => {
      this.binarySubscribers.delete(callback);
    };
  }

  subscribe(topic: string, callback: (data: unknown) => void): () => void {
    let subs = this.subscribers.get(topic);
    if (!subs) {
      subs = new Set();
      this.subscribers.set(topic, subs);
    }
    subs.add(callback);

    return () => {
      subs?.delete(callback);
      if (subs && subs.size === 0) {
        this.subscribers.delete(topic);
      }
    };
  }

  private handleMessage(event: MessageEvent): void {
    // Binary messages (mirror frames) bypass JSON entirely — hot path.
    if (event.data instanceof ArrayBuffer) {
      for (const cb of this.binarySubscribers) cb(event.data);
      return;
    }

    let raw: Record<string, unknown>;
    try {
      raw = JSON.parse(event.data as string);
    } catch {
      return;
    }

    if (raw.type === 'rpc-response' && raw.response) {
      const resp = raw.response as JsonRpcResponse;
      const pending = this.pending.get(String(resp.id));
      if (pending) {
        clearTimeout(pending.timer);
        this.pending.delete(resp.id);
        if (resp.error) {
          pending.reject(new Error(typeof resp.error === 'string' ? resp.error : resp.error.message ?? 'RPC error'));
        } else {
          pending.resolve(resp.result);
        }
      }
      return;
    }

    if (typeof raw.type === 'string' && raw.type !== 'rpc-request') {
      const subs = this.subscribers.get(raw.type);
      if (subs) {
        for (const cb of subs) {
          cb(raw);
        }
      }
      return;
    }

    if ('id' in raw && raw.id) {
      const rid = String(raw.id);
      const pending = this.pending.get(rid);
      if (pending) {
        clearTimeout(pending.timer);
        this.pending.delete(rid);
        if (raw.error) {
          const err = raw.error as { message?: string };
          pending.reject(new Error(err.message));
        } else {
          pending.resolve(raw.result);
        }
      }
    } else if ('method' in raw && typeof raw.method === 'string') {
      const subs = this.subscribers.get(raw.method);
      if (subs) {
        for (const cb of subs) {
          cb(raw.params);
        }
      }
    }
  }

  private failPending(reason: string): void {
    for (const [id, { reject, timer }] of this.pending) {
      clearTimeout(timer);
      reject(new Error(reason));
    }
    this.pending.clear();
  }

  private reconnect(): void {
    const delay = Math.min(
      this.baseDelay * Math.pow(2, this.reconnectAttempts),
      this.maxReconnectDelay
    );
    this.reconnectAttempts++;

    this.reconnectTimer = setTimeout(() => {
      if (this.closed) return;
      this.connect().catch(() => {
        /* reconnect loop continues via onclose */
      });
    }, delay);
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
      this.request('session.heartbeat', {}).catch(() => {
        this.ws?.close();
      });
    }, 20000);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
  }
}
