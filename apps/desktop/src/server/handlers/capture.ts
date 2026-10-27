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
  /** Consecutive congested reportStats samples before a quality step. */
  qosBadStreak: number;
  /** Monitor a full-desktop capture follows (undefined = primary). */
  monitorName?: string;
  /** Frames skipped because the socket was backed up (diagnostics). */
  droppedFrames: number;
  /** Virtual sessions already match the phone: never rescale them. */
  nativeScale: boolean;
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

/**
 * Outbound bytes queued on a socket. Bun's ServerWebSocket exposes
 * getBufferedAmount(); the `bufferedAmount` property only exists on browser-style
 * sockets (and test doubles), and is undefined on the server.
 */
export function socketBufferedAmount(ws: WebSocket): number {
  const sock = ws as WebSocket & { getBufferedAmount?: () => number; bufferedAmount?: number };
  try {
    if (typeof sock.getBufferedAmount === 'function') return Number(sock.getBufferedAmount()) || 0;
  } catch {
    return 0;
  }
  return typeof sock.bufferedAmount === 'number' ? sock.bufferedAmount : 0;
}

/**
 * Hard ceiling for queued video on the control socket. index.ts closes the
 * socket ("Client too slow") once 4 MB is buffered when it sends JSON, so video
 * must never push the queue anywhere near that.
 */
export const CAPTURE_MAX_BUFFERED_BYTES = 1_500_000;

/**
 * True when the next frame should be dropped: the socket already holds more
 * than one frame (keeps latency at ~1 frame), or sending would cross the hard
 * ceiling that protects the control socket.
 */
export function socketBackedUp(ws: WebSocket, lastFrameBytes: number, nextFrameBytes = 0): boolean {
  const buffered = socketBufferedAmount(ws);
  if (buffered > Math.min(Math.max(lastFrameBytes, 32_768), CAPTURE_MAX_BUFFERED_BYTES)) return true;
  return buffered > 0 && buffered + nextFrameBytes > CAPTURE_MAX_BUFFERED_BYTES * 2;
}

/** Called for every outgoing frame; returning false stops the capture. */
export type CaptureAuthorizer = (ws: WebSocket) => boolean;
let captureAuthorizer: CaptureAuthorizer = () => true;

/**
 * Install the per-frame credential check (token expiry, device revocation).
 * Binary frames bypass index.ts send(), so without this a stream would outlive
 * its 1 h access token. Must be O(1): it runs up to 30x/s per stream.
 */
export function setCaptureAuthorizer(fn: CaptureAuthorizer | null): void {
  captureAuthorizer = fn ?? (() => true);
}

export interface MonitorInfo {
  /** RandR output/monitor name, e.g. "HDMI-A-0". */
  name: string;
  x: number;
  y: number;
  width: number;
  height: number;
  primary: boolean;
}

interface ScreenGeometry {
  at: number;
  screen: { width: number; height: number };
  monitors: MonitorInfo[];
}

/** Monitor layouts change (hotplug, resolution, rotation); never trust them for long. */
export const GEOMETRY_TTL_MS = 10_000;
let geometry: ScreenGeometry | null = null;

type GeometryProbe = (args: string[]) => string;

const defaultProbe: GeometryProbe = (args) => {
  const out = Bun.spawnSync(args, {
    env: { ...process.env, DISPLAY },
    stdout: 'pipe',
    stderr: 'ignore',
    timeout: 2000,
  } as unknown as Parameters<typeof Bun.spawnSync>[1]);
  return out.exitCode === 0 ? (out.stdout?.toString() ?? '') : '';
};
let geometryProbe: GeometryProbe = defaultProbe;

/** Test hook: replace the xrandr/xdotool runner (null restores the real one). */
export function setGeometryProbeForTests(probe: GeometryProbe | null): void {
  geometryProbe = probe ?? defaultProbe;
  geometry = null;
}

/**
 * Parse `xrandr --current` (no output re-probe, ~1 ms). Every output line with
 * a geometry is an active monitor, connected or not; "connected (normal ...)"
 * lines without one are inactive and skipped.
 */
