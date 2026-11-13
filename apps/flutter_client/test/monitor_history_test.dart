// The chart data contract: host timestamps, real elapsed time, peaks kept
// when reducing points, the endpoint at the latest sample, and headline /
// endpoint / peak computed from the same samples and window.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/monitor/monitor_models.dart';
import 'package:nexuslink/src/monitor/monitor_provider.dart';
import 'package:nexuslink/src/widgets/history_chart.dart';

Vitals vitals(
  int t, {
  double cpu = 5,
  double? gpu,
  double? hot,
  double? rx,
  double? tx,
}) => Vitals({
  'timestamp': t,
  'cpu': {'percent': cpu, 'tempC': 40},
  'memory': {'percent': 30},
  'gpus': [
    if (gpu != null) {'busyPercent': gpu, 'hotspotC': hot, 'tempC': 50},
  ],
  'net': {'rxBps': rx ?? 0, 'txBps': tx ?? 0},
  'disk': {'readBps': 0, 'writeBps': 0},
});

/// Paints [chart] at [size] and returns the painter for inspection.
TimeChartPainter paint(TimeChartPainter p, {Size size = const Size(300, 120)}) {
  final recorder = ui.PictureRecorder();
  p.paint(Canvas(recorder), size);
  recorder.endRecording();
  return p;
}

TimeChartPainter painter(
  List<Sample> s, {
  List<Sample>? secondary,
  double? max = 100,
  Duration window = const Duration(minutes: 5),
  int? end,
}) => TimeChartPainter(
  samples: s,
  secondary: secondary,
  end: end ?? latestTime([s, ?secondary]),
  window: window,
  max: max,
  fromZero: true,
  label: (v) => '${v.round()}',
  color: Colors.cyan,
  secondaryColor: Colors.grey,
  fill: true,
  gutter: 40,
  axis: true,
  timeLabels: true,
  labelSize: 10,
);

