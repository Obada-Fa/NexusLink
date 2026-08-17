// Host input injection via long-lived `xdotool -` processes (script mode: one
// command per stdin line). Injection cost drops from a ~10-30ms process spawn
// per event to a pipe write, which is what makes scroll/drag feel native.
//
// One injector per X display: the real desktop (default DISPLAY) and every
// virtual app session (:50+) each get their own xdotool process and their own
// scroll accumulator, so parallel sessions never interleave state.

const DEFAULT_DISPLAY = process.env.DISPLAY || ':0';

// @types/bun in this workspace predates some stdio options (valid at runtime),
// so spawn options are passed through this loosely-typed alias.
type SpawnOpts = Parameters<typeof Bun.spawn>[1];

const MOUSE_BUTTON: Record<string, string> = { left: '1', middle: '2', right: '3' };

/** Host px per wheel click when translating a pixel scroll delta. */
const SCROLL_PX_PER_CLICK = 24;
const MAX_SCROLL_CLICKS = 15;

type Proc = ReturnType<typeof Bun.spawn>;

class DisplayInjector {
  private proc: Proc | null = null;

  // Fractional wheel remainder carried across scroll messages. Touch scrolls
  // arrive as many small per-move deltas (often < SCROLL_PX_PER_CLICK each);
  // rounding every message independently drops them, which kills slow scrolls
  // and inertia tails. Sign flips drain the remainder naturally.
  scrollAccumX = 0;
  scrollAccumY = 0;

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
        this.proc = null; // lazy respawn on next command
      }).catch(() => {
        this.proc = null;
      });
      return this.proc;
    } catch {
      this.proc = null;
      return null;
    }
  }

  /**
   * Send xdotool script lines. Each line is one command; embedded newlines in
   * arguments are never allowed here (callers sanitize), so a malicious payload
   * cannot smuggle extra commands into the stream.
   */
  send(...lines: string[]): boolean {
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

  stop(): void {
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

/** Allow only sane keysym combos (letters, digits, _, +) — e.g. "ctrl+shift+t". */
function safeCombo(combo: string): boolean {
  return /^[A-Za-z0-9_+]+$/.test(combo) && combo.length <= 64;
}

/** Relative pointer move (trackpad / precision mode). */
export function mouseMove(dx: number, dy: number, display?: string): { ok: boolean } {
  if (dx === 0 && dy === 0) return { ok: true };
  return { ok: forDisplay(display).send(`mousemove_relative -- ${r(dx)} ${r(dy)}`) };
}

/** Absolute click (optionally moving to x,y first). */
export function mouseClick(
  button: 'left' | 'right' | 'middle',
  x?: number,
  y?: number,
  display?: string,
): { ok: boolean } {
  const b = MOUSE_BUTTON[button] ?? '1';
  const lines =
    typeof x === 'number' && typeof y === 'number'
      ? [`mousemove --sync ${r(x)} ${r(y)}`, `click ${b}`]
      : [`click ${b}`];
  return { ok: forDisplay(display).send(...lines) };
}

/** Press-and-hold a button at x,y (drag start). */
export function buttonDown(
  button: 'left' | 'right' | 'middle',
  x?: number,
  y?: number,
  display?: string,
): { ok: boolean } {
  const b = MOUSE_BUTTON[button] ?? '1';
  const lines: string[] = [];
  if (typeof x === 'number' && typeof y === 'number') lines.push(`mousemove --sync ${r(x)} ${r(y)}`);
  lines.push(`mousedown ${b}`);
  return { ok: forDisplay(display).send(...lines) };
}

/** Release a held button at x,y (drag end). */
export function buttonUp(
  button: 'left' | 'right' | 'middle',
  x?: number,
  y?: number,
  display?: string,
): { ok: boolean } {
  const b = MOUSE_BUTTON[button] ?? '1';
  const lines: string[] = [];
  if (typeof x === 'number' && typeof y === 'number') lines.push(`mousemove --sync ${r(x)} ${r(y)}`);
  lines.push(`mouseup ${b}`);
  return { ok: forDisplay(display).send(...lines) };
}

/** Absolute pointer move (drag motion). */
export function mouseMoveAbs(x: number, y: number, display?: string): { ok: boolean } {
  return { ok: forDisplay(display).send(`mousemove --sync ${r(x)} ${r(y)}`) };
}

function takeClicks(inj: DisplayInjector, axis: 'x' | 'y', delta: number): number {
  const accum = (axis === 'x' ? inj.scrollAccumX : inj.scrollAccumY) + delta;
  let clicks = Math.trunc(accum / SCROLL_PX_PER_CLICK);
  let rest = accum - clicks * SCROLL_PX_PER_CLICK;
  if (Math.abs(clicks) > MAX_SCROLL_CLICKS) {
    // Burst cap: clamp and drop the excess instead of queueing a catch-up.
    clicks = Math.sign(clicks) * MAX_SCROLL_CLICKS;
    rest = 0;
  }
  if (axis === 'x') inj.scrollAccumX = rest;
  else inj.scrollAccumY = rest;
  return clicks;
}

/**
 * Wheel scroll at an optional point. Pixel deltas → discrete wheel clicks.
 * With `modifiers` (e.g. ['ctrl']) the wheel fires inside a keydown/keyup
 * bracket — this is how pinch-zoom reaches the host.
 */
export function mouseScroll(
  deltaX: number,
  deltaY: number,
  x?: number,
  y?: number,
  modifiers?: string[],
  display?: string,
): { ok: boolean } {
  const inj = forDisplay(display);
  const lines: string[] = [];
  if (typeof x === 'number' && typeof y === 'number' && (x !== 0 || y !== 0)) {
    lines.push(`mousemove --sync ${r(x)} ${r(y)}`);
  }
  const mods = (modifiers ?? []).filter(safeCombo);
  for (const m of mods) lines.push(`keydown ${m}`);

  const vClicks = takeClicks(inj, 'y', deltaY);
  if (vClicks !== 0) {
    // xdotool: button 4 = wheel up, 5 = wheel down. deltaY>0 scrolls content down.
    lines.push(`click --repeat ${Math.abs(vClicks)} ${vClicks > 0 ? '5' : '4'}`);
  }
  const hClicks = takeClicks(inj, 'x', deltaX);
  if (hClicks !== 0) {
    // button 6 = wheel left, 7 = wheel right.
    lines.push(`click --repeat ${Math.abs(hClicks)} ${hClicks > 0 ? '7' : '6'}`);
  }

  for (const m of mods.reverse()) lines.push(`keyup ${m}`);
  if (lines.length === 0) return { ok: true };
  return { ok: inj.send(...lines) };
}

/** Key event with optional modifiers, e.g. key='c', modifiers=['ctrl']. */
export function keyEvent(key: string, modifiers?: string[], display?: string): { ok: boolean } {
  if (!key) return { ok: false };
  const combo = [...(modifiers ?? []), key].join('+');
  if (!safeCombo(combo)) return { ok: false };
  return { ok: forDisplay(display).send(`key ${combo}`) };
}

/**
 * Type a literal string into the focused window (phone keyboard input).
 * Deliberately NOT routed through the script pipe: script mode whitespace-splits
 * arguments and would mangle spacing. A one-shot spawn passes the text as a
 * single argv entry, and typing is not latency-critical.
 */
export function typeText(text: string, display?: string): { ok: boolean } {
  if (!text) return { ok: false };
  try {
    Bun.spawn(['xdotool', 'type', '--delay', '8', '--', text.slice(0, 512)], {
      stdout: 'ignore',
      stderr: 'ignore',
      env: { ...process.env, DISPLAY: display || DEFAULT_DISPLAY },
    } as unknown as SpawnOpts);
    return { ok: true };
  } catch {
    return { ok: false };
  }
}

/** Tear down all injectors (tests / shutdown). */
export function stopInjector(): void {
  for (const inj of injectors.values()) inj.stop();
  injectors.clear();
}
