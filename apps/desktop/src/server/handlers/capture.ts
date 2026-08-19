// Host screen capture via ffmpeg x11grab → MJPEG, streamed to the mobile client as
// base64 `stream-frame` messages. No Rust / WebRTC required for the LAN path; this
// is the pragmatic pixel pipeline that makes Mirror mode actually show the screen.

import type { WsMessage } from '@nexuslink/rpc-types';

const DISPLAY = process.env.DISPLAY || ':0';
const SOI = Buffer.from([0xff, 0xd8]); // JPEG start-of-image marker

// @types/bun here predates the 'ignore' stdio option (valid at runtime).
type SpawnOpts = Parameters<typeof Bun.spawn>[1];

type SendFn = (ws: WebSocket, msg: WsMessage) => void;

let sendFn: SendFn | null = null;

export function setSend(fn: SendFn): void {
  sendFn = fn;
}

interface CaptureSession {
  id: string;
  /** 32-bit key stamped into every binary frame header for client-side matching. */
  key: number;
  proc: ReturnType<typeof Bun.spawn>;
  ws: WebSocket;
  /** Region currently being grabbed (undefined = pre-region legacy path). */
  region?: Region;
  ffArgs: { fps: number; scaleW: number; q: number };
  /** Re-resolves the tracked window's rect; set for per-window captures. */
  resolveRegion?: () => Region | null;
  watchdog?: ReturnType<typeof setInterval>;
  /** X display being grabbed (virtual app sessions use their own). */
  display: string;
}

/** Binary frame header: u32 magic 'NLF1' | u32 streamKey | f64 timestampMs (LE). */
export const FRAME_MAGIC = 0x4e4c4631;
export const FRAME_HEADER_BYTES = 16;

let nextStreamKey = 1;

const sessions = new Map<string, CaptureSession>();

/**
 * Split a rolling buffer of concatenated MJPEG data into whole JPEG frames on
 * start-of-image (0xFFD8) boundaries. Returns the frames found and the unconsumed
 * remainder (which begins at the last SOI seen). Framing on SOI is robust against
 * 0xFFD9 bytes that legitimately appear inside entropy-coded scan data.
 */
export function extractFrames(buf: Buffer): { frames: Buffer[]; rest: Buffer } {
  const frames: Buffer[] = [];
  let work = buf;

  const first = work.indexOf(SOI);
  if (first < 0) return { frames, rest: Buffer.alloc(0) };
  if (first > 0) work = work.subarray(first);

  let next = work.length > 2 ? work.indexOf(SOI, 2) : -1;
  while (next !== -1) {
    frames.push(work.subarray(0, next));
    work = work.subarray(next);
    next = work.length > 2 ? work.indexOf(SOI, 2) : -1;
  }

  return { frames, rest: work };
}

let cachedGeometry: { width: number; height: number } | null = null;
let cachedPrimary: { x: number; y: number; width: number; height: number } | null = null;

/**
 * Full X11 virtual-screen size (spans ALL monitors — e.g. 1920x2280 for two
 * stacked 1080p/1200p displays). This is the coordinate space xdotool injects
 * into and the bound x11grab must never overflow.
 */
export function getScreenMetadata(): { width: number; height: number } {
  if (cachedGeometry) return cachedGeometry;
  try {
    const out = Bun.spawnSync(['xrandr', '--query'], {
      env: { ...process.env, DISPLAY },
    });
    // "Screen 0: minimum 320 x 200, current 1920 x 2280, maximum ..."
    const m = out.stdout.toString().match(/current\s+(\d+)\s+x\s+(\d+)/);
    if (m) {
      cachedGeometry = { width: parseInt(m[1]!, 10), height: parseInt(m[2]!, 10) };
      return cachedGeometry;
    }
  } catch {
    // fall through
  }
  try {
    const out = Bun.spawnSync(['xdotool', 'getdisplaygeometry'], {
      env: { ...process.env, DISPLAY },
    });
    const [w, h] = out.stdout.toString().trim().split(/\s+/).map((n) => parseInt(n, 10));
    if (w && h) {
      cachedGeometry = { width: w, height: h };
      return cachedGeometry;
    }
  } catch {
    // fall through to default
  }
  cachedGeometry = { width: 1920, height: 1080 };
  return cachedGeometry;
}

