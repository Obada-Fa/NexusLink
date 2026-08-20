// WebRTC encoder pipeline: spins up a real virtual session and a real
// GStreamer webrtcbin agent, and asserts a valid H.264 SDP offer (plus ICE)
// reaches the signaling relay. Full negotiation needs a peer (the phone), so
// the test stops at offer/ICE generation — the part that proves the encode
// pipeline builds and plays. Skipped when GStreamer/PyGObject is missing.

import { describe, expect, test } from 'bun:test';
import { existsSync } from 'node:fs';
import type { WebRtcSignal, WsMessage } from '@nexuslink/rpc-types';
import { createAppSession, closeAppSession } from '../app-sessions';
import { webrtcAvailability, startWebrtc, stopWebrtc, setSend } from '../webrtc';

const hasStack =
  existsSync('/usr/bin/Xvfb') &&
  existsSync('/usr/share/applications/debian-xterm.desktop') &&
  webrtcAvailability().available;

describe('webrtc.start guards', () => {
  test('refuses a physical/desktop upgrade without a sessionId', () => {
    const res = startWebrtc(undefined, 24, { readyState: 1 } as unknown as WebSocket);
    expect(res.available).toBe(false);
    expect(res.reason ?? '').toContain('virtual');
  });
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

      const started = startWebrtc(session.sessionId, 20, fakeWs);
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

  test('reports unavailable for unknown sessions', () => {
    const res = startWebrtc('no-such-session', 24, { readyState: 1 } as unknown as WebSocket);
    expect(res.available).toBe(false);
  });
});
