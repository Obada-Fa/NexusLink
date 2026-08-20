import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// Latest-frame-wins gate: a newer JPEG always replaces a queued one so the
/// decoder never renders stale pictures when the network is faster than paint.
class LatestJpegGate {
  Uint8List? _pending;
  bool _busy = false;

  void offer(Uint8List jpeg) => _pending = jpeg;

  bool get hasPending => _pending != null;
  bool get busy => _busy;

  /// Take the newest pending JPEG. Returns null if empty.
  Uint8List? take() {
    final jpeg = _pending;
    _pending = null;
    return jpeg;
  }

  void markBusy(bool value) => _busy = value;
}

/// Decode JPEG off the UI isolate via Flutter's image codec (engine worker),
/// posting a [ui.Image] for [CustomPainter]. Drops in-flight decodes when a
/// newer frame is already waiting.
class MirrorFrameSink {
  MirrorFrameSink({
    required this.onImage,
    this.onDisplayed,
    this.onDecodeAge,
  });

  final void Function(ui.Image image) onImage;
  final VoidCallback? onDisplayed;
  final void Function(int decodeAgeMs)? onDecodeAge;

  /// Decode at the painted pixel width when set (less work on the phone).
  int? targetWidth;

  final LatestJpegGate _gate = LatestJpegGate();
  bool _closed = false;

  void pushJpeg(Uint8List jpeg) {
    if (_closed) return;
    _gate.offer(jpeg);
    _drain();
  }

  Future<void> _drain() async {
    if (_gate.busy || _closed) return;
    _gate.markBusy(true);
    try {
      while (!_closed) {
        final jpeg = _gate.take();
        if (jpeg == null) break;
        try {
          final started = DateTime.now();
          final codec = await ui.instantiateImageCodec(
            jpeg,
            targetWidth: targetWidth,
          );
          final frame = await codec.getNextFrame();
          codec.dispose();
          onDecodeAge?.call(DateTime.now().difference(started).inMilliseconds);
          if (_closed || _gate.hasPending) {
            frame.image.dispose();
            continue;
          }
          onImage(frame.image);
          onDisplayed?.call();
        } catch (_) {
          // Corrupt JPEG — skip.
        }
      }
    } finally {
      _gate.markBusy(false);
      if (!_closed && _gate.hasPending) {
        await _drain();
      }
    }
  }

  void dispose() {
    _closed = true;
    _gate.take();
  }
}
