// Flat, instrument-style history charts for Desktop and the system monitor.
//
// Rules: x is elapsed host time (not sample index), so irregular pushes and
// reconnect gaps plot where they happened; points are reduced by keeping each
// bucket's low and high, so a short spike survives; the line ends at the
// latest real sample and that point is marked. No curves, no gradients, faint
// gridlines, a light fill only where asked (the main load chart).

import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import '../monitor/time_series.dart';
import '../theme/nexus_theme.dart';

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

/// Width of the value-label gutter shared by a stack of aligned charts, so
/// their plot edges line up at any text size.
double chartGutter(BuildContext context, {double base = 40}) =>
    base * chartLabelSize(context) / 10;

double chartLabelSize(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(11).clamp(11, 19).toDouble();

/// A gap longer than this between two samples breaks the line (the phone was
/// away or the PC was offline) instead of drawing a misleading ramp.
const chartGapBreak = Duration(seconds: 15);

// ---------------------------------------------------------------------------
// Tiny unlabeled history for table rows

/// Thin vertical bars over the last [window], newest at the right. Each bar is
/// the highest reading in its slice of time; the last bar is the latest
/// reading itself, so it matches the number printed beside it.
class HistoryBars extends StatelessWidget {
  const HistoryBars({
    super.key,
    required this.samples,
    this.max = 100,
    this.color = NX.accent,
    this.height = 18,
    this.width = 48,
    this.window = const Duration(minutes: 5),
  });
  final List<Sample> samples;
  final double max;
  final Color color;
  final double height;
  final double width;
  final Duration window;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: RepaintBoundary(
      child: CustomPaint(
        size: Size(width, height),
        painter: _BarsPainter(samples, max, color, window),
      ),
    ),
  );
}

/// Bar heights for [HistoryBars]: one per slot, null where no sample fell.
@visibleForTesting
List<double?> barValues(List<Sample> samples, int count, Duration window) {
  if (count <= 0 || samples.isEmpty) return const [];
  final end = samples.last.t;
  final span = window.inMilliseconds / count;
  final start = end - window.inMilliseconds;
  final out = List<double?>.filled(count, null);
  for (final s in samples) {
    if (s.t < start) continue;
    final slot = math.min(count - 1, ((s.t - start) / span).floor());
    final v = out[slot];
    out[slot] = v == null ? s.v : math.max(v, s.v);
  }
  out[count - 1] = samples.last.v;
  return out;
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.samples, this.max, this.color, this.window);
  final List<Sample> samples;
  final double max;
  final Color color;
  final Duration window;

  static const _bar = 3.0;
  static const _gap = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final count = ((size.width + _gap) / (_bar + _gap)).floor();
    // Baseline so an idle machine still reads as a chart, not empty space.
    canvas.drawRect(
      Rect.fromLTWH(0, size.height - 1, size.width, 1),
      Paint()..color = NX.line,
    );
    final data = barValues(samples, count, window);
    final old = Paint()..color = color.withValues(alpha: .45);
    final now = Paint()..color = color;
    for (var i = 0; i < data.length; i++) {
      final v = data[i];
      if (v == null) continue;
      final x = i * (_bar + _gap);
      final h = math.max(1.0, (v / max).clamp(0.0, 1.0) * size.height);
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
      old.samples != samples || old.max != max || old.color != color;
}

// ---------------------------------------------------------------------------
// Time chart

/// Coordinates the inspection cursor across the plots on one monitor page.
class ChartInspection extends StatefulWidget {
  const ChartInspection({super.key, required this.child});
  final Widget child;

  @override
  State<ChartInspection> createState() => _ChartInspectionState();
}

class _ChartInspectionState extends State<ChartInspection> {
  final cursor = ValueNotifier<int?>(null);

