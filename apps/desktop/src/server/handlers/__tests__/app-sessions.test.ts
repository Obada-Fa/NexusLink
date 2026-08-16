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
} from '../app-sessions';
import { startCapture, stopCapture, FRAME_MAGIC } from '../capture';
import { typeText } from '../input';

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
