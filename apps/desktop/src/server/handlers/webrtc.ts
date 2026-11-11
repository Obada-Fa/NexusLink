// One GStreamer encoder per peer. Linked MJPEG captures own the display,
// crop and geometry watcher for both transports.
import { fileURLToPath } from 'node:url';
import type { WsMessage, WebRtcClientSignal, WebRtcSignal } from '@nexuslink/rpc-types';
import { getAppSession, getSessionAudioSource } from './app-sessions';
import { getCaptureTarget, pauseCapture, watchCapture } from './capture';

const agentPath = fileURLToPath(new URL('../webrtc-agent.py', import.meta.url));
const pci = () => process.env.NEXUSLINK_VAAPI_PCI || '0000:03:00.0';
type Proc = ReturnType<typeof Bun.spawn>;
type SendFn = (ws: WebSocket, msg: WsMessage) => void;
let sendFn: SendFn = () => {};
let authorized = (ws: WebSocket) => ws.readyState === 1;

export function setSend(fn: SendFn): void {
  sendFn = fn;
}

export function setWebrtcAuthorizer(fn: (ws: WebSocket) => boolean): void {
  authorized = fn;
}

const bitrates = [1500, 2200, 3000, 4000, 5500] as const;
const initialStep = 2;
type BitrateState = { step: number; bad: number; good: number; zoomed: boolean };
type Stats = Extract<WebRtcClientSignal, { kind: 'stats' }>;

export function planWebrtcBitrate(state: BitrateState, stats: Stats, targetFps: number): BitrateState {
  const bad = stats.fps < targetFps * 0.65 || stats.loss > 0.05 || stats.jitterMs > 65 || (stats.rttMs ?? 0) > 350;
  const good = stats.fps >= targetFps * 0.85 && stats.loss < 0.015 && stats.jitterMs < 35 && (stats.rttMs ?? 0) < 220;
  if (bad && state.bad >= 1) return { ...state, step: Math.max(0, state.step - 1), bad: 0, good: 0 };
  if (good && state.good >= 3) {
    const ceiling = state.zoomed ? bitrates.length - 1 : initialStep;
    return { ...state, step: Math.min(ceiling, state.step + 1), bad: 0, good: 0 };
  }
  return { ...state, bad: bad ? state.bad + 1 : 0, good: good ? state.good + 1 : 0 };
}

export function planWebrtcZoom(state: BitrateState, zoomed: boolean): BitrateState {
  if (zoomed === state.zoomed) return state;
  const step = zoomed ? Math.min(state.step + 1, bitrates.length - 1) : Math.min(state.step, initialStep);
  return { step, zoomed, bad: 0, good: 0 };
}

interface WebRtcStream {
  id: string;
  proc: Proc;
  ws: WebSocket;
  streamId?: string;
  unwatch?: () => void;
  authTimer?: ReturnType<typeof setInterval>;
  startupTimer?: ReturnType<typeof setTimeout>;
  fps: number;
  bitrate: BitrateState;
  lastStatsAt: number;
}

type Availability = { available: boolean; reason?: string };
type StartResult = Availability & { webrtcId?: string; codec?: 'H264' };
const streams = new Map<string, WebRtcStream>();
let probeInFlight: Promise<Availability> | undefined;
let lastProbe: { pci: string; result: Availability; at: number } | undefined;

export async function webrtcAvailability(): Promise<Availability> {
  const address = pci();
  if (lastProbe?.pci === address && (lastProbe.result.available || Date.now() - lastProbe.at < 10_000)) {
    return lastProbe.result;
  }
  if (probeInFlight) return probeInFlight;
  probeInFlight = (async () => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    let result: Availability;
    try {
      const proc = Bun.spawn(['python3', agentPath, '--probe', '--pci', address], {
        stdout: 'pipe', stdin: 'ignore', stderr: 'ignore',
      });
      let timedOut = false;
      timer = setTimeout(() => { timedOut = true; proc.kill('SIGKILL'); }, 5000);
      const [code, output] = await Promise.all([proc.exited, new Response(proc.stdout).text()]);
      if (timedOut) result = { available: false, reason: 'GStreamer probe timed out' };
      else if (code === 0) result = { available: true };
      else {
        let reason = 'GStreamer, PyGObject or VA-API is unavailable';
        try { reason = JSON.parse(output).message ?? reason; } catch { /* Python failed before emitting JSON */ }
        result = { available: false, reason };
      }
    } catch {
      result = { available: false, reason: 'Could not start the Python GStreamer probe' };
    } finally {
      clearTimeout(timer);
    }
    lastProbe = { pci: address, result, at: Date.now() };
    return result;
  })().finally(() => { probeInFlight = undefined; });
  return probeInFlight;
}

