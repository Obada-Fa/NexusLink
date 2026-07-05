import type { WsMessage, PerfSnapshot } from '@nexuslink/rpc-types';

type SendFn = (ws: WebSocket, msg: WsMessage) => void;

let sendFn: SendFn;
let interval: ReturnType<typeof setInterval> | null = null;

export function startSidecarReader(
  fn: SendFn,
  getPerf: () => Promise<PerfSnapshot>,
  getSessions: () => WebSocket[],
) {
  sendFn = fn;

  if (interval) clearInterval(interval);

  interval = setInterval(async () => {
    try {
      const perf = await getPerf();
      const msg: WsMessage = { type: 'perf-update', data: perf };
      for (const ws of getSessions()) {
        sendFn(ws, msg);
      }
    } catch {
      // Perf read failed — skip this tick
    }
  }, 2000);
}

export function stopSidecarReader(): void {
  if (interval) {
    clearInterval(interval);
    interval = null;
  }
}