export function parseXrandrCurrent(text: string): {
  screen: { width: number; height: number } | null;
  monitors: MonitorInfo[];
} {
  const sm = text.match(/current\s+(\d+)\s+x\s+(\d+)/);
  const screen = sm ? { width: Number(sm[1]), height: Number(sm[2]) } : null;
  const monitors: MonitorInfo[] = [];
  const re = /^(\S+)\s+(?:connected|disconnected)(\s+primary)?\s+(\d+)x(\d+)\+(\d+)\+(\d+)/;
  for (const line of text.split('\n')) {
    const m = re.exec(line);
    if (!m) continue;
    const mon = { name: m[1]!, primary: !!m[2], width: Number(m[3]), height: Number(m[4]), x: Number(m[5]), y: Number(m[6]) };
    if (mon.width > 0 && mon.height > 0) monitors.push(mon);
  }
  return { screen, monitors };
}

/** Parse `xrandr --listactivemonitors`: " 0: +*HDMI-A-0 1920/508x1080/286+0+0  HDMI-A-0". */
export function parseListActiveMonitors(text: string): MonitorInfo[] {
  const out: MonitorInfo[] = [];
  const re = /^\s*\d+:\s+\+?(\*?)(\S+)\s+(\d+)\/\d+x(\d+)\/\d+\+(-?\d+)\+(-?\d+)/;
  for (const line of text.split('\n')) {
    const m = re.exec(line);
    if (!m) continue;
    out.push({ name: m[2]!, primary: m[1] === '*', width: Number(m[3]), height: Number(m[4]), x: Number(m[5]), y: Number(m[6]) });
  }
  return out;
}

function loadGeometry(force = false): ScreenGeometry {
  if (!force && geometry && Date.now() - geometry.at < GEOMETRY_TTL_MS) return geometry;
  let screen: { width: number; height: number } | null = null;
  let monitors: MonitorInfo[] = [];
  try {
    const parsed = parseXrandrCurrent(geometryProbe(['xrandr', '--current']));
    screen = parsed.screen;
    monitors = parsed.monitors;
  } catch { /* fall through */ }
  if (!monitors.length) {
    try { monitors = parseListActiveMonitors(geometryProbe(['xrandr', '--listactivemonitors'])); } catch { /* fall through */ }
  }
  if (!screen) {
    try {
      const [w, h] = geometryProbe(['xdotool', 'getdisplaygeometry']).trim().split(/\s+/).map((n) => parseInt(n, 10));
      if (w && h) screen = { width: w, height: h };
    } catch { /* fall through */ }
  }
  if (!screen && monitors.length) {
    screen = {
      width: Math.max(...monitors.map((m) => m.x + m.width)),
      height: Math.max(...monitors.map((m) => m.y + m.height)),
    };
  }
  // A transient probe failure (X busy, timeout) keeps the last good layout
  // instead of snapping to a made-up 1080p screen.
  if (!screen && geometry) return geometry;
  screen ??= { width: 1920, height: 1080 };
  if (!monitors.length) monitors = [{ name: 'screen', x: 0, y: 0, width: screen.width, height: screen.height, primary: true }];
  if (!monitors.some((m) => m.primary)) monitors[0] = { ...monitors[0]!, primary: true };
  geometry = { at: Date.now(), screen, monitors };
  return geometry;
}

/**
 * Full X11 virtual-screen size (spans ALL monitors — e.g. 1920x2280 for two
 * stacked 1080p/1200p displays). This is the coordinate space xdotool injects
 * into and the bound x11grab must never overflow. Cached for GEOMETRY_TTL_MS.
 */
export function getScreenMetadata(): { width: number; height: number } {
  return { ...loadGeometry().screen };
}

/**
 * Active monitors in virtual-screen coordinates, primary flagged. `fresh`
 * bypasses the TTL cache (startCapture always does).
 */
export function listMonitors(opts: { fresh?: boolean } = {}): MonitorInfo[] {
  return loadGeometry(opts.fresh === true).monitors.map((m) => ({ ...m }));
}

/**
 * The primary monitor's rect within the virtual screen. Full-desktop mirror
 * captures this (not the whole virtual screen) so multi-monitor hosts show
 * the screen the user actually works on.
 */
export function getPrimaryMonitor(): { x: number; y: number; width: number; height: number } {
  const mons = loadGeometry().monitors;
  const m = mons.find((x) => x.primary) ?? mons[0]!;
  return { x: m.x, y: m.y, width: m.width, height: m.height };
}

