import { describe, it, expect } from 'bun:test';
import {
  GestureEngine,
  LONGPRESS_THRESHOLD_MS,
  type GestureEvent,
  type GestureCallbacks,
  type FrameScheduler,
  // scroll-physics
  decayVelocity,
  inertiaDisplacement,
  inertiaTotalDistance,
  ScrollVelocityTracker,
  SCROLL_INERTIA_LAMBDA,
  // classifier
  resolveAxis,
  projectToAxis,
  isTap,
  isDoubleTap,
  // input-mapper
  WireMapper,
} from '../index';

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

describe('scroll-physics', () => {
  it('decayVelocity is identity at t=0 and monotonically decreasing', () => {
    expect(decayVelocity(1000, 0)).toBe(1000);
    const a = decayVelocity(1000, 0.1);
    const b = decayVelocity(1000, 0.2);
    expect(a).toBeLessThan(1000);
    expect(b).toBeLessThan(a);
    expect(b).toBeGreaterThan(0);
  });

  it('decay matches the closed form e^(-λt)', () => {
    const t = 0.3;
    expect(decayVelocity(1000, t)).toBeCloseTo(1000 * Math.exp(-SCROLL_INERTIA_LAMBDA * t), 6);
  });

  it('inertiaDisplacement over [0,∞) equals total distance v0/λ', () => {
    const v0 = 900;
    const total = inertiaTotalDistance(v0);
    expect(total).toBeCloseTo(v0 / SCROLL_INERTIA_LAMBDA, 6);
    // Displacement across a very long window approaches the total.
    expect(inertiaDisplacement(v0, 0, 100)).toBeCloseTo(total, 4);
  });

  it('inertiaDisplacement is additive across contiguous intervals', () => {
    const v0 = 500;
    const whole = inertiaDisplacement(v0, 0, 1);
    const part = inertiaDisplacement(v0, 0, 0.4) + inertiaDisplacement(v0, 0.4, 1);
    expect(part).toBeCloseTo(whole, 9);
  });

  it('ScrollVelocityTracker converges toward a sustained velocity', () => {
    const tr = new ScrollVelocityTracker();
    // 20 px every 10ms == 2000 px/s, sustained.
    let t = 0;
    tr.addSample(0, 0, t); // priming sample
    for (let i = 0; i < 30; i++) {
      t += 10;
      tr.addSample(0, 20, t);
    }
    expect(tr.velocity.vy).toBeGreaterThan(1500);
    expect(tr.velocity.vy).toBeLessThan(2500);
    expect(tr.velocity.vx).toBeCloseTo(0, 5);
    expect(tr.speed).toBeGreaterThan(1500);
  });
});

describe('classifier', () => {
  it('resolveAxis returns none below the travel threshold', () => {
    expect(resolveAxis(2, 3)).toBe('none');
  });

  it('resolveAxis locks vertical / horizontal / free by angle', () => {
    expect(resolveAxis(0, 40)).toBe('vertical');
    expect(resolveAxis(0, -40)).toBe('vertical');
    expect(resolveAxis(40, 0)).toBe('horizontal');
    expect(resolveAxis(-40, 2)).toBe('horizontal');
    expect(resolveAxis(30, 30)).toBe('free'); // 45deg diagonal
  });

  it('projectToAxis zeroes the off-axis component', () => {
    expect(projectToAxis(5, 9, 'vertical')).toEqual({ dx: 0, dy: 9 });
    expect(projectToAxis(5, 9, 'horizontal')).toEqual({ dx: 5, dy: 0 });
    expect(projectToAxis(5, 9, 'free')).toEqual({ dx: 5, dy: 9 });
  });

  it('isTap / isDoubleTap honour their boundaries', () => {
    expect(isTap(120, 3)).toBe(true);
    expect(isTap(600, 3)).toBe(false);
    expect(isTap(120, 40)).toBe(false);
    expect(isDoubleTap(200, 5)).toBe(true);
    expect(isDoubleTap(400, 5)).toBe(false);
    expect(isDoubleTap(200, 50)).toBe(false);
  });
});

describe('input-mapper', () => {
  it('assigns monotonic seq and maps gesture events to wire events', () => {
    let clock = 100;
    const m = new WireMapper(() => clock);
    const tap = m.map({ type: 'mouse-click', button: 'left', x: 10, y: 20 });
    clock = 105;
    const scroll = m.map({ type: 'mouse-scroll', deltaX: 1, deltaY: -4, x: 3, y: 7, inertial: true });
    expect(tap).toEqual({ kind: 'pointer.tap', x: 10, y: 20, seq: 0, t: 100 });
    expect(scroll).toEqual({ kind: 'scroll.delta', x: 3, y: 7, dxPx: 1, dyPx: -4, inertial: true, seq: 1, t: 105 });
  });

  it('maps right/middle clicks, drag and zoom', () => {
    const m = new WireMapper(() => 0);
    expect(m.map({ type: 'mouse-click', button: 'right', x: 1, y: 2 })!.kind).toBe('pointer.context');
    expect(m.map({ type: 'mouse-click', button: 'middle', x: 1, y: 2 })!.kind).toBe('pointer.middle');
    expect(m.map({ type: 'drag-start', x: 1, y: 2 })!.kind).toBe('drag.start');
    expect(m.map({ type: 'zoom', scale: 0.2, x: 1, y: 2 })!.kind).toBe('zoom.delta');
  });
});

