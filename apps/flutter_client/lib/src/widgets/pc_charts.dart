// Fallback PC status for hosts without `monitor.v1`: CPU and memory history
// from the older perf-update push, drawn with the design-system charts.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rpc/rpc_client.dart';
import '../state/connection.dart';
import '../theme/nexus_theme.dart';
import '../theme/nx_widgets.dart';
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
    List<double> series(String key) => history
        .where((s) => s[key] is num)
        .map((s) => (s[key] as num).toDouble())
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            LiveDot(
              color: fresh ? NX.working : (connected ? NX.waiting : NX.idle),
              pulse: fresh,
            ),
            const SizedBox(width: 6),
            Text('PC status', style: Theme.of(context).textTheme.titleLarge),
          ],
        ),
        Text(
          !connected
              ? 'PC offline · Last received readings'
              : fresh
              ? 'Live · Recent samples'
              : 'Waiting for live readings…',
          style: const TextStyle(color: NX.textDim),
        ),
        const SizedBox(height: 10),
        for (final (label, key, color) in const [
          ('CPU', 'cpuPercent', NX.accent),
          ('Memory', 'ramPercent', NX.accent2),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: NxCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          label,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Text(
                        data?[key] is num
                            ? '${(data![key] as num).toStringAsFixed(0)}%'
                            : '—',
                        style: TextStyle(
                          color: data?[key] is num
                              ? NX.heat((data![key] as num).toDouble())
                              : NX.textDim,
                          fontWeight: FontWeight.w800,
                          fontFeatures: NX.tabular,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Sparkline(
                    values: series(key),
                    color: fresh ? color : NX.idle,
                    max: 100,
                    height: 64,
                  ),
                  if (key == 'ramPercent' && data?['ramUsedGb'] is num)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '${(data!['ramUsedGb'] as num).toStringAsFixed(1)} GB used',
                        style: const TextStyle(color: NX.textDim),
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (data?['diskFreeBytes'] is num)
          NxCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.storage, color: NX.textDim),
              title: const Text('Disk available'),
              trailing: Text(
                '${((data!['diskFreeBytes'] as num) / 1073741824).toStringAsFixed(1)} GB',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontFeatures: NX.tabular,
                ),
              ),
            ),
          ),
        const SizedBox(height: 8),
        const Text(
          'Update NexusLink on the PC to see GPU, temperatures, agent apps and RustDesk health here.',
          style: TextStyle(color: NX.textFaint, fontSize: 12),
        ),
      ],
    );
  }
}
