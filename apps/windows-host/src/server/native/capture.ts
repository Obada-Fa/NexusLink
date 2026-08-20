import jpeg from 'jpeg-js';
import { ptr } from 'bun:ffi';
import type { CaptureRegion, ScreenMetadata } from '@nexuslink/rpc-types';
import type { WsMessage } from '@nexuslink/rpc-types';
import {
  g32, u32, isNullPtr, windowRect, idToHwnd,
  SM_CXSCREEN, SM_CYSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
  SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SRCCOPY, HALFTONE,
  DxgiDuplicator,
  type DesktopFrame,
} from './win32';

export const FRAME_MAGIC = 0x4e4c4631;
export const FRAME_HEADER_BYTES = 16;

type SendFn = (ws: WebSocket, msg: WsMessage | ArrayBuffer | Uint8Array) => void;

let sendFn: SendFn | null = null;
let nextStreamKey = 1;

export function setCaptureSend(fn: SendFn): void {
  sendFn = fn;
}

export function getScreenMetadata(): ScreenMetadata & { x: number; y: number } {
  const x = u32.GetSystemMetrics(SM_XVIRTUALSCREEN);
  const y = u32.GetSystemMetrics(SM_YVIRTUALSCREEN);
  const width = u32.GetSystemMetrics(SM_CXVIRTUALSCREEN) || u32.GetSystemMetrics(SM_CXSCREEN);
  const height = u32.GetSystemMetrics(SM_CYVIRTUALSCREEN) || u32.GetSystemMetrics(SM_CYSCREEN);
  return {
    x,
    y,
    width: width > 0 ? width : 1920,
    height: height > 0 ? height : 1080,
  };
}

export function getPrimaryMonitor(): CaptureRegion {
  return {
    x: 0,
    y: 0,
    width: u32.GetSystemMetrics(SM_CXSCREEN) || 1920,
    height: u32.GetSystemMetrics(SM_CYSCREEN) || 1080,
  };
}

interface CaptureSession {
  id: string;
  key: number;
  ws: WebSocket;
  region: CaptureRegion;
  hwnd?: string;
  running: boolean;
  fps: number;
  q: number;
  maxW: number;
  lastFrameBytes: number;
  quality: string;
  lastQosAt: number;
  lastEmittedRegion?: CaptureRegion;
}

const sessions = new Map<string, CaptureSession>();

function qualitySettings(quality: string): { q: number; maxW: number } {
  switch (quality) {
    case 'low': return { q: 45, maxW: 800 };
    case 'medium': return { q: 60, maxW: 1280 };
    case 'high': return { q: 75, maxW: 1600 };
    default: return { q: 85, maxW: 1920 };
  }
}

function socketBackedUp(ws: WebSocket, lastFrameBytes: number): boolean {
  const buffered = (ws as WebSocket & { bufferedAmount?: number }).bufferedAmount ?? 0;
  return buffered > Math.max(lastFrameBytes, 32_768);
}

const PW_RENDERFULLCONTENT = 2;

function captureRectGdi(region: CaptureRegion, hwnd?: string): { bgra: Buffer; width: number; height: number } | null {
  const srcW = Math.max(1, Math.round(region.width) & ~1);
  const srcH = Math.max(1, Math.round(region.height) & ~1);
  const srcX = Math.round(region.x);
  const srcY = Math.round(region.y);

  const desktop = u32.GetDesktopWindow();
  const hdcScreen = hwnd
    ? u32.GetWindowDC(idToHwnd(hwnd) as never)
    : u32.GetDC(desktop as never);
  if (isNullPtr(hdcScreen)) return null;

  const hdcMem = g32.CreateCompatibleDC(hdcScreen as never);
  const hbmp = g32.CreateCompatibleBitmap(hdcScreen as never, srcW, srcH);
  const old = g32.SelectObject(hdcMem as never, hbmp as never);
  g32.SetStretchBltMode(hdcMem as never, HALFTONE);

  let ok = 0;
  if (hwnd) {
    ok = u32.PrintWindow(idToHwnd(hwnd) as never, hdcMem as never, PW_RENDERFULLCONTENT);
    if (!ok) {
      ok = g32.BitBlt(hdcMem as never, 0, 0, srcW, srcH, hdcScreen as never, 0, 0, SRCCOPY);
    }
  } else {
    ok = g32.BitBlt(hdcMem as never, 0, 0, srcW, srcH, hdcScreen as never, srcX, srcY, SRCCOPY);
  }

  const bmi = Buffer.alloc(44);
  bmi.writeUInt32LE(40, 0);
  bmi.writeInt32LE(srcW, 4);
  bmi.writeInt32LE(-srcH, 8);
  bmi.writeUInt16LE(1, 12);
  bmi.writeUInt16LE(32, 14);
  const bgra = Buffer.alloc(srcW * srcH * 4);
  if (ok) {
    g32.GetDIBits(
      hdcMem as never,
      hbmp as never,
      0,
      srcH,
      ptr(bgra),
      ptr(bmi),
      0,
    );
  }

  g32.SelectObject(hdcMem as never, old as never);
  g32.DeleteObject(hbmp as never);
  g32.DeleteDC(hdcMem as never);
  u32.ReleaseDC((hwnd ? idToHwnd(hwnd) : desktop) as never, hdcScreen as never);

  if (!ok) return null;
  return { bgra, width: srcW, height: srcH };
}