// ---------------------------------------------------------------------------
// DOM mocks (mirrors the harness in gesture-engine.test.ts)
// ---------------------------------------------------------------------------

class MockTouch {
  identifier: number;
  clientX: number;
  clientY: number;
  constructor(identifier: number, clientX: number, clientY: number) {
    this.identifier = identifier;
    this.clientX = clientX;
    this.clientY = clientY;
  }
}

class MockTouchEvent {
  type: string;
  touches: MockTouch[];
  defaultPrevented = false;
  constructor(type: string, touches: MockTouch[]) {
    this.type = type;
    this.touches = touches;
  }
  preventDefault(): void {
    this.defaultPrevented = true;
  }
}

function createMockElement() {
  const listeners = new Map<string, EventListener[]>();
  const el = {
    addEventListener(type: string, listener: EventListener) {
      const arr = listeners.get(type) ?? [];
      arr.push(listener);
      listeners.set(type, arr);
    },
    removeEventListener(type: string, listener: EventListener) {
      const arr = listeners.get(type);
      if (arr) arr.splice(arr.indexOf(listener), 1);
    },
    dispatchEvent(event: MockTouchEvent) {
      for (const fn of listeners.get(event.type) ?? []) fn.call(el, event as unknown as Event);
      return !event.defaultPrevented;
    },
    getBoundingClientRect: () => ({
      width: 375, height: 667, left: 0, top: 0, right: 375, bottom: 667, x: 0, y: 0, toJSON: () => ({}),
    }),
  };
  return { el };
}

function touch(x: number, y: number, id = 0): MockTouch {
  return new MockTouch(id, x, y);
}

/** Deterministic scheduler + clock for momentum tests. */
class ManualScheduler implements FrameScheduler {
  t = 0;
  private queue: Array<{ id: number; cb: (t: number) => void }> = [];
  private nid = 1;
  now(): number {
    return this.t;
  }
  request(cb: (t: number) => void): number {
    const id = this.nid++;
    this.queue.push({ id, cb });
    return id;
  }
  cancel(id: number): void {
    this.queue = this.queue.filter((q) => q.id !== id);
  }
  /** Advance the clock only (no frames) — used between touch samples. */
  tick(dtMs: number): void {
    this.t += dtMs;
  }
  /** Advance the clock and fire all currently-queued frame callbacks. */
  frame(dtMs: number): void {
    this.t += dtMs;
    const q = this.queue;
    this.queue = [];
    for (const item of q) item.cb(this.t);
  }
  get pending(): number {
    return this.queue.length;
  }
}

// ---------------------------------------------------------------------------
// Engine — direct-manipulation behaviours
// ---------------------------------------------------------------------------

