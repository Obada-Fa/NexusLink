import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../rpc/rpc_client.dart';
import '../state/connection.dart';
import '../workspace/metrics.dart';

final _historyProvider = Provider<List<Map<String, dynamic>>>((ref) {
  ref.watch(activeClientProvider);
  final samples = <Map<String, dynamic>>[];
  ref.listen(metricsProvider, (_, next) {
    if (next == null) return;
    samples.add(Map.of(next));
    if (samples.length > 60) samples.removeAt(0);
  });
  return samples;
});

class PcCharts extends ConsumerStatefulWidget {
  const PcCharts({super.key});
  @override
  ConsumerState<PcCharts> createState() => _PcChartsState();
}

class _PcChartsState extends ConsumerState<PcCharts> {
  Timer? _clock;
  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(_historyProvider);
    final data = ref.watch(metricsProvider);
    final connected =
        ref.watch(connectionStatusProvider) == RpcStatus.connected;
    final fresh =
        connected &&
        data != null &&
        DateTime.now().millisecondsSinceEpoch -
                (data['timestamp'] as num? ?? 0) <
            15000;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('PC status', style: Theme.of(context).textTheme.titleLarge),
        Text(
          !connected
              ? 'PC offline · Last received readings'
              : fresh
              ? 'Live · Recent samples'
              : 'Waiting for live readings…',
        ),
        const SizedBox(height: 8),
        for (final metric in [
          ('CPU', 'cpuPercent', Colors.lightBlueAccent),
          ('Memory', 'ramPercent', Colors.tealAccent),
        ])
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(metric.$1),
                      Text(
                        data?[metric.$2] is num
                            ? '${(data![metric.$2] as num).toStringAsFixed(0)}%'
                            : '—',
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 80,
                    width: double.infinity,
                    child: CustomPaint(
                      painter: _ChartPainter(
                        history
                            .where((s) => s[metric.$2] is num)
                            .map((s) => (s[metric.$2] as num).toDouble())
                            .toList(),
                        fresh ? metric.$3 : Colors.grey,
                      ),
                    ),
                  ),
                  if (metric.$2 == 'ramPercent' && data?['ramUsedGb'] is num)
                    Text(
                      '${(data!['ramUsedGb'] as num).toStringAsFixed(1)} GB used',
                    ),
                ],
              ),
            ),
          ),
        if (data?['diskFreeBytes'] is num)
          ListTile(
            leading: const Icon(Icons.storage),
            title: const Text('Disk available'),
            trailing: Text(
              '${((data!['diskFreeBytes'] as num) / 1073741824).toStringAsFixed(1)} GB',
            ),
          ),
      ],
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.samples, this.color);
  final List<double> samples;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = Colors.grey.withValues(alpha: 0.2)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (samples.isEmpty) return;
    final line = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = size.width * i / 59;
      final y = size.height * (1 - samples[i].clamp(0, 100) / 100);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
      if (i == samples.length - 1) {
        canvas.drawCircle(Offset(x, y), 3, Paint()..color = color);
      }
    }
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(_ChartPainter oldDelegate) => true;
}
