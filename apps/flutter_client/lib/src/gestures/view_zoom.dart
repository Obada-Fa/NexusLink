// Local zoom/pan of the mirrored picture, plus mouse-mode pointer
// acceleration. Pure Dart so the math is unit-testable.
//
// The picture is painted into the view box with BoxFit (contain or fill) and
// then transformed by `translate(pan) * scale(scale)` about the view origin,
// the same transform GestureEngine.setCanvasTransform undoes for hit-testing.

import 'dart:math' as math;

import 'scale_to_host.dart';

const double minViewScale = 1;
const double maxViewScale = 8;

/// Where the fitted frame sits inside the view at scale 1 (view px).
typedef ContentRect = ({double x, double y, double w, double h});

ContentRect fittedContentRect(
  double viewW,
  double viewH,
  double hostW,
  double hostH,
  ScaleFit fit,
) {
  if (viewW <= 0 || viewH <= 0 || hostW <= 0 || hostH <= 0) {
    return (x: 0, y: 0, w: viewW, h: viewH);
  }
  if (fit == ScaleFit.fill) return (x: 0, y: 0, w: viewW, h: viewH);
  final hostAspect = hostW / hostH;
  if (viewW / viewH > hostAspect) {
    final w = viewH * hostAspect;
    return (x: (viewW - w) / 2, y: 0, w: w, h: viewH);
  }
  final h = viewW / hostAspect;
  return (x: 0, y: (viewH - h) / 2, w: viewW, h: h);
}

class ViewZoom {
  double scale = 1;
  double panX = 0;
  double panY = 0;

  bool get zoomed => scale > 1.01;

  void reset() {
    scale = 1;
    panX = 0;
    panY = 0;
  }

  /// View point → point in the untransformed (scale 1) view box.
  ({double x, double y}) toContent(double vx, double vy) =>
      (x: (vx - panX) / scale, y: (vy - panY) / scale);

  /// Untransformed view-box point → where it is drawn now.
  ({double x, double y}) toView(double cx, double cy) =>
      (x: cx * scale + panX, y: cy * scale + panY);

  /// One pinch/pan step: the content under the previous focal point
  /// (focal - delta) ends up under the new focal point, scaled by [ratio].
  void applyStep({
    required double ratio,
    required double focalX,
    required double focalY,
    required double dx,
    required double dy,
    required ContentRect rect,
    required double viewW,
    required double viewH,
  }) {
    final anchor = toContent(focalX - dx, focalY - dy);
    final next = (scale * (ratio.isFinite && ratio > 0 ? ratio : 1))
        .clamp(minViewScale, maxViewScale)
        .toDouble();
    scale = next;
    panX = focalX - anchor.x * next;
    panY = focalY - anchor.y * next;
    clamp(rect, viewW, viewH);
  }

  /// Keep the picture covering the view: no dragging it off-screen. An axis
  /// where the scaled picture is smaller than the view stays centred.
  void clamp(ContentRect rect, double viewW, double viewH) {
    if (scale <= minViewScale) {
      reset();
      return;
    }
    panX = _clampAxis(panX, rect.x, rect.w, viewW);
    panY = _clampAxis(panY, rect.y, rect.h, viewH);
  }

  double _clampAxis(double pan, double offset, double size, double view) {
    final scaled = size * scale;
    if (scaled <= view) return (view - scaled) / 2 - offset * scale;
    final lo = view - (offset + size) * scale; // right/bottom edge on screen
    final hi = -offset * scale; // left/top edge on screen
    return pan.clamp(lo, hi).toDouble();
  }

  /// Pan just enough that view point ([vx], [vy]) sits at least [margin]
  /// inside the view (mouse mode: the picture follows the cursor).
  void follow(
    double vx,
    double vy,
    double margin,
    ContentRect rect,
    double viewW,
    double viewH,
  ) {
    if (!zoomed) return;
    final m = math.min(margin, math.min(viewW, viewH) / 4);
    if (vx < m) panX += m - vx;
    if (vx > viewW - m) panX -= vx - (viewW - m);
    if (vy < m) panY += m - vy;
    if (vy > viewH - m) panY -= vy - (viewH - m);
    clamp(rect, viewW, viewH);
  }
}

/// Finger speed (view px per ms) → cursor gain. Slow strokes stay ~1:1 for
/// precise aiming; fast flicks cross the screen without re-gripping.
double pointerGain(double speedPxPerMs) {
  const lowSpeed = 0.15, highSpeed = 1.6;
  const lowGain = 0.9, highGain = 2.6;
  final t = ((speedPxPerMs - lowSpeed) / (highSpeed - lowSpeed))
      .clamp(0.0, 1.0)
      .toDouble();
  final smooth = t * t * (3 - 2 * t);
  return lowGain + (highGain - lowGain) * smooth;
}

/// Mouse-mode cursor kept on the phone in host px (capture-region space), so
/// it moves the instant the finger does instead of after a PC round trip.
class VirtualCursor {
  double x = 0;
  double y = 0;
  double _lastMs = -1;
  double _speed = 0;

  void placeAt(double hx, double hy) {
    x = hx;
    y = hy;
  }

  /// Move by a finger delta in VIEW px. [hostPerViewPx] converts on-screen
  /// distance to host px at the current zoom, so a zoomed view gives finer
  /// control automatically.
  void moveBy(
    double dx,
    double dy,
    double timestampMs,
    double hostPerViewPx,
    double hostW,
    double hostH,
  ) {
    final dt = _lastMs < 0 ? 16.0 : (timestampMs - _lastMs).clamp(4.0, 100.0);
    _lastMs = timestampMs;
    final raw = math.sqrt(dx * dx + dy * dy) / dt;
    // Light smoothing so one jittery sample doesn't spike the gain.
    _speed = _speed * 0.5 + raw * 0.5;
    final gain = pointerGain(_speed) * hostPerViewPx;
    x = (x + dx * gain).clamp(0.0, math.max(0.0, hostW - 1)).toDouble();
    y = (y + dy * gain).clamp(0.0, math.max(0.0, hostH - 1)).toDouble();
  }

  /// A new stroke starts from rest (no carried-over speed).
  void endStroke() {
    _lastMs = -1;
    _speed = 0;
  }
}
