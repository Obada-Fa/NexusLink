// WebRTC encoder pipeline: spins up a real virtual session and a real
// GStreamer webrtcbin agent, and asserts a valid H.264 SDP offer (plus ICE)
// reaches the signaling relay. Full negotiation needs a peer (the phone), so
// the test stops at offer/ICE generation — the part that proves the encode
// pipeline builds and plays. Skipped when GStreamer/PyGObject is missing.

import { describe, expect, test } from 'bun:test';
import { existsSync } from 'node:fs';
import type { WebRtcSignal, WsMessage } from '@nexuslink/rpc-types';
import { createAppSession, closeAppSession } from '../app-sessions';
import { planWebrtcBitrate, planWebrtcZoom, webrtcAvailability, startWebrtc, stopWebrtc, setSend } from '../webrtc';
import { clampRegion } from '../capture';

const hasStack =
  existsSync('/usr/bin/Xvfb') &&
  existsSync('/usr/share/applications/debian-xterm.desktop') &&
  (await webrtcAvailability()).available;

describe('webrtc.start guards', () => {
  test('requires a capture owned by the connection or a legacy virtual session', async () => {
    const socket = { readyState: 1 } as unknown as WebSocket;
    const res = await startWebrtc({}, socket);
    expect(res.available).toBe(false);
    expect(res.reason).toContain('screen capture');
    expect((await startWebrtc({ streamId: 'unowned' }, socket)).reason).toContain('this connection');
  });
});

test('capture crop intersects the display and keeps even dimensions', () => {
  const screen = { width: 1920, height: 1080 };
  expect(clampRegion({ x: -21, y: -6, width: 200, height: 90 }, screen))
    .toEqual({ x: 0, y: 0, width: 178, height: 84 });
  expect(clampRegion({ x: 1700, y: 1000, width: 300, height: 300 }, screen))
    .toEqual({ x: 1700, y: 1000, width: 220, height: 80 });
  expect(clampRegion({ x: 2000, y: 0, width: 100, height: 100 }, screen).width).toBe(0);
});

test('H.264 bitrate respects the floor and waits for sustained congestion or recovery', () => {
  let state = { step: 2, bad: 0, good: 0, zoomed: false };
  const bad = { kind: 'stats', fps: 12, loss: 0.07, jitterMs: 10 } as const;
  const good = { kind: 'stats', fps: 24, loss: 0, jitterMs: 8 } as const;
  state = planWebrtcBitrate(state, bad, 24);
  expect(state.step).toBe(2);
  state = planWebrtcBitrate(state, bad, 24);
  expect(state.step).toBe(1);
  for (let sample = 0; sample < 8; sample++) state = planWebrtcBitrate(state, bad, 24);
  expect(state.step).toBe(0);
  for (let sample = 0; sample < 3; sample++) state = planWebrtcBitrate(state, good, 24);
  expect(state.step).toBe(0);
  expect(planWebrtcBitrate(state, good, 24).step).toBe(1);
});

test('zoom immediately adds one bitrate step and unzoom restores the normal ceiling', () => {
  const initial = { step: 2, bad: 1, good: 0, zoomed: false };
  const zoomed = planWebrtcZoom(initial, true);
  expect(zoomed).toEqual({ step: 3, bad: 0, good: 0, zoomed: true });
  expect(planWebrtcZoom(zoomed, true)).toBe(zoomed);
  expect(planWebrtcZoom(zoomed, false).step).toBe(2);
});

describe.if(hasStack)('webrtc pipeline', () => {
  test(
    'agent builds the encode pipeline and emits an H.264 offer + ICE',
    async () => {
      const session = await createAppSession('debian-xterm', 390, 844, 1);
      const signals: WebRtcSignal[] = [];
      setSend((_ws, msg: WsMessage) => {
        if (msg.type === 'webrtc-signal') signals.push(msg.data);
      });
      const fakeWs = { readyState: 1 } as unknown as WebSocket;

      const started = await startWebrtc({ sessionId: session.sessionId, fps: 20 }, fakeWs);
      try {
        expect(started.available).toBe(true);
        expect(started.webrtcId).toBeTruthy();

        const deadline = Date.now() + 15_000;
        while (Date.now() < deadline) {
          const offer = signals.find((s) => s.kind === 'offer');
          const ice = signals.find((s) => s.kind === 'ice');
          if (offer && ice) break;
          await Bun.sleep(150);
        }

        const offer = signals.find((s) => s.kind === 'offer');
        expect(offer).toBeTruthy();
        if (offer && offer.kind === 'offer') {
          expect(offer.sdp).toContain('m=video');
          expect(offer.sdp).toContain('H264');
        }
        expect(signals.some((s) => s.kind === 'ice')).toBe(true);
      } finally {
        if (started.webrtcId) stopWebrtc(started.webrtcId);
        closeAppSession(session.sessionId);
        setSend(() => {});
      }
    },
    30_000,
  );

  test('reports unavailable for unknown sessions', async () => {
    const res = await startWebrtc({ sessionId: 'no-such-session' }, { readyState: 1 } as unknown as WebSocket);
    expect(res.available).toBe(false);
  });
});
