// Flat, instrument-style history charts for Desktop and the PC detail views.
//
// Design rules: no smoothing curves, no gradients, no glow. Samples are
// averaged to the available pixels so 2-second jitter doesn't turn into a
// zig-zag; the newest reading sits at the right edge and is marked; axes are
// faint and labelled with real values.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/nexus_theme.dart';

/// Averages [values] into at most [buckets] groups, keeping the newest last.
List<double> bucketMeans(List<double> values, int buckets) {
  if (buckets <= 0 || values.isEmpty) return const [];
  if (values.length <= buckets) return values;
  final out = <double>[];
  final size = values.length / buckets;
  for (var b = 0; b < buckets; b++) {
    final start = (b * size).floor();
    final end = math.max(start + 1, ((b + 1) * size).floor());
    var sum = 0.0;
    for (var i = start; i < end && i < values.length; i++) {
      sum += values[i];
    }
    out.add(sum / (end - start));
  }
  return out;
}

/// "Nice" axis bounds and step for [lo]..[hi] with about [ticks] intervals.
({double min, double max, double step}) niceAxis(
  double lo,
  double hi, {
  int ticks = 2,
  bool fromZero = false,
}) {
  if (fromZero) lo = math.min(0, lo);
  if (hi - lo < 1e-9) {
    hi = lo + (lo.abs() < 1 ? 1 : lo.abs() * .1);
  }
  final raw = (hi - lo) / ticks;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  final step =
      (norm <= 1
          ? 1
          : norm <= 2
          ? 2
          : norm <= 2.5
          ? 2.5
          : norm <= 5
          ? 5
          : 10) *
      mag;
  return (
    min: (lo / step).floor() * step,
    max: (hi / step).ceil() * step,
    step: step,
  );
}

/// Thin vertical bars of recent history, newest at the right. For table rows.
class HistoryBars extends StatelessWidget {
  const HistoryBars({
    super.key,
    required this.values,
    this.max = 100,
    this.color = NX.accent,
    this.height = 18,
    this.width = 48,
  });
  final List<double> values;
  final double max;
  final Color color;
  final double height;
  final double width;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: RepaintBoundary(
      child: CustomPaint(
        size: Size(width, height),
        painter: _BarsPainter(values, max, color),
      ),
    ),
  );
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.values, this.max, this.color);
  final List<double> values;
  final double max;
  final Color color;

  static const _bar = 3.0;
  static const _gap = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final count = ((size.width + _gap) / (_bar + _gap)).floor();
    final data = bucketMeans(values, count);
    // Baseline so an idle machine still reads as a chart, not empty space.
    canvas.drawRect(
      Rect.fromLTWH(0, size.height - 1, size.width, 1),
      Paint()..color = NX.line,
    );
    final old = Paint()..color = color.withValues(alpha: .5);
    final now = Paint()..color = color;
    for (var i = 0; i < data.length; i++) {
      final slot = count - data.length + i;
      final x = slot * (_bar + _gap);
      final h = math.max(1.0, (data[i] / max).clamp(0.0, 1.0) * size.height);
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(x, size.height - h, _bar, h),
          topLeft: const Radius.circular(1),
          topRight: const Radius.circular(1),
        ),
        i == data.length - 1 ? now : old,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.values != values || old.max != max || old.color != color;
}

/// Line chart with faint value gridlines, a flat light fill and the latest
/// reading marked. [max] fixes the top (percentages); otherwise the axis fits
/// the data with round numbers. [secondary] draws a second, quieter series.
class HistoryChart extends StatelessWidget {
  const HistoryChart({
    super.key,
    required this.values,
    this.secondary,
    this.max,
    this.fromZero = true,
    this.unit = '',
    this.format,
    this.color = NX.accent,
    this.secondaryColor = NX.textDim,
    this.height = 96,
    this.axis = true,
  });
  final List<double> values;
  final List<double>? secondary;
  final double? max;

  /// Start the axis at zero (loads, rates); false fits temperatures etc.
  final bool fromZero;
  final String unit;

  /// Axis label formatter; defaults to the rounded value plus [unit].
  final String Function(double)? format;
  final Color color;
  final Color secondaryColor;
  final double height;