  @override
  void dispose() {
    cursor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _InspectionScope(notifier: cursor, child: widget.child);
}

class _InspectionScope extends InheritedNotifier<ValueNotifier<int?>> {
  const _InspectionScope({required super.notifier, required super.child});
}

/// Leaves missing history and the interior of a connection gap empty.
Sample? nearestReading(List<Sample> samples, int t) {
  if (samples.isEmpty || t < samples.first.t || t > samples.last.t) return null;
  final next = samples.indexWhere((s) => s.t >= t);
  if (next == 0 || samples[next].t == t) return samples[next];
  final a = samples[next - 1], b = samples[next];
  if (b.t - a.t > chartGapBreak.inMilliseconds) return null;
  return t - a.t <= b.t - t ? a : b;
}

/// A line chart over elapsed time.
///
/// Charts stacked to compare (load above temperature above power) pass the
/// same [end], [window] and [gutter] so their plot edges and time axes match;
/// only the bottom one usually shows [timeLabels].
class TimeChart extends StatelessWidget {
  const TimeChart({
    super.key,
    required this.samples,
    this.secondary,
    this.end,
    this.window = const Duration(minutes: 5),
    this.max,
    this.fromZero = true,
    this.unit = '',
    this.format,
    this.color = NX.accent,
    this.secondaryColor = NX.textDim,
    this.fill = false,
    this.height = 96,
    this.gutter,
    this.axis = true,
    this.timeLabels = false,
    this.markPeak = false,
  });
  final List<Sample> samples;

  /// Drawn as a dashed, quieter line (Upload, Write).
  final List<Sample>? secondary;

  /// Right edge of the time axis (ms). Defaults to the newest sample shown.
  final int? end;
  final Duration window;

  /// Fixed top (percentages); otherwise the axis fits the data.
  final double? max;

  /// Start the axis at zero (loads, rates); false fits temperatures etc.
  final bool fromZero;
  final String unit;

  /// Axis label formatter; defaults to the rounded value plus [unit].
  final String Function(double)? format;
  final Color color;
  final Color secondaryColor;

  /// Light fill under the main line. Reserved for the main load chart.
  final bool fill;
  final double height;

  /// Value-label gutter width; pass the same value to align stacked charts.
  final double? gutter;

  /// Gridlines and their value labels.
  final bool axis;

  /// Elapsed-time labels under the plot ("5 min … now").
  final bool timeLabels;

  final bool markPeak;

  @override
  Widget build(BuildContext context) {
    final cursor = context
        .dependOnInheritedWidgetOfExactType<_InspectionScope>()
        ?.notifier;
    final last = end ?? latestTime([samples, ?secondary]);
    final painter = TimeChartPainter(
      samples: samples,
      secondary: secondary,
      end: last,
      window: window,
      max: max,
      fromZero: fromZero,
      label: format ?? (v) => '${_trim(v)}$unit',
      color: color,
      secondaryColor: secondaryColor,
      fill: fill,
      gutter: gutter,
      axis: axis,
      timeLabels: timeLabels,
      labelSize: chartLabelSize(context),
      markPeak: markPeak,
      cursor: cursor?.value,
    );
    final chart = SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: painter),
    );
    if (cursor == null || last == null) return chart;
    void inspect(Offset local) {
      final plot = painter.plot;
      if (plot == null || plot.width <= 0) return;
      final fraction = (local.dx / plot.width).clamp(0.0, 1.0);
      cursor.value = last - ((1 - fraction) * window.inMilliseconds).round();
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (event) => inspect(event.localPosition),
      onLongPressMoveUpdate: (event) => inspect(event.localPosition),
      onLongPressEnd: (_) => cursor.value = null,
      onLongPressCancel: () => cursor.value = null,
      child: chart,
    );
  }

  static String _trim(double v) =>
      v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);
}

/// Exposed for tests: where the chart puts things.
class TimeChartPainter extends CustomPainter {
  TimeChartPainter({
    required this.samples,
    required this.secondary,
    required this.end,
    required this.window,
    required this.max,
    required this.fromZero,
    required this.label,
    required this.color,
    required this.secondaryColor,
    required this.fill,
    required this.gutter,
    required this.axis,
    required this.timeLabels,
    required this.labelSize,
    this.markPeak = false,
    this.cursor,
  });
  final List<Sample> samples;
  final List<Sample>? secondary;
  final int? end;
  final Duration window;
  final double? max;
  final bool fromZero;
  final String Function(double) label;
  final Color color;
  final Color secondaryColor;
  final bool fill;
  final double? gutter;
  final bool axis;
  final bool timeLabels;
  final double labelSize;
  final bool markPeak;
  final int? cursor;

