// Extra-key encoding for the phone terminal (Terminus-style).
// Sticky Ctrl turns the next character into a control code (CTRL+C → 0x03);
// sticky Alt prefixes ESC. Arrow/function keys are raw VT sequences.

export interface ExtraKey {
  label: string;
  /** Raw bytes to send, or a named modifier. */
  code: string;
  modifier?: 'ctrl' | 'alt';
}

export const EXTRA_KEYS_ROW1: ExtraKey[] = [
  { label: 'ESC', code: '\x1b' },
  { label: 'TAB', code: '\t' },
  { label: 'CTRL', code: 'CTRL', modifier: 'ctrl' },
  { label: 'ALT', code: 'ALT', modifier: 'alt' },
  { label: '/', code: '/' },
  { label: '-', code: '-' },
  { label: '|', code: '|' },
  { label: '_', code: '_' },
];

export const EXTRA_KEYS_ROW2: ExtraKey[] = [
  { label: '←', code: '\x1b[D' },
  { label: '↑', code: '\x1b[A' },
  { label: '↓', code: '\x1b[B' },
  { label: '→', code: '\x1b[C' },
  { label: '⌂', code: '\x1b[H' }, // Home
  { label: 'END', code: '\x1b[F' },
  { label: 'PG↑', code: '\x1b[5~' },
  { label: 'PG↓', code: '\x1b[6~' },
];

export const EXTRA_KEYS_ROW3: ExtraKey[] = [
  { label: '^C', code: '\x03' },
  { label: '^D', code: '\x04' },
  { label: '^Z', code: '\x1a' },
  { label: '^L', code: '\x0c' },
  { label: '^A', code: '\x01' },
  { label: '^W', code: '\x17' },
  { label: '^U', code: '\x15' },
  { label: '^R', code: '\x12' },
];

/** Apply sticky Ctrl/Alt to a payload about to be sent to the PTY. */
export function applyStickyModifiers(
  data: string,
  ctrl: boolean,
  alt: boolean,
): { data: string; ctrl: boolean; alt: boolean } {
  let out = data;
  let nextCtrl = ctrl;
  let nextAlt = alt;
  if (ctrl && out.length === 1) {
    const ch = out.toUpperCase();
    if (ch >= 'A' && ch <= 'Z') {
      out = String.fromCharCode(ch.charCodeAt(0) & 0x1f);
      nextCtrl = false;
    } else if (out === ' ') {
      out = '\0';
      nextCtrl = false;
    }
  }
  if (alt) {
    out = '\x1b' + out;
    nextAlt = false;
  }
  return { data: out, ctrl: nextCtrl, alt: nextAlt };
}
