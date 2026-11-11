import {
  startCapture,
  stopCapture,
} from '../../apps/desktop/src/server/handlers/capture';
import { mouseClick, stopInjector } from '../../apps/desktop/src/server/handlers/input';
import { setSend, signalWebrtc, startWebrtc, stopWebrtcForSocket } from '../../apps/desktop/src/server/handlers/webrtc';
import type { WebRtcClientSignal } from '@nexuslink/rpc-types';

const display = process.env.DISPLAY;
if (!display || !/^:[1-9]\d*$/.test(display) || !process.env.NEXUSLINK_BENCH_XAUTHORITY ||
    process.env.XAUTHORITY !== process.env.NEXUSLINK_BENCH_XAUTHORITY) {
  throw new Error('Run the benchmark through run.py to allocate its private display');
}

const [target, x, y, width, height] = Bun.argv.slice(2);
const region = { x: Number(x), y: Number(y), width: Number(width), height: Number(height) };
let streamId: string | undefined;
let currentSocket: WebSocket | undefined;
let webrtcId: string | undefined;

setSend((ws, message) => ws.send(JSON.stringify(message)));

function stop() {
  if (streamId) stopCapture(streamId);
  if (currentSocket) stopWebrtcForSocket(currentSocket);
  streamId = undefined;
  webrtcId = undefined;
  currentSocket = undefined;
  stopInjector();
}

const page = Bun.file(new URL('client.html', import.meta.url));
const server = Bun.serve({
  hostname: '127.0.0.1',
  port: 0,
  fetch(request, server) {
    const url = new URL(request.url);
    if (url.pathname === '/') return new Response(page);
    if (url.pathname === '/stream' && request.headers.get('Origin') === url.origin &&
        !streamId && server.upgrade(request)) return;
    return new Response(null, { status: 404 });
  },
  websocket: {
    open(ws) {
      currentSocket = ws as unknown as WebSocket;
      const stream = startCapture(
        'medium', 24, currentSocket,
        target === 'desktop' ? undefined : region, undefined,
        target === 'virtual' ? display : undefined,
      );
      streamId = stream.streamId;
    },
    async message(ws, payload) {
      if (payload === 'tap') {
        const { ok } = mouseClick('left', region.x + 25, region.y + 25, display);
        if (!ok) ws.send('input failed');
        return;
      }
      const message = JSON.parse(String(payload));
      const socket = ws as unknown as WebSocket;
      if (message.type === 'start-h264' && streamId) {
        const reply = await startWebrtc({ streamId }, socket);
        if (socket === currentSocket) {
          webrtcId = reply.webrtcId;
          ws.send(JSON.stringify({ type: 'webrtc-start', ...reply }));
        }
        return;
      }
      if (message.type === 'signal' && webrtcId) {
        signalWebrtc(webrtcId, message.data as WebRtcClientSignal, socket);
        return;
      }
      if (message.type === 'stop-h264') {
        stopWebrtcForSocket(socket);
        webrtcId = undefined;
        return;
      }
      if (message.result || message.error) {
        stop();
        console.log(JSON.stringify(message));
      }
    },
    close: stop,
  },
});

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.on(signal, () => {
    stop();
    server.stop(true);
  });
}

console.log(server.port);