  /// Set after [paint]: the plot area and the endpoint marker's centre.
  Rect? plot;
  Offset? endpoint;

  TextPainter _text(String s, [Color ink = NX.textDim]) => TextPainter(
    text: TextSpan(
      text: s,
      style: TextStyle(
        color: ink,
        fontSize: labelSize,
        fontFamily: 'monospace',
        fontFeatures: NX.tabular,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final last = end;
    final grid = Paint()
      ..color = NX.line.withValues(alpha: .7)
      ..strokeWidth = 1;
    final w = window.inMilliseconds;
    final start = last == null ? 0 : last - w;
    final main = last == null
        ? const <Sample>[]
        : inWindow(samples, window, end: last);
    final second = last == null || secondary == null
        ? const <Sample>[]
        : inWindow(secondary!, window, end: last);
    final all = [for (final s in main) s.v, for (final s in second) s.v];

    final ax = max != null
        ? (min: 0.0, max: max!, step: max! / 2)
        : all.isEmpty
        ? (min: 0.0, max: 1.0, step: .5)
        : niceAxis(
            all.reduce(math.min),
            all.reduce(math.max),
            fromZero: fromZero,
          );
    final ticks = <double>[
      for (var v = ax.min; v <= ax.max + ax.step * .01; v += ax.step) v,
    ];

    var right = size.width;
    if (axis) {
      final widest = ticks
          .map((t) => _text(label(t)).width)
          .fold<double>(0, math.max);
      right = size.width - math.max(gutter ?? 0, widest + 8);
    } else if (gutter != null) {
      right = size.width - gutter!;
    }
    final top = markPeak
        ? labelSize * 2.3
        : axis
        ? labelSize * .7
        : 3.0;
    final timeBand = timeLabels ? labelSize + 6 : 0.0;
    final bottom = size.height - timeBand - (axis ? labelSize * .7 : 3.0);
    plot = Rect.fromLTRB(0, top, right, bottom);
    double y(double v) =>
        bottom -
        ((v - ax.min) / (ax.max - ax.min)).clamp(0.0, 1.0) * (bottom - top);
    double x(int t) => w <= 0 ? right : (t - start) / w * right;

    if (axis) {
      var previousY = double.infinity;
      final labelHeight = _text(label(ax.max)).height + 2;
      for (final t in ticks) {
        final yy = y(t).roundToDouble() + .5;
        canvas.drawLine(Offset(0, yy), Offset(right, yy), grid);
        if (t != ax.min &&
            t != ticks.last &&
            (previousY - yy < labelHeight || yy - top < labelHeight)) {
          continue;
        }
        previousY = yy;
        final tp = _text(label(t));
        tp.paint(canvas, Offset(right + 8, yy - tp.height / 2));
      }
    } else {
      canvas.drawLine(Offset(0, bottom + .5), Offset(right, bottom + .5), grid);
    }

    if (timeLabels) {
      final ty = size.height - labelSize - 2;
      final left = _text(fmtElapsed(window));
      final mid = _text(fmtElapsed(window ~/ 2));
      final now = _text('now');
      left.paint(canvas, Offset(0, ty));
      mid.paint(canvas, Offset(right / 2 - mid.width / 2, ty));
      now.paint(canvas, Offset(right - now.width, ty));
    }

    if (last == null) return;
    final buckets = math.max(2, (right / 3).floor());

    /// Runs of reduced points, split where the samples have a long gap.
    List<List<Offset>> runs(List<Sample> raw) {
      final out = <List<Offset>>[];
      var startIndex = 0;
      for (var i = 1; i <= raw.length; i++) {
        if (i < raw.length &&
            raw[i].t - raw[i - 1].t <= chartGapBreak.inMilliseconds) {
          continue;
        }
        // Split on real samples first. Reduction alone can put two retained
        // peaks far apart even when the host reported continuously.
        final points = reducePeaks(
          raw.sublist(startIndex, i),
          buckets,
          start: start,
          end: last,
        );
        out.add([for (final point in points) Offset(x(point.t), y(point.v))]);
        startIndex = i;
      }
      return out;
    }

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    if (second.isNotEmpty) {
      for (final run in runs(second)) {
        if (run.length < 2) continue;
        _dashed(
          canvas,
          _path(run),
          stroke
            ..color = secondaryColor
            ..strokeWidth = 1.5,
        );
      }
    }

    for (final run in runs(main)) {
      if (run.length < 2) {
        canvas.drawCircle(run.first, 1.5, Paint()..color = color);
        continue;
      }
      final path = _path(run);
      if (fill) {
        final area = Path.from(path)
          ..lineTo(run.last.dx, bottom)
          ..lineTo(run.first.dx, bottom)
          ..close();
        canvas.drawPath(area, Paint()..color = color.withValues(alpha: .10));
      }
      canvas.drawPath(
        path,
        stroke
          ..color = color
          ..strokeWidth = 1.75,
      );
    }
    if (main.isNotEmpty) {
      final dot = Offset(x(main.last.t), y(main.last.v));
      endpoint = dot;
      canvas.drawCircle(dot, axis ? 4 : 2.5, Paint()..color = NX.bg);
      canvas.drawCircle(dot, axis ? 2.75 : 1.75, Paint()..color = color);
    }
    void tag(String text, Offset at) {
      final tp = _text(text, NX.text);
      final dx = (at.dx - tp.width / 2).clamp(
        0.0,
        math.max(0.0, right - tp.width),
      );
      final dy = math.max(0.0, at.dy - tp.height - 7);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(dx - 2, dy - 1, tp.width + 4, tp.height + 2),
          const Radius.circular(3),
        ),
        Paint()..color = NX.bg,
      );
      tp.paint(canvas, Offset(dx.toDouble(), dy));
    }

    final time = cursor;
    if (time != null && time >= start && time <= last) {
      final xx = x(time);
      canvas.drawLine(
        Offset(xx, top),
        Offset(xx, bottom),
        Paint()..color = NX.textDim,
      );
      final sample = nearestReading(main, time);
      final ago = fmtElapsed(Duration(milliseconds: last - time));
      tag(
        '${sample == null ? '—' : label(sample.v)} · ${ago == 'now' ? ago : '$ago ago'}',
        Offset(xx, top),
      );
      if (sample != null) {
        canvas.drawCircle(
          Offset(x(sample.t), y(sample.v)),
          3.5,
          Paint()..color = color,
        );
      }
    } else if (markPeak && main.isNotEmpty) {
      final peak = main.reduce((a, b) => a.v >= b.v ? a : b);
      final at = Offset(x(peak.t), y(peak.v));
      canvas.drawCircle(at, 3, Paint()..color = color);
      tag('Peak ${label(peak.v)}', at);
    }
  }

