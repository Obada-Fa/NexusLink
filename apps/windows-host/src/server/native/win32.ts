import { dlopen, FFIType, ptr, JSCallback } from 'bun:ffi';

const user32 = dlopen('user32.dll', {
  GetSystemMetrics: { args: [FFIType.i32], returns: FFIType.i32 },
  GetDC: { args: [FFIType.ptr], returns: FFIType.ptr },
  ReleaseDC: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.i32 },
  GetDesktopWindow: { args: [], returns: FFIType.ptr },
  GetWindowDC: { args: [FFIType.ptr], returns: FFIType.ptr },
  GetWindowRect: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.i32 },
  GetClientRect: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.i32 },
  IsWindow: { args: [FFIType.ptr], returns: FFIType.i32 },
  IsWindowVisible: { args: [FFIType.ptr], returns: FFIType.i32 },
  GetWindowTextLengthW: { args: [FFIType.ptr], returns: FFIType.i32 },
  GetWindowTextW: { args: [FFIType.ptr, FFIType.ptr, FFIType.i32], returns: FFIType.i32 },
  GetClassNameW: { args: [FFIType.ptr, FFIType.ptr, FFIType.i32], returns: FFIType.i32 },
  GetWindowThreadProcessId: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.u32 },
  EnumWindows: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.i32 },
  GetForegroundWindow: { args: [], returns: FFIType.ptr },
  SetForegroundWindow: { args: [FFIType.ptr], returns: FFIType.i32 },
  ShowWindow: { args: [FFIType.ptr, FFIType.i32], returns: FFIType.i32 },
  SetWindowPos: {
    args: [FFIType.ptr, FFIType.ptr, FFIType.i32, FFIType.i32, FFIType.i32, FFIType.i32, FFIType.u32],
    returns: FFIType.i32,
  },
  SetCursorPos: { args: [FFIType.i32, FFIType.i32], returns: FFIType.i32 },
  mouse_event: {
    args: [FFIType.u32, FFIType.u32, FFIType.u32, FFIType.u32, FFIType.ptr],
    returns: FFIType.void,
  },
  keybd_event: {
    args: [FFIType.u8, FFIType.u8, FFIType.u32, FFIType.ptr],
    returns: FFIType.void,
  },
  MapVirtualKeyW: { args: [FFIType.u32, FFIType.u32], returns: FFIType.u32 },
  VkKeyScanW: { args: [FFIType.u16], returns: FFIType.i16 },
  PrintWindow: { args: [FFIType.ptr, FFIType.ptr, FFIType.u32], returns: FFIType.i32 },
  FindWindowW: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
  PostMessageW: { args: [FFIType.ptr, FFIType.u32, FFIType.ptr, FFIType.ptr], returns: FFIType.i32 },
  GetAncestor: { args: [FFIType.ptr, FFIType.u32], returns: FFIType.ptr },
  GetWindow: { args: [FFIType.ptr, FFIType.u32], returns: FFIType.ptr },
  GetWindowLongPtrW: { args: [FFIType.ptr, FFIType.i32], returns: FFIType.ptr },
});

const gdi32 = dlopen('gdi32.dll', {
  CreateCompatibleDC: { args: [FFIType.ptr], returns: FFIType.ptr },
  CreateCompatibleBitmap: { args: [FFIType.ptr, FFIType.i32, FFIType.i32], returns: FFIType.ptr },
  SelectObject: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
  BitBlt: {
    args: [FFIType.ptr, FFIType.i32, FFIType.i32, FFIType.i32, FFIType.i32, FFIType.ptr, FFIType.i32, FFIType.i32, FFIType.u32],
    returns: FFIType.i32,
  },
  StretchBlt: {
    args: [
      FFIType.ptr, FFIType.i32, FFIType.i32, FFIType.i32, FFIType.i32,
      FFIType.ptr, FFIType.i32, FFIType.i32, FFIType.i32, FFIType.i32, FFIType.u32,
    ],
    returns: FFIType.i32,
  },
  GetDIBits: {
    args: [FFIType.ptr, FFIType.ptr, FFIType.u32, FFIType.u32, FFIType.ptr, FFIType.ptr, FFIType.u32],
    returns: FFIType.i32,
  },
  DeleteObject: { args: [FFIType.ptr], returns: FFIType.i32 },
  DeleteDC: { args: [FFIType.ptr], returns: FFIType.i32 },
  SetStretchBltMode: { args: [FFIType.ptr, FFIType.i32], returns: FFIType.i32 },
});

const kernel32 = dlopen('kernel32.dll', {
  GetLogicalDriveStringsW: { args: [FFIType.u32, FFIType.ptr], returns: FFIType.u32 },
  OpenProcess: { args: [FFIType.u32, FFIType.i32, FFIType.u32], returns: FFIType.ptr },
  CloseHandle: { args: [FFIType.ptr], returns: FFIType.i32 },
  QueryFullProcessImageNameW: {
    args: [FFIType.ptr, FFIType.u32, FFIType.ptr, FFIType.ptr],
    returns: FFIType.i32,
  },
});

