import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../rpc/rpc_client.dart';
import '../state/connection.dart';
import 'monitor_models.dart';

/// Rolling series for charts; one sample per monitor-update (1-5 s).
class MonitorHistory {
  MonitorHistory([Map<String, List<double>>? series]) : series = series ?? {};
  final Map<String, List<double>> series;
  static const capacity = 150;
  List<double> operator [](String key) => series[key] ?? const [];
  MonitorHistory add(Vitals v) {
    final next = {for (final e in series.entries) e.key: List<double>.of(e.value)};
    void push(String key, double? value) {
      if (value == null) return;
      final list = next.putIfAbsent(key, () => []);
      list.add(value);
      if (list.length > capacity) list.removeRange(0, list.length - capacity);
    }

    push('cpu', v.cpu);
    push('ram', v.ramPercent);
    push('gpu', v.mainGpu?.busy);
    push('vram', v.mainGpu?.vramPercent);
    push('cpuTemp', v.cpuTempC);
    push('gpuTemp', v.mainGpu?.hotspotC ?? v.mainGpu?.tempC);
    push('netRx', v.netRx);
    push('netTx', v.netTx);
    push('diskRead', v.diskRead);
    push('diskWrite', v.diskWrite);
    push('gpuPower', v.mainGpu?.powerW);
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
      history: (state.history ?? MonitorHistory()).add(snapshot.vitals),
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

  Future<String> remoteAction(String service, String action) => _action(
    'monitor.remoteAction',
    {'service': service, 'action': action},
  );

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
