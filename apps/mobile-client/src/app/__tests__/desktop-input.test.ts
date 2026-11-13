import { expect, it } from 'bun:test';
import { attachDesktopInput } from '@/lib/desktop-input';

function fixture(sessionId?: string, region = { x: 100, y: 200, width: 1600, height: 800 }) {
  const owner = new EventTarget();
  const doc = Object.assign(new EventTarget(), { defaultView: owner, hidden: false });
  const element = Object.assign(new EventTarget(), {
    ownerDocument: doc, clientHeight: 600,
    getBoundingClientRect: () => ({ left: 10, top: 20, width: 1000, height: 600 }),
    setPointerCapture: (_id: number) => {},
  });
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  const detach = attachDesktopInput(element as unknown as HTMLElement, {
    region: () => region, sessionId,
    send: (method, params) => calls.push({ method, params }),
  });
  function fire(type: string, props: Record<string, unknown> = {}) {
    const event = Object.assign(new Event(type, { cancelable: true }), {
      pointerType: 'mouse', pointerId: 1, button: 0, clientX: 510, clientY: 320, ...props,
    });
    element.dispatchEvent(event);
    return event;
  }
  return { owner, doc, calls, fire, detach };
}

it('controls the full desktop without a virtual app session', () => {
  const f = fixture(undefined, { x: 0, y: 0, width: 1920, height: 1080 });
  f.fire('pointermove');
  f.fire('pointerdown');
  f.fire('pointermove', { clientX: 760 });
  f.fire('pointerup', { clientX: 760 });
  f.fire('pointerdown', { button: 2 });
  f.fire('pointerup', { button: 2 });
  f.fire('wheel', { deltaX: 0, deltaY: 120, deltaMode: 0 });
  expect(f.calls).toEqual([
    { method: 'input.mouseMoveAbs', params: { x: 960, y: 540 } },
    { method: 'input.buttonDown', params: { button: 'left', x: 960, y: 540 } },
    { method: 'input.mouseMoveAbs', params: { x: 1440, y: 540 } },
    { method: 'input.buttonUp', params: { button: 'left', x: 1440, y: 540 } },
    { method: 'input.buttonDown', params: { button: 'right', x: 960, y: 540 } },
    { method: 'input.buttonUp', params: { button: 'right', x: 960, y: 540 } },
    { method: 'input.mouseScroll', params: { x: 960, y: 540, deltaX: 0, deltaY: 120 } },
  ]);
  f.detach();
});

it('maps a desktop monitor to its physical position instead of a session display', () => {
  const f = fixture(undefined, { x: 1920, y: 0, width: 1920, height: 1080 });
  f.fire('pointermove');
  expect(f.calls).toEqual([{ method: 'input.mouseMoveAbs', params: { x: 2880, y: 540 } }]);
  f.detach();
});

it('maps hover into the captured window and ignores letterboxing and touch', () => {
  const f = fixture();
  f.fire('pointermove');
  expect(f.calls).toEqual([{ method: 'input.mouseMoveAbs', params: { x: 900, y: 600 } }]);
  f.fire('pointermove', { clientY: 30 });
  f.fire('pointerdown', { pointerType: 'touch' });
  expect(f.calls).toHaveLength(1);
  f.detach();
});

it('sends native click pairs, drag motion and session targeting', () => {
  const f = fixture('virtual-1');
  for (const [button, name] of [[0, 'left'], [1, 'middle'], [2, 'right']] as const) {
    expect(f.fire('pointerdown', { button }).defaultPrevented).toBe(true);
    f.fire('pointerup', { button });
    expect(f.calls.slice(-2).map(c => [c.method, c.params.button, c.params.sessionId]))
      .toEqual([['input.buttonDown', name, 'virtual-1'], ['input.buttonUp', name, 'virtual-1']]);
  }
  f.fire('pointerdown');
  f.fire('pointermove', { clientX: 1200 });
  f.fire('pointerup', { clientX: 1200 });
  expect(f.calls.at(-2)?.params.x).toBe(1699);
  expect(f.calls.at(-1)?.method).toBe('input.buttonUp');
  f.detach();
});

it('releases held buttons on interruption and removes listeners on cleanup', () => {
  for (const interruption of ['blur', 'pointercancel', 'lostpointercapture', 'hidden', 'detach']) {
    const f = fixture();
    f.fire('pointerdown');
    if (interruption === 'blur') f.owner.dispatchEvent(new Event('blur'));
    else if (interruption === 'hidden') {
      f.doc.hidden = true;
      f.doc.dispatchEvent(new Event('visibilitychange'));
    } else if (interruption === 'detach') f.detach();
    else f.fire(interruption);
    expect(f.calls.at(-1)).toEqual({ method: 'input.buttonUp', params: { button: 'left' } });
    f.detach();
    const count = f.calls.length;
    f.fire('pointermove');
    expect(f.calls).toHaveLength(count);
  }
});

it('forwards wheel units and trackpad zoom and suppresses browser context menus', () => {
  const f = fixture();
  const event = f.fire('wheel', { deltaX: 2, deltaY: -3, deltaMode: 1, ctrlKey: true });
  expect(event.defaultPrevented).toBe(true);
  expect(f.calls[0]).toEqual({ method: 'input.mouseScroll', params: {
    x: 900, y: 600, deltaX: 32, deltaY: -48, modifiers: ['ctrl'],
  } });
  expect(f.fire('contextmenu').defaultPrevented).toBe(true);
  f.detach();
});
