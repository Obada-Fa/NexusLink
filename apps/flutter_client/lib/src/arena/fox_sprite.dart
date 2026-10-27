import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Red Fox atlas (MIT, Virtual Pet Desktop contributors — assets/arena/FOX-CREDITS.txt):
/// 4 columns × 8 rows of frames. Decoded at half size: 112 px frames are plenty on a phone.
const _frame = 112.0;

final foxAtlasProvider = FutureProvider<ui.Image>((ref) async {
  final data = await rootBundle.load('assets/arena/fox-atlas.png');
  final codec = await ui.instantiateImageCodec(
    data.buffer.asUint8List(),
    targetWidth: 448,
  );
  return (await codec.getNextFrame()).image;
});

enum FoxClip {
  idle(0, 420),
  walk(1, 120),
  run(2, 85),
  call(3, 120),
  play(4, 140),
  sleep(5, 520),
  attention(6, 250),
  sniff(7, 180);

  const FoxClip(this.row, this.frameMs);
  final int row;
  final int frameMs;
}

/// What a fox does for an agent state — same moods as the Android floating pet.
/// [stateAgeMs] = time since the state last changed; [clockMs] = scene time.
FoxClip foxClipFor({
  required String state,
  String? activity,
  required int stateAgeMs,
  required int clockMs,
  bool celebrating = false,
}) {
  if (celebrating) return FoxClip.play;
  switch (state) {
    case 'waiting':
      return stateAgeMs % 6000 < 900 ? FoxClip.call : FoxClip.attention;
    case 'failed':
      return FoxClip.attention;
    case 'working':
      return switch (activity) {
        'running-command' => FoxClip.run,
        'reading' || 'searching' || 'browsing' => FoxClip.sniff,
        'editing' => FoxClip.play,
        'thinking' || 'responding' => FoxClip.walk,
        _ => clockMs % 9000 < 6500 ? FoxClip.run : FoxClip.sniff,
      };
    case 'done':
      return stateAgeMs > 90000 ? FoxClip.sleep : FoxClip.idle;
    default:
      return FoxClip.sleep;
  }
}

/// Draws one frame of [clip] into [dst]; [flip] faces left.
void paintFox(
  Canvas canvas,
  ui.Image atlas,
  FoxClip clip,
  int clockMs,
  Rect dst, {
  bool flip = false,
  bool reduced = false,
  double opacity = 1,
}) {
  final frame = reduced
      ? (clip == FoxClip.sleep ? 2 : 0)
      : (clockMs ~/ clip.frameMs) % 4;
  final src = Rect.fromLTWH(frame * _frame, clip.row * _frame, _frame, _frame);
  final paint = Paint()
    ..filterQuality = FilterQuality.medium
    ..color = Color.fromRGBO(0, 0, 0, opacity);
  // Soft contact shadow.
  canvas.drawOval(
    Rect.fromCenter(
      center: Offset(dst.center.dx, dst.bottom - dst.height * .07),
      width: dst.width * .62,
      height: dst.height * .1,
    ),
    Paint()..color = const Color(0x66000000),
  );
  if (flip) {
    canvas.save();
    canvas.translate(dst.center.dx, 0);
    canvas.scale(-1, 1);
    canvas.translate(-dst.center.dx, 0);
    canvas.drawImageRect(atlas, src, dst, paint);
    canvas.restore();
  } else {
    canvas.drawImageRect(atlas, src, dst, paint);
  }
}

/// Deterministic confetti burst, [t] in 0..1 over its lifetime.
void paintConfetti(
  Canvas canvas,
  Offset origin,
  double t,
  int seed,
  List<Color> colors,
) {
  if (t <= 0 || t >= 1) return;
  final rnd = math.Random(seed);
  for (var i = 0; i < 22; i++) {
    final angle = -math.pi / 2 + (rnd.nextDouble() - .5) * math.pi * 1.1;
    final speed = 90 + rnd.nextDouble() * 110;
    final time = t * 1.6;
    final p =
        origin +
        Offset(
          math.cos(angle) * speed * time,
          math.sin(angle) * speed * time + 140 * time * time,
        );
    final size = 3.0 + rnd.nextDouble() * 3;
    canvas.save();
    canvas.translate(p.dx, p.dy);
    canvas.rotate(time * (4 + rnd.nextDouble() * 6));
    canvas.drawRect(
      Rect.fromCenter(center: Offset.zero, width: size, height: size * .55),
      Paint()
        ..color = colors[i % colors.length].withValues(
          alpha: (1 - t).clamp(0, 1),
        ),
    );
    canvas.restore();
  }
}
