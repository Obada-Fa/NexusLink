export const PAN_SENSITIVITY = 5;
export const SCROLL_SENSITIVITY = 10;
export const LONGPRESS_THRESHOLD_MS = 500;
export const LONGPRESS_MAX_MOVE_PX = 10;

const DOUBLE_TAP_THRESHOLD_MS = 300;
const DOUBLE_TAP_MAX_MOVE_PX = 30;

export type GestureEvent =
  | { type: 'mouse-move'; dx: number; dy: number }
  | { type: 'mouse-click'; button: 'left' | 'right' | 'middle'; x: number; y: number }
  | { type: 'mouse-dbl-click'; x: number; y: number }
  | { type: 'mouse-scroll'; deltaX: number; deltaY: number; x: number; y: number };

export type GestureCallbacks = {
  onGesture: (event: GestureEvent) => void;
};

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

  if (viewAspect > hostAspect) {
    contentWidth = viewWidth;
    contentHeight = viewWidth / hostAspect;
    offsetX = 0;
    offsetY = (viewHeight - contentHeight) / 2;
  } else {
    contentHeight = viewHeight;
    contentWidth = viewHeight * hostAspect;
    offsetX = (viewWidth - contentWidth) / 2;
    offsetY = 0;
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

  private hostWidth = 1920;
  private hostHeight = 1080;
  private viewWidth = 0;
  private viewHeight = 0;
  private viewOffsetX = 0;
  private viewOffsetY = 0;

  private longPressTimer: ReturnType<typeof setTimeout> | null = null;
  private longPressFired = false;

  private startPos: { x: number; y: number } | null = null;
  private startTime = 0;
  private lastPos: { x: number; y: number } | null = null;
  private lastTapTime = 0;
  private lastTapPos: { x: number; y: number } | null = null;

  private prevScrollMid: { x: number; y: number } | null = null;
  private activeTouches = 0;

  private moveAccumDx = 0;
  private moveAccumDy = 0;

  private resizeObserver: ResizeObserver | null = null;

  constructor(element: HTMLElement, callbacks: GestureCallbacks) {
    this.element = element;
    this.callbacks = callbacks;
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
    this.resetState();
  }

  setHostDimensions(width: number, height: number): void {
    this.hostWidth = width;
    this.hostHeight = height;
  }

  setCallbacks(callbacks: GestureCallbacks): void {
    this.callbacks = callbacks;
  }

  get isAttached(): boolean {
    return this.attached;
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
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return Math.sqrt(dx * dx + dy * dy);
  }

  private clearLongPressTimer(): void {
    if (this.longPressTimer !== null) {
      clearTimeout(this.longPressTimer);
      this.longPressTimer = null;
    }
  }

  private resetState(): void {
    this.startPos = null;
    this.lastPos = null;
    this.prevScrollMid = null;
    this.moveAccumDx = 0;
    this.moveAccumDy = 0;
    this.longPressFired = false;
    this.activeTouches = 0;
  }

  private onTouchStart = (e: TouchEvent): void => {
    e.preventDefault();
    this.activeTouches = e.touches.length;

    if (e.touches.length === 1) {
      const touch = e.touches[0]!;
      const host = this.toHost(touch);
      this.startPos = host;
      this.startTime = Date.now();
      this.lastPos = host;
      this.moveAccumDx = 0;
      this.moveAccumDy = 0;
      this.longPressFired = false;

      this.clearLongPressTimer();
      this.longPressTimer = setTimeout(() => {
        this.longPressFired = true;
        this.clearLongPressTimer();
        if (this.startPos) {
          this.emit({
            type: 'mouse-click',
            button: 'right',
            x: this.startPos.x,
            y: this.startPos.y,
          });
        }
      }, LONGPRESS_THRESHOLD_MS);
    } else if (e.touches.length >= 2) {
      this.clearLongPressTimer();
      this.longPressFired = false;
      const t0 = e.touches[0]!;
      const t1 = e.touches[1]!;
      this.prevScrollMid = {
        x: (t0.clientX + t1.clientX) / 2,
        y: (t0.clientY + t1.clientY) / 2,
      };
    }
  };

  private onTouchMove = (e: TouchEvent): void => {
    e.preventDefault();

    if (e.touches.length === 1 && !this.longPressFired) {
      const touch = e.touches[0]!;
      const host = this.toHost(touch);

      if (this.startPos) {
        const moved = this.dist(host, this.startPos);
        if (moved > LONGPRESS_MAX_MOVE_PX) {
          this.clearLongPressTimer();
        }
      }

      if (this.lastPos) {
        this.moveAccumDx += host.x - this.lastPos.x;
        this.moveAccumDy += host.y - this.lastPos.y;

        if (Math.abs(this.moveAccumDx) >= PAN_SENSITIVITY || Math.abs(this.moveAccumDy) >= PAN_SENSITIVITY) {
          this.clearLongPressTimer();
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
    } else if (e.touches.length >= 2) {
      this.clearLongPressTimer();
      const t0 = e.touches[0]!;
      const t1 = e.touches[1]!;
      const midX = (t0.clientX + t1.clientX) / 2;
      const midY = (t0.clientY + t1.clientY) / 2;

      if (this.prevScrollMid) {
        const rawDX = midX - this.prevScrollMid.x;
        const rawDY = midY - this.prevScrollMid.y;

        const sx = Math.abs(rawDX) >= SCROLL_SENSITIVITY ? Math.trunc(rawDX / SCROLL_SENSITIVITY) : 0;
        const sy = Math.abs(rawDY) >= SCROLL_SENSITIVITY ? Math.trunc(rawDY / SCROLL_SENSITIVITY) : 0;

        if (sx !== 0 || sy !== 0) {
          const host = this.toHost(t0);
          this.emit({
            type: 'mouse-scroll',
            deltaX: -sx,
            deltaY: sy,
            x: host.x,
            y: host.y,
          });
        }
      }

      this.prevScrollMid = { x: midX, y: midY };
    }
  };

  private onTouchEnd = (e: TouchEvent): void => {
    this.clearLongPressTimer();

    if (e.touches.length === 0) {
      const now = Date.now();

      if (this.longPressFired) {
        this.resetState();
        return;
      }

      if (this.startPos) {
        const moved = this.lastPos ? this.dist(this.startPos, this.lastPos) : 0;
        const touchDuration = now - this.startTime;

        if (moved < PAN_SENSITIVITY && touchDuration < LONGPRESS_THRESHOLD_MS) {
          const dt = now - this.lastTapTime;
          const dTap = this.lastTapPos ? this.dist(this.startPos, this.lastTapPos) : Infinity;

          if (this.lastTapTime > 0 && dt < DOUBLE_TAP_THRESHOLD_MS && dTap < DOUBLE_TAP_MAX_MOVE_PX) {
            this.emit({
              type: 'mouse-dbl-click',
              x: this.startPos.x,
              y: this.startPos.y,
            });
            this.lastTapTime = 0;
            this.lastTapPos = null;
            this.resetState();
            return;
          }

          this.emit({
            type: 'mouse-click',
            button: 'left',
            x: this.startPos.x,
            y: this.startPos.y,
          });
          this.lastTapTime = now;
          this.lastTapPos = { ...this.startPos };
        }
      }

      this.resetState();
    } else if (e.touches.length === 1) {
      this.activeTouches = 1;
      this.prevScrollMid = null;
      this.longPressFired = false;
      const touch = e.touches[0]!;
      const host = this.toHost(touch);
      this.startPos = host;
      this.startTime = Date.now();
      this.lastPos = host;
      this.moveAccumDx = 0;
      this.moveAccumDy = 0;

      this.clearLongPressTimer();
      this.longPressTimer = setTimeout(() => {
        this.longPressFired = true;
        this.clearLongPressTimer();
        if (this.startPos) {
          this.emit({
            type: 'mouse-click',
            button: 'right',
            x: this.startPos.x,
            y: this.startPos.y,
          });
        }
      }, LONGPRESS_THRESHOLD_MS);
    }
  };
}