export async function startWebrtc(
  params: { streamId?: string; sessionId?: string; fps?: number },
  ws: WebSocket,
): Promise<StartResult> {
  const { streamId, sessionId } = params;
  const app = sessionId ? getAppSession(sessionId) : null;
  if (sessionId && !app) return { available: false, reason: 'Unknown app session' };
  if (!streamId && !app) return { available: false, reason: 'Start a screen capture before upgrading to H.264' };
  if (streamId && !getCaptureTarget(streamId, ws)) return { available: false, reason: 'No matching capture on this connection' };

  const availability = await webrtcAvailability();
  if (!availability.available) return availability;
  if (ws.readyState !== 1 || !authorized(ws)) return { available: false, reason: 'Capture connection closed' };

  // Resolve after probing so the crop is current, even when GStreamer initializes slowly.
  const target = streamId ? getCaptureTarget(streamId, ws) : app && {
    display: app.display,
    region: { x: 0, y: 0, width: app.width & ~1, height: app.height & ~1 },
    fps: params.fps ?? 24,
  };
  if (!target || (app && target.display !== app.display)) {
    return { available: false, reason: 'No matching capture on this connection' };
  }

  for (const stream of streams.values()) {
    if (streamId && stream.streamId === streamId && stream.ws === ws) stopWebrtc(stream.id);
  }

  const { x, y, width, height } = target.region;
  const fps = Math.max(10, Math.min(30, Math.round(target.fps || 24)));
  const argv = [
    'python3', agentPath, '--display', target.display, '--region', ...[x, y, width, height].map(String),
    '--fps', String(fps), '--pci', pci(), '--bitrate', String(bitrates[initialStep]),
  ];
  const audioSource = sessionId ? getSessionAudioSource(sessionId) : null;
  if (audioSource) argv.push('--audio-source', audioSource);
  const stun = process.env.NEXUSLINK_STUN ?? 'stun://stun.l.google.com:19302';
  if (stun) argv.push('--stun', stun);

  let proc: Proc;
  try {
    proc = Bun.spawn(argv, { stdin: 'pipe', stdout: 'pipe', stderr: 'ignore' });
  } catch {
    return { available: false, reason: 'Could not start the GStreamer encoder' };
  }

  const id = crypto.randomUUID();
  const stream: WebRtcStream = {
    id, proc, ws, streamId, fps,
    bitrate: { step: initialStep, bad: 0, good: 0, zoomed: false },
    lastStatsAt: 0,
  };
  streams.set(id, stream);
  if (streamId) {
    stream.unwatch = watchCapture(streamId, ws, (change) => {
      if (change === 'region') fail(stream, 'Capture region changed', 'region-changed');
      else fail(stream, 'Screen capture ended', 'capture-ended');
    }) ?? undefined;
  }
  stream.startupTimer = setTimeout(() => fail(stream, 'WebRTC connection timed out'), 15_000);
  stream.authTimer = setInterval(() => {
    if (ws.readyState !== 1 || !authorized(ws)) stopWebrtc(id);
  }, 1000);
  void pumpAgent(stream).then(
    () => fail(stream, 'H.264 encoder exited'),
    () => fail(stream, 'Lost signaling from the H.264 encoder'),
  );
  return { webrtcId: id, available: true, codec: 'H264' };
}

function push(stream: WebRtcStream, data: WebRtcSignal): void {
  if (stream.ws.readyState === 1) sendFn(stream.ws, { type: 'webrtc-signal', webrtcId: stream.id, data });
}

