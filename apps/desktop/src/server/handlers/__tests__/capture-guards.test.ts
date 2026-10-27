// Capture backpressure, per-frame authorization and monitor geometry. A fake
// `ffmpeg` on PATH emits tiny JPEG markers, and the xrandr probe is stubbed, so
// nothing here touches the real X display.
import { afterAll, afterEach, beforeAll, describe, expect, it } from 'bun:test';
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  CAPTURE_MAX_BUFFERED_BYTES,
  getCaptureInfo,
  getPrimaryMonitor,
  getScreenMetadata,
  listMonitors,
  parseListActiveMonitors,
  parseXrandrCurrent,
  setCaptureAuthorizer,
  setGeometryProbeForTests,
  socketBackedUp,
  socketBufferedAmount,
  startCapture,
  stopCapture,
} from '../capture';

const XRANDR_TWO = `Screen 0: minimum 320 x 200, current 1920 x 2280, maximum 16384 x 16384
DisplayPort-0 connected 1920x1200+0+0 (normal left inverted right x axis y axis) 527mm x 296mm
   1920x1200     59.95*+
HDMI-A-0 connected primary 1920x1080+0+1200 (normal left inverted right x axis y axis) 0mm x 0mm
   1920x1080     60.00*+
DisplayPort-1 connected (normal left inverted right x axis y axis)
HDMI-A-1 disconnected (normal left inverted right x axis y axis)
`;
const XRANDR_ONE = `Screen 0: minimum 320 x 200, current 1280 x 720, maximum 16384 x 16384
HDMI-A-0 connected primary 1280x720+0+0 (normal left inverted right x axis y axis) 0mm x 0mm
DisplayPort-0 connected (normal left inverted right x axis y axis)
`;

let xrandr = XRANDR_TWO;
let probes = 0;
const fakeBin = mkdtempSync(join(tmpdir(), 'nl-fake-ffmpeg-'));
const realPath = process.env.PATH;

beforeAll(() => {
  // Emits a fake JPEG (SOI ... EOI) every 20 ms until killed.
  writeFileSync(join(fakeBin, 'ffmpeg'), "#!/bin/sh\nwhile :; do printf '\\377\\330AB\\377\\331'; sleep 0.02; done\n");
  chmodSync(join(fakeBin, 'ffmpeg'), 0o755);
  process.env.PATH = `${fakeBin}:${realPath}`;
  setGeometryProbeForTests((args) => {
    probes++;
    return args[1] === '--current' ? xrandr : '';
  });
});
afterAll(() => {
  process.env.PATH = realPath;
  setGeometryProbeForTests(null);
  setCaptureAuthorizer(null);
  rmSync(fakeBin, { recursive: true, force: true });
});
afterEach(() => {
  setCaptureAuthorizer(null);
  xrandr = XRANDR_TWO;
});

function fakeSocket(buffered = () => 0) {
  const sent: Uint8Array[] = [];
  const ws = { readyState: 1, getBufferedAmount: buffered, send: (b: Uint8Array) => { sent.push(b); return b.length; } };
  return { ws: ws as unknown as WebSocket, sent };
}
const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

describe('capture backpressure', () => {
  it('reads Bun getBufferedAmount() (bufferedAmount is undefined on ServerWebSocket)', () => {
    const bunWs = { getBufferedAmount: () => 900_000 } as unknown as WebSocket;
    expect(socketBufferedAmount(bunWs)).toBe(900_000);
    expect(socketBackedUp(bunWs, 40_000)).toBe(true);
    expect(socketBackedUp({ getBufferedAmount: () => 0 } as unknown as WebSocket, 40_000)).toBe(false);
  });

  it('never lets a huge last frame raise the drop threshold past the hard cap', () => {
    const ws = { getBufferedAmount: () => CAPTURE_MAX_BUFFERED_BYTES + 1 } as unknown as WebSocket;
    expect(socketBackedUp(ws, 10_000_000)).toBe(true);
  });

  it('drops frames instead of queueing while the socket is backed up', async () => {
    const { ws, sent } = fakeSocket(() => 2_000_000);
    const { streamId } = startCapture('low', 30, ws);
    try {
      await wait(400);
      expect(sent.length).toBe(0);
      expect(getCaptureInfo(streamId)!.droppedFrames).toBeGreaterThan(0);
    } finally {
      stopCapture(streamId);
    }
  });
});

