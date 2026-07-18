// Host input injection via xdotool (X11). No Rust sidecar required — this is the
// pure-Bun Infrastructure Control path for LAN/X11 hosts. Commands are serialized
// through a promise chain so ordering is preserved, with backpressure that drops
// non-critical motion/scroll events when the queue backs up (clicks/keys never drop).

const DISPLAY = process.env.DISPLAY || ':0';

// @types/bun in this workspace predates the 'ignore' stdio option (valid at runtime),
// so spawn options are passed through this loosely-typed alias.
type SpawnOpts = Parameters<typeof Bun.spawn>[1];

const MOUSE_BUTTON: Record<string, string> = { left: '1', middle: '2', right: '3' };

/** Above this many queued commands, coalesce away motion/scroll to keep latency low. */
const MAX_PENDING = 8;
/** Host px per wheel click when translating a pixel scroll delta. */
const SCROLL_PX_PER_CLICK = 24;
const MAX_SCROLL_CLICKS = 15;

let chain: Promise<void> = Promise.resolve();
let pending = 0;

function runXdotool(args: string[]): Promise<void> {
  pending++;
  chain = chain
    .then(
      () =>
        new Promise<void>((resolve) => {
          try {
            const proc = Bun.spawn(['xdotool', ...args], {
              stdout: 'ignore',
              stderr: 'ignore',
              env: { ...process.env, DISPLAY },
            } as unknown as SpawnOpts);
            proc.exited.then(() => resolve()).catch(() => resolve());
          } catch {
            resolve();
          }
        }),
    )
    .catch(() => {})
    .finally(() => {
      pending--;
    });
  return chain;
}

function r(n: number): string {
  return String(Math.round(n));
}

/** Relative pointer move (trackpad / drag). Dropped under backpressure. */
export function mouseMove(dx: number, dy: number): { ok: boolean } {
  if (pending > MAX_PENDING) return { ok: true };
  if (dx === 0 && dy === 0) return { ok: true };
  void runXdotool(['mousemove_relative', '--', r(dx), r(dy)]);
  return { ok: true };
}

/** Absolute click (optionally moving to x,y first). Never dropped. */
export function mouseClick(button: 'left' | 'right' | 'middle', x?: number, y?: number): { ok: boolean } {
  const b = MOUSE_BUTTON[button] ?? '1';
  const args =
    typeof x === 'number' && typeof y === 'number'
      ? ['mousemove', r(x), r(y), 'click', b]
      : ['click', b];
  void runXdotool(args);
  return { ok: true };
}

/** Wheel scroll at an optional point. Pixel deltas → discrete wheel clicks. */
export function mouseScroll(deltaX: number, deltaY: number, x?: number, y?: number): { ok: boolean } {
  if (pending > MAX_PENDING) return { ok: true };
  if (typeof x === 'number' && typeof y === 'number' && (x !== 0 || y !== 0)) {
    void runXdotool(['mousemove', r(x), r(y)]);
  }
  const vClicks = Math.min(MAX_SCROLL_CLICKS, Math.round(Math.abs(deltaY) / SCROLL_PX_PER_CLICK));
  if (vClicks > 0) {
    // xdotool: button 4 = wheel up, 5 = wheel down. deltaY>0 scrolls content down.
    void runXdotool(['click', '--repeat', String(vClicks), deltaY > 0 ? '5' : '4']);
  }
  const hClicks = Math.min(MAX_SCROLL_CLICKS, Math.round(Math.abs(deltaX) / SCROLL_PX_PER_CLICK));
  if (hClicks > 0) {
    // button 6 = wheel left, 7 = wheel right.
    void runXdotool(['click', '--repeat', String(hClicks), deltaX > 0 ? '7' : '6']);
  }
  return { ok: true };
}

/** Key event with optional modifiers, e.g. key='c', modifiers=['ctrl']. Never dropped. */
export function keyEvent(key: string, modifiers?: string[]): { ok: boolean } {
  if (!key) return { ok: false };
  const combo = [...(modifiers ?? []), key].join('+');
  void runXdotool(['key', combo]);
  return { ok: true };
}

/** Type a literal string into the focused window (phone keyboard input). */
export function typeText(text: string): { ok: boolean } {
  if (!text) return { ok: false };
  // Cap per-call length so one runaway request can't wedge the input queue.
  void runXdotool(['type', '--delay', '8', '--', text.slice(0, 512)]);
  return { ok: true };
}