  /// Gridlines and their labels. Off for small tiles.
  final bool axis;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context);
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: _LinePainter(
              values: values,
              secondary: secondary,
              max: max,
              fromZero: fromZero,
              label: format ?? (v) => '${_trim(v)}$unit',
              color: color,
              secondaryColor: secondaryColor,
              axis: axis,
              labelSize: scale.scale(10).clamp(10, 14).toDouble(),
            ),
          ),
        ),
      ),
    );
  }

  static String _trim(double v) =>
      v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);
}

class _LinePainter extends CustomPainter {
  _LinePainter({
    required this.values,
    required this.secondary,
    required this.max,
    required this.fromZero,
    required this.label,
    required this.color,
    required this.secondaryColor,
    required this.axis,
    required this.labelSize,
  });
  final List<double> values;
  final List<double>? secondary;
  final double? max;
  final bool fromZero;
  final String Function(double) label;
  final Color color;
  final Color secondaryColor;
  final bool axis;
  final double labelSize;

  TextPainter _text(String s) => TextPainter(
    text: TextSpan(
      text: s,
      style: TextStyle(
        color: NX.textFaint,
        fontSize: labelSize,
        fontFamily: 'monospace',
        fontFeatures: NX.tabular,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final all = [...values, ...?secondary];
    if (all.isEmpty) return;
    final lo = all.reduce(math.min), hi = all.reduce(math.max);
    final ax = max != null
        ? (min: 0.0, max: max!, step: max! / 2)
        : niceAxis(lo, hi, fromZero: fromZero);

    // Labels sit at the right, so the newest point stays at the plot's edge.
    var right = size.width;
    final ticks = <double>[];
    if (axis) {
      for (var v = ax.min; v <= ax.max + ax.step * .01; v += ax.step) {
        ticks.add(v);
      }
      final widest = ticks
          .map((t) => _text(label(t)).width)
          .fold<double>(0, math.max);
      right = size.width - widest - 8;
    }
    final top = axis ? labelSize * .7 : 3.0;
    final bottom = size.height - (axis ? labelSize * .7 : 3.0);
    double y(double v) =>
        bottom -
        ((v - ax.min) / (ax.max - ax.min)).clamp(0.0, 1.0) * (bottom - top);

    if (axis) {
      final grid = Paint()
        ..color = NX.line
        ..strokeWidth = 1;
      for (final t in ticks) {
        final yy = y(t).roundToDouble() + .5;
        canvas.drawLine(Offset(0, yy), Offset(right, yy), grid);
        final tp = _text(label(t));
        tp.paint(canvas, Offset(right + 8, yy - tp.height / 2));
      }
    }

    // At most 60 points (~5 s each over the 5-minute history): the shape
    // stays honest while 2-second jitter stops reading as noise.
    final buckets = math.max(2, math.min(60, (right / 4).floor()));
    Path? line(List<double> raw, {bool fill = false}) {
      final data = bucketMeans(raw, buckets);
      if (data.length < 2) return null;
      final dx = right / (buckets - 1);
      final start = right - (data.length - 1) * dx;
      final path = Path()..moveTo(start, y(data.first));
      for (var i = 1; i < data.length; i++) {
        path.lineTo(start + i * dx, y(data[i]));
      }
      if (fill) {
        final area = Path.from(path)
          ..lineTo(right, bottom)
          ..lineTo(start, bottom)
          ..close();
        canvas.drawPath(area, Paint()..color = color.withValues(alpha: .10));
      }
      return path;
    }

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    if (secondary != null) {
      final p = line(secondary!);
      if (p != null) {
        canvas.drawPath(
          p,
          stroke
            ..color = secondaryColor
            ..strokeWidth = 1.25,
        );
      }
    }
    final main = line(values, fill: true);
    if (main != null) {
      canvas.drawPath(
        main,
        stroke
          ..color = color
          ..strokeWidth = 1.75,
      );
      final last = Offset(right, y(bucketMeans(values, buckets).last));
      canvas.drawCircle(last, 4, Paint()..color = NX.bg);
      canvas.drawCircle(last, 2.75, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) => true;
}