/**
 * The primary monitor's rect within the virtual screen. Full-desktop mirror
 * captures this (not the whole virtual screen) so multi-monitor hosts show
 * the screen the user actually works on.
 */
export function getPrimaryMonitor(): { x: number; y: number; width: number; height: number } {
  if (cachedPrimary) return cachedPrimary;
  try {
    const out = Bun.spawnSync(['xrandr', '--query'], {
      env: { ...process.env, DISPLAY },
    });
    const lines = out.stdout.toString().split('\n');
    // "DisplayPort-0 connected primary 1920x1080+0+1200 (..."
    const geoRe = /(\d+)x(\d+)\+(\d+)\+(\d+)/;
    const primary = lines.find((l) => l.includes(' connected primary'));
    const anyConnected = lines.find((l) => l.includes(' connected'));
    const m = (primary ?? anyConnected)?.match(geoRe);
    if (m) {
      cachedPrimary = {
        width: parseInt(m[1]!, 10),
        height: parseInt(m[2]!, 10),
        x: parseInt(m[3]!, 10),
        y: parseInt(m[4]!, 10),
      };
      return cachedPrimary;
    }
  } catch {
    // fall through
  }
  const screen = getScreenMetadata();
  cachedPrimary = { x: 0, y: 0, width: screen.width, height: screen.height };
  return cachedPrimary;
}

function qualitySettings(quality: 'low' | 'medium' | 'high' | 'full'): { scaleW: number; q: number } {
  switch (quality) {
    case 'low':
      return { scaleW: 640, q: 8 };
    case 'high':
      return { scaleW: 1280, q: 3 };
    case 'full':
      return { scaleW: 0, q: 2 };
    default:
      return { scaleW: 960, q: 5 };
  }
}

