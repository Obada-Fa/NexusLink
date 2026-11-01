import { afterEach, describe, expect, test } from 'bun:test';
import {
  takeClicksFromAccum,
  SCROLL_PX_PER_CLICK,
  MAX_SCROLL_CLICKS_PER_FLUSH,
  ZOOM_PX_PER_CLICK,
  MAX_ZOOM_CLICKS_PER_FLUSH,
  keyEvent,
  stopInjector,
  typeText,
} from '../input';

describe('takeClicksFromAccum', () => {
  test('holds sub-click remainder so slow scrolls still move', () => {
    const a = takeClicksFromAccum(10, SCROLL_PX_PER_CLICK, MAX_SCROLL_CLICKS_PER_FLUSH);
    expect(a.clicks).toBe(0);
    expect(a.rest).toBe(10);
    const b = takeClicksFromAccum(a.rest + 20, SCROLL_PX_PER_CLICK, MAX_SCROLL_CLICKS_PER_FLUSH);
    expect(b.clicks).toBe(1);
    expect(b.rest).toBe(6);
  });

  test('a delayed pinch burst cannot replay as a zoom dump', () => {
    // 30 queued pinch events of ~40px (the "zoom again and suddenly way in" case).
    const dumped = 40 * 30;
    const { clicks, rest } = takeClicksFromAccum(
      dumped,
      ZOOM_PX_PER_CLICK,
      MAX_ZOOM_CLICKS_PER_FLUSH,
    );
    expect(clicks).toBe(1);
    expect(rest).toBe(0);
  });

  test('a delayed scroll burst is capped and does not catch up', () => {
    const dumped = SCROLL_PX_PER_CLICK * 40;
    const { clicks, rest } = takeClicksFromAccum(
      dumped,
      SCROLL_PX_PER_CLICK,
      MAX_SCROLL_CLICKS_PER_FLUSH,
    );
    expect(clicks).toBe(MAX_SCROLL_CLICKS_PER_FLUSH);
    expect(rest).toBe(0);
  });

  test('negative deltas zoom/scroll the other way with the same cap', () => {
    const { clicks, rest } = takeClicksFromAccum(
      -ZOOM_PX_PER_CLICK * 12,
      ZOOM_PX_PER_CLICK,
      MAX_ZOOM_CLICKS_PER_FLUSH,
    );
    expect(clicks).toBe(-1);
    expect(rest).toBe(0);
  });
});

describe('text and key ordering', () => {
  const realSpawn = Bun.spawn;
  afterEach(() => {
    stopInjector();
    (Bun as { spawn: unknown }).spawn = realSpawn;
  });

  test('a key waits for text still being typed, and text for earlier text', async () => {
    const log: string[] = [];
    const finish: Array<() => void> = [];
    (Bun as { spawn: unknown }).spawn = (cmd: string[]) => {
      if (cmd[1] === 'type') {
        log.push(`type ${cmd[cmd.length - 1]}`);
        return { exited: new Promise<void>((done) => finish.push(done)) };
      }
      return {
        stdin: { write: (line: string) => log.push(line.trim()), flush() {} },
        exited: new Promise(() => {}),
        kill() {},
      };
    };
    const flush = () => new Promise((done) => setTimeout(done, 0));

    typeText('hello', ':order');
    typeText('world', ':order');
    keyEvent('Return', undefined, ':order');
    await flush();
    expect(log).toEqual(['type hello']);

    finish[0]();
    await flush();
    expect(log).toEqual(['type hello', 'type world']);

    finish[1]();
    await flush();
    expect(log).toEqual(['type hello', 'type world', 'key Return']);
  });
});
