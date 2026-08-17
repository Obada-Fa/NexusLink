import { describe, it, expect } from 'bun:test';
import {
  scaleToHost,
  GestureEngine,
  PAN_SENSITIVITY,
  SCROLL_SENSITIVITY,
  LONGPRESS_THRESHOLD_MS,
  LONGPRESS_MAX_MOVE_PX,
  type GestureEvent,
  type GestureCallbacks,
} from '../index';

describe('scaleToHost', () => {
  it('scales with matching aspect ratio (no letterbox)', () => {
    const result = scaleToHost(50, 50, 100, 100, 1920, 1080);
    expect(result.x).toBe(960);
    expect(result.y).toBe(540);
  });

  it('handles wider view than host (letterbox left/right)', () => {
    // view 200×100 (aspect 2) vs host 16:9 — contain fits height.
    const result = scaleToHost(100, 50, 200, 100, 1920, 1080);
    expect(result.x).toBe(960);
    expect(result.y).toBe(540);
  });

  it('handles taller view than host (letterbox top/bottom)', () => {
    // view 100×200 (aspect 0.5) vs host 16:9 — contain fits width.
    const result = scaleToHost(50, 100, 100, 200, 1920, 1080);
    expect(result.x).toBe(960);
    expect(result.y).toBe(540);
  });

  it('maps a tap on the painted content, not the letterbox, on a tall phone', () => {
    // Phone stage 390×780 viewing a 16:9 capture — bars above/below the frame.
    // The content is 390 × (390 / (1920/1080)) = 219.375 tall, offsetY ≈ 280.3.
    const mid = scaleToHost(195, 390, 390, 780, 1920, 1080);
    expect(mid.x).toBe(960);
    expect(mid.y).toBe(540);
    const topBar = scaleToHost(195, 10, 390, 780, 1920, 1080);
    expect(topBar.y).toBe(0);
  });

  it('clamps output to host bounds', () => {
    const result = scaleToHost(-100, -100, 100, 100, 1920, 1080);
    expect(result.x).toBe(0);
    expect(result.y).toBe(0);

    const result2 = scaleToHost(500, 500, 100, 100, 1920, 1080);
    expect(result2.x).toBe(1920);
    expect(result2.y).toBe(1080);
  });

  it('returns zero for invalid dimensions', () => {
    expect(scaleToHost(50, 50, 0, 100, 1920, 1080)).toEqual({ x: 0, y: 0 });
    expect(scaleToHost(50, 50, 100, 0, 1920, 1080)).toEqual({ x: 0, y: 0 });
    expect(scaleToHost(50, 50, 100, 100, 0, 1080)).toEqual({ x: 0, y: 0 });
  });

  it('perfect square views map center correctly', () => {
    const result = scaleToHost(100, 100, 200, 200, 1920, 1080);
    expect(result.x).toBe(960);
    expect(result.y).toBe(540);
  });

  it('fill fit maps the view corner to the host corner (no letterbox)', () => {
    const result = scaleToHost(100, 200, 200, 400, 780, 1688, 'fill');
    expect(result.x).toBe(390);
    expect(result.y).toBe(844);
  });
});

class MockTouch {
  identifier: number;
  clientX: number;
  clientY: number;
  pageX: number;
  pageY: number;
  screenX: number;
  screenY: number;
  target: EventTarget;

  constructor(init: {
    identifier: number;
    target: EventTarget;
    clientX: number;
    clientY: number;
    pageX: number;
    pageY: number;
    screenX: number;
    screenY: number;
  }) {
    this.identifier = init.identifier;
    this.target = init.target;
    this.clientX = init.clientX;
    this.clientY = init.clientY;
    this.pageX = init.pageX;
    this.pageY = init.pageY;
    this.screenX = init.screenX;
    this.screenY = init.screenY;
  }
}

class MockTouchEvent {
  type: string;
  touches: MockTouch[];
  changedTouches: MockTouch[];
  altKey = false;
  metaKey = false;
  ctrlKey = false;
  shiftKey = false;
  defaultPrevented = false;

  constructor(type: string, init: { touches: MockTouch[]; changedTouches?: MockTouch[] }) {
    this.type = type;
    this.touches = init.touches;
    this.changedTouches = init.changedTouches ?? init.touches;
  }

  preventDefault(): void {
    this.defaultPrevented = true;
  }
}

function createMockElement(): {
  // `el` is a structural DOM stub whose dispatchEvent accepts MockTouchEvent; typed
  // loosely so it can stand in for both HTMLElement (listeners) and Touch.target.
  el: any;
  listeners: Map<string, EventListener[]>;
  getRect: () => DOMRect;
} {
  const listeners = new Map<string, EventListener[]>();

  const el = {
    addEventListener(type: string, listener: EventListener, _options?: unknown) {
      let arr = listeners.get(type);
      if (!arr) {
        arr = [];
        listeners.set(type, arr);
      }
      arr.push(listener);
    },
    removeEventListener(type: string, listener: EventListener, _options?: unknown) {
      const arr = listeners.get(type);
      if (arr) {
        const idx = arr.indexOf(listener);
        if (idx !== -1) arr.splice(idx, 1);
      }
    },
    dispatchEvent(event: MockTouchEvent) {
      const arr = listeners.get(event.type);
      if (arr) {
        for (const fn of arr) {
          fn.call(el, event as unknown as Event);
        }
      }
      return !event.defaultPrevented;
    },
  };

  const getRect = () => ({
    width: 375,
    height: 667,
    left: 0,
    top: 0,
    right: 375,
    bottom: 667,
    x: 0,
    y: 0,
    toJSON: () => ({}),
  });

  return { el, listeners, getRect };
}

