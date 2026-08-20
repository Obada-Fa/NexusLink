import 'package:flutter/material.dart';
import 'dart:ui' as ui;

/// Paints a decoded [ui.Image]. Repaint is driven by [repaint], not setState.
class MirrorFramePainter extends CustomPainter {
  MirrorFramePainter({
    required this.image,
    required this.fit,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final ui.Image? image;
  final BoxFit fit;

  @override
  void paint(Canvas canvas, Size size) {
    final img = image;
    if (img == null) return;
    final src = Rect.fromLTWH(
      0,
      0,
      img.width.toDouble(),
      img.height.toDouble(),
    );
    final fitted = applyBoxFit(fit, src.size, size);
    final dest = Alignment.center.inscribe(fitted.destination, Offset.zero & size);
    canvas.drawImageRect(
      img,
      src,
      dest,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(MirrorFramePainter old) =>
      old.image != image || old.fit != fit;
}