export interface Region {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** Clamp a wanted rect into the virtual screen and even-align for x11grab. */
function clampRegion(want: Region): Region {
  const screen = getScreenMetadata();
  const x = Math.max(0, Math.min(screen.width - 32, Math.round(want.x)));
  const y = Math.max(0, Math.min(screen.height - 32, Math.round(want.y)));
  const width = Math.min(screen.width - x, Math.round(want.width)) & ~1;
  const height = Math.min(screen.height - y, Math.round(want.height)) & ~1;
  return { x, y, width, height };
}

function spawnGrabber(
  grab: Region,
  ffArgs: { fps: number; scaleW: number; q: number },
  display: string = DISPLAY,
) {
  // Portrait regions are narrow — don't upscale past the source width. scaleW: 0 means native resolution.
  const outW = ffArgs.scaleW > 0 ? (Math.min(ffArgs.scaleW, grab.width) & ~1) : (grab.width & ~1);
  return Bun.spawn(
    [
      'ffmpeg',
      '-loglevel', 'quiet',
      '-f', 'x11grab',
      '-framerate', String(ffArgs.fps),
      '-video_size', `${grab.width}x${grab.height}`,
      '-i', `${display}+${grab.x},${grab.y}`,
      '-vf', `scale=${outW}:-2`,
      '-q:v', String(ffArgs.q),
      '-f', 'image2pipe',
      '-vcodec', 'mjpeg',
      '-',
    ],
    {
      stdout: 'pipe',
      stderr: 'ignore',
      env: { ...process.env, DISPLAY: display },
    } as unknown as SpawnOpts,
  );
}

function regionsDiffer(a: Region, b: Region): boolean {
  return (
    Math.abs(a.x - b.x) > 4 ||
    Math.abs(a.y - b.y) > 4 ||
    Math.abs(a.width - b.width) > 4 ||
    Math.abs(a.height - b.height) > 4
  );
}

export function startCapture(
  quality: 'low' | 'medium' | 'high' | 'full',
  fps: number,
  ws: WebSocket,
  region?: Region,
  resolveRegion?: () => Region | null,
  display?: string,
): { streamId: string; streamKey: number; region: Region } {
  const id = crypto.randomUUID();
  const key = nextStreamKey++;
  const { scaleW, q } = qualitySettings(quality);
  const clampedFps = Math.max(1, Math.min(30, Math.round(fps || 24)));
  const ffArgs = { fps: clampedFps, scaleW, q };

  // Virtual app sessions grab their whole (phone-shaped) screen exactly as
  // given; the physical path clamps against the real desktop geometry.
  let grab: Region;
  if (display && region) {
    grab = {
      x: region.x,
      y: region.y,
      width: region.width & ~1,
      height: region.height & ~1,
    };
  } else {
    const want =
      region && region.width > 16 && region.height > 16 ? region : getPrimaryMonitor();
    grab = clampRegion(want);
  }

  if (process.platform === 'win32') {
    throw new Error('Screen capture is not available on Windows yet. Use Agents from the dock.');
  }
  const proc = spawnGrabber(grab, ffArgs, display);
  const session: CaptureSession = {
    id, key, proc, ws, region: grab, ffArgs, resolveRegion,
    display: display ?? DISPLAY,
  };
  sessions.set(id, session);

  void pumpFrames(session).catch(() => {});

  // Window-tracked captures follow the window: if the WM (or the user at the
  // desk) moves/resizes it, re-grab the new rect and tell the client so touch
  // mapping stays aligned.
  if (resolveRegion) {
    session.watchdog = setInterval(() => {
      if (!sessions.has(id)) return;
      const current = resolveRegion();
      if (!current) return;
      const next = clampRegion(current);
      if (next.width < 32 || next.height < 32) return;
      if (!session.region || !regionsDiffer(session.region, next)) return;
      try {
        session.proc.kill();
      } catch {
        // already gone
      }
      session.region = next;
      session.proc = spawnGrabber(next, ffArgs, session.display);
      void pumpFrames(session).catch(() => {});
      if (sendFn && ws.readyState === 1) {
        sendFn(ws, { type: 'stream-region', streamId: id, region: next });
      }
    }, 2000);
  }

  // Always return the grabbed region — the client maps touch coordinates
  // through it (critical on multi-monitor hosts where the primary monitor
  // does not start at 0,0).
  return { streamId: id, streamKey: key, region: grab };
}

async function pumpFrames(session: CaptureSession): Promise<void> {
  const { proc, ws, id } = session;
  let buf: Buffer = Buffer.alloc(0);

  const stream = proc.stdout as unknown as ReadableStream<Uint8Array>;
  const reader = stream.getReader();

  // MJPEG from image2pipe is a concatenation of JPEGs; we frame on SOI boundaries
  // (robust against 0xFFD9 bytes appearing inside entropy-coded scan data).
  try {
    while (sessions.has(id)) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value) continue;
      buf = Buffer.concat([buf, Buffer.from(value)]);

      const { frames, rest } = extractFrames(buf);
      for (const frame of frames) emitFrame(session, frame);
      buf = rest;

      // Safety valve against unbounded growth if a boundary is never found.
      if (buf.length > 8_000_000) buf = buf.subarray(buf.length - 2);
    }
  } finally {
    reader.releaseLock();
  }
}

function emitFrame(session: CaptureSession, frame: Buffer): void {
  const { ws, key } = session;
  if (ws.readyState !== 1) return;
  // Binary WS frame: fixed header + raw JPEG. No base64 (-25% bytes), no JSON
  // parse on the hot path — this is what makes 24-30fps feel smooth.
  const header = Buffer.allocUnsafe(FRAME_HEADER_BYTES);
  header.writeUInt32LE(FRAME_MAGIC, 0);
  header.writeUInt32LE(key >>> 0, 4);
  header.writeDoubleLE(Date.now(), 8);
  try {
    ws.send(Buffer.concat([header, frame]));
  } catch {
    // socket going down; close handler tears the session down
  }
}

export function stopCapture(streamId: string): void {
  const session = sessions.get(streamId);
  if (!session) return;
  sessions.delete(streamId);
  if (session.watchdog) clearInterval(session.watchdog);
  try {
    session.proc.kill();
  } catch {
    // already gone
  }
}

/** Tear down any capture sessions bound to a disconnected socket. */
export function stopCapturesForSocket(ws: WebSocket): void {
  const toStop: string[] = [];
  sessions.forEach((session, id) => {
    if (session.ws === ws) toStop.push(id);
  });
  toStop.forEach(stopCapture);
}