function cropBgra(
  src: DesktopFrame,
  region: CaptureRegion,
): { bgra: Buffer; width: number; height: number } | null {
  const x = Math.max(0, Math.round(region.x - src.originX));
  const y = Math.max(0, Math.round(region.y - src.originY));
  const width = Math.min(src.width - x, Math.round(region.width)) & ~1;
  const height = Math.min(src.height - y, Math.round(region.height)) & ~1;
  if (width < 2 || height < 2) return null;
  if (x === 0 && y === 0 && width === src.width && height === src.height) {
    return { bgra: src.bgra, width, height };
  }
  const out = Buffer.allocUnsafe(width * height * 4);
  for (let row = 0; row < height; row++) {
    const si = ((y + row) * src.width + x) * 4;
    src.bgra.copy(out, row * width * 4, si, si + width * 4);
  }
  return { bgra: out, width, height };
}

interface SharpPipeline {
  recomb(matrix: number[][]): SharpPipeline;
  resize(width: number): SharpPipeline;
  jpeg(opts: { quality: number; chromaSubsampling: string }): { toBuffer(): Promise<Buffer> };
}
type SharpCtor = (
  input: Buffer,
  opts: { raw: { width: number; height: number; channels: number } },
) => SharpPipeline;

let sharpJpeg: ((
  bgra: Buffer, width: number, height: number, quality: number, maxW: number,
) => Promise<Buffer>) | null | undefined;

async function encodeJpeg(
  bgra: Buffer, width: number, height: number, quality: number, maxW: number,
): Promise<Buffer | null> {
  if (sharpJpeg === undefined) {
    try {
      // Native JPEG encoder; optional at compile time (falls back to jpeg-js).
      // @ts-expect-error sharp is an optional runtime dependency
      const mod = await import('sharp') as { default: SharpCtor };
      const sharp = mod.default;
      sharpJpeg = async (buf, w, h, q, mw) => {
        let img = sharp(buf, { raw: { width: w, height: h, channels: 4 } })
          .recomb([[0, 0, 1], [0, 1, 0], [1, 0, 0]]);
        if (w > mw) img = img.resize(mw & ~1);
        return img.jpeg({ quality: q, chromaSubsampling: '4:2:0' }).toBuffer();
      };
    } catch {
      sharpJpeg = null;
    }
  }
  if (sharpJpeg) {
    try {
      return await sharpJpeg(bgra, width, height, quality, maxW);
    } catch {
      // fall through to jpeg-js
    }
  }
  const rgba = Buffer.alloc(width * height * 4);
  for (let i = 0; i < bgra.length; i += 4) {
    rgba[i] = bgra[i + 2]!;
    rgba[i + 1] = bgra[i + 1]!;
    rgba[i + 2] = bgra[i]!;
    rgba[i + 3] = 255;
  }
  let data = rgba;
  let w = width;
  let h = height;
  if (width > maxW) {
    w = maxW & ~1;
    h = Math.max(2, Math.round((height * w) / width) & ~1);
    const scaled = Buffer.alloc(w * h * 4);
    for (let y = 0; y < h; y++) {
      const sy = Math.min(height - 1, Math.floor((y * height) / h));
      for (let x = 0; x < w; x++) {
        const sx = Math.min(width - 1, Math.floor((x * width) / w));
        const si = (sy * width + sx) * 4;
        const di = (y * w + x) * 4;
        scaled[di] = rgba[si]!;
        scaled[di + 1] = rgba[si + 1]!;
        scaled[di + 2] = rgba[si + 2]!;
        scaled[di + 3] = 255;
      }
    }
    data = scaled;
  }
  return Buffer.from(jpeg.encode({ data, width: w, height: h }, quality).data);
}

function emitFrame(session: CaptureSession, jpegBuf: Buffer): void {
  if (session.ws.readyState !== 1) return;
  if (socketBackedUp(session.ws, session.lastFrameBytes)) return;
  const header = Buffer.allocUnsafe(FRAME_HEADER_BYTES);
  header.writeUInt32LE(FRAME_MAGIC, 0);
  header.writeUInt32LE(session.key >>> 0, 4);
  header.writeDoubleLE(Date.now(), 8);
  try {
    const payload = Buffer.concat([header, jpegBuf]);
    session.ws.send(payload);
    session.lastFrameBytes = payload.length;
  } catch {
    // socket going down
  }
}