describe('GestureEngine v2 (touch mode)', () => {
  function setup(scheduler?: FrameScheduler) {
    const { el } = createMockElement();
    const events: GestureEvent[] = [];
    const callbacks: GestureCallbacks = { onGesture: (e) => events.push(e) };
    const now = scheduler ? () => (scheduler as ManualScheduler).now() : undefined;
    const engine = new GestureEngine(el as unknown as HTMLElement, callbacks, {
      mode: 'touch',
      scheduler,
      now,
    });
    engine.setHostDimensions(1080, 1920); // portrait host, ~1:1 aspect with the mock view
    engine.attach();
    return { el, events, engine };
  }

  it('one-finger vertical pan emits drag events (not scroll)', () => {
    const { el, events, engine } = setup();
    el.dispatchEvent(new MockTouchEvent('touchstart', [touch(200, 600)]));
    el.dispatchEvent(new MockTouchEvent('touchmove', [touch(200, 540)]));
    el.dispatchEvent(new MockTouchEvent('touchmove', [touch(200, 480)]));
    el.dispatchEvent(new MockTouchEvent('touchend', []));

    expect(events.filter((e) => e.type === 'drag-start')).toHaveLength(1);
    expect(events.filter((e) => e.type === 'drag-move').length).toBeGreaterThan(0);
    expect(events.filter((e) => e.type === 'drag-end')).toHaveLength(1);
    expect(events.filter((e) => e.type === 'mouse-scroll')).toHaveLength(0);
    expect(events.filter((e) => e.type === 'mouse-move')).toHaveLength(0);
    engine.detach();
  });

  it('produces a momentum fling after a fast two-finger flick, cancelled by a new touch', () => {
    const sched = new ManualScheduler();
    const { el, events, engine } = setup(sched);

    el.dispatchEvent(new MockTouchEvent('touchstart', [touch(100, 600), touch(150, 600)]));
    let y = 600;
    for (let i = 0; i < 5; i++) {
      sched.tick(16);
      y -= 40;
      el.dispatchEvent(new MockTouchEvent('touchmove', [touch(100, y), touch(150, y)]));
    }
    el.dispatchEvent(new MockTouchEvent('touchend', []));

    // Pump animation frames: inertial scroll events should be produced.
    for (let i = 0; i < 20; i++) sched.frame(16);
    const inertial = events.filter((e) => e.type === 'mouse-scroll' && e.inertial === true);
    expect(inertial.length).toBeGreaterThan(0);

    // Finger-catch: a new touch cancels the fling immediately.
    const countBefore = events.length;
    el.dispatchEvent(new MockTouchEvent('touchstart', [touch(200, 600)]));
    for (let i = 0; i < 20; i++) sched.frame(16);
    const afterInertial = events
      .slice(countBefore)
      .filter((e) => e.type === 'mouse-scroll' && e.inertial === true);
    expect(afterInertial.length).toBe(0);
    expect(sched.pending).toBe(0);
    engine.detach();
  });

  it('slow two-finger pan below the fling threshold does not start inertia', () => {
    const sched = new ManualScheduler();
    const { el, events, engine } = setup(sched);

    el.dispatchEvent(new MockTouchEvent('touchstart', [touch(100, 600), touch(150, 600)]));
    let y = 600;
    for (let i = 0; i < 4; i++) {
      sched.tick(200); // very slow: ~large dt => low velocity
      y -= 5;
      el.dispatchEvent(new MockTouchEvent('touchmove', [touch(100, y), touch(150, y)]));
    }
    el.dispatchEvent(new MockTouchEvent('touchend', []));
    for (let i = 0; i < 20; i++) sched.frame(16);
    const inertial = events.filter((e) => e.type === 'mouse-scroll' && e.inertial === true);
    expect(inertial.length).toBe(0);
    engine.detach();
  });

  it('long-press then move does not start a left-drag', async () => {
    const { el, events, engine } = setup();
    el.dispatchEvent(new MockTouchEvent('touchstart', [touch(100, 200)]));
    await new Promise((r) => setTimeout(r, LONGPRESS_THRESHOLD_MS + 40));
    el.dispatchEvent(new MockTouchEvent('touchmove', [touch(140, 250)]));
    el.dispatchEvent(new MockTouchEvent('touchmove', [touch(170, 280)]));
    el.dispatchEvent(new MockTouchEvent('touchend', []));

    const context = events.filter((e) => e.type === 'mouse-click' && e.button === 'right');
    expect(context.length).toBe(1);
    expect(events.filter((e) => e.type === 'drag-start')).toHaveLength(0);
    expect(events.filter((e) => e.type === 'drag-move')).toHaveLength(0);
    engine.detach();
  });

  it('two-finger pinch emits zoom', () => {
    const { el, events, engine } = setup();
    el.dispatchEvent(new MockTouchEvent('touchstart', [touch(100, 300), touch(200, 300)]));
    el.dispatchEvent(new MockTouchEvent('touchmove', [touch(70, 300), touch(230, 300)]));
    el.dispatchEvent(new MockTouchEvent('touchend', []));

    const zooms = events.filter((e) => e.type === 'zoom');
    expect(zooms.length).toBeGreaterThan(0);
    if (zooms[0]!.type === 'zoom') expect(zooms[0]!.scale).toBeGreaterThan(0);
    engine.detach();
  });

  it('three-finger tap emits a middle click', () => {
    const { el, events, engine } = setup();
    el.dispatchEvent(
      new MockTouchEvent('touchstart', [touch(100, 200), touch(150, 200), touch(200, 200)]),
    );
    el.dispatchEvent(new MockTouchEvent('touchend', []));

    const middle = events.filter((e) => e.type === 'mouse-click' && e.button === 'middle');
    expect(middle.length).toBe(1);
    engine.detach();
  });

  it('precision flag forces relative cursor movement even in touch mode', () => {
    const { el } = createMockElement();
    const events: GestureEvent[] = [];
    const engine = new GestureEngine(
      el as unknown as HTMLElement,
      { onGesture: (e) => events.push(e) },
      { mode: 'touch', precision: true },
    );
    engine.setHostDimensions(1080, 1920);
    engine.attach();

    el.dispatchEvent(new MockTouchEvent('touchstart', [touch(200, 600)]));
    el.dispatchEvent(new MockTouchEvent('touchmove', [touch(200, 500)]));
    el.dispatchEvent(new MockTouchEvent('touchend', []));

    expect(events.some((e) => e.type === 'mouse-move')).toBe(true);
    expect(events.some((e) => e.type === 'mouse-scroll')).toBe(false);
    expect(events.some((e) => e.type === 'drag-start')).toBe(false);
    engine.detach();
  });
});
