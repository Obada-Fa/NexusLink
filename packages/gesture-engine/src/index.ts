// NexusLink Gesture Engine v2
//
// Direct-manipulation touch translation (architecture.md Module C). The default
// `direct` mode treats the finger as touching content at an absolute host
// coordinate: a one-finger pan is a momentum scroll, not a cursor drag. The legacy
// relative-cursor behaviour survives as `trackpad` mode (a.k.a. Precision mode).
//
// Public surface (`GestureEngine`, `attach`/`detach`, `setHostDimensions`,
// `scaleToHost`, and the exported sensitivity constants) is preserved. Internals
// are delegated to ./classifier, ./scroll-physics, and ./input-mapper.

import {
  resolveAxis,
  projectToAxis,
  isTap,
  isDoubleTap,
  type Axis,
  type GestureState,
} from './classifier';
import {
  ScrollVelocityTracker,
  decayVelocity,
  SCROLL_INERTIA_LAMBDA,
  SCROLL_INERTIA_MIN_VELOCITY,
  SCROLL_INERTIA_STOP_VELOCITY,
} from './scroll-physics';

export * from './scroll-physics';
export * from './classifier';
export * from './input-mapper';

// --- Preserved public constants (the trackpad-mode tuning contract) ---
export const PAN_SENSITIVITY = 5;
export const SCROLL_SENSITIVITY = 10;
export const LONGPRESS_THRESHOLD_MS = 500;
export const LONGPRESS_MAX_MOVE_PX = 10;

// --- v2 tuning ---
/** Precision mode divides relative cursor deltas by this for fine control. */
export const PRECISION_DIVISOR = 3;
/** Minimum pinch-distance change (px) before a two-finger gesture reads as zoom. */
export const PINCH_MIN_DELTA_PX = 6;
/** Screen-px → zoom-scale factor per pinch step. */
export const PINCH_ZOOM_SCALE = 0.005;

export type GestureMode = 'direct' | 'trackpad';

export type GestureEvent =
  | { type: 'mouse-move'; dx: number; dy: number }
  | { type: 'mouse-click'; button: 'left' | 'right' | 'middle'; x: number; y: number }
  | { type: 'mouse-dbl-click'; x: number; y: number }
  | { type: 'mouse-scroll'; deltaX: number; deltaY: number; x: number; y: number; inertial?: boolean }
  | { type: 'drag-start'; x: number; y: number }
  | { type: 'drag-move'; x: number; y: number }
  | { type: 'drag-end'; x: number; y: number }
  | { type: 'zoom'; scale: number; x: number; y: number };

export type GestureCallbacks = {
  onGesture: (event: GestureEvent) => void;
};

/** Injectable frame scheduler so momentum inertia is deterministically testable. */
export interface FrameScheduler {
  now(): number;
  request(cb: (t: number) => void): number;
  cancel(id: number): void;
}

export interface GestureOptions {
  /** 'direct' (default): one-finger pan = momentum scroll. 'trackpad': relative cursor. */
  mode?: GestureMode;
  /** Force relative-cursor control with reduced sensitivity (overrides mode). */
  precision?: boolean;
  /** Frame scheduler for inertia; defaults to rAF (browser) or setTimeout. */
  scheduler?: FrameScheduler;
  /** Clock for durations/timestamps; defaults to Date.now. */
  now?: () => number;
}

function defaultScheduler(): FrameScheduler {
  const clock =
    typeof performance !== 'undefined' && typeof performance.now === 'function'
      ? () => performance.now()
      : () => Date.now();
  if (typeof requestAnimationFrame === 'function') {
    return {
      now: clock,
      request: (cb) => requestAnimationFrame(cb),
      cancel: (id) => cancelAnimationFrame(id),
    };
  }
  return {
    now: clock,
    request: (cb) => setTimeout(() => cb(clock()), 16) as unknown as number,
    cancel: (id) => clearTimeout(id),
  };
}

/**
 * Map a touch point within a (possibly letterboxed) view element to the
 * corresponding pixel on the host screen. Unchanged from v1.
 */
