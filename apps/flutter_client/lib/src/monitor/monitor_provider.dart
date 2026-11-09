import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../rpc/rpc_client.dart';
import '../state/connection.dart';
import 'monitor_models.dart';
import 'time_series.dart';

export 'time_series.dart';

/// Rolling, timestamped series for charts and headlines. Each reading keeps
/// the host's own timestamp, so charts plot real elapsed time even when pushes
/// arrive irregularly or after a reconnect.
class MonitorHistory {
  MonitorHistory([Map<String, List<Sample>>? series]) : series = series ?? {};

  /// Evenly spaced values ending at [end] (tests and previews).
  factory MonitorHistory.values(
    Map<String, List<double>> values, {
    int stepMs = 2000,
    int? end,
  }) {
    final last = end ?? DateTime.now().millisecondsSinceEpoch;
    return MonitorHistory({
      for (final e in values.entries)
        e.key: [
          for (var i = 0; i < e.value.length; i++)
            Sample(last - (e.value.length - 1 - i) * stepMs, e.value[i]),
        ],
    });
  }

  final Map<String, List<Sample>> series;

  /// What the charts show.
  static const window = Duration(minutes: 5);

  /// What is kept (a little more than [window], bounded in count).
  static const keep = Duration(minutes: 6);
  static const capacity = 400;

  /// Samples for [key], oldest first.
  List<Sample> samples(String key) => series[key] ?? const [];

  /// Values only, oldest first.
  List<double> operator [](String key) => [for (final s in samples(key)) s.v];

  /// Window stats for [key] ending at its latest sample.
  SeriesStats? stats(String key, {Duration window = window, int? end}) =>
      statsOf(samples(key), window, end: end);

  /// Adds every metric of [v] at the host time [at] (milliseconds). A sample
  /// at or before the series' last time replaces nothing and is dropped, so a
  /// one-shot refresh racing a push never draws a step backwards.
  MonitorHistory add(Vitals v, {int? at}) {
    final t = at ?? (v.timestamp > 0 ? v.timestamp : 0);
    if (t <= 0) return this;
    final next = {
      for (final e in series.entries) e.key: List<Sample>.of(e.value),
    };
    void push(String key, double? value) {
      if (value == null || !value.isFinite) return;
      final list = next.putIfAbsent(key, () => []);
      if (list.isNotEmpty && list.last.t >= t) return;
      list.add(Sample(t, value));
      final oldest = t - keep.inMilliseconds;
      var drop = 0;
      while (drop < list.length && list[drop].t < oldest) {
        drop++;
      }
      drop = math.max(drop, list.length - capacity);
      if (drop > 0) list.removeRange(0, drop);
    }

    final gpu = v.mainGpu;
    push('cpu', v.cpu);
    final cores = v.perCore;
    for (var i = 0; i < cores.length; i++) {
      push('cpuThread:$i', cores[i]);
    }
    push('ram', v.ramPercent);
    push('cpuTemp', v.cpuTempC);
    push('gpu', gpu?.busy);
    push('vram', gpu?.vramPercent);
    // The hottest GPU sensor, the one that throttles (same as the headline).
    push('gpuTemp', gpu?.hotspotC ?? gpu?.tempC);
    push('gpuPower', gpu?.powerW);
    push('netRx', v.netRx);
    push('netTx', v.netTx);
    push('diskRead', v.diskRead);
    push('diskWrite', v.diskWrite);
    return MonitorHistory(next);
  }
}

class MonitorState {
  const MonitorState({this.snapshot, this.history, this.error});
  final MonitorSnapshot? snapshot;
  final MonitorHistory? history;
  final String? error;
  bool get ready => snapshot != null;
}

class MonitorNotifier extends Notifier<MonitorState> {
  RpcClient? _client;
  @override
  MonitorState build() {
    final client = ref.watch(activeClientProvider);
    _client = client;
    if (client == null) return const MonitorState();
    final unsub = client.subscribe('monitor-update', (msg) {
      final snap = msg['snapshot'];
      if (snap is Map) _apply(MonitorSnapshot(Map<String, dynamic>.from(snap)));
    });
    ref.onDispose(unsub);
    return MonitorState(history: MonitorHistory());
  }

  void _apply(MonitorSnapshot snapshot) {
    final last = state.snapshot;
    // Ignore an out-of-order snapshot (e.g. a slow one-shot fetch).
    if (last != null && snapshot.at.isBefore(last.at)) return;
    state = MonitorState(
      snapshot: snapshot,
      history: (state.history ?? MonitorHistory()).add(
        snapshot.vitals,
        at: snapshot.vitals.timestamp > 0
            ? snapshot.vitals.timestamp
            : snapshot.at.millisecondsSinceEpoch,
      ),
    );
  }

  /// One-shot fetch so a screen paints instantly instead of waiting for the next push.
  Future<void> refresh() async {
    final client = _client;
    if (client == null || !client.supports('monitor.v1')) return;
    try {
      _apply(MonitorSnapshot(await client.requestMap('monitor.snapshot')));
    } catch (e) {
      state = MonitorState(
        snapshot: state.snapshot,
        history: state.history,
        error: '$e',
      );
    }
  }

  Future<String> appAction(AgentApp app, String action) =>
      _action('monitor.appAction', {
        if (app.isDesktop) 'appId': app.appId else 'instanceId': app.id,
        'action': action,
      });

  Future<String> launch(String appId) =>
      _action('monitor.appAction', {'appId': appId, 'action': 'launch'});

  Future<String> remoteAction(String service, String action) =>
      _action('monitor.remoteAction', {'service': service, 'action': action});

  Future<String> _action(String method, Map<String, dynamic> params) async {
    final client = _client;
    if (client == null) return 'Not connected to the PC.';
    final result = await client.requestMap(
      method,
      params,
      const Duration(seconds: 40),
    );
    unawaited(refresh());
    return result['message'] as String? ??
        (result['ok'] == true ? 'Done.' : 'That didn’t work.');
  }
}

final monitorProvider = NotifierProvider<MonitorNotifier, MonitorState>(
  MonitorNotifier.new,
);

bool hostSupportsMonitor(RpcClient? client) =>
    client?.supports('monitor.v1') == true;

/// Keeps live monitor pushes flowing while [child] is on screen and the app is in
/// the foreground; stops them otherwise (battery + PC CPU).
class MonitorDemand extends ConsumerStatefulWidget {
  const MonitorDemand({
    super.key,
    required this.owner,
    required this.child,
    this.intervalMs = 2000,
    this.active = true,
  });
  final String owner;
  final int intervalMs;
  final bool active;
  final Widget child;
  @override
  ConsumerState<MonitorDemand> createState() => _MonitorDemandState();
}

class _MonitorDemandState extends ConsumerState<MonitorDemand>
    with WidgetsBindingObserver {
  RpcClient? _client;
  bool _foreground = true;
  String get _key => 'monitor:${widget.owner}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _sync();
      ref.read(monitorProvider.notifier).refresh();
    });
  }

  @override
  void didUpdateWidget(MonitorDemand old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active || old.intervalMs != widget.intervalMs) {
      _sync();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
    if (_foreground) ref.read(monitorProvider.notifier).refresh();
  }

  void _sync() {
    final client = ref.read(activeClientProvider);
    if (!identical(client, _client)) {
      _client?.demand(_key, 0);
      _client = client;
    }
    client?.demand(_key, widget.active && _foreground ? widget.intervalMs : 0);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _client?.demand(_key, 0);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(activeClientProvider, (_, _) {
      _sync();
      ref.read(monitorProvider.notifier).refresh();
    });
    return widget.child;
  }
}