function fail(stream: WebRtcStream, reason: string, code: Extract<WebRtcSignal, { kind: 'error' }>['code'] = 'failed'): void {
  if (streams.get(stream.id) !== stream) return;
  stopWebrtc(stream.id);
  push(stream, { kind: 'error', reason, code });
}

async function pumpAgent(stream: WebRtcStream): Promise<void> {
  const reader = (stream.proc.stdout as ReadableStream<Uint8Array>).getReader();
  const decoder = new TextDecoder();
  let buf = '';
  try {
    while (streams.has(stream.id)) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      let nl: number;
      while (streams.has(stream.id) && (nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        const msg = JSON.parse(line);
        if (msg.type === 'offer') push(stream, { kind: 'offer', sdp: msg.sdp });
        if (msg.type === 'ice') push(stream, { kind: 'ice', candidate: msg.candidate, sdpMLineIndex: msg.sdpMLineIndex });
        if (msg.type === 'error') fail(stream, String(msg.message));
        if (msg.type === 'status' && msg.state === 'connected') clearTimeout(stream.startupTimer);
      }
    }
  } finally {
    reader.releaseLock();
  }
}

function write(stream: WebRtcStream, msg: object): void {
  try {
    const stdin = stream.proc.stdin as { write(s: string): unknown; flush(): unknown };
    stdin.write(JSON.stringify(msg) + '\n');
    stdin.flush();
  } catch {
    fail(stream, 'Could not signal the H.264 encoder');
  }
}

function updateBitrate(stream: WebRtcStream, next: BitrateState): void {
  const changed = next.step !== stream.bitrate.step;
  stream.bitrate = next;
  if (changed) write(stream, { type: 'bitrate', kbps: bitrates[next.step] });
}

export function signalWebrtc(id: string, data: WebRtcClientSignal, ws: WebSocket): void {
  const stream = streams.get(id);
  if (stream?.ws !== ws || !data || !authorized(ws)) return;
  switch (data.kind) {
    case 'answer':
      if (typeof data.sdp === 'string' && data.sdp.length <= 65536) write(stream, { type: 'answer', sdp: data.sdp });
      break;
    case 'ice':
      if (typeof data.candidate === 'string' && data.candidate.length <= 2048 &&
          Number.isInteger(data.sdpMLineIndex) && data.sdpMLineIndex >= 0 && data.sdpMLineIndex < 2) {
        write(stream, { type: 'ice', candidate: data.candidate, sdpMLineIndex: data.sdpMLineIndex });
      }
      break;
    case 'playing':
      if (stream.streamId) pauseCapture(stream.streamId, ws, true);
      break;
    case 'keyframe':
      write(stream, { type: 'keyframe' });
      break;
    case 'zoom':
      if (typeof data.zoomed === 'boolean') updateBitrate(stream, planWebrtcZoom(stream.bitrate, data.zoomed));
      break;
    case 'stats': {
      const now = Date.now();
      if (now - stream.lastStatsAt < 1800 || ![data.fps, data.loss, data.jitterMs, data.rttMs ?? 0].every(Number.isFinite) ||
          data.fps < 0 || data.loss < 0 || data.loss > 1 || data.jitterMs < 0 || (data.rttMs ?? 0) < 0) return;
      stream.lastStatsAt = now;
      updateBitrate(stream, planWebrtcBitrate(stream.bitrate, data, stream.fps));
      break;
    }
  }
}

export function stopWebrtc(id: string, ws?: WebSocket): void {
  const stream = streams.get(id);
  if (!stream || (ws && stream.ws !== ws)) return;
  streams.delete(id);
  clearInterval(stream.authTimer);
  clearTimeout(stream.startupTimer);
  stream.unwatch?.();
  try { stream.proc.kill(); } catch { /* already gone */ }
  if (stream.streamId && stream.ws.readyState === 1 && authorized(stream.ws)) pauseCapture(stream.streamId, stream.ws, false);
}

export function stopWebrtcForSocket(ws: WebSocket): void {
  for (const stream of streams.values()) if (stream.ws === ws) stopWebrtc(stream.id);
}
