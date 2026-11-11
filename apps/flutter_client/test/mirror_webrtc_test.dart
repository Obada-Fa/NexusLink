import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/screens/mirror_webrtc.dart';

void main() {
  test(
    'keeps MJPEG until the first H.264 picture and ignores late pictures',
    () {
      final playback = MirrorPlayback();
      expect(playback.codec, MirrorCodec.mjpeg);
      playback.begin(Duration.zero);
      expect(playback.codec, MirrorCodec.connecting);
      expect(playback.expired(const Duration(seconds: 5)), isFalse);
      expect(playback.expired(MirrorPlayback.startTimeout), isTrue);
      expect(playback.firstPicture(MirrorPlayback.startTimeout), isFalse);
      playback.fallback();
      expect(playback.codec, MirrorCodec.mjpeg);
      expect(playback.firstPicture(const Duration(seconds: 7)), isFalse);
    },
  );

  test('recovers to MJPEG on stall and can try again after a crop change', () {
    final playback = MirrorPlayback()..begin(Duration.zero);
    expect(playback.firstPicture(const Duration(seconds: 2)), isTrue);
    expect(playback.codec, MirrorCodec.h264);
    playback.pictureProgress(const Duration(seconds: 5));
    expect(playback.expired(const Duration(seconds: 9)), isFalse);
    expect(playback.expired(const Duration(seconds: 10)), isTrue);
    playback.fallback();
    expect(playback.codec, MirrorCodec.mjpeg);
    playback.begin(const Duration(seconds: 10));
    expect(playback.firstPicture(const Duration(seconds: 11)), isTrue);
    expect(playback.codec, MirrorCodec.h264);
  });

  test('WebRTC rates use video counter deltas and elapsed receiver time', () {
    const before = MirrorRtcCounters(
      at: Duration(seconds: 2),
      id: 'video',
      bytes: 20000,
      frames: 10,
      received: 91,
      lost: 1,
      jitterMs: 10,
    );
    const after = MirrorRtcCounters(
      at: Duration(seconds: 4),
      id: 'video',
      bytes: 770000,
      frames: 58,
      received: 189,
      lost: 3,
      jitterMs: 12,
      rttMs: 85,
    );
    final rates = after.since(before)!;
    expect(rates.kbitPerSecond, 3000);
    expect(rates.fps, 24);
    expect(rates.loss, 0.02);
    expect(rates.jitterMs, 12);
    expect(rates.rttMs, 85);
    expect(before.since(after), isNull);
  });

  test('retries H.264 with backoff, never after the capture or host refuses', () {
    final policy = MirrorRetryPolicy();
    expect(policy.afterFallback('capture-ended', Duration.zero), isNull);
    expect(policy.afterFallback('unavailable', Duration.zero), isNull);
    expect(policy.afterFallback('region-changed', Duration.zero), Duration.zero);
    final waits = [
      for (var i = 0; i < 5; i++) policy.afterFallback('failed', Duration.zero),
    ];
    expect(waits, [
      const Duration(seconds: 10),
      const Duration(seconds: 30),
      const Duration(seconds: 60),
      const Duration(minutes: 2),
      const Duration(minutes: 2),
    ]);
    // A long healthy run followed by one stall starts the backoff over.
    expect(
      policy.afterFallback(null, MirrorRetryPolicy.healthyRun),
      const Duration(seconds: 10),
    );
    expect(
      policy.afterFallback(null, const Duration(seconds: 5)),
      const Duration(seconds: 30),
    );
  });
}
