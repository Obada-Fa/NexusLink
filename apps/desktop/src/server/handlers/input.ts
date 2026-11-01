// Host input injection via long-lived `xdotool -` processes (script mode: one
// command per stdin line). Injection cost drops from a ~10-30ms process spawn
// per event to a pipe write.
//
// High-frequency events (drag moves, scroll, pinch-zoom) are coalesced: the
// pipe never queues a backlog of `mousemove --sync` / ctrl+wheel commands that
// then dump after the finger has already stopped. Latest pointer wins; extra
// scroll/zoom from a delayed burst is dropped instead of catching up.

const DEFAULT_DISPLAY = process.env.DISPLAY || ':0';

type SpawnOpts = Parameters<typeof Bun.spawn>[1];

const MOUSE_BUTTON: Record<string, string> = { left: '1', middle: '2', right: '3' };

/** Host px per wheel click for two-finger scroll. */
export const SCROLL_PX_PER_CLICK = 24;
/** Max wheel clicks flushed in one slice — drop the rest (no catch-up). */
export const MAX_SCROLL_CLICKS_PER_FLUSH = 3;
/** Pinch-zoom is ctrl+wheel; coarser so a pinch is a few steps, not twenty. */
export const ZOOM_PX_PER_CLICK = 80;
export const MAX_ZOOM_CLICKS_PER_FLUSH = 1;
/** Don't emit another zoom click sooner than this (ms). */
export const MIN_ZOOM_INTERVAL_MS = 50;
/** Merge window for moves/scrolls. */
export const FLUSH_MS = 8;

type Proc = ReturnType<typeof Bun.spawn>;

export function takeClicksFromAccum(
  accum: number,
  pxPerClick: number,
  maxClicks: number,
): { clicks: number; rest: number } {
  if (pxPerClick <= 0 || accum === 0) return { clicks: 0, rest: accum };
  let clicks = Math.trunc(accum / pxPerClick);
  let rest = accum - clicks * pxPerClick;
  if (Math.abs(clicks) > maxClicks) {
    clicks = Math.sign(clicks) * maxClicks;
    // Drop leftover so a delayed burst cannot replay as a zoom/scroll dump.
    rest = 0;
  }
  return { clicks, rest };
}

function modsKey(mods: string[]): string {
  return mods.join('+');
}

class DisplayInjector {
  private proc: Proc | null = null;
  private flushTimer: ReturnType<typeof setTimeout> | null = null;

  pendingMove: { x: number; y: number } | null = null;
  pendingScroll: {
    dx: number;
    dy: number;
    x?: number;
    y?: number;
    mods: string[];
  } | null = null;
  lastZoomAt = 0;

  constructor(readonly display: string) {}

  private getProc(): Proc | null {
    if (this.proc && this.proc.exitCode === null && !this.proc.killed) return this.proc;
    try {
      this.proc = Bun.spawn(['xdotool', '-'], {
        stdin: 'pipe',
        stdout: 'ignore',
        stderr: 'ignore',
        env: { ...process.env, DISPLAY: this.display },
      } as unknown as SpawnOpts);
      this.proc.exited.then(() => {
        this.proc = null;
      }).catch(() => {
        this.proc = null;
      });
      return this.proc;
    } catch {
      this.proc = null;
      return null;
    }
  }

  send(...lines: string[]): boolean {
    if (lines.length === 0) return true;
    const proc = this.getProc();
    if (!proc) return false;
    try {
      const stdin = proc.stdin as unknown as { write(s: string): unknown; flush?: () => void };
      stdin.write(lines.join('\n') + '\n');
      stdin.flush?.();
      return true;
    } catch {
      this.proc = null;
      return false;
    }
  }

  queueMove(x: number, y: number): void {
    this.pendingMove = { x, y };
    this.scheduleFlush();
  }

  queueScroll(dx: number, dy: number, x: number | undefined, y: number | undefined, mods: string[]): void {
    const cur = this.pendingScroll;
    if (cur && modsKey(cur.mods) === modsKey(mods)) {
      cur.dx += dx;
      cur.dy += dy;
      if (typeof x === 'number') cur.x = x;
      if (typeof y === 'number') cur.y = y;
    } else {
      if (cur) this.flush();
      this.pendingScroll = { dx, dy, x, y, mods };
    }
    this.scheduleFlush();
  }

