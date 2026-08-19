import type { PerfSnapshot, WsMessage } from '@nexuslink/rpc-types';

type SendFn = (ws: WebSocket, msg: WsMessage) => void;

let interval: ReturnType<typeof setInterval> | null = null;

export function startPerfBroadcast(
  send: SendFn,
  getPerf: () => Promise<PerfSnapshot>,
  getSessions: () => WebSocket[],
): void {
  if (interval) clearInterval(interval);
  interval = setInterval(async () => {
    try {
      const sessions = getSessions();
      if (sessions.length === 0) return;
      const perf = await getPerf();
      const msg: WsMessage = { type: 'perf-update', data: perf };
      for (const ws of sessions) send(ws, msg);
    } catch {
      // skip this tick
    }
  }, 2000);
}