const shell32 = dlopen('shell32.dll', {
  ShellExecuteW: {
    args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.i32],
    returns: FFIType.ptr,
  },
});

export const SM_CXSCREEN = 0;
export const SM_CYSCREEN = 1;
export const SM_XVIRTUALSCREEN = 76;
export const SM_YVIRTUALSCREEN = 77;
export const SM_CXVIRTUALSCREEN = 78;
export const SM_CYVIRTUALSCREEN = 79;
export const SRCCOPY = 0x00cc0020;
export const HALFTONE = 4;
export const SW_RESTORE = 9;
export const SW_SHOW = 5;
export const SW_MAXIMIZE = 3;
export const HWND_TOP = 0;
export const SWP_SHOWWINDOW = 0x0040;
export const SWP_NOZORDER = 0x0004;
export const MOUSEEVENTF_MOVE = 0x0001;
export const MOUSEEVENTF_LEFTDOWN = 0x0002;
export const MOUSEEVENTF_LEFTUP = 0x0004;
export const MOUSEEVENTF_RIGHTDOWN = 0x0008;
export const MOUSEEVENTF_RIGHTUP = 0x0010;
export const MOUSEEVENTF_MIDDLEDOWN = 0x0020;
export const MOUSEEVENTF_MIDDLEUP = 0x0040;
export const MOUSEEVENTF_WHEEL = 0x0800;
export const MOUSEEVENTF_HWHEEL = 0x1000;
export const KEYEVENTF_KEYUP = 0x0002;
export const GWL_EXSTYLE = -20;
export const WS_EX_TOOLWINDOW = 0x00000080;
export const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
export const GA_ROOT = 2;

export const u32 = user32.symbols;
export const g32 = gdi32.symbols;
export const k32 = kernel32.symbols;
export const sh32 = shell32.symbols;

export function wideBuffer(s: string): Uint16Array {
  const buf = new Uint16Array(s.length + 1);
  for (let i = 0; i < s.length; i++) buf[i] = s.charCodeAt(i);
  return buf;
}

export function readWide(buf: Uint16Array, maxLen: number): string {
  let n = 0;
  while (n < maxLen && buf[n] !== 0) n++;
  return String.fromCharCode(...buf.subarray(0, n));
}

export function hwndToId(hwnd: number | bigint): string {
  return BigInt(hwnd as number).toString();
}

export function idToHwnd(id: string): number {
  return Number(BigInt(id));
}

export function isNullPtr(p: unknown): boolean {
  if (p == null) return true;
  if (typeof p === 'number') return p === 0;
  if (typeof p === 'bigint') return p === 0n;
  return false;
}

export function enumTopLevelWindows(): Array<number | bigint> {
  const found: Array<number | bigint> = [];
  const cb = new JSCallback(
    (hwnd) => {
      if (!isNullPtr(hwnd)) found.push(hwnd as number | bigint);
      return true;
    },
    { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.bool },
  );
  try {
    u32.EnumWindows(cb.ptr, ptr(new Uint8Array(8)));
  } finally {
    cb.close();
  }
  return found;
}

export interface WinRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export function windowRect(hwnd: number | bigint): WinRect | null {
  const buf = new Int32Array(4);
  if (!u32.GetWindowRect(hwnd as never, ptr(buf))) return null;
  const left = buf[0]!;
  const top = buf[1]!;
  const right = buf[2]!;
  const bottom = buf[3]!;
  return { x: left, y: top, width: right - left, height: bottom - top };
}

export function windowTitle(hwnd: number | bigint): string {
  const len = u32.GetWindowTextLengthW(hwnd as never);
  if (len <= 0) return '';
  const buf = new Uint16Array(len + 2);
  u32.GetWindowTextW(hwnd as never, ptr(buf), buf.length);
  return readWide(buf, buf.length);
}

export function windowClass(hwnd: number | bigint): string {
  const buf = new Uint16Array(256);
  u32.GetClassNameW(hwnd as never, ptr(buf), buf.length);
  return readWide(buf, buf.length);
}

export function windowPid(hwnd: number | bigint): number {
  const pidBuf = new Uint32Array(1);
  u32.GetWindowThreadProcessId(hwnd as never, ptr(pidBuf));
  return pidBuf[0] ?? 0;
}

export function processImagePath(pid: number): string {
  if (!pid) return '';
  const handle = k32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
  if (isNullPtr(handle)) return '';
  try {
    const buf = new Uint16Array(32768);
    const size = new Uint32Array([buf.length]);
    if (!k32.QueryFullProcessImageNameW(handle as never, 0, ptr(buf), ptr(size))) return '';
    return readWide(buf, size[0] ?? buf.length);
  } finally {
    k32.CloseHandle(handle as never);
  }
}

export { ptr, FFIType, JSCallback };