export function scaleToHost(
  touchX: number,
  touchY: number,
  viewWidth: number,
  viewHeight: number,
  hostWidth: number,
  hostHeight: number,
): { x: number; y: number } {
  if (viewWidth <= 0 || viewHeight <= 0 || hostWidth <= 0 || hostHeight <= 0) {
    return { x: 0, y: 0 };
  }

  const hostAspect = hostWidth / hostHeight;
  const viewAspect = viewWidth / viewHeight;

  let contentWidth: number;
  let contentHeight: number;
  let offsetX: number;
  let offsetY: number;

  // object-fit: contain / BoxFit.contain:
  // - view relatively wider → fit height, letterbox left/right
  // - view relatively taller → fit width, letterbox top/bottom
  if (viewAspect > hostAspect) {
    contentHeight = viewHeight;
    contentWidth = viewHeight * hostAspect;
    offsetX = (viewWidth - contentWidth) / 2;
    offsetY = 0;
  } else {
    contentWidth = viewWidth;
    contentHeight = viewWidth / hostAspect;
    offsetX = 0;
    offsetY = (viewHeight - contentHeight) / 2;
  }

  if (contentWidth <= 0 || contentHeight <= 0) {
    return { x: 0, y: 0 };
  }

  const scaledX = ((touchX - offsetX) / contentWidth) * hostWidth;
  const scaledY = ((touchY - offsetY) / contentHeight) * hostHeight;

  return {
    x: Math.max(0, Math.min(hostWidth, Math.round(scaledX))),
    y: Math.max(0, Math.min(hostHeight, Math.round(scaledY))),
  };
}

export class GestureEngine {
  private element: HTMLElement;
  private callbacks: GestureCallbacks | null;
  private attached = false;

  private mode: GestureMode;
  private precision: boolean;
  private readonly scheduler: FrameScheduler;
  private readonly now: () => number;

  private hostWidth = 1920;
  private hostHeight = 1080;
  private viewWidth = 0;
  private viewHeight = 0;
  private viewOffsetX = 0;
  private viewOffsetY = 0;

  private state: GestureState = 'idle';
  private longPressTimer: ReturnType<typeof setTimeout> | null = null;
  private longPressFired = false;

  private startPos: { x: number; y: number } | null = null;
  private startTime = 0;
  private lastPos: { x: number; y: number } | null = null;
  private lastTapTime = 0;
  private lastTapPos: { x: number; y: number } | null = null;

  private axis: Axis = 'none';
  private dragStarted = false;
  private maxTouches = 0;

  // Scroll accumulation (fractional host px carried between emits).
  private scrollCarryX = 0;
  private scrollCarryY = 0;
  private moveAccumDx = 0;
  private moveAccumDy = 0;
  private readonly velocity = new ScrollVelocityTracker();
  private inertiaId: number | null = null;

  // Two-finger state.
  private prevScrollMid: { x: number; y: number } | null = null;
  private prevPinchDist = 0;

  private resizeObserver: ResizeObserver | null = null;

  constructor(element: HTMLElement, callbacks: GestureCallbacks, options: GestureOptions = {}) {
    this.element = element;
    this.callbacks = callbacks;
    this.mode = options.mode ?? 'direct';
    this.precision = options.precision ?? false;
    this.scheduler = options.scheduler ?? defaultScheduler();
    this.now = options.now ?? (() => Date.now());
  }

  attach(): void {
    if (this.attached) return;
    this.attached = true;

    this.element.addEventListener('touchstart', this.onTouchStart, { passive: false });
    this.element.addEventListener('touchmove', this.onTouchMove, { passive: false });
    this.element.addEventListener('touchend', this.onTouchEnd);
    this.element.addEventListener('touchcancel', this.onTouchEnd);

    this.updateElementDimensions();
    if (typeof ResizeObserver !== 'undefined') {
      this.resizeObserver = new ResizeObserver(() => this.updateElementDimensions());
      this.resizeObserver.observe(this.element);
    }
  }

  detach(): void {
    if (!this.attached) return;
    this.attached = false;

    this.element.removeEventListener('touchstart', this.onTouchStart);
    this.element.removeEventListener('touchmove', this.onTouchMove);
    this.element.removeEventListener('touchend', this.onTouchEnd);
    this.element.removeEventListener('touchcancel', this.onTouchEnd);

    this.resizeObserver?.disconnect();
    this.resizeObserver = null;

    this.clearLongPressTimer();
    this.cancelInertia();
    this.resetState();
  }

