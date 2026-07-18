// Host input injection via a single long-lived `xdotool -` process (script mode:
// one command per stdin line). Injection cost drops from a ~10-30ms process spawn
// per event to a pipe write, which is what makes scroll/drag feel native. The
// process is respawned lazily if it dies; ordering is inherent to the pipe.

const DISPLAY = process.env.DISPLAY || ':0';

// @types/bun in this workspace predates some stdio options (valid at runtime),
// so spawn options are passed through this loosely-typed alias.
type SpawnOpts = Parameters<typeof Bun.spawn>[1];

const MOUSE_BUTTON: Record<string, string> = { left: '1', middle: '2', right: '3' };

/** Host px per wheel click when translating a pixel scroll delta. */
const SCROLL_PX_PER_CLICK = 24;
const MAX_SCROLL_CLICKS = 15;

type Injector = ReturnType<typeof Bun.spawn>;

let injector: Injector | null = null;

function getInjector(): Injector | null {
  if (injector && injector.exitCode === null && !injector.killed) return injector;
  try {
    injector = Bun.spawn(['xdotool', '-'], {
      stdin: 'pipe',
      stdout: 'ignore',
      stderr: 'ignore',
      env: { ...process.env, DISPLAY },
    } as unknown as SpawnOpts);
    injector.exited.then(() => {
      // Lazy respawn on next command.
      injector = null;
    }).catch(() => {
      injector = null;
    });
    return injector;
  } catch {
    injector = null;
    return null;
  }
}

/**
 * Send xdotool script lines. Each line is one command; embedded newlines in
 * arguments are never allowed here (callers sanitize), so a malicious payload
 * cannot smuggle extra commands into the stream.
 */
function send(...lines: string[]): boolean {
  const proc = getInjector();
  if (!proc) return false;
  try {
    const stdin = proc.stdin as unknown as { write(s: string): unknown; flush?: () => void };
    stdin.write(lines.join('\n') + '\n');
    stdin.flush?.();
    return true;
  } catch {
    injector = null;
    return false;
  }
}

function r(n: number): string {
  return String(Math.round(n));
}

/** Allow only sane keysym combos (letters, digits, _, +) — e.g. "ctrl+shift+t". */
function safeCombo(combo: string): boolean {
  return /^[A-Za-z0-9_+]+$/.test(combo) && combo.length <= 64;
}

/** Relative pointer move (trackpad / precision mode). */
export function mouseMove(dx: number, dy: number): { ok: boolean } {
  if (dx === 0 && dy === 0) return { ok: true };
  return { ok: send(`mousemove_relative -- ${r(dx)} ${r(dy)}`) };
}

/** Absolute click (optionally moving to x,y first). */
export function mouseClick(button: 'left' | 'right' | 'middle', x?: number, y?: number): { ok: boolean } {
  const b = MOUSE_BUTTON[button] ?? '1';
  const lines =
    typeof x === 'number' && typeof y === 'number'
      ? [`mousemove ${r(x)} ${r(y)}`, `click ${b}`]
      : [`click ${b}`];
  return { ok: send(...lines) };
}

/** Press-and-hold a button at x,y (drag start). */
export function buttonDown(button: 'left' | 'right' | 'middle', x?: number, y?: number): { ok: boolean } {
  const b = MOUSE_BUTTON[button] ?? '1';
  const lines: string[] = [];
  if (typeof x === 'number' && typeof y === 'number') lines.push(`mousemove ${r(x)} ${r(y)}`);
  lines.push(`mousedown ${b}`);
  return { ok: send(...lines) };
}

/** Release a held button at x,y (drag end). */
export function buttonUp(button: 'left' | 'right' | 'middle', x?: number, y?: number): { ok: boolean } {
  const b = MOUSE_BUTTON[button] ?? '1';
  const lines: string[] = [];
  if (typeof x === 'number' && typeof y === 'number') lines.push(`mousemove ${r(x)} ${r(y)}`);
  lines.push(`mouseup ${b}`);
  return { ok: send(...lines) };
}

/** Absolute pointer move (drag motion). */
export function mouseMoveAbs(x: number, y: number): { ok: boolean } {
  return { ok: send(`mousemove ${r(x)} ${r(y)}`) };
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
): { ok: boolean } {
  const lines: string[] = [];
  if (typeof x === 'number' && typeof y === 'number' && (x !== 0 || y !== 0)) {
    lines.push(`mousemove ${r(x)} ${r(y)}`);
  }
  const mods = (modifiers ?? []).filter(safeCombo);
  for (const m of mods) lines.push(`keydown ${m}`);

  const vClicks = Math.min(MAX_SCROLL_CLICKS, Math.round(Math.abs(deltaY) / SCROLL_PX_PER_CLICK));
  if (vClicks > 0) {
    // xdotool: button 4 = wheel up, 5 = wheel down. deltaY>0 scrolls content down.
    lines.push(`click --repeat ${vClicks} ${deltaY > 0 ? '5' : '4'}`);
  }
  const hClicks = Math.min(MAX_SCROLL_CLICKS, Math.round(Math.abs(deltaX) / SCROLL_PX_PER_CLICK));
  if (hClicks > 0) {
    // button 6 = wheel left, 7 = wheel right.
    lines.push(`click --repeat ${hClicks} ${deltaX > 0 ? '7' : '6'}`);
  }

  for (const m of mods.reverse()) lines.push(`keyup ${m}`);
  if (lines.length === 0) return { ok: true };
  return { ok: send(...lines) };
}

/** Key event with optional modifiers, e.g. key='c', modifiers=['ctrl']. */
export function keyEvent(key: string, modifiers?: string[]): { ok: boolean } {
  if (!key) return { ok: false };
  const combo = [...(modifiers ?? []), key].join('+');
  if (!safeCombo(combo)) return { ok: false };
  return { ok: send(`key ${combo}`) };
}

/**
 * Type a literal string into the focused window (phone keyboard input).
 * Deliberately NOT routed through the script pipe: script mode whitespace-splits
 * arguments and would mangle spacing. A one-shot spawn passes the text as a
 * single argv entry, and typing is not latency-critical.
 */
export function typeText(text: string): { ok: boolean } {
  if (!text) return { ok: false };
  try {
    Bun.spawn(['xdotool', 'type', '--delay', '8', '--', text.slice(0, 512)], {
      stdout: 'ignore',
      stderr: 'ignore',
      env: { ...process.env, DISPLAY },
    } as unknown as SpawnOpts);
    return { ok: true };
  } catch {
    return { ok: false };
  }
}

/** Tear down the injector (tests / shutdown). */
export function stopInjector(): void {
  try {
    injector?.kill();
  } catch {
    // already gone
  }
  injector = null;
}
