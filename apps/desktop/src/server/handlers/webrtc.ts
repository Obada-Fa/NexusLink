// Host-side WebRTC stream manager: one Python/GStreamer agent process per
// stream (see ../webrtc-agent.py). The agent does capture + H.264/Opus encode +
// webrtcbin; this module spawns it, relays signaling between the agent's stdio
// and the phone's control WebSocket, and tears streams down with their socket.
//
// MJPEG-over-WS remains the automatic fallback: webrtc.start reports
// available:false when GStreamer/PyGObject is missing and clients keep using
// screen.startCapture.

import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import type { WsMessage, WebRtcSignal } from '@nexuslink/rpc-types';
import { getSessionDisplay, getSessionAudioSource } from './app-sessions';

type SpawnOpts = Parameters<typeof Bun.spawn>[1];
type Proc = ReturnType<typeof Bun.spawn>;

const AGENT_PATH = join(dirname(fileURLToPath(import.meta.url)), '..', 'webrtc-agent.py');

type SendFn = (ws: WebSocket, msg: WsMessage) => void;
let sendFn: SendFn = () => {};

export function setSend(fn: SendFn): void {
  sendFn = fn;
}

interface WebRtcStream {
  webrtcId: string;
  proc: Proc;
  ws: WebSocket;
  sessionId: string;
}

const streams = new Map<string, WebRtcStream>();

let availabilityCache: { available: boolean; reason?: string } | null = null;

/** GStreamer WebRTC needs python3 + PyGObject + webrtcbin; probe once. */
export function webrtcAvailability(): { available: boolean; reason?: string } {
  if (availabilityCache) return availabilityCache;
  try {
    const probe = Bun.spawnSync(
      [
        'python3', '-c',
        "import gi; gi.require_version('Gst','1.0'); gi.require_version('GstWebRTC','1.0'); " +
        "from gi.repository import Gst; Gst.init(None); " +
        "import sys; sys.exit(0 if Gst.ElementFactory.find('webrtcbin') else 1)",
      ],
      { stderr: 'ignore', stdout: 'ignore' } as unknown as SpawnOpts,
    );
    availabilityCache =
      probe.exitCode === 0
        ? { available: true }
        : { available: false, reason: 'GStreamer webrtcbin not available on the host' };
  } catch {
    availabilityCache = { available: false, reason: 'python3 not available on the host' };
  }
  return availabilityCache;
}

export function startWebrtc(
  sessionId: string,
  fps: number,
  ws: WebSocket,
): { webrtcId?: string; available: boolean; reason?: string } {
  const avail = webrtcAvailability();
  if (!avail.available) return avail;

  const display = getSessionDisplay(sessionId);
  if (!display) return { available: false, reason: 'unknown app session' };

  const webrtcId = crypto.randomUUID();
  const audioSource = getSessionAudioSource(sessionId);
  const argv = [
    'python3', AGENT_PATH,
    '--display', display,
    '--fps', String(Math.max(10, Math.min(30, Math.round(fps || 24)))),
  ];
  if (audioSource) argv.push('--audio-source', audioSource);
  argv.push('--stun', process.env.NEXUSLINK_STUN || 'stun://stun.l.google.com:19302');

  const proc = Bun.spawn(argv, {
    stdin: 'pipe',
    stdout: 'pipe',
    stderr: 'ignore',
  } as unknown as SpawnOpts);

  const stream: WebRtcStream = { webrtcId, proc, ws, sessionId };
  streams.set(webrtcId, stream);
  void pumpAgent(stream).catch(() => {});
  proc.exited.then(() => streams.delete(webrtcId)).catch(() => {});

  return { webrtcId, available: true };
}

/** Relay agent stdout JSON lines to the phone as webrtc-signal pushes. */
async function pumpAgent(stream: WebRtcStream): Promise<void> {
  const reader = (stream.proc.stdout as unknown as ReadableStream<Uint8Array>).getReader();
  const decoder = new TextDecoder();
  let buf = '';
  try {
    while (streams.has(stream.webrtcId)) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      let nl: number;
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (!line) continue;
        let msg: Record<string, unknown>;
        try {
          msg = JSON.parse(line);
        } catch {
          continue;
        }
        const data = toSignal(msg);
        if (data && stream.ws.readyState === 1) {
          sendFn(stream.ws, { type: 'webrtc-signal', webrtcId: stream.webrtcId, data });
        }
      }
    }
  } finally {
    reader.releaseLock();
  }
}

function toSignal(msg: Record<string, unknown>): WebRtcSignal | null {
  if (msg.type === 'offer' && typeof msg.sdp === 'string') {
    return { kind: 'offer', sdp: msg.sdp };
  }
  if (msg.type === 'ice' && typeof msg.candidate === 'string') {
    return {
      kind: 'ice',
      candidate: msg.candidate,
      sdpMLineIndex: typeof msg.sdpMLineIndex === 'number' ? msg.sdpMLineIndex : 0,
    };
  }
  return null;
}

/** Client → agent: answer SDP and ICE candidates. */
export function signalWebrtc(webrtcId: string, data: WebRtcSignal): void {
  const stream = streams.get(webrtcId);
  if (!stream) return;
  const line =
    data.kind === 'ice'
      ? { type: 'ice', candidate: data.candidate, sdpMLineIndex: data.sdpMLineIndex }
      : { type: data.kind, sdp: data.sdp };
  try {
    const stdin = stream.proc.stdin as unknown as { write(s: string): unknown; flush?: () => void };
    stdin.write(JSON.stringify(line) + '\n');
    stdin.flush?.();
  } catch {
    // agent going down; exit handler cleans up
  }
}

export function stopWebrtc(webrtcId: string): void {
  const stream = streams.get(webrtcId);
  if (!stream) return;
  streams.delete(webrtcId);
  try {
    stream.proc.kill();
  } catch {
    // already gone
  }
}

export function stopWebrtcForSocket(ws: WebSocket): void {
  const toStop: string[] = [];
  streams.forEach((s, id) => {
    if (s.ws === ws) toStop.push(id);
  });
  toStop.forEach(stopWebrtc);
}