  private scheduleFlush(): void {
    if (this.flushTimer != null) return;
    this.flushTimer = setTimeout(() => {
      this.flushTimer = null;
      this.flush();
    }, FLUSH_MS);
  }

  /** Push coalesced motion/scroll now. Discrete clicks call this first. */
  flush(): void {
    if (this.flushTimer != null) {
      clearTimeout(this.flushTimer);
      this.flushTimer = null;
    }
    const lines: string[] = [];
    const move = this.pendingMove;
    this.pendingMove = null;
    if (move) lines.push(`mousemove ${r(move.x)} ${r(move.y)}`);

    const scroll = this.pendingScroll;
    if (scroll) {
      const zoom = scroll.mods.includes('ctrl');
      if (zoom && Date.now() - this.lastZoomAt < MIN_ZOOM_INTERVAL_MS) {
        // Too soon for another zoom step — keep the bucket for the next slice.
        this.scheduleFlush();
      } else {
        this.pendingScroll = null;
        const px = zoom ? ZOOM_PX_PER_CLICK : SCROLL_PX_PER_CLICK;
        const max = zoom ? MAX_ZOOM_CLICKS_PER_FLUSH : MAX_SCROLL_CLICKS_PER_FLUSH;
        const v = takeClicksFromAccum(scroll.dy, px, max);
        const h = takeClicksFromAccum(scroll.dx, px, max);
        if (v.clicks !== 0 || h.clicks !== 0) {
          if (!move && typeof scroll.x === 'number' && typeof scroll.y === 'number') {
            lines.push(`mousemove ${r(scroll.x)} ${r(scroll.y)}`);
          }
          for (const m of scroll.mods) lines.push(`keydown ${m}`);
          if (v.clicks !== 0) {
            lines.push(`click --repeat ${Math.abs(v.clicks)} ${v.clicks > 0 ? '5' : '4'}`);
          }
          if (h.clicks !== 0) {
            lines.push(`click --repeat ${Math.abs(h.clicks)} ${h.clicks > 0 ? '7' : '6'}`);
          }
          for (const m of [...scroll.mods].reverse()) lines.push(`keyup ${m}`);
          if (zoom) this.lastZoomAt = Date.now();
        }
        // Tiny leftover (less than one click) is discarded on zoom so it
        // cannot combine with the next pinch into a surprise jump.
        if (!zoom && (v.rest !== 0 || h.rest !== 0)) {
          this.pendingScroll = {
            dx: h.rest,
            dy: v.rest,
            x: scroll.x,
            y: scroll.y,
            mods: scroll.mods,
          };
        }
      }
    }

    if (lines.length) this.send(...lines);
  }

  stop(): void {
    if (this.flushTimer != null) {
      clearTimeout(this.flushTimer);
      this.flushTimer = null;
    }
    this.pendingMove = null;
    this.pendingScroll = null;
    try {
      this.proc?.kill();
    } catch {
      // already gone
    }
    this.proc = null;
  }
}

const injectors = new Map<string, DisplayInjector>();

function forDisplay(display?: string): DisplayInjector {
  const key = display || DEFAULT_DISPLAY;
  let inj = injectors.get(key);
  if (!inj) {
    inj = new DisplayInjector(key);
    injectors.set(key, inj);
  }
  return inj;
}

function r(n: number): string {
  return String(Math.round(n));
}

function safeCombo(combo: string): boolean {
  return /^[A-Za-z0-9_+]+$/.test(combo) && combo.length <= 64;
}

/** Relative pointer move (trackpad / precision mode). Coalesced via abs path? no — relative must apply in order but we still skip --sync. */
export function mouseMove(dx: number, dy: number, display?: string): { ok: boolean } {
  if (dx === 0 && dy === 0) return { ok: true };
  return { ok: forDisplay(display).send(`mousemove_relative -- ${r(dx)} ${r(dy)}`) };
}

