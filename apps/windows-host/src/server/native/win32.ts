import { dlopen, FFIType, ptr, JSCallback, toArrayBuffer, CFunction } from 'bun:ffi';

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

export { ptr, FFIType, JSCallback, toArrayBuffer, CFunction };

// --- DXGI Desktop Duplication (vsync-locked, GPU path) ----------------------

const DXGI_ERROR_WAIT_TIMEOUT = 0x887a0027;
const DXGI_ERROR_ACCESS_LOST = 0x887a0026;
const D3D11_SDK_VERSION = 7;
const D3D_DRIVER_TYPE_HARDWARE = 1;
const D3D11_USAGE_STAGING = 3;
const D3D11_CPU_ACCESS_READ = 0x20000;
const D3D11_MAP_READ = 1;

const IID_IDXGIDevice = guid(0x54ec77fa, 0x1377, 0x44e6, [0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c]);
const IID_IDXGIOutput1 = guid(0x00cddea8, 0x939b, 0x4b83, [0xa3, 0x40, 0xa6, 0x85, 0x22, 0x66, 0x66, 0xcc]);
const IID_ID3D11Texture2D = guid(0x6f15aaf2, 0xd208, 0x4e89, [0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c]);

function guid(d1: number, d2: number, d3: number, rest: number[]): Buffer {
  const b = Buffer.alloc(16);
  b.writeUInt32LE(d1, 0);
  b.writeUInt16LE(d2, 4);
  b.writeUInt16LE(d3, 6);
  for (let i = 0; i < 8; i++) b[8 + i] = rest[i]!;
  return b;
}

type Ptr = number | bigint;

function u64(buf: Buffer, off = 0): bigint {
  return buf.readBigUInt64LE(off);
}

function vtblFn(obj: Ptr, slot: number): Ptr {
  const objBytes = Buffer.from(toArrayBuffer(obj as never, 0, 8));
  const vtbl = u64(objBytes);
  const slotBytes = Buffer.from(toArrayBuffer(vtbl as never, slot * 8, 8));
  return u64(slotBytes);
}

type ComFn = ((...args: unknown[]) => number | bigint | null) & { close(): void };

const comCache = new Map<string, ComFn>();

function comCall(
  obj: Ptr,
  slot: number,
  args: (typeof FFIType)[keyof typeof FFIType][],
  returns: (typeof FFIType)[keyof typeof FFIType],
  callArgs: unknown[],
): number | bigint | null {
  const fnPtr = vtblFn(obj, slot);
  const key = `${String(fnPtr)}:${args.length}:${String(returns)}`;
  let fn = comCache.get(key);
  if (!fn) {
    fn = CFunction({
      ptr: fnPtr as never,
      args: [FFIType.ptr, ...args],
      returns,
    }) as ComFn;
    comCache.set(key, fn);
  }
  return fn(obj, ...callArgs);
}

function qi(obj: Ptr, iid: Buffer): Ptr | null {
  const out = Buffer.alloc(8);
  const hr = Number(comCall(obj, 0, [FFIType.ptr, FFIType.ptr], FFIType.i32, [ptr(iid), ptr(out)]) ?? 1);
  if (hr !== 0) return null;
  const p = u64(out);
  return p === 0n ? null : p;
}

function releaseCom(obj: Ptr | null | undefined): void {
  if (obj == null || isNullPtr(obj)) return;
  try {
    comCall(obj, 2, [], FFIType.u32, []);
  } catch {
    // already released
  }
}

let dxgiLoaded: {
  CreateDXGIFactory1?: never;
  D3D11CreateDevice: (
    adapter: Ptr | null,
    driverType: number,
    software: Ptr | null,
    flags: number,
    levels: Ptr | null,
    nlevels: number,
    sdk: number,
    device: Ptr,
    outLevel: Ptr | null,
    context: Ptr,
  ) => number;
} | null | undefined;

function loadDxgi(): typeof dxgiLoaded {
  if (dxgiLoaded !== undefined) return dxgiLoaded;
  if (process.platform !== 'win32') {
    dxgiLoaded = null;
    return null;
  }
  try {
    const d3d = dlopen('d3d11.dll', {
      D3D11CreateDevice: {
        args: [
          FFIType.ptr, FFIType.i32, FFIType.ptr, FFIType.u32, FFIType.ptr,
          FFIType.u32, FFIType.u32, FFIType.ptr, FFIType.ptr, FFIType.ptr,
        ],
        returns: FFIType.i32,
      },
    });
    dxgiLoaded = { D3D11CreateDevice: d3d.symbols.D3D11CreateDevice as never };
    return dxgiLoaded;
  } catch {
    dxgiLoaded = null;
    return null;
  }
}

