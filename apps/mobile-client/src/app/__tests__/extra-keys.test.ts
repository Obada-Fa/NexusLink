import { describe, expect, it } from 'bun:test';
import { applyStickyModifiers, EXTRA_KEYS_ROW1, EXTRA_KEYS_ROW3 } from '@/lib/extra-keys';

describe('applyStickyModifiers', () => {
  it('CTRL+C becomes ETX (0x03)', () => {
    expect(applyStickyModifiers('c', true, false)).toEqual({
      data: '\x03',
      ctrl: false,
      alt: false,
    });
    expect(applyStickyModifiers('C', true, false).data).toBe('\x03');
  });

  it('CTRL+D / CTRL+Z match Terminus control codes', () => {
    expect(applyStickyModifiers('d', true, false).data).toBe('\x04');
    expect(applyStickyModifiers('z', true, false).data).toBe('\x1a');
  });

  it('Alt prefixes ESC and consumes the sticky state', () => {
    expect(applyStickyModifiers('b', false, true)).toEqual({
      data: '\x1bb',
      ctrl: false,
      alt: false,
    });
  });

  it('leaves unmodified input alone', () => {
    expect(applyStickyModifiers('ls\r', false, false)).toEqual({
      data: 'ls\r',
      ctrl: false,
      alt: false,
    });
  });
});

describe('extra key layout', () => {
  it('exposes sticky Ctrl/Alt and a dedicated ^C', () => {
    expect(EXTRA_KEYS_ROW1.some((k) => k.modifier === 'ctrl')).toBe(true);
    expect(EXTRA_KEYS_ROW3.find((k) => k.label === '^C')?.code).toBe('\x03');
  });
});
