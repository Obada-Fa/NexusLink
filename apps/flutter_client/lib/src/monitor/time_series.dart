// Timestamped monitor readings and the arithmetic every chart and headline
// shares, so a number printed beside a chart always agrees with the chart:
// the endpoint is the latest sample, the peak is computed from the same
// samples in the same window, and reducing points never drops a short spike.

import 'dart:math' as math;

/// One reading at the host's clock (milliseconds since the epoch).
class Sample {
  const Sample(this.t, this.v);
  final int t;
  final double v;

  @override
  bool operator ==(Object other) =>
      other is Sample && other.t == t && other.v == v;

  @override
  int get hashCode => Object.hash(t, v);

  @override
  String toString() => 'Sample($t, $v)';
}

/// Low / average / peak / latest over one window of samples.
class SeriesStats {
  const SeriesStats({
    required this.latest,
    required this.peak,
    required this.low,
    required this.average,
    required this.from,
    required this.to,
  });
  final Sample latest;
  final double peak;
  final double low;
  final double average;

  /// First and last sample times inside the window.
  final int from;
  final int to;

  Duration get span => Duration(milliseconds: to - from);
}

/// Samples whose time is within [window] of [end] (inclusive), oldest first.
/// [end] defaults to the series' own latest sample.
List<Sample> inWindow(List<Sample> samples, Duration window, {int? end}) {
  if (samples.isEmpty) return const [];
  final last = end ?? samples.last.t;
  final start = last - window.inMilliseconds;
  var i = samples.length;
  while (i > 0 && samples[i - 1].t >= start) {
    i--;
  }
  return [
    for (var j = i; j < samples.length; j++)
      if (samples[j].t <= last) samples[j],
  ];
}

/// Stats for the samples in [window] ending at [end] (default: the latest
/// sample), or null when there are none. The peak always includes the latest
/// reading, so a headline can never exceed the displayed peak.
SeriesStats? statsOf(List<Sample> samples, Duration window, {int? end}) {
  final w = inWindow(samples, window, end: end);
  if (w.isEmpty) return null;
  var hi = -double.infinity, lo = double.infinity, sum = 0.0;
  for (final s in w) {
    hi = math.max(hi, s.v);
    lo = math.min(lo, s.v);
    sum += s.v;
  }
  return SeriesStats(
    latest: w.last,
    peak: hi,
    low: lo,
    average: sum / w.length,
    from: w.first.t,
    to: w.last.t,
  );
}

/// Reduces [samples] to at most about `2 * buckets + 1` points for drawing.
///
/// The time span [start]..[end] is split into equal buckets; each bucket keeps
/// its minimum and maximum in time order, so a one-sample spike survives. The
/// last sample is always kept exactly, so the line ends at the real reading.
List<Sample> reducePeaks(
  List<Sample> samples,
  int buckets, {
  required int start,
  required int end,
}) {
  final visible = [
    for (final s in samples)
      if (s.t >= start && s.t <= end) s,
  ];
  if (buckets <= 0 || visible.length <= buckets * 2 || end <= start) {
    return visible;
  }
  final span = (end - start) / buckets;
  final out = <Sample>[];
  var b = 0;
  Sample? lo, hi;
  void flush() {
    if (lo == null || hi == null) return;
    if (identical(lo, hi)) {
      out.add(lo!);
    } else if (lo!.t <= hi!.t) {
      out
        ..add(lo!)
        ..add(hi!);
    } else {
      out
        ..add(hi!)
        ..add(lo!);
    }
    lo = hi = null;
  }

  for (final s in visible) {
    final bucket = math.min(buckets - 1, ((s.t - start) / span).floor());
    if (bucket != b) {
      flush();
      b = bucket;
    }
    if (lo == null || s.v < lo!.v) lo = s;
    if (hi == null || s.v > hi!.v) hi = s;
  }
  flush();
  final last = visible.last;
  if (out.isEmpty || out.last != last) {
    out.removeWhere((s) => s.t == last.t);
    out.add(last);
  }
  return out;
}

/// The newest sample time across several series (the shared chart end), or
/// null when all are empty.
int? latestTime(Iterable<List<Sample>> series) {
  int? end;
  for (final s in series) {
    if (s.isEmpty) continue;
    end = end == null ? s.last.t : math.max(end, s.last.t);
  }
  return end;
}

/// "now", "30 s", "2 min", "1.5 min" — elapsed-time axis labels.
String fmtElapsed(Duration d) {
  final s = d.inMilliseconds / 1000;
  if (s < 1) return 'now';
  if (s < 60) return '${s.round()} s';
  final m = s / 60;
  return m == m.roundToDouble()
      ? '${m.round()} min'
      : '${m.toStringAsFixed(1)} min';
}