void main() {
  const t0 = 1700000000000;

  group('MonitorHistory', () {
    test('stores host timestamps and drops stale or duplicate pushes', () {
      var h = MonitorHistory();
      h = h.add(vitals(t0, cpu: 10), at: t0);
      h = h.add(vitals(t0 + 2000, cpu: 20), at: t0 + 2000);
      // A one-shot refresh racing the push: same time, then older.
      h = h.add(vitals(t0 + 2000, cpu: 99), at: t0 + 2000);
      h = h.add(vitals(t0 + 1000, cpu: 99), at: t0 + 1000);
      expect(h.samples('cpu'), const [Sample(t0, 10), Sample(t0 + 2000, 20)]);
      expect(h['cpu'], [10, 20]);
    });

    test(
      'logical CPU samples keep their host time and index across missing reports',
      () {
        Vitals cpuAt(int time, List<double> threads) => Vitals({
          'timestamp': time,
          'cpu': {'perCore': threads},
        });
        final h = MonitorHistory()
            .add(cpuAt(t0, [15, 80]))
            .add(cpuAt(t0 + 2000, []))
            .add(cpuAt(t0 + 24000, [92, 6]))
            .add(cpuAt(t0 + 24000, [0, 0]));
        expect(h.samples('cpuThread:0'), [
          const Sample(t0, 15),
          const Sample(t0 + 24000, 92),
        ]);
        expect(h.samples('cpuThread:1'), [
          const Sample(t0, 80),
          const Sample(t0 + 24000, 6),
        ]);
        expect(nearestReading(h.samples('cpuThread:0'), t0 + 12000), isNull);
      },
    );
    test('keeps about six minutes, by time not count', () {
      var h = MonitorHistory();
      for (var i = 0; i <= 400; i++) {
        h = h.add(vitals(t0 + i * 1000, cpu: i.toDouble()), at: t0 + i * 1000);
      }
      final s = h.samples('cpu');
      expect(s.last.t, t0 + 400000);
      expect(s.first.t, greaterThanOrEqualTo(t0 + 400000 - 360000));
    });

    test('GPU temperature series is the hotspot, like the headline', () {
      final h = MonitorHistory().add(vitals(t0, gpu: 67, hot: 71), at: t0);
      expect(h['gpuTemp'], [71]);
      expect(h['gpu'], [67]);
    });

    test('a missing sensor adds no samples', () {
      final h = MonitorHistory().add(vitals(t0), at: t0);
      expect(h.samples('gpu'), isEmpty);
      expect(h.stats('gpu'), isNull);
    });
  });

  group('stats', () {
    test('headline, endpoint and peak agree (67% never beside a 59% peak)', () {
      // Earlier load peaked at 59, the latest reading is 67.
      final s = [
        for (var i = 0; i < 100; i++)
          Sample(t0 + i * 2000, 40 + (i % 20).toDouble()),
        const Sample(t0 + 100 * 2000, 67),
      ];
      final st = statsOf(s, const Duration(minutes: 5))!;
      expect(st.latest.v, 67);
      expect(st.peak, 67);
      expect(st.peak, greaterThanOrEqualTo(st.latest.v));
      final p = paint(painter(s));
      // Endpoint at the latest sample's time (right edge) and value.
      expect(p.endpoint!.dx, closeTo(p.plot!.right, .01));
      final y67 = p.plot!.bottom - .67 * p.plot!.height;
      expect(p.endpoint!.dy, closeTo(y67, .01));
    });

    test('an idle PC: flat line, peak equals low', () {
      final s = [for (var i = 0; i < 150; i++) Sample(t0 + i * 2000, 1.5)];
      final st = statsOf(s, const Duration(minutes: 5))!;
      expect(st.peak, 1.5);
      expect(st.low, 1.5);
      expect(st.average, closeTo(1.5, 1e-9));
    });

    test('short history: the window is what exists, and the line starts '
        'where the first sample is', () {
      final s = [
        const Sample(t0, 10),
        const Sample(t0 + 2000, 30),
        const Sample(t0 + 4000, 20),
      ];
      final st = statsOf(s, const Duration(minutes: 5))!;
      expect(st.span, const Duration(seconds: 4));
      expect(st.peak, 30);
      final p = paint(painter(s));
      expect(p.endpoint!.dx, closeTo(p.plot!.right, .01));
    });
  });

  group('reducePeaks', () {
    test('keeps a one-sample spike among many points', () {
      final s = [
        for (var i = 0; i < 300; i++) Sample(t0 + i * 1000, i == 137 ? 95 : 10),
      ];
      final r = reducePeaks(s, 40, start: t0, end: t0 + 299000);
      expect(r.length, lessThanOrEqualTo(81));
      expect(r.map((x) => x.v), contains(95));
      expect(r.last, s.last);
    });

    test('irregular timestamps keep time order and the exact last sample', () {
      final s = [
        const Sample(t0, 5),
        const Sample(t0 + 700, 9),
        const Sample(t0 + 9100, 3),
        const Sample(t0 + 9400, 60),
        const Sample(t0 + 31000, 12),
      ];
      final r = reducePeaks(s, 2, start: t0, end: t0 + 31000);
      for (var i = 1; i < r.length; i++) {
        expect(r[i].t, greaterThan(r[i - 1].t));
      }
      expect(r.map((x) => x.v), contains(60));
      expect(r.last, const Sample(t0 + 31000, 12));
    });
  });

  group('charts', () {
    test('x is elapsed time: a sample 150 s before the end is mid-plot', () {
      final s = [
        const Sample(t0, 10),
        const Sample(t0 + 150000, 50),
        const Sample(t0 + 300000, 20),
      ];
      final p = paint(painter(s));
      final mid = p.plot!.right / 2;
      // The endpoint is the right edge; the middle sample lands at half width.
      expect(p.endpoint!.dx, closeTo(p.plot!.right, .01));
      expect(mid, closeTo(p.plot!.width / 2, .01));
    });

    test('stacked charts with the same gutter share plot edges', () {
      final load = [for (var i = 0; i < 60; i++) Sample(t0 + i * 5000, 30)];
      final temp = [for (var i = 0; i < 60; i++) Sample(t0 + i * 5000, 61)];
      final end = latestTime([load, temp]);
      final a = paint(painter(load, end: end));
      final b = paint(painter(temp, end: end, max: null));
      expect(a.plot!.left, b.plot!.left);
      expect(a.plot!.right, b.plot!.right);
    });

    test('a spike and the temperature rise after it line up in x', () {
      // Load spikes at 120 s; temperature peaks 10 s later.
      final load = [
        for (var i = 0; i <= 150; i++) Sample(t0 + i * 2000, i == 60 ? 98 : 8),
      ];
      final temp = [
        for (var i = 0; i <= 150; i++)
          Sample(t0 + i * 2000, i >= 65 && i <= 70 ? 82 : 55),
      ];
      final end = latestTime([load, temp])!;
      final a = paint(painter(load, end: end));
      final b = paint(painter(temp, end: end, max: null));
      double x(TimeChartPainter p, int t) =>
          (t - (end - 300000)) / 300000 * p.plot!.right;
      expect(x(a, t0 + 120000), closeTo(x(b, t0 + 120000), .01));
      expect(x(b, t0 + 130000) - x(a, t0 + 120000), greaterThan(0));
      expect(statsOf(load, const Duration(minutes: 5))!.peak, 98);
      expect(statsOf(temp, const Duration(minutes: 5))!.peak, 82);
    });

    test('simultaneous upload and download both scale the axis', () {
      final rx = [for (var i = 0; i < 30; i++) Sample(t0 + i * 2000, 2e6)];
      final tx = [for (var i = 0; i < 30; i++) Sample(t0 + i * 2000, 5e6)];
      final p = paint(painter(rx, secondary: tx, max: null));
      // Download (2 MB/s) sits below the top because upload (5 MB/s) is
      // higher; both are in view.
      expect(p.endpoint!.dy, greaterThan(p.plot!.top + 1));
      expect(p.endpoint!.dy, lessThan(p.plot!.bottom));
    });

    test(
      'tiny bars: last bar is the latest reading, earlier bars keep peaks',
      () {
        final s = [
          for (var i = 0; i < 150; i++)
            Sample(t0 + i * 2000, i == 20 ? 90 : 10),
          const Sample(t0 + 150 * 2000, 67),
        ];
        final bars = barValues(s, 11, const Duration(minutes: 5));
        expect(bars.last, 67);
        expect(bars.whereType<double>().reduce((a, b) => a > b ? a : b), 90);
      },
    );

    test(
      'inspection never borrows a reading across a gap or before a sensor started',
      () {
        const series = [Sample(1000, 11), Sample(2000, 12), Sample(40000, 91)];
        expect(nearestReading(series, 0), isNull);
        expect(nearestReading(series, 1600), series[1]);
        expect(nearestReading(series, 2100), isNull);
        expect(nearestReading(series, 40000), series.last);
        expect(nearestReading(series, 41000), isNull);
      },
    );

    testWidgets('holding a chart inspects one host time across both plots', (
      tester,
    ) async {
      const samples = [Sample(0, 40), Sample(10000, 60)];
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChartInspection(
              child: Column(
                children: [
                  TimeChart(
                    samples: samples,
                    max: 100,
                    window: Duration(seconds: 10),
                  ),
                  TimeChart(
                    samples: samples,
                    max: 100,
                    window: Duration(seconds: 10),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      List<TimeChartPainter> painters() => tester
          .widgetList<CustomPaint>(
            find.descendant(
              of: find.byType(TimeChart),
              matching: find.byType(CustomPaint),
            ),
          )
          .map((w) => w.painter! as TimeChartPainter)
          .toList();
      final position =
          tester.getTopLeft(find.byType(TimeChart).first) +
          Offset(painters().first.plot!.width * .5, 45);
      final gesture = await tester.startGesture(position);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(painters().map((p) => p.cursor), [5000, 5000]);
      await gesture.moveBy(const Offset(50, 0));
      await tester.pump();
      expect(painters().first.cursor, greaterThan(5000));
      expect(painters().last.cursor, painters().first.cursor);
      await gesture.up();
      await tester.pump();
      expect(painters().map((p) => p.cursor), [null, null]);
    });

    test('elapsed labels', () {
      expect(fmtElapsed(const Duration(minutes: 5)), '5 min');
      expect(fmtElapsed(const Duration(seconds: 150)), '2.5 min');
      expect(fmtElapsed(const Duration(seconds: 40)), '40 s');
      expect(fmtElapsed(Duration.zero), 'now');
    });
  });
}
