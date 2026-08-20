import {
  u32, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP,
  MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_WHEEL, MOUSEEVENTF_HWHEEL,
  KEYEVENTF_KEYUP,
} from './win32';

const BUTTON_DOWN: Record<string, number> = {
  left: MOUSEEVENTF_LEFTDOWN,
  right: MOUSEEVENTF_RIGHTDOWN,
  middle: MOUSEEVENTF_MIDDLEDOWN,
};
const BUTTON_UP: Record<string, number> = {
  left: MOUSEEVENTF_LEFTUP,
  right: MOUSEEVENTF_RIGHTUP,
  middle: MOUSEEVENTF_MIDDLEUP,
};

const NAMED_KEYS: Record<string, number> = {
  enter: 0x0d,
  return: 0x0d,
  tab: 0x09,
  escape: 0x1b,
  esc: 0x1b,
  backspace: 0x08,
  delete: 0x2e,
  space: 0x20,
  arrowup: 0x26,
  arrowdown: 0x28,
  arrowleft: 0x25,
  arrowright: 0x27,
  home: 0x24,
  end: 0x23,
  pageup: 0x21,
  pagedown: 0x22,
  control: 0x11,
  ctrl: 0x11,
  shift: 0x10,
  alt: 0x12,
  meta: 0x5b,
  win: 0x5b,
};

function vkForKey(key: string): number | null {
  const named = NAMED_KEYS[key.toLowerCase()];
  if (named) return named;
  if (key.length === 1) {
    const scan = u32.VkKeyScanW(key.charCodeAt(0));
    if (scan !== -1) return scan & 0xff;
    const upper = key.toUpperCase().charCodeAt(0);
    if (upper >= 65 && upper <= 90) return upper;
  }
  if (/^f([1-9]|1[0-2])$/i.test(key)) return 0x70 + (Number(key.slice(1)) - 1);
  return null;
}

function tapVk(vk: number, up: boolean): void {
  const scan = u32.MapVirtualKeyW(vk, 0);
  u32.keybd_event(vk, scan, up ? KEYEVENTF_KEYUP : 0, null as never);
}

const FLUSH_MS = 8;

let pendingAbs: { x: number; y: number } | null = null;
let flushTimer: ReturnType<typeof setTimeout> | null = null;

function flushAbs(): void {
  if (flushTimer != null) {
    clearTimeout(flushTimer);
    flushTimer = null;
  }
  const p = pendingAbs;
  pendingAbs = null;
  if (p) u32.SetCursorPos(Math.round(p.x), Math.round(p.y));
}

export function mouseMoveAbs(x: number, y: number): { ok: boolean } {
  pendingAbs = { x, y };
  if (flushTimer == null) {
    flushTimer = setTimeout(() => {
      flushTimer = null;
      flushAbs();
    }, FLUSH_MS);
  }
  return { ok: true };
}

export function mouseMove(dx: number, dy: number): { ok: boolean } {
  u32.mouse_event(0x0001, Math.round(dx) >>> 0, Math.round(dy) >>> 0, 0, null as never);
  return { ok: true };
}

function maybeMove(x?: number, y?: number): void {
  if (typeof x === 'number' && typeof y === 'number') {
    flushAbs();
    u32.SetCursorPos(Math.round(x), Math.round(y));
  }
}

export function mouseClick(button: string, x?: number, y?: number): { ok: boolean } {
  maybeMove(x, y);
  const down = BUTTON_DOWN[button] ?? MOUSEEVENTF_LEFTDOWN;
  const up = BUTTON_UP[button] ?? MOUSEEVENTF_LEFTUP;
  u32.mouse_event(down, 0, 0, 0, null as never);
  u32.mouse_event(up, 0, 0, 0, null as never);
  return { ok: true };
}

export function buttonDown(button: string, x?: number, y?: number): { ok: boolean } {
  maybeMove(x, y);
  u32.mouse_event(BUTTON_DOWN[button] ?? MOUSEEVENTF_LEFTDOWN, 0, 0, 0, null as never);
  return { ok: true };
}

export function buttonUp(button: string, x?: number, y?: number): { ok: boolean } {
  maybeMove(x, y);
  u32.mouse_event(BUTTON_UP[button] ?? MOUSEEVENTF_LEFTUP, 0, 0, 0, null as never);
  return { ok: true };
}

export function mouseScroll(deltaX: number, deltaY: number, x: number, y: number): { ok: boolean } {
  maybeMove(x, y);
  if (deltaY) u32.mouse_event(MOUSEEVENTF_WHEEL, 0, 0, Math.round(-deltaY) >>> 0, null as never);
  if (deltaX) u32.mouse_event(MOUSEEVENTF_HWHEEL, 0, 0, Math.round(deltaX) >>> 0, null as never);
  return { ok: true };
}

export function keyEvent(key: string, modifiers?: string[]): { ok: boolean } {
  const mods = modifiers ?? [];
  for (const m of mods) {
    const vk = vkForKey(m);
    if (vk) tapVk(vk, false);
  }
  const vk = vkForKey(key);
  if (vk) {
    tapVk(vk, false);
    tapVk(vk, true);
  }
  for (const m of [...mods].reverse()) {
    const mvk = vkForKey(m);
    if (mvk) tapVk(mvk, true);
  }
  return { ok: true };
}

export function typeText(text: string): { ok: boolean } {
  for (const ch of text) {
    if (ch === '\n') {
      keyEvent('enter');
      continue;
    }
    const scan = u32.VkKeyScanW(ch.charCodeAt(0));
    if (scan === -1) continue;
    const vk = scan & 0xff;
    const shift = (scan & 0x100) !== 0;
    if (shift) tapVk(0x10, false);
    tapVk(vk, false);
    tapVk(vk, true);
    if (shift) tapVk(0x10, true);
  }
  return { ok: true };
}