/** Absolute click. Flushes pending motion first; --sync only here (rare). */
export function mouseClick(
  button: 'left' | 'right' | 'middle',
  x?: number,
  y?: number,
  display?: string,
): { ok: boolean } {
  const inj = forDisplay(display);
  inj.flush();
  const b = MOUSE_BUTTON[button] ?? '1';
  const lines =
    typeof x === 'number' && typeof y === 'number'
      ? [`mousemove ${r(x)} ${r(y)}`, `click ${b}`]
      : [`click ${b}`];
  return { ok: inj.send(...lines) };
}

export function buttonDown(
  button: 'left' | 'right' | 'middle',
  x?: number,
  y?: number,
  display?: string,
): { ok: boolean } {
  const inj = forDisplay(display);
  inj.flush();
  const b = MOUSE_BUTTON[button] ?? '1';
  const lines: string[] = [];
  if (typeof x === 'number' && typeof y === 'number') lines.push(`mousemove ${r(x)} ${r(y)}`);
  lines.push(`mousedown ${b}`);
  return { ok: inj.send(...lines) };
}

export function buttonUp(
  button: 'left' | 'right' | 'middle',
  x?: number,
  y?: number,
  display?: string,
): { ok: boolean } {
  const inj = forDisplay(display);
  inj.flush();
  const b = MOUSE_BUTTON[button] ?? '1';
  const lines: string[] = [];
  if (typeof x === 'number' && typeof y === 'number') lines.push(`mousemove ${r(x)} ${r(y)}`);
  lines.push(`mouseup ${b}`);
  return { ok: inj.send(...lines) };
}

/** Absolute pointer move (drag). Latest position wins; never queues --sync. */
export function mouseMoveAbs(x: number, y: number, display?: string): { ok: boolean } {
  forDisplay(display).queueMove(x, y);
  return { ok: true };
}

/**
 * Wheel scroll / pinch-zoom. Deltas merge until the next 8ms flush; a delayed
 * burst cannot replay as twenty ctrl+wheel steps.
 */
export function mouseScroll(
  deltaX: number,
  deltaY: number,
  x?: number,
  y?: number,
  modifiers?: string[],
  display?: string,
): { ok: boolean } {
  const mods = (modifiers ?? []).filter(safeCombo);
  forDisplay(display).queueScroll(deltaX, deltaY, x, y, mods);
  return { ok: true };
}

export function keyEvent(key: string, modifiers?: string[], display?: string): { ok: boolean } {
  if (!key) return { ok: false };
  const combo = [...(modifiers ?? []), key].join('+');
  if (!safeCombo(combo)) return { ok: false };
  const inj = forDisplay(display);
  const pending = pendingText.get(display ?? '');
  if (pending) {
    void pending.then(() => {
      inj.flush();
      inj.send(`key ${combo}`);
    });
    return { ok: true };
  }
  inj.flush();
  return { ok: inj.send(`key ${combo}`) };
}

/** Text still being typed per display; each call is its own xdotool process, so later input must wait or it overtakes. */
const pendingText = new Map<string, Promise<void>>();

export function typeText(text: string, display?: string): { ok: boolean } {
  if (!text) return { ok: false };
  const key = display ?? '';
  const run = async (): Promise<void> => {
    try {
      const proc = Bun.spawn(['xdotool', 'type', '--delay', '8', '--', text.slice(0, 512)], {
        stdout: 'ignore',
        stderr: 'ignore',
        env: { ...process.env, DISPLAY: display || DEFAULT_DISPLAY },
      } as unknown as SpawnOpts);
      await proc.exited;
    } catch {
      // A failed xdotool must not block the input queued behind it.
    }
  };
  const next: Promise<void> = (pendingText.get(key) ?? Promise.resolve()).then(run).finally(() => {
    if (pendingText.get(key) === next) pendingText.delete(key);
  });
  pendingText.set(key, next);
  return { ok: true };
}

export function stopInjector(): void {
  for (const inj of injectors.values()) inj.stop();
  injectors.clear();
}