export interface DesktopFrame {
  bgra: Buffer;
  width: number;
  height: number;
  originX: number;
  originY: number;
}

/**
 * DXGI Output Duplication: blocks until the desktop changes or `timeoutMs`.
 * Returns tightly packed BGRA (8-bit). Caller must not hold the GPU resource
 * — pixels are copied out before ReleaseFrame.
 */
export class DxgiDuplicator {
  private device: Ptr | null = null;
  private ctx: Ptr | null = null;
  private dup: Ptr | null = null;
  private staging: Ptr | null = null;
  private stagingW = 0;
  private stagingH = 0;
  originX = 0;
  originY = 0;
  width = 0;
  height = 0;

  static open(): DxgiDuplicator | null {
    const api = loadDxgi();
    if (!api) return null;
    const inst = new DxgiDuplicator();
    try {
      if (!inst.init(api)) {
        inst.close();
        return null;
      }
      return inst;
    } catch {
      inst.close();
      return null;
    }
  }

  private init(api: NonNullable<typeof dxgiLoaded>): boolean {
    const deviceBuf = Buffer.alloc(8);
    const ctxBuf = Buffer.alloc(8);
    const hr = api.D3D11CreateDevice(
      null,
      D3D_DRIVER_TYPE_HARDWARE,
      null,
      0,
      null,
      0,
      D3D11_SDK_VERSION,
      ptr(deviceBuf) as never,
      null,
      ptr(ctxBuf) as never,
    );
    if (hr !== 0) return false;
    this.device = u64(deviceBuf);
    this.ctx = u64(ctxBuf);
    if (this.device === 0n || this.ctx === 0n) return false;

    const dxgiDev = qi(this.device, IID_IDXGIDevice);
    if (!dxgiDev) return false;
    const adapterBuf = Buffer.alloc(8);
    // IDXGIDevice::GetAdapter = slot 7
    if (Number(comCall(dxgiDev, 7, [FFIType.ptr], FFIType.i32, [ptr(adapterBuf)]) ?? 1) !== 0) {
      releaseCom(dxgiDev);
      return false;
    }
    const adapter = u64(adapterBuf);
    releaseCom(dxgiDev);
    const outputBuf = Buffer.alloc(8);
    // IDXGIAdapter::EnumOutputs = slot 7
    if (Number(comCall(adapter, 7, [FFIType.u32, FFIType.ptr], FFIType.i32, [0, ptr(outputBuf)]) ?? 1) !== 0) {
      releaseCom(adapter);
      return false;
    }
    const output = u64(outputBuf);
    releaseCom(adapter);

    const desc = Buffer.alloc(128);
    // IDXGIOutput::GetDesc = slot 7
    comCall(output, 7, [FFIType.ptr], FFIType.i32, [ptr(desc)]);
    // RECT DesktopCoordinates at offset 64
    const left = desc.readInt32LE(64);
    const top = desc.readInt32LE(68);
    const right = desc.readInt32LE(72);
    const bottom = desc.readInt32LE(76);
    this.originX = left;
    this.originY = top;
    this.width = Math.max(0, right - left);
    this.height = Math.max(0, bottom - top);

    const output1 = qi(output, IID_IDXGIOutput1);
    releaseCom(output);
    if (!output1) return false;
    const dupBuf = Buffer.alloc(8);
    // IDXGIOutput1::DuplicateOutput = slot 22
    const dupHr = Number(comCall(
      output1, 22, [FFIType.ptr, FFIType.ptr], FFIType.i32,
      [this.device, ptr(dupBuf)],
    ) ?? 1);
    releaseCom(output1);
    if (dupHr !== 0) return false;
    this.dup = u64(dupBuf);
    return this.dup !== 0n;
  }