describe('capture authorizer', () => {
  it('streams while authorized and stops the capture once authorization fails', async () => {
    let allowed = true;
    const { ws, sent } = fakeSocket();
    setCaptureAuthorizer((sock) => sock === ws && allowed);
    const { streamId } = startCapture('low', 30, ws);
    await wait(400);
    expect(sent.length).toBeGreaterThan(0);
    allowed = false;
    await wait(300);
    expect(getCaptureInfo(streamId)).toBeNull();
    const after = sent.length;
    await wait(200);
    expect(sent.length).toBe(after);
  });

  it('treats a throwing authorizer as unauthorized', async () => {
    const { ws, sent } = fakeSocket();
    setCaptureAuthorizer(() => { throw new Error('db closed'); });
    const { streamId } = startCapture('low', 30, ws);
    await wait(300);
    expect(sent.length).toBe(0);
    expect(getCaptureInfo(streamId)).toBeNull();
  });
});

describe('monitor geometry', () => {
  it('parses xrandr --current, skipping inactive outputs', () => {
    const { screen, monitors } = parseXrandrCurrent(XRANDR_TWO);
    expect(screen).toEqual({ width: 1920, height: 2280 });
    expect(monitors).toEqual([
      { name: 'DisplayPort-0', primary: false, width: 1920, height: 1200, x: 0, y: 0 },
      { name: 'HDMI-A-0', primary: true, width: 1920, height: 1080, x: 0, y: 1200 },
    ]);
  });

  it('parses xrandr --listactivemonitors', () => {
    const mons = parseListActiveMonitors('Monitors: 2\n 0: +*HDMI-A-0 1920/508x1080/286+0+1200  HDMI-A-0\n 1: +DisplayPort-0 1920/527x1200/296+0+0  DisplayPort-0\n');
    expect(mons[0]).toEqual({ name: 'HDMI-A-0', primary: true, width: 1920, height: 1080, x: 0, y: 1200 });
    expect(mons[1]!.primary).toBe(false);
  });

  it('re-reads geometry on every startCapture so resolution changes are honoured', () => {
    const { ws } = fakeSocket();
    expect(getScreenMetadata()).toEqual({ width: 1920, height: 2280 });
    xrandr = XRANDR_ONE;
    // Cached reads stay within the TTL...
    expect(getScreenMetadata().width).toBe(1920);
    // ...but a new capture sees the new layout immediately.
    const r = startCapture('low', 10, ws);
    try {
      expect(r.region).toEqual({ x: 0, y: 0, width: 1280, height: 720 });
      expect(r.monitor).toBe('HDMI-A-0');
      expect(getScreenMetadata()).toEqual({ width: 1280, height: 720 });
      expect(getPrimaryMonitor()).toEqual({ x: 0, y: 0, width: 1280, height: 720 });
    } finally {
      stopCapture(r.streamId);
    }
  });

  it('captures a named monitor and rejects unknown names', () => {
    const { ws } = fakeSocket();
    expect(listMonitors({ fresh: true }).map((m) => m.name)).toEqual(['DisplayPort-0', 'HDMI-A-0']);
    const r = startCapture('low', 10, ws, undefined, undefined, undefined, { monitor: 'displayport-0' });
    try {
      expect(r.region).toEqual({ x: 0, y: 0, width: 1920, height: 1200 });
      expect(r.monitor).toBe('DisplayPort-0');
    } finally {
      stopCapture(r.streamId);
    }
    expect(() => startCapture('low', 10, ws, undefined, undefined, undefined, { monitor: 'VGA-9' })).toThrow(/Unknown monitor/);
  });

  it('keeps the last good layout when a probe fails transiently', () => {
    listMonitors({ fresh: true });
    const before = probes;
    xrandr = '';
    const mons = listMonitors({ fresh: true });
    expect(probes).toBeGreaterThan(before);
    expect(mons.map((m) => m.name)).toEqual(['DisplayPort-0', 'HDMI-A-0']);
  });
});