  static Path _path(List<Offset> pts) {
    final p = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final o in pts.skip(1)) {
      p.lineTo(o.dx, o.dy);
    }
    return p;
  }

  static void _dashed(Canvas canvas, Path path, Paint paint) {
    const dash = 5.0, gap = 4.0;
    for (final PathMetric m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, math.min(d + dash, m.length)), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(TimeChartPainter old) => true;
}

// ---------------------------------------------------------------------------
// Legend

/// A short stroke matching a chart line: solid or dashed.
class LegendStroke extends StatelessWidget {
  const LegendStroke({super.key, required this.color, this.dashed = false});
  final Color color;
  final bool dashed;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(18, 8),
    painter: _StrokePainter(color, dashed),
  );
}

class _StrokePainter extends CustomPainter {
  _StrokePainter(this.color, this.dashed);
  final Color color;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = dashed ? 1.5 : 1.75
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    if (!dashed) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      return;
    }
    for (var x = 0.0; x < size.width; x += 9) {
      canvas.drawLine(
        Offset(x, y),
        Offset(math.min(x + 5, size.width), y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_StrokePainter old) =>
      old.color != color || old.dashed != dashed;
}

/// "── Download  - - Upload" with values.
class ChartLegend extends StatelessWidget {
  const ChartLegend({super.key, required this.entries});

  /// (label, value, color, dashed)
  final List<(String, String, Color, bool)> entries;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 16,
    runSpacing: 4,
    children: [
      for (final (label, value, color, dashed) in entries)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            LegendStroke(color: color, dashed: dashed),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(color: NX.textDim, fontSize: 12.5),
            ),
            const SizedBox(width: 6),
            Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                fontFeatures: NX.tabular,
              ),
            ),
          ],
        ),
    ],
  );
}
