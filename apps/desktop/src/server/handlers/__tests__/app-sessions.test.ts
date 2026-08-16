// Virtual app session lifecycle, headless integration: real Xvfb + openbox +
// xterm, real ffmpeg capture, real xdotool injection. Skipped automatically on
// hosts without the X tooling.

import { describe, expect, test } from 'bun:test';
import { existsSync } from 'node:fs';
import {
  computeSessionGeometry,
  createAppSession,
  getSessionDisplay,
  listAppSessions,
  closeAppSession,
  ensurePortrait,
} from '../app-sessions';
import { startCapture, stopCapture, FRAME_MAGIC } from '../capture';
import { typeText } from '../input';
import { findChromeBin } from '../app-profiles';

const hasStack =
  existsSync('/usr/bin/Xvfb') &&
  existsSync('/usr/bin/xdotool') &&
  existsSync('/usr/bin/ffmpeg') &&
  existsSync('/usr/share/applications/debian-xterm.desktop');

describe('computeSessionGeometry', () => {
  test('honors DPR when under the pixel budget', () => {
    const g = computeSessionGeometry(390, 844, 2);
    expect(g.width).toBe(780);
    expect(g.height).toBe(1688);
    expect(g.dpr).toBe(2);
  });

  test('clamps total pixels while preserving aspect ratio', () => {
    const g = computeSessionGeometry(480, 1040, 3); // 3x would be 4.5MP
    expect(g.width * g.height).toBeLessThanOrEqual(2_300_000);
    const want = 480 / 1040;
    const got = g.width / g.height;
    expect(Math.abs(got - want) / want).toBeLessThan(0.01);
  });

  test('even-aligns dimensions for the video pipeline', () => {
    const g = computeSessionGeometry(393, 851, 2.625);
    expect(g.width % 2).toBe(0);
    expect(g.height % 2).toBe(0);
  });
});

describe('ensurePortrait', () => {
  test('leaves portrait sizes alone', () => {
    expect(ensurePortrait(390, 844)).toEqual({ width: 390, height: 844 });
  });

  test('swaps landscape so the virtual monitor is phone-shaped', () => {
    expect(ensurePortrait(844, 390)).toEqual({ width: 390, height: 844 });
  });
});

describe.if(hasStack)('app session integration (Xvfb + xterm)', () => {
  test(
    'create → stream frames → inject input → close',
    async () => {
      const info = await createAppSession('debian-xterm', 390, 844, 1);
      try {
        expect(info.status).toBe('running');
        expect(info.width).toBe(390);
        expect(info.height).toBe(844);
        expect(info.display).toMatch(/^:\d+$/);

        // Session appears in the list and resolves to its display.
        expect(listAppSessions().some((s) => s.sessionId === info.sessionId)).toBe(true);
        expect(getSessionDisplay(info.sessionId)).toBe(info.display);

        // Give xterm a beat to map its window under openbox.
        await Bun.sleep(1500);

        // Frames stream from the VIRTUAL display: full surface, 1:1, JPEG.
        const received: Buffer[] = [];
        const fakeWs = {
          readyState: 1,
          send(buf: Uint8Array) {
            received.push(Buffer.from(buf));
          },
        } as unknown as WebSocket;

        const cap = startCapture(
          'medium', 15, fakeWs,
          { x: 0, y: 0, width: info.width, height: info.height },
          undefined,
          info.display,
        );
        expect(cap.region).toEqual({ x: 0, y: 0, width: 390, height: 844 });

        const deadline = Date.now() + 8000;
        while (received.length < 3 && Date.now() < deadline) {
          await Bun.sleep(100);
        }
        stopCapture(cap.streamId);
        expect(received.length).toBeGreaterThanOrEqual(3);

        // Binary frame = NLF1 header + JPEG (SOI marker).
        const frame = received[0]!;
        expect(frame.readUInt32LE(0)).toBe(FRAME_MAGIC);
        expect(frame[16]).toBe(0xff);
        expect(frame[17]).toBe(0xd8);

        // Input injection binds to the session display without throwing.
        expect(typeText('echo nexuslink', info.display).ok).toBe(true);
      } finally {
        const closed = closeAppSession(info.sessionId);
        expect(closed.ok).toBe(true);
        expect(getSessionDisplay(info.sessionId)).toBeNull();
      }
    },
    30_000,
  );
});

const hasChrome = hasStack && !!findChromeBin() && existsSync('/usr/bin/xwininfo');

function windowGeom(display: string, windowId: string): { width: number; height: number } | null {
  const out = Bun.spawnSync(['xwininfo', '-id', windowId], {
    env: { ...process.env, DISPLAY: display },
    stderr: 'ignore',
  });
  const text = out.stdout?.toString() ?? '';
  const w = text.match(/Width:\s*(\d+)/)?.[1];
  const h = text.match(/Height:\s*(\d+)/)?.[1];
  if (!w || !h) return null;
  return { width: parseInt(w, 10), height: parseInt(h, 10) };
}

function sessionWindowIds(display: string): string[] {
  const out = Bun.spawnSync(['wmctrl', '-l'], {
    env: { ...process.env, DISPLAY: display },
    stderr: 'ignore',
  });
  return (out.stdout?.toString() ?? '')
    .split('\n')
    .flatMap((line) => {
      const m = line.match(/^(0x[0-9a-f]+)/i);
      return m ? [m[1]!] : [];
    });
}

describe.if(hasChrome)('chromium fills the portrait virtual monitor', () => {
  test(
    'Chrome window covers the Xvfb (not a landscape strip on black)',
    async () => {
      const info = await createAppSession('nexus.chrome-mobile', 390, 844, 2);
      try {
        expect(info.width).toBeLessThan(info.height);
        const deadline = Date.now() + 12_000;
        let best = { width: 0, height: 0 };
        while (Date.now() < deadline) {
          for (const id of sessionWindowIds(info.display)) {
            const g = windowGeom(info.display, id);
            if (g && g.width * g.height > best.width * best.height) best = g;
          }
          if (best.height >= info.height * 0.85 && best.width >= info.width * 0.85) break;
          await Bun.sleep(250);
        }
        expect(best.width).toBeGreaterThanOrEqual(Math.round(info.width * 0.85));
        expect(best.height).toBeGreaterThanOrEqual(Math.round(info.height * 0.85));
        expect(best.height).toBeGreaterThan(best.width);
      } finally {
        closeAppSession(info.sessionId);
      }
    },
    30_000,
  );
});