  setHostDimensions(width: number, height: number): void {
    this.hostWidth = width;
    this.hostHeight = height;
  }

  setCallbacks(callbacks: GestureCallbacks): void {
    this.callbacks = callbacks;
  }

  setMode(mode: GestureMode): void {
    this.mode = mode;
  }

  setPrecision(precision: boolean): void {
    this.precision = precision;
  }

  get isAttached(): boolean {
    return this.attached;
  }

  /** Effective mode: precision forces relative-cursor (trackpad) behaviour. */
  private effectiveMode(): GestureMode {
    return this.precision ? 'trackpad' : this.mode;
  }

  private emit(gesture: GestureEvent): void {
    this.callbacks?.onGesture(gesture);
  }

  private updateElementDimensions(): void {
    const rect = this.element.getBoundingClientRect();
    this.viewWidth = rect.width;
    this.viewHeight = rect.height;
    this.viewOffsetX = rect.left;
    this.viewOffsetY = rect.top;
  }

  private toHost(touch: Touch): { x: number; y: number } {
    return scaleToHost(
      touch.clientX - this.viewOffsetX,
      touch.clientY - this.viewOffsetY,
      this.viewWidth,
      this.viewHeight,
      this.hostWidth,
      this.hostHeight,
    );
  }

  private dist(a: { x: number; y: number }, b: { x: number; y: number }): number {
    return Math.hypot(a.x - b.x, a.y - b.y);
  }

  private clearLongPressTimer(): void {
    if (this.longPressTimer !== null) {
      clearTimeout(this.longPressTimer);
      this.longPressTimer = null;
    }
  }

  private cancelInertia(): void {
    if (this.inertiaId !== null) {
      this.scheduler.cancel(this.inertiaId);
      this.inertiaId = null;
    }
  }

  private resetState(): void {
    this.startPos = null;
    this.lastPos = null;
    this.prevScrollMid = null;
    this.prevPinchDist = 0;
    this.moveAccumDx = 0;
    this.moveAccumDy = 0;
    this.scrollCarryX = 0;
    this.scrollCarryY = 0;
    this.longPressFired = false;
    this.dragStarted = false;
    this.axis = 'none';
    this.maxTouches = 0;
    this.state = 'idle';
  }

  private beginSingleTouch(touch: Touch): void {
    const host = this.toHost(touch);
    this.startPos = host;
    this.startTime = this.now();
    this.lastPos = host;
    this.axis = 'none';
    this.scrollCarryX = 0;
    this.scrollCarryY = 0;
    this.moveAccumDx = 0;
    this.moveAccumDy = 0;
    this.longPressFired = false;
    this.dragStarted = false;
    this.velocity.reset();
    this.state = 'undecided';

    this.clearLongPressTimer();
    this.longPressTimer = setTimeout(() => {
      this.longPressFired = true;
      this.clearLongPressTimer();
      this.state = 'longpress-pending';
      if (this.startPos) {
        this.emit({ type: 'mouse-click', button: 'right', x: this.startPos.x, y: this.startPos.y });
      }
    }, LONGPRESS_THRESHOLD_MS);
  }

  private onTouchStart = (e: TouchEvent): void => {
    e.preventDefault();
    this.cancelInertia(); // finger-catch: a new touch stops any running fling
    this.maxTouches = Math.max(this.maxTouches, e.touches.length);

    if (e.touches.length === 1) {
      this.beginSingleTouch(e.touches[0]!);
    } else if (e.touches.length >= 2) {
      this.clearLongPressTimer();
      this.longPressFired = false;
      this.state = 'pinching';
      const t0 = e.touches[0]!;
      const t1 = e.touches[1]!;
      // Anchor + start time so a 3-finger tap (no movement) can resolve to a click.
      this.startPos = this.toHost(t0);
      this.startTime = this.now();
      this.lastPos = this.startPos;
      this.prevScrollMid = {
        x: (t0.clientX + t1.clientX) / 2,
        y: (t0.clientY + t1.clientY) / 2,
      };
      this.prevPinchDist = Math.hypot(t0.clientX - t1.clientX, t0.clientY - t1.clientY);
    }
  };