  acquire(timeoutMs: number): DesktopFrame | null {
    if (!this.dup || !this.device || !this.ctx) return null;
    const info = Buffer.alloc(128);
    const resBuf = Buffer.alloc(8);
    // IDXGIOutputDuplication::AcquireNextFrame = slot 8
    const hr = Number(comCall(
      this.dup, 8, [FFIType.u32, FFIType.ptr, FFIType.ptr], FFIType.i32,
      [timeoutMs, ptr(info), ptr(resBuf)],
    ) ?? 1) >>> 0;
    if (hr === DXGI_ERROR_WAIT_TIMEOUT) return null;
    if (hr === DXGI_ERROR_ACCESS_LOST) {
      this.rebind();
      return null;
    }
    if (hr !== 0) return null;
    const resource = u64(resBuf);
    try {
      const tex = qi(resource, IID_ID3D11Texture2D);
      if (!tex) return null;
      try {
        const pixels = this.copyTexture(tex);
        return pixels;
      } finally {
        releaseCom(tex);
      }
    } finally {
      releaseCom(resource);
      // ReleaseFrame = slot 14
      comCall(this.dup, 14, [], FFIType.i32, []);
    }
  }

  private copyTexture(tex: Ptr): DesktopFrame | null {
    const desc = Buffer.alloc(44);
    // ID3D11Texture2D::GetDesc = slot 10
    comCall(tex, 10, [FFIType.ptr], FFIType.void, [ptr(desc)]);
    const width = desc.readUInt32LE(0);
    const height = desc.readUInt32LE(4);
    if (width < 2 || height < 2) return null;

    if (!this.staging || this.stagingW !== width || this.stagingH !== height) {
      releaseCom(this.staging);
      this.staging = null;
      const stDesc = Buffer.from(desc);
      stDesc.writeUInt32LE(1, 8); // MipLevels
      stDesc.writeUInt32LE(1, 12); // ArraySize
      stDesc.writeUInt32LE(1, 20); // SampleDesc.Count
      stDesc.writeUInt32LE(0, 24); // SampleDesc.Quality
      stDesc.writeUInt32LE(D3D11_USAGE_STAGING, 28);
      stDesc.writeUInt32LE(0, 32); // BindFlags
      stDesc.writeUInt32LE(D3D11_CPU_ACCESS_READ, 36);
      stDesc.writeUInt32LE(0, 40); // MiscFlags
      const out = Buffer.alloc(8);
      // ID3D11Device::CreateTexture2D = slot 5
      const hr = Number(comCall(
        this.device!, 5, [FFIType.ptr, FFIType.ptr, FFIType.ptr], FFIType.i32,
        [ptr(stDesc), null, ptr(out)],
      ) ?? 1);
      if (hr !== 0) return null;
      this.staging = u64(out);
      this.stagingW = width;
      this.stagingH = height;
    }

    // ID3D11DeviceContext::CopyResource = slot 47
    comCall(this.ctx!, 47, [FFIType.ptr, FFIType.ptr], FFIType.void, [this.staging, tex]);
    const mapped = Buffer.alloc(16);
    // Map = slot 14
    const mapHr = Number(comCall(
      this.ctx!, 14,
      [FFIType.ptr, FFIType.u32, FFIType.i32, FFIType.u32, FFIType.ptr],
      FFIType.i32,
      [this.staging, 0, D3D11_MAP_READ, 0, ptr(mapped)],
    ) ?? 1);
    if (mapHr !== 0) return null;
    try {
      const pData = u64(mapped);
      const rowPitch = mapped.readUInt32LE(8);
      const tight = Buffer.allocUnsafe(width * height * 4);
      const src = Buffer.from(toArrayBuffer(pData as never, 0, rowPitch * height));
      const rowBytes = width * 4;
      for (let y = 0; y < height; y++) {
        src.copy(tight, y * rowBytes, y * rowPitch, y * rowPitch + rowBytes);
      }
      return { bgra: tight, width, height, originX: this.originX, originY: this.originY };
    } finally {
      // Unmap = slot 15
      comCall(this.ctx!, 15, [FFIType.ptr, FFIType.u32], FFIType.void, [this.staging, 0]);
    }
  }

  private rebind(): void {
    releaseCom(this.dup);
    this.dup = null;
    const api = loadDxgi();
    if (!api) return;
    try {
      this.init(api);
    } catch {
      // next acquire returns null
    }
  }

  close(): void {
    releaseCom(this.staging);
    releaseCom(this.dup);
    releaseCom(this.ctx);
    releaseCom(this.device);
    this.staging = this.dup = this.ctx = this.device = null;
  }
}