/** Resolve a monitor by RandR name (exact, then case-insensitive). */
function findMonitor(name: string, mons: MonitorInfo[]): MonitorInfo | undefined {
  return mons.find((m) => m.name === name) ?? mons.find((m) => m.name.toLowerCase() === name.toLowerCase());
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
      '-draw_mouse', '0',
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

export interface CaptureOptions {
  /**
   * RandR monitor name (see listMonitors()) for a full-desktop capture.
   * Ignored when a region/window or virtual display is given. Unknown names throw.
   */
  monitor?: string;
}

/** Full-desktop captures re-check the monitor layout this often (hotplug / mode change). */
const MONITOR_WATCH_MS = 5000;

export function startCapture(
  quality: 'low' | 'medium' | 'high' | 'full',
  fps: number,
  ws: WebSocket,
  region?: Region,
  resolveRegion?: () => Region | null,
  display?: string,
  options: CaptureOptions = {},
): { streamId: string; streamKey: number; region: Region; monitor?: string } {
  if (process.platform === 'win32') {
    throw new Error('Screen capture is not available on Windows yet. Use Agents from the dock.');
  }
  const id = crypto.randomUUID();
  const key = nextStreamKey++;
  const clampedFps = Math.max(1, Math.min(30, Math.round(fps || 24)));
  const qualityName = quality;
  const { scaleW, q } = qualitySettings(qualityName);
  // Virtual (phone-shaped) sessions already match the source — don't scale/upscale.
  const ffArgs = { fps: clampedFps, scaleW: display ? 0 : scaleW, q };

  // Virtual app sessions grab their whole (phone-shaped) screen exactly as
  // given; the physical path clamps against the real desktop geometry, which
  // is re-read on every start so resolution/monitor changes are picked up.
  let grab: Region;
  let monitorName: string | undefined;
  const validRegion = region && region.width > 16 && region.height > 16 ? region : undefined;
  const fullDesktop = !display && !validRegion;
  if (display && region) {
    grab = {
      x: region.x,
      y: region.y,
      width: region.width & ~1,
      height: region.height & ~1,
    };
  } else {
    const mons = loadGeometry(true).monitors;
    let want: Region;
    if (validRegion) {
      want = validRegion;
    } else if (options.monitor && fullDesktop) {
      const mon = findMonitor(options.monitor, mons);
      if (!mon) {
        throw new Error(`Unknown monitor "${options.monitor}". Available: ${mons.map((m) => m.name).join(', ')}`);
      }
      monitorName = mon.name;
      want = mon;
    } else {
      const primary = mons.find((m) => m.primary) ?? mons[0]!;
      monitorName = primary.name;
      want = primary;
    }
    grab = clampRegion(want);
  }

  const proc = spawnGrabber(grab, ffArgs, display);
  const session: CaptureSession = {
    id, key, proc, ws, region: grab, ffArgs, resolveRegion,
    display: display ?? DISPLAY,
    gen: 1,
    lastFrameBytes: 0,
    quality: qualityName,
    lastQosAt: 0,
    qosBadStreak: 0,
    monitorName: fullDesktop && options.monitor ? monitorName : undefined,
    droppedFrames: 0,
    nativeScale: !!display,
  };
  sessions.set(id, session);

  void pumpFrames(session, session.gen).catch(() => {});

  const regrab = (current: Region | null) => {
    if (!sessions.has(id) || !current) return;
    const next = clampRegion(current);
    if (next.width < 32 || next.height < 32) return;
    if (!session.region || !regionsDiffer(session.region, next)) return;
    restartGrabber(session, next);
    if (sendFn && ws.readyState === 1) {
      sendFn(ws, { type: 'stream-region', streamId: id, region: next });
    }
  };

  // Window-tracked captures follow the window: if the WM (or the user at the
  // desk) moves/resizes it, re-grab the new rect and tell the client so touch
  // mapping stays aligned.
  if (resolveRegion) {
    session.watchdog = setInterval(() => regrab(resolveRegion()), 2000);
  } else if (fullDesktop) {
    // Full-desktop captures follow their monitor: a resolution change or
    // unplug would otherwise leave x11grab dead (out-of-bounds grab) and touch
    // mapping wrong. Falls back to the primary if the chosen monitor is gone.
    session.watchdog = setInterval(() => {
      if (!sessions.has(id)) return;
      const mons = loadGeometry(true).monitors;
      const mon = (session.monitorName && findMonitor(session.monitorName, mons)) || mons.find((m) => m.primary) || mons[0];
      regrab(mon ?? null);
    }, MONITOR_WATCH_MS);
  }

  // Always return the grabbed region — the client maps touch coordinates
  // through it (critical on multi-monitor hosts where the primary monitor
  // does not start at 0,0).
  return { streamId: id, streamKey: key, region: grab, ...(fullDesktop && monitorName ? { monitor: monitorName } : {}) };
}

const QUALITY_LADDER = ['low', 'medium', 'high', 'full'] as const;

export type CaptureQuality = (typeof QUALITY_LADDER)[number];

/**
 * Step JPEG quality/scale only. Capture fps stays locked so the phone keeps
 * seeing motion instead of a 10 fps slideshow (game-stream QoS, not file-transfer).
 * `decodeAgeMs` is client-local receive→decode time — never a host-vs-phone wall clock.
 */
export function planStreamQos(opts: {
  quality: CaptureQuality;
  fps: number;
  displayedFps: number;
  decodeAgeMs: number;
  badStreak: number;
}): { quality: CaptureQuality; fps: number; restart: boolean; badStreak: number } {
  const { quality, fps, displayedFps, decodeAgeMs } = opts;
  const idx = QUALITY_LADDER.indexOf(quality);
  const down = displayedFps < Math.max(6, fps * 0.45) || decodeAgeMs > 120;
  const up = displayedFps >= fps * 0.75 && decodeAgeMs < 50;

  if (down) {
    const streak = opts.badStreak + 1;
    if (streak < 2 || idx <= 0) {
      return { quality, fps, restart: false, badStreak: streak };
    }
    return {
      quality: QUALITY_LADDER[idx - 1]!,
      fps,
      restart: true,
      badStreak: 0,
    };
  }

  if (up && idx < QUALITY_LADDER.length - 1) {
    return {
      quality: QUALITY_LADDER[idx + 1]!,
      fps,
      restart: true,
      badStreak: 0,
    };
  }

  return { quality, fps, restart: false, badStreak: 0 };
}

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

/** Client displayed-FPS / decode-age feedback. Step JPEG quality, never capture fps. */
export function reportStreamStats(streamId: string, decodeFps: number, frameAgeMs: number): void {
  const session = sessions.get(streamId);
  if (!session) return;
  const now = Date.now();
  if (now - session.lastQosAt < 2000) return;
  session.lastQosAt = now;

  const planned = planStreamQos({
    quality: session.quality,
    fps: session.ffArgs.fps,
    displayedFps: decodeFps,
    decodeAgeMs: frameAgeMs,
    badStreak: session.qosBadStreak,
  });
  session.qosBadStreak = planned.badStreak;
  if (!planned.restart) return;
  applyQuality(session, planned.quality);
}

function applyQuality(session: CaptureSession, quality: CaptureQuality): void {
  session.quality = quality;
  const { scaleW, q } = qualitySettings(quality);
  session.ffArgs = {
    fps: session.ffArgs.fps,
    scaleW: session.nativeScale ? 0 : scaleW,
    q,
  };
  const grab = session.region;
  if (grab) restartGrabber(session, grab);
}

/**
 * Client asks for a quality step now (e.g. the phone zoomed in and needs
 * native-resolution frames). QoS may still step it back down if congested.
 */
export function setStreamQuality(streamId: string, quality: CaptureQuality): void {
  const session = sessions.get(streamId);
  if (!session || !QUALITY_LADDER.includes(quality) || session.quality === quality) return;
  session.qosBadStreak = 0;
  // Hold off the next QoS sample so it judges the new quality, not the old one.
  session.lastQosAt = Date.now();
  applyQuality(session, quality);
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
  // Binary frames skip index.ts send(), so re-check the credential per frame:
  // an expired token or revoked device stops the stream instead of leaking it.
  let allowed = false;
  try { allowed = captureAuthorizer(ws) === true; } catch { allowed = false; }
  if (!allowed) {
    stopCapture(session.id);
    return;
  }
  const bytes = FRAME_HEADER_BYTES + frame.length;
  if (socketBackedUp(ws, session.lastFrameBytes, bytes)) {
    session.droppedFrames++;
    return;
  }
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

/** Live diagnostics for one stream (null once stopped). */
export function getCaptureInfo(streamId: string): { region?: Region; monitor?: string; droppedFrames: number; quality: CaptureQuality } | null {
  const s = sessions.get(streamId);
  return s ? { region: s.region, monitor: s.monitorName, droppedFrames: s.droppedFrames, quality: s.quality } : null;
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
