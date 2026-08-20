import { describe, it, expect } from 'bun:test';
import { extractFrames, MjpegRing, socketBackedUp, planStreamQos } from '../capture';

const SOI = Buffer.from([0xff, 0xd8]);
const EOI = Buffer.from([0xff, 0xd9]);

/** Build a fake JPEG frame with a marker byte in the body (incl. a stray 0xFFD9). */
function fakeJpeg(tag: number, withStrayEoi = false): Buffer {
  const body = withStrayEoi
    ? Buffer.from([tag, 0x01, 0xff, 0xd9, 0x02]) // stray EOI inside scan data
    : Buffer.from([tag, 0x01, 0x02, 0x03]);
  return Buffer.concat([SOI, body, EOI]);
}

describe('extractFrames (MJPEG framing)', () => {
  it('returns no frames and empties the buffer when no SOI is present', () => {
    const { frames, rest } = extractFrames(Buffer.from([0x00, 0x11, 0x22]));
    expect(frames.length).toBe(0);
    expect(rest.length).toBe(0);
  });

  it('holds a single incomplete frame as remainder until the next SOI arrives', () => {
    const one = fakeJpeg(0xaa);
    const { frames, rest } = extractFrames(one);
    // A lone frame can't be closed until the following SOI, so it stays buffered.
    expect(frames.length).toBe(0);
    expect(rest.equals(one)).toBe(true);
  });

  it('emits complete frames delimited by the following SOI', () => {
    const a = fakeJpeg(0xaa);
    const b = fakeJpeg(0xbb);
    const c = fakeJpeg(0xcc);
    const { frames, rest } = extractFrames(Buffer.concat([a, b, c]));
    expect(frames.length).toBe(2);
    expect(frames[0]!.equals(a)).toBe(true);
    expect(frames[1]!.equals(b)).toBe(true);
    expect(rest.equals(c)).toBe(true); // last frame held until next SOI
  });

  it('is not fooled by stray 0xFFD9 bytes inside scan data', () => {
    const a = fakeJpeg(0xaa, true); // contains an embedded EOI
    const b = fakeJpeg(0xbb);
    const { frames, rest } = extractFrames(Buffer.concat([a, b]));
    expect(frames.length).toBe(1);
    expect(frames[0]!.equals(a)).toBe(true); // whole frame, not truncated at stray EOI
    expect(rest.equals(b)).toBe(true);
  });

  it('discards leading garbage before the first SOI', () => {
    const a = fakeJpeg(0xaa);
    const b = fakeJpeg(0xbb);
    const junk = Buffer.from([0x99, 0x88, 0x77]);
    const { frames } = extractFrames(Buffer.concat([junk, a, b]));
    expect(frames.length).toBe(1);
    expect(frames[0]!.equals(a)).toBe(true);
  });
});

describe('MjpegRing', () => {
  it('extracts complete frames without growing via concat', () => {
    const a = fakeJpeg(0xaa);
    const b = fakeJpeg(0xbb);
    const ring = new MjpegRing(4096);
    ring.append(a);
    expect(ring.takeFrames().length).toBe(0); // incomplete until next SOI
    ring.append(b);
    const frames = ring.takeFrames();
    expect(frames.length).toBe(1);
    expect(frames[0]!.equals(a)).toBe(true);
  });

  it('survives a chunk larger than capacity by keeping the tail', () => {
    const ring = new MjpegRing(16);
    ring.append(Buffer.alloc(64, 0x11));
    const frames = ring.takeFrames();
    expect(frames.length).toBe(0);
  });
});

describe('socketBackedUp', () => {
  it('drops when the socket already holds more than one frame', () => {
    const ws = { bufferedAmount: 80_000 } as unknown as WebSocket;
    expect(socketBackedUp(ws, 40_000)).toBe(true);
    expect(socketBackedUp({ bufferedAmount: 0 } as unknown as WebSocket, 40_000)).toBe(false);
  });
});

describe('planStreamQos', () => {
  it('never lowers capture fps, even with a clock-skewed age', () => {
    const r = planStreamQos({
      quality: 'medium',
      fps: 24,
      displayedFps: 24,
      decodeAgeMs: 5000,
      badStreak: 2,
    });
    expect(r.fps).toBe(24);
  });

  it('requires two consecutive bad reports before dropping quality', () => {
    const first = planStreamQos({
      quality: 'medium',
      fps: 24,
      displayedFps: 8,
      decodeAgeMs: 200,
      badStreak: 0,
    });
    expect(first.restart).toBe(false);
    expect(first.quality).toBe('medium');
    expect(first.fps).toBe(24);

    const second = planStreamQos({
      quality: 'medium',
      fps: 24,
      displayedFps: 8,
      decodeAgeMs: 200,
      badStreak: first.badStreak,
    });
    expect(second.restart).toBe(true);
    expect(second.quality).toBe('low');
    expect(second.fps).toBe(24);
  });

  it('does not drop fps when already at the lowest quality', () => {
    const r = planStreamQos({
      quality: 'low',
      fps: 24,
      displayedFps: 5,
      decodeAgeMs: 300,
      badStreak: 8,
    });
    expect(r.fps).toBe(24);
    expect(r.quality).toBe('low');
    expect(r.restart).toBe(false);
  });
});
