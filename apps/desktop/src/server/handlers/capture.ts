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
  /** Bumps on soft-restart so the previous stdout pump exits. */
  gen: number;
  lastFrameBytes: number;
  quality: 'low' | 'medium' | 'high' | 'full';
  lastQosAt: number;
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

/** Pre-allocated MJPEG scrape buffer — append copies into one allocation, never concatenates. */
export class MjpegRing {
  private readonly buf: Buffer;
  private length = 0;

  constructor(capacity = 8_000_000) {
    this.buf = Buffer.allocUnsafe(capacity);
  }

  append(chunk: Uint8Array): void {
    if (chunk.length >= this.buf.length) {
      this.buf.set(chunk.subarray(chunk.length - this.buf.length));
      this.length = this.buf.length;
      return;
    }
    if (this.length + chunk.length > this.buf.length) {
      const keep = Math.min(this.length, 2);
      if (keep) this.buf.copyWithin(0, this.length - keep);
      this.length = keep;
    }
    this.buf.set(chunk, this.length);
    this.length += chunk.length;
  }

  /** Copies complete JPEGs out so later appends cannot clobber in-flight frames. */
  takeFrames(): Buffer[] {
    const { frames, rest } = extractFrames(this.buf.subarray(0, this.length));
    const copies = frames.map((f) => Buffer.from(f));
    if (rest.length) rest.copy(this.buf, 0);
    this.length = rest.length;
    return copies;
  }
}

/** True when the WS outbound buffer already holds more than one frame. */
export function socketBackedUp(ws: WebSocket, lastFrameBytes: number): boolean {
  const buffered = (ws as WebSocket & { bufferedAmount?: number }).bufferedAmount ?? 0;
  return buffered > Math.max(lastFrameBytes, 32_768);
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
      '-fflags', 'nobuffer',
      '-flags', 'low_delay',
      '-probesize', '32',
      '-analyzeduration', '0',
      '-f', 'x11grab',
      '-framerate', String(ffArgs.fps),
      '-video_size', `${grab.width}x${grab.height}`,
      '-thread_queue_size', '1',
      '-i', `${display}+${grab.x},${grab.y}`,
      '-vf', `scale=${outW}:-2`,
      '-q:v', String(ffArgs.q),
      '-flush_packets', '1',
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
  const clampedFps = Math.max(1, Math.min(30, Math.round(fps || 24)));
  const qualityName = quality;
  const { scaleW, q } = qualitySettings(qualityName);
  // Virtual (phone-shaped) sessions already match the source — don't scale/upscale.
  const ffArgs = { fps: clampedFps, scaleW: display ? 0 : scaleW, q };

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
    gen: 1,
    lastFrameBytes: 0,
    quality: qualityName,
    lastQosAt: 0,
  };
  sessions.set(id, session);

  void pumpFrames(session, session.gen).catch(() => {});

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
      restartGrabber(session, next);
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

const QUALITY_LADDER = ['low', 'medium', 'high', 'full'] as const;

function restartGrabber(session: CaptureSession, grab: Region): void {
  const oldProc = session.proc;
  session.region = grab;
  session.proc = spawnGrabber(grab, session.ffArgs, session.display);
  const gen = ++session.gen;
  const killOld = () => {
    try { oldProc.kill(); } catch { /* already gone */ }
  };
  const failSafe = setTimeout(killOld, 1500);
  void pumpFrames(session, gen, () => {
    clearTimeout(failSafe);
    killOld();
  }).catch(() => {
    clearTimeout(failSafe);
    killOld();
  });
}

/** Client FPS / frame-age feedback. Step JPEG quality (and fps) instead of queueing. */
export function reportStreamStats(streamId: string, decodeFps: number, frameAgeMs: number): void {
  const session = sessions.get(streamId);
  if (!session) return;
  const now = Date.now();
  if (now - session.lastQosAt < 2000) return;
  session.lastQosAt = now;

  const idx = QUALITY_LADDER.indexOf(session.quality);
  const down = frameAgeMs > 80 || decodeFps < Math.max(6, session.ffArgs.fps * 0.45);
  const up = frameAgeMs < 40 && decodeFps >= session.ffArgs.fps * 0.75;
  let nextIdx = idx;
  if (down && idx > 0) nextIdx = idx - 1;
  else if (up && idx < QUALITY_LADDER.length - 1) nextIdx = idx + 1;
  else if (!down && !up) return;
  else if (down && session.ffArgs.fps > 12) {
    session.ffArgs = { ...session.ffArgs, fps: Math.max(10, session.ffArgs.fps - 4) };
    const grab = session.region;
    if (grab) restartGrabber(session, grab);
    return;
  } else {
    return;
  }

  session.quality = QUALITY_LADDER[nextIdx]!;
  const { scaleW, q } = qualitySettings(session.quality);
  session.ffArgs = {
    fps: down
      ? Math.max(10, session.ffArgs.fps - 2)
      : Math.min(24, session.ffArgs.fps + 2),
    scaleW: session.ffArgs.scaleW === 0 ? 0 : scaleW,
    q,
  };
  const grab = session.region;
  if (grab) restartGrabber(session, grab);
}

async function pumpFrames(
  session: CaptureSession,
  gen: number,
  onFirstFrame?: () => void,
): Promise<void> {
  const proc = session.proc;
  const ring = new MjpegRing();
  let first = true;

  const stream = proc.stdout as unknown as ReadableStream<Uint8Array>;
  const reader = stream.getReader();

  try {
    while (sessions.has(session.id) && session.gen === gen) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value) continue;
      ring.append(value);

      const frames = ring.takeFrames();
      for (const frame of frames) {
        if (session.gen !== gen) return;
        if (first) {
          first = false;
          onFirstFrame?.();
        }
        emitFrame(session, frame);
      }
    }
  } finally {
    reader.releaseLock();
  }
}

function emitFrame(session: CaptureSession, frame: Buffer): void {
  const { ws, key } = session;
  if (ws.readyState !== 1) return;
  if (socketBackedUp(ws, session.lastFrameBytes)) return;
  const header = Buffer.allocUnsafe(FRAME_HEADER_BYTES);
  header.writeUInt32LE(FRAME_MAGIC, 0);
  header.writeUInt32LE(key >>> 0, 4);
  header.writeDoubleLE(Date.now(), 8);
  try {
    const payload = Buffer.concat([header, frame]);
    ws.send(payload);
    session.lastFrameBytes = payload.length;
  } catch {
    // socket going down; close handler tears the session down
  }
}

export function stopCapture(streamId: string): void {
  const session = sessions.get(streamId);
  if (!session) return;
  sessions.delete(streamId);
  session.gen++;
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