  private onTouchMove = (e: TouchEvent): void => {
    e.preventDefault();
    this.maxTouches = Math.max(this.maxTouches, e.touches.length);

    if (e.touches.length === 1) {
      this.handleSingleMove(e.touches[0]!);
    } else if (e.touches.length >= 2) {
      this.handleMultiMove(e.touches[0]!, e.touches[1]!);
    }
  };

  private handleSingleMove(touch: Touch): void {
    const host = this.toHost(touch);

    // Held-then-move => drag (long press already emitted its context click).
    if (this.longPressFired) {
      if (!this.dragStarted) {
        this.dragStarted = true;
        this.state = 'dragging';
        this.emit({ type: 'drag-start', x: host.x, y: host.y });
      } else {
        this.emit({ type: 'drag-move', x: host.x, y: host.y });
      }
      this.lastPos = host;
      return;
    }

    if (!this.lastPos || !this.startPos) {
      this.lastPos = host;
      return;
    }

    // Any real movement past the long-press slop cancels the pending long press.
    if (this.dist(host, this.startPos) > LONGPRESS_MAX_MOVE_PX) {
      this.clearLongPressTimer();
    }

    const rawDx = host.x - this.lastPos.x;
    const rawDy = host.y - this.lastPos.y;

    if (this.effectiveMode() === 'direct') {
      this.state = 'scrolling';
      // Lock axis once travel is decisive.
      if (this.axis === 'none') {
        this.axis = resolveAxis(host.x - this.startPos.x, host.y - this.startPos.y);
      }
      const proj = projectToAxis(rawDx, rawDy, this.axis);
      // Content tracks the finger: scroll delta is opposite to finger travel.
      const sdx = -proj.dx;
      const sdy = -proj.dy;
      this.velocity.addSample(sdx, sdy, this.now());
      this.scrollCarryX += sdx;
      this.scrollCarryY += sdy;
      const ix = Math.trunc(this.scrollCarryX);
      const iy = Math.trunc(this.scrollCarryY);
      if (ix !== 0 || iy !== 0) {
        this.scrollCarryX -= ix;
        this.scrollCarryY -= iy;
        this.emit({ type: 'mouse-scroll', deltaX: ix, deltaY: iy, x: host.x, y: host.y });
      }
    } else {
      // Trackpad: relative cursor movement.
      this.state = 'panning';
      const divisor = this.precision ? PRECISION_DIVISOR : 1;
      this.moveAccumDx += rawDx / divisor;
      this.moveAccumDy += rawDy / divisor;
      if (
        Math.abs(this.moveAccumDx) >= PAN_SENSITIVITY ||
        Math.abs(this.moveAccumDy) >= PAN_SENSITIVITY
      ) {
        const dx = Math.trunc(this.moveAccumDx);
        const dy = Math.trunc(this.moveAccumDy);
        if (dx !== 0 || dy !== 0) {
          this.emit({ type: 'mouse-move', dx, dy });
        }
        this.moveAccumDx -= dx;
        this.moveAccumDy -= dy;
      }
    }

    this.lastPos = host;
  }

  private handleMultiMove(t0: Touch, t1: Touch): void {
    this.clearLongPressTimer();
    this.state = 'pinching';

    const midX = (t0.clientX + t1.clientX) / 2;
    const midY = (t0.clientY + t1.clientY) / 2;
    const pinchDist = Math.hypot(t0.clientX - t1.clientX, t0.clientY - t1.clientY);

    const panDx = this.prevScrollMid ? midX - this.prevScrollMid.x : 0;
    const panDy = this.prevScrollMid ? midY - this.prevScrollMid.y : 0;
    const pinchDelta = pinchDist - this.prevPinchDist;

    const host = this.toHost(t0);

    // Pinch dominates over pan → zoom; otherwise two-finger pan → scroll.
    if (Math.abs(pinchDelta) >= PINCH_MIN_DELTA_PX && Math.abs(pinchDelta) > Math.hypot(panDx, panDy)) {
      this.emit({ type: 'zoom', scale: pinchDelta * PINCH_ZOOM_SCALE, x: host.x, y: host.y });
    } else {
      // Content tracks the fingers.
      this.scrollCarryX += -panDx;
      this.scrollCarryY += -panDy;
      const ix = Math.trunc(this.scrollCarryX);
      const iy = Math.trunc(this.scrollCarryY);
      if (ix !== 0 || iy !== 0) {
        this.scrollCarryX -= ix;
        this.scrollCarryY -= iy;
        this.emit({ type: 'mouse-scroll', deltaX: ix, deltaY: iy, x: host.x, y: host.y });
      }
    }

    this.prevScrollMid = { x: midX, y: midY };
    this.prevPinchDist = pinchDist;
  }

