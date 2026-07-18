// Maps engine GestureEvents to the canonical over-the-wire input protocol carried
// on the unordered/lossy `input` DataChannel (see architecture.md Module C4).
// Every wire event is sequence-numbered + timestamped so the host can drop stale
// scroll frames (seq regression) and coalesce to its injection tick.

import type { GestureEvent } from './index';

export type WireInputEvent =
  | { kind: 'pointer.tap'; x: number; y: number; seq: number; t: number }
  | { kind: 'pointer.double'; x: number; y: number; seq: number; t: number }
  | { kind: 'pointer.context'; x: number; y: number; seq: number; t: number }
  | { kind: 'pointer.middle'; x: number; y: number; seq: number; t: number }
  | { kind: 'scroll.delta'; x: number; y: number; dxPx: number; dyPx: number; inertial: boolean; seq: number; t: number }
  | { kind: 'drag.start'; x: number; y: number; seq: number; t: number }
  | { kind: 'drag.move'; x: number; y: number; seq: number; t: number }
  | { kind: 'drag.end'; x: number; y: number; seq: number; t: number }
  | { kind: 'zoom.delta'; scale: number; cx: number; cy: number; seq: number; t: number }
  | { kind: 'cursor.move'; dx: number; dy: number; seq: number; t: number };

type NowFn = () => number;

/** Stateful mapper: assigns a monotonic seq and timestamp to each wire event. */
export class WireMapper {
  private seq = 0;
  private readonly now: NowFn;

  constructor(now: NowFn = () => Date.now()) {
    this.now = now;
  }

  /** Convert a GestureEvent to a wire event, or null if it has no wire form. */
  map(ev: GestureEvent): WireInputEvent | null {
    const seq = this.seq++;
    const t = this.now();
    switch (ev.type) {
      case 'mouse-click':
        if (ev.button === 'right') return { kind: 'pointer.context', x: ev.x, y: ev.y, seq, t };
        if (ev.button === 'middle') return { kind: 'pointer.middle', x: ev.x, y: ev.y, seq, t };
        return { kind: 'pointer.tap', x: ev.x, y: ev.y, seq, t };
      case 'mouse-dbl-click':
        return { kind: 'pointer.double', x: ev.x, y: ev.y, seq, t };
      case 'mouse-scroll':
        return {
          kind: 'scroll.delta',
          x: ev.x,
          y: ev.y,
          dxPx: ev.deltaX,
          dyPx: ev.deltaY,
          inertial: ev.inertial ?? false,
          seq,
          t,
        };
      case 'mouse-move':
        return { kind: 'cursor.move', dx: ev.dx, dy: ev.dy, seq, t };
      case 'drag-start':
        return { kind: 'drag.start', x: ev.x, y: ev.y, seq, t };
      case 'drag-move':
        return { kind: 'drag.move', x: ev.x, y: ev.y, seq, t };
      case 'drag-end':
        return { kind: 'drag.end', x: ev.x, y: ev.y, seq, t };
      case 'zoom':
        return { kind: 'zoom.delta', scale: ev.scale, cx: ev.x, cy: ev.y, seq, t };
      default:
        return null;
    }
  }

  reset(): void {
    this.seq = 0;
  }
}
