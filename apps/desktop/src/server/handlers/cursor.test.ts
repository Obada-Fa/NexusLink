import { expect, test } from 'bun:test';
import { getCursorHint } from './cursor';

test('missing display falls back safely, including concurrent requests', async () => {
  const hints = await Promise.all([
    getCursorHint('invalid-display'), getCursorHint('invalid-display'),
  ]);
  for (const hint of hints) expect(hint).toEqual({ supported: false, textCursor: false });
  expect(await getCursorHint('invalid-display')).toEqual(hints[0]);
});