function createTouch(
  x: number,
  y: number,
  identifier: number,
  target: EventTarget,
): MockTouch {
  return new MockTouch({
    identifier,
    clientX: x,
    clientY: y,
    pageX: x,
    pageY: y,
    screenX: x,
    screenY: y,
    target,
  });
}

describe('GestureEngine', () => {
  it('exports all constants', () => {
    expect(PAN_SENSITIVITY).toBe(5);
    expect(SCROLL_SENSITIVITY).toBe(10);
    expect(LONGPRESS_THRESHOLD_MS).toBe(500);
    expect(LONGPRESS_MAX_MOVE_PX).toBe(10);
  });

  it('attaches and detaches', () => {
    const { el, getRect } = createMockElement();
    const events: GestureEvent[] = [];
    const callbacks: GestureCallbacks = { onGesture: (e) => events.push(e) };
    const engine = new GestureEngine(el as unknown as HTMLElement, callbacks);

    // Provide the getBoundingClientRect stub
    Object.defineProperty(el, 'getBoundingClientRect', { value: getRect, configurable: true });

    engine.attach();
    expect(engine.isAttached).toBe(true);

    engine.detach();
    expect(engine.isAttached).toBe(false);
  });

  it('emits mouse-click on tap', () => {
    const { el, getRect } = createMockElement();
    const events: GestureEvent[] = [];
    const callbacks: GestureCallbacks = { onGesture: (e) => events.push(e) };
    const engine = new GestureEngine(el as unknown as HTMLElement, callbacks);

    Object.defineProperty(el, 'getBoundingClientRect', { value: getRect, configurable: true });
    engine.attach();

    const touch = createTouch(100, 200, 0, el);
    el.dispatchEvent(new MockTouchEvent('touchstart', { touches: [touch] }));
    el.dispatchEvent(new MockTouchEvent('touchend', { touches: [] }));

    expect(events.length).toBe(1);
    expect(events[0]!.type).toBe('mouse-click');
    if (events[0]!.type === 'mouse-click') {
      expect(events[0]!.button).toBe('left');
    }

    engine.detach();
  });

  it('emits mouse-move on drag (trackpad/precision mode)', () => {
    const { el, getRect } = createMockElement();
    const events: GestureEvent[] = [];
    const callbacks: GestureCallbacks = { onGesture: (e) => events.push(e) };
    // Relative cursor movement is trackpad / Precision mode.
    // Default `direct` mode is a left-button drag at the finger.
    const engine = new GestureEngine(el as unknown as HTMLElement, callbacks, { mode: 'trackpad' });

    Object.defineProperty(el, 'getBoundingClientRect', { value: getRect, configurable: true });
    engine.attach();

    const touchStart = createTouch(100, 200, 0, el);
    el.dispatchEvent(new MockTouchEvent('touchstart', { touches: [touchStart] }));

    // Move enough to exceed PAN_SENSITIVITY (must be >5px in host coords)
    // 10px move in 375px view ~ 51px in 1920 host, exceeds PAN_SENSITIVITY
    const touchMove = createTouch(115, 220, 0, el);
    el.dispatchEvent(new MockTouchEvent('touchmove', { touches: [touchMove] }));

    el.dispatchEvent(new MockTouchEvent('touchend', { touches: [] }));

    const moveEvents = events.filter((e) => e.type === 'mouse-move');
    expect(moveEvents.length).toBeGreaterThan(0);

    engine.detach();
  });

  it('emits right-click on long press', async () => {
    const { el, getRect } = createMockElement();
    const events: GestureEvent[] = [];
    const callbacks: GestureCallbacks = { onGesture: (e) => events.push(e) };
    const engine = new GestureEngine(el as unknown as HTMLElement, callbacks);

    Object.defineProperty(el, 'getBoundingClientRect', { value: getRect, configurable: true });
    engine.attach();

    const touch = createTouch(100, 200, 0, el);
    el.dispatchEvent(new MockTouchEvent('touchstart', { touches: [touch] }));

    await new Promise((r) => setTimeout(r, LONGPRESS_THRESHOLD_MS + 50));

    const rightClicks = events.filter(
      (e) => e.type === 'mouse-click' && e.button === 'right',
    );
    expect(rightClicks.length).toBe(1);

    engine.detach();
  });

  it('emits mouse-scroll on two-finger pan', () => {
    const { el, getRect } = createMockElement();
    const events: GestureEvent[] = [];
    const callbacks: GestureCallbacks = { onGesture: (e) => events.push(e) };
    const engine = new GestureEngine(el as unknown as HTMLElement, callbacks);

    Object.defineProperty(el, 'getBoundingClientRect', { value: getRect, configurable: true });
    engine.attach();

    const t0 = createTouch(100, 200, 0, el);
    const t1 = createTouch(150, 250, 1, el);
    el.dispatchEvent(new MockTouchEvent('touchstart', { touches: [t0, t1] }));

    // Move two fingers together by enough to trigger scroll
    const t0m = createTouch(100, 260, 0, el);
    const t1m = createTouch(150, 310, 1, el);
    el.dispatchEvent(new MockTouchEvent('touchmove', { touches: [t0m, t1m] }));

    el.dispatchEvent(new MockTouchEvent('touchend', { touches: [] }));

    const scrollEvents = events.filter((e) => e.type === 'mouse-scroll');
    expect(scrollEvents.length).toBeGreaterThan(0);

    engine.detach();
  });

  it('emits mouse-dbl-click on double tap', () => {
    const { el, getRect } = createMockElement();
    const events: GestureEvent[] = [];
    const callbacks: GestureCallbacks = { onGesture: (e) => events.push(e) };
    const engine = new GestureEngine(el as unknown as HTMLElement, callbacks);

    Object.defineProperty(el, 'getBoundingClientRect', { value: getRect, configurable: true });
    engine.attach();

    // First tap
    const touch1 = createTouch(100, 200, 0, el);
    el.dispatchEvent(new MockTouchEvent('touchstart', { touches: [touch1] }));
    el.dispatchEvent(new MockTouchEvent('touchend', { touches: [] }));

    // Second tap (immediately)
    const touch2 = createTouch(102, 202, 0, el);
    el.dispatchEvent(new MockTouchEvent('touchstart', { touches: [touch2] }));
    el.dispatchEvent(new MockTouchEvent('touchend', { touches: [] }));

    const dblClicks = events.filter((e) => e.type === 'mouse-dbl-click');
    const singleClicks = events.filter(
      (e) => e.type === 'mouse-click' && e.button === 'left',
    );

    expect(dblClicks.length).toBe(1);
    expect(singleClicks.length).toBe(1);

    engine.detach();
  });

  it('cancels long press on significant movement', async () => {
    const { el, getRect } = createMockElement();
    const events: GestureEvent[] = [];
    const callbacks: GestureCallbacks = { onGesture: (e) => events.push(e) };
    const engine = new GestureEngine(el as unknown as HTMLElement, callbacks);

    Object.defineProperty(el, 'getBoundingClientRect', { value: getRect, configurable: true });
    engine.attach();

    const touchStart = createTouch(100, 200, 0, el);
    el.dispatchEvent(new MockTouchEvent('touchstart', { touches: [touchStart] }));

    // Move beyond LONGPRESS_MAX_MOVE_PX threshold
    const touchMove = createTouch(120, 220, 0, el);
    el.dispatchEvent(new MockTouchEvent('touchmove', { touches: [touchMove] }));

    // Also trigger a move > PAN_SENSITIVITY to ensure long press is cancelled
    const touchMove2 = createTouch(135, 235, 0, el);
    el.dispatchEvent(new MockTouchEvent('touchmove', { touches: [touchMove2] }));

    await new Promise((r) => setTimeout(r, LONGPRESS_THRESHOLD_MS + 50));

    const rightClicks = events.filter(
      (e) => e.type === 'mouse-click' && e.button === 'right',
    );
    expect(rightClicks.length).toBe(0);

    engine.detach();
  });

  it('setHostDimensions updates host resolution', () => {
    const { el, getRect } = createMockElement();
    const events: GestureEvent[] = [];
    const callbacks: GestureCallbacks = { onGesture: (e) => events.push(e) };
    const engine = new GestureEngine(el as unknown as HTMLElement, callbacks);

    Object.defineProperty(el, 'getBoundingClientRect', { value: getRect, configurable: true });
    engine.attach();

    engine.setHostDimensions(3840, 2160);

    const touch = createTouch(50, 50, 0, el);
    el.dispatchEvent(new MockTouchEvent('touchstart', { touches: [touch] }));
    el.dispatchEvent(new MockTouchEvent('touchend', { touches: [] }));

    expect(events.length).toBe(1);
    expect(events[0]!.type).toBe('mouse-click');
    if (events[0]!.type === 'mouse-click') {
      expect(typeof events[0]!.x).toBe('number');
      expect(typeof events[0]!.y).toBe('number');
    }

    engine.detach();
  });

  it('does not double-attach', () => {
    const { el, getRect } = createMockElement();
    const callbacks: GestureCallbacks = { onGesture: () => {} };
    const engine = new GestureEngine(el as unknown as HTMLElement, callbacks);

    Object.defineProperty(el, 'getBoundingClientRect', { value: getRect, configurable: true });

    engine.attach();
    engine.attach(); // second call should be no-op
    expect(engine.isAttached).toBe(true);

    engine.detach();
    expect(engine.isAttached).toBe(false);
  });
});