function currentRegion(session: CaptureSession): CaptureRegion {
  if (session.hwnd) {
    const r = windowRect(idToHwnd(session.hwnd));
    if (r && r.width > 16 && r.height > 16) return r;
  }
  return session.region;
}

async function pumpCapture(session: CaptureSession): Promise<void> {
  const dup = DxgiDuplicator.open();
  try {
    while (session.running && sessions.has(session.id)) {
      if (session.ws.readyState !== 1) break;
      const region = currentRegion(session);
      if (
        sendFn &&
        session.ws.readyState === 1 &&
        (!session.lastEmittedRegion ||
          Math.abs(session.lastEmittedRegion.x - region.x) > 4 ||
          Math.abs(session.lastEmittedRegion.y - region.y) > 4 ||
          Math.abs(session.lastEmittedRegion.width - region.width) > 4 ||
          Math.abs(session.lastEmittedRegion.height - region.height) > 4)
      ) {
        session.lastEmittedRegion = region;
        sendFn(session.ws, { type: 'stream-region', streamId: session.id, region });
      }
      let pixels: { bgra: Buffer; width: number; height: number } | null = null;
      if (dup) {
        const desktop = dup.acquire(42);
        if (!desktop) continue;
        pixels = session.hwnd
          ? cropBgra(desktop, region)
          : { bgra: desktop.bgra, width: desktop.width, height: desktop.height };
        if (!pixels && session.hwnd) {
          pixels = captureRectGdi(region, session.hwnd);
        }
      } else {
        pixels = captureRectGdi(region, session.hwnd);
        const interval = Math.max(33, Math.round(1000 / Math.max(1, Math.min(24, session.fps || 12))));
        await Bun.sleep(interval);
      }
      if (!pixels) continue;
      try {
        const frame = await encodeJpeg(pixels.bgra, pixels.width, pixels.height, session.q, session.maxW);
        if (frame && session.running) emitFrame(session, frame);
      } catch (err) {
        console.warn('[capture]', err);
      }
    }
  } finally {
    dup?.close();
  }
}

export function startCapture(
  quality: 'low' | 'medium' | 'high' | 'full',
  fps: number,
  ws: WebSocket,
  region?: CaptureRegion,
  windowId?: string,
): { streamId: string; streamKey: number; region: CaptureRegion } {
  const id = crypto.randomUUID();
  const key = nextStreamKey++;
  const { q, maxW } = qualitySettings(quality);
  let grab = region && region.width > 16 && region.height > 16 ? region : getPrimaryMonitor();
  if (windowId) {
    const r = windowRect(idToHwnd(windowId));
    if (r) grab = r;
  }
  const session: CaptureSession = {
    id, key, ws, region: grab, hwnd: windowId, running: true,
    fps: Math.max(1, Math.min(24, fps || 12)),
    q, maxW, lastFrameBytes: 0,
    quality, lastQosAt: 0,
  };
  sessions.set(id, session);
  void pumpCapture(session).catch((err) => console.warn('[capture]', err));
  return { streamId: id, streamKey: key, region: grab };
}

export function stopCapture(streamId: string): void {
  const session = sessions.get(streamId);
  if (!session) return;
  sessions.delete(streamId);
  session.running = false;
}

export function stopCapturesForSocket(ws: WebSocket): void {
  for (const [id, session] of [...sessions.entries()]) {
    if (session.ws === ws) stopCapture(id);
  }
}

const QUALITY_LADDER = ['low', 'medium', 'high', 'full'] as const;

export function reportStreamStats(streamId: string, decodeFps: number, frameAgeMs: number): void {
  const session = sessions.get(streamId);
  if (!session) return;
  const now = Date.now();
  if (now - session.lastQosAt < 2000) return;
  session.lastQosAt = now;
  const idx = QUALITY_LADDER.indexOf(session.quality as typeof QUALITY_LADDER[number]);
  const down = frameAgeMs > 80 || decodeFps < Math.max(6, session.fps * 0.45);
  const up = frameAgeMs < 40 && decodeFps >= session.fps * 0.75;
  let next = idx < 0 ? 1 : idx;
  if (down && next > 0) next -= 1;
  else if (up && next < QUALITY_LADDER.length - 1) next += 1;
  else if (down && session.fps > 8) {
    session.fps = Math.max(8, session.fps - 2);
    return;
  } else return;
  session.quality = QUALITY_LADDER[next]!;
  const s = qualitySettings(session.quality);
  session.q = s.q;
  session.maxW = s.maxW;
  if (down) session.fps = Math.max(8, session.fps - 2);
  if (up) session.fps = Math.min(24, session.fps + 2);
}

export { sendFn };