  private onTouchEnd = (e: TouchEvent): void => {
    if (e.touches.length === 0) {
      this.finishGesture();
    } else if (e.touches.length === 1) {
      // Lifted from multi-touch back to single: restart a fresh single-touch track.
      this.prevScrollMid = null;
      this.beginSingleTouch(e.touches[0]!);
    }
  };

  private finishGesture(): void {
    this.clearLongPressTimer();

    // Drag release.
    if (this.dragStarted) {
      const p = this.lastPos ?? this.startPos;
      if (p) this.emit({ type: 'drag-end', x: p.x, y: p.y });
      this.resetState();
      return;
    }

    // Long press already emitted its context click; nothing more on release.
    if (this.longPressFired) {
      this.resetState();
      return;
    }

    // Three-finger tap → middle click.
    if (this.maxTouches >= 3 && this.startPos && this.state !== 'scrolling') {
      const moved = this.lastPos ? this.dist(this.startPos, this.lastPos) : 0;
      const duration = this.now() - this.startTime;
      if (isTap(duration, moved)) {
        this.emit({ type: 'mouse-click', button: 'middle', x: this.startPos.x, y: this.startPos.y });
        this.resetState();
        return;
      }
    }

    if (this.startPos && this.state !== 'pinching') {
      const moved = this.lastPos ? this.dist(this.startPos, this.lastPos) : 0;
      const duration = this.now() - this.startTime;

      if (isTap(duration, moved) && this.maxTouches < 2) {
        const now = this.now();
        const gap = now - this.lastTapTime;
        const tapDist = this.lastTapPos ? this.dist(this.startPos, this.lastTapPos) : Infinity;

        if (this.lastTapTime > 0 && isDoubleTap(gap, tapDist)) {
          this.emit({ type: 'mouse-dbl-click', x: this.startPos.x, y: this.startPos.y });
          this.lastTapTime = 0;
          this.lastTapPos = null;
          this.resetState();
          return;
        }

        this.emit({ type: 'mouse-click', button: 'left', x: this.startPos.x, y: this.startPos.y });
        this.lastTapTime = now;
        this.lastTapPos = { ...this.startPos };
        this.resetState();
        return;
      }

      // A one-finger direct scroll that ended with velocity → momentum fling.
      if (this.effectiveMode() === 'direct' && this.state === 'scrolling') {
        this.startInertia();
      }
    }

    this.resetState();
  }

  private startInertia(): void {
    const { vx, vy } = this.velocity.velocity;
    const speed = Math.hypot(vx, vy);
    if (speed < SCROLL_INERTIA_MIN_VELOCITY) return;

    const anchorX = this.lastPos?.x ?? 0;
    const anchorY = this.lastPos?.y ?? 0;
    const startT = this.scheduler.now();
    let lastT = startT;
    let carryX = 0;
    let carryY = 0;

    const tick = (t: number): void => {
      const dtSec = Math.max(0, (t - lastT) / 1000);
      lastT = t;
      const elapsed = (t - startT) / 1000;
      if (decayVelocity(speed, elapsed) < SCROLL_INERTIA_STOP_VELOCITY) {
        this.inertiaId = null;
        return;
      }
      const vxNow = vx * Math.exp(-SCROLL_INERTIA_LAMBDA * elapsed);
      const vyNow = vy * Math.exp(-SCROLL_INERTIA_LAMBDA * elapsed);
      carryX += vxNow * dtSec;
      carryY += vyNow * dtSec;
      const ix = Math.trunc(carryX);
      const iy = Math.trunc(carryY);
      if (ix !== 0 || iy !== 0) {
        carryX -= ix;
        carryY -= iy;
        this.emit({ type: 'mouse-scroll', deltaX: ix, deltaY: iy, x: anchorX, y: anchorY, inertial: true });
      }
      this.inertiaId = this.scheduler.request(tick);
    };

    this.inertiaId = this.scheduler.request(tick);
  }
}
