type Button = 'left' | 'middle' | 'right';
interface Region { x: number; y: number; width: number; height: number }

/** Native laptop input alongside (and independent of) the touch gesture engine. */
export function attachDesktopInput(element: HTMLElement, options: {
  region: () => Region;
  sessionId?: string;
  send: (method: string, params: Record<string, unknown>) => void;
}) {
  const buttons = new Set<Button>();
  const owner = element.ownerDocument.defaultView!;
  const send = (method: string, params: Record<string, unknown>) =>
    options.send(method, { ...params, ...(options.sessionId ? { sessionId: options.sessionId } : {}) });
  const point = (event: MouseEvent, clamp = false) => {
    const rect = element.getBoundingClientRect();
    const region = options.region();
    const scale = Math.min(rect.width / region.width, rect.height / region.height);
    if (!(scale > 0)) return null;
    const x = (event.clientX - rect.left - (rect.width - region.width * scale) / 2) / scale;
    const y = (event.clientY - rect.top - (rect.height - region.height * scale) / 2) / scale;
    if (!clamp && (x < 0 || y < 0 || x >= region.width || y >= region.height)) return null;
    return { x: region.x + Math.max(0, Math.min(region.width - 1, Math.round(x))),
      y: region.y + Math.max(0, Math.min(region.height - 1, Math.round(y))) };
  };
  const button = (event: PointerEvent) => (['left', 'middle', 'right'] as const)[event.button];
  const move = (event: PointerEvent) => {
    if (event.pointerType !== 'mouse') return;
    const p = point(event, buttons.size > 0);
    if (p) send('input.mouseMoveAbs', p);
  };
  const down = (event: PointerEvent) => {
    if (event.pointerType !== 'mouse') return;
    const b = button(event);
    const p = point(event);
    if (!b || !p) return;
    event.preventDefault();
    element.setPointerCapture(event.pointerId);
    buttons.add(b);
    send('input.buttonDown', { button: b, ...p });
  };
  const up = (event: PointerEvent) => {
    if (event.pointerType !== 'mouse') return;
    const b = button(event);
    if (!b || !buttons.delete(b)) return;
    send('input.buttonUp', { button: b, ...point(event, true) });
  };
  const release = () => {
    for (const b of buttons) send('input.buttonUp', { button: b });
    buttons.clear();
  };
  const wheel = (event: WheelEvent) => {
    const p = point(event);
    if (!p) return;
    event.preventDefault();
    const factor = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? element.clientHeight : 1;
    send('input.mouseScroll', { ...p, deltaX: event.deltaX * factor, deltaY: event.deltaY * factor,
      ...(event.ctrlKey ? { modifiers: ['ctrl'] } : {}) });
  };
  const context = (event: Event) => event.preventDefault();
  const hidden = () => { if (element.ownerDocument.hidden) release(); };
  element.addEventListener('pointermove', move);
  element.addEventListener('pointerdown', down);
  element.addEventListener('pointerup', up);
  element.addEventListener('pointercancel', release);
  element.addEventListener('lostpointercapture', release);
  element.addEventListener('wheel', wheel, { passive: false });
  element.addEventListener('contextmenu', context);
  owner.addEventListener('blur', release);
  element.ownerDocument.addEventListener('visibilitychange', hidden);
  return () => {
    release();
    element.removeEventListener('pointermove', move);
    element.removeEventListener('pointerdown', down);
    element.removeEventListener('pointerup', up);
    element.removeEventListener('pointercancel', release);
    element.removeEventListener('lostpointercapture', release);
    element.removeEventListener('wheel', wheel);
    element.removeEventListener('contextmenu', context);
    owner.removeEventListener('blur', release);
    element.ownerDocument.removeEventListener('visibilitychange', hidden);
  };
}
