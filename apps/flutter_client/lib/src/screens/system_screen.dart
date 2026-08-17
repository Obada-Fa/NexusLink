// System overview: static host info (system.getInfo) + a live performance
// readout driven by the host's perf-update push (fallback to polling
// system.getPerf if no pushes arrive).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/connection.dart';
import '../widgets/not_connected_view.dart';

class SystemScreen extends ConsumerStatefulWidget {
  const SystemScreen({super.key});

  @override
  ConsumerState<SystemScreen> createState() => _SystemScreenState();
}

class _SystemScreenState extends ConsumerState<SystemScreen> {
  Map<String, dynamic>? _info;
  Map<String, dynamic>? _perf;
  String? _error;
  void Function()? _unsub;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final client = ref.read(activeClientProvider);
    if (client == null) {
      setState(() => _error = 'Not connected.');
      return;
    }
    try {
      final info = await client.request('system.getInfo') as Map<String, dynamic>;
      if (mounted) setState(() => _info = info);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    // Live perf: prefer host pushes; poll as a fallback so the UI is never stale.
    _unsub = client.subscribe('perf-update', (msg) {
      final data = msg['data'];
      if (data is Map<String, dynamic> && mounted) setState(() => _perf = data);
    });
    _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final p = await client.request('system.getPerf') as Map<String, dynamic>;
        if (mounted) setState(() => _perf = p);
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _unsub?.call();
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('System')),
      body: _error != null
          ? looksLikeConnectionError(_error)
              ? NotConnectedView(
                  message: _error!,
                  onReconnected: () {
                    setState(() => _error = null);
                    _init();
                  },
                )
              : Center(
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.redAccent)))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_perf != null) ...[
                  _meter('CPU', (_perf!['cpuPercent'] as num?)?.toDouble() ?? 0),
                  _meter('Memory', (_perf!['ramPercent'] as num?)?.toDouble() ?? 0,
                      detail:
                          '${(_perf!['ramUsedGb'] as num?)?.toStringAsFixed(1) ?? '?'} GB'),
                  const SizedBox(height: 16),
                ],
                if (_info != null) _infoCard(_info!),
                if (_info == null && _perf == null)
                  const Center(child: Padding(
                    padding: EdgeInsets.only(top: 40),
                    child: CircularProgressIndicator(),
                  )),
              ],
            ),
    );
  }

  Widget _meter(String label, double pct, {String? detail}) {
    final v = (pct / 100).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(detail ?? '${pct.toStringAsFixed(0)}%',
                  style: const TextStyle(color: Colors.white70)),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: v,
              minHeight: 8,
              backgroundColor: const Color(0xFF1E1E30),
              valueColor: AlwaysStoppedAnimation(
                  v > 0.85 ? const Color(0xFFEE5555) : const Color(0xFF2A6AFF)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoCard(Map<String, dynamic> info) {
    final rows = <(String, String)>[
      ('Host', '${info['hostname'] ?? '—'}'),
      ('OS', '${info['os'] ?? '—'}'),
      ('CPU', '${info['cpuModel'] ?? '—'}'),
      ('RAM', '${info['totalRamGb'] ?? '—'} GB'),
      ('User', '${info['username'] ?? '—'}'),
      ('Uptime', _uptime((info['uptimeSeconds'] as num?)?.toInt() ?? 0)),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: rows
              .map((r) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                            width: 70,
                            child: Text(r.$1,
                                style: const TextStyle(color: Colors.white54, fontSize: 13))),
                        Expanded(
                            child: Text(r.$2,
                                style: const TextStyle(fontSize: 13))),
                      ],
                    ),
                  ))
              .toList(),
        ),
      ),
    );
  }

  static String _uptime(int seconds) {
    final d = seconds ~/ 86400;
    final h = (seconds % 86400) ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (d > 0) return '${d}d ${h}h';
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }
}
