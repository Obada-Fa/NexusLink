import jpeg from 'jpeg-js';
import { ptr } from 'bun:ffi';
import type { CaptureRegion, ScreenMetadata } from '@nexuslink/rpc-types';
import type { WsMessage } from '@nexuslink/rpc-types';
import {
  g32, u32, isNullPtr, windowRect, idToHwnd,
  SM_CXSCREEN, SM_CYSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
  SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SRCCOPY, HALFTONE,
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
  timer?: ReturnType<typeof setInterval>;
  q: number;
  maxW: number;
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

function captureRect(region: CaptureRegion, hwnd?: string): { rgba: Buffer; width: number; height: number } | null {
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
    ok = u32.PrintWindow(idToHwnd(hwnd) as never, hdcMem as never, 2);
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
  const pixels = Buffer.alloc(srcW * srcH * 4);
  if (ok) {
    g32.GetDIBits(
      hdcMem as never,
      hbmp as never,
      0,
      srcH,
      ptr(pixels),
      ptr(bmi),
      0,
    );
  }

  g32.SelectObject(hdcMem as never, old as never);
  g32.DeleteObject(hbmp as never);
  g32.DeleteDC(hdcMem as never);
  u32.ReleaseDC((hwnd ? idToHwnd(hwnd) : desktop) as never, hdcScreen as never);

  if (!ok) return null;

  const rgba = Buffer.alloc(srcW * srcH * 4);
  for (let i = 0; i < pixels.length; i += 4) {
    rgba[i] = pixels[i + 2]!;
    rgba[i + 1] = pixels[i + 1]!;
    rgba[i + 2] = pixels[i]!;
    rgba[i + 3] = 255;
  }
  return { rgba, width: srcW, height: srcH };
}

function scaleRgba(
  src: Buffer, sw: number, sh: number, maxW: number,
): { data: Buffer; width: number; height: number } {
  if (sw <= maxW) return { data: src, width: sw, height: sh };
  const width = maxW & ~1;
  const height = Math.max(2, Math.round((sh * width) / sw) & ~1);
  const data = Buffer.alloc(width * height * 4);
  for (let y = 0; y < height; y++) {
    const sy = Math.min(sh - 1, Math.floor((y * sh) / height));
    for (let x = 0; x < width; x++) {
      const sx = Math.min(sw - 1, Math.floor((x * sw) / width));
      const si = (sy * sw + sx) * 4;
      const di = (y * width + x) * 4;
      data[di] = src[si]!;
      data[di + 1] = src[si + 1]!;
      data[di + 2] = src[si + 2]!;
      data[di + 3] = 255;
    }
  }
  return { data, width, height };
}

function grabJpeg(session: CaptureSession): Buffer | null {
  let region = session.region;
  if (session.hwnd) {
    const r = windowRect(idToHwnd(session.hwnd));
    if (r && r.width > 16 && r.height > 16) region = r;
  }
  const grabbed = captureRect(region, session.hwnd);
  if (!grabbed) return null;
  const scaled = scaleRgba(grabbed.rgba, grabbed.width, grabbed.height, session.maxW);
  const encoded = jpeg.encode({ data: scaled.data, width: scaled.width, height: scaled.height }, session.q);
  return Buffer.from(encoded.data);
}

function emitFrame(session: CaptureSession, jpegBuf: Buffer): void {
  if (session.ws.readyState !== 1) return;
  const header = Buffer.allocUnsafe(FRAME_HEADER_BYTES);
  header.writeUInt32LE(FRAME_MAGIC, 0);
  header.writeUInt32LE(session.key >>> 0, 4);
  header.writeDoubleLE(Date.now(), 8);
  try {
    session.ws.send(Buffer.concat([header, jpegBuf]));
  } catch {
    // socket going down
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
    id, key, ws, region: grab, hwnd: windowId, q, maxW,
  };
  sessions.set(id, session);
  const interval = Math.max(33, Math.round(1000 / Math.max(1, Math.min(24, fps || 12))));
  session.timer = setInterval(() => {
    if (!sessions.has(id) || ws.readyState !== 1) {
      stopCapture(id);
      return;
    }
    try {
      const frame = grabJpeg(session);
      if (frame) emitFrame(session, frame);
    } catch (err) {
      console.warn('[capture]', err);
    }
  }, interval);
  return { streamId: id, streamKey: key, region: grab };
}

export function stopCapture(streamId: string): void {
  const session = sessions.get(streamId);
  if (!session) return;
  sessions.delete(streamId);
  if (session.timer) clearInterval(session.timer);
}

export function stopCapturesForSocket(ws: WebSocket): void {
  for (const [id, session] of [...sessions.entries()]) {
    if (session.ws === ws) stopCapture(id);
  }
}

export { sendFn };
