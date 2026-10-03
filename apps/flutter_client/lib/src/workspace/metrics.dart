import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../state/connection.dart';

class MetricsNotifier extends Notifier<Map<String, dynamic>?> {
  @override
  Map<String, dynamic>? build() {
    final client = ref.watch(activeClientProvider);
    if (client == null) return null;
    final unsub = client.subscribe('perf-update', (msg) {
      final data = msg['data'];
      if (data is Map<String, dynamic>) state = data;
    });
    ref.onDispose(unsub);
    return null;
  }
}

final metricsProvider =
    NotifierProvider<MetricsNotifier, Map<String, dynamic>?>(
      MetricsNotifier.new,
    );

class WorkspaceSettings extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() => {'stats': true, 'experimental': false};
  void set(String key, bool value) => state = {...state, key: value};
}

final workspaceSettingsProvider =
    NotifierProvider<WorkspaceSettings, Map<String, bool>>(
      WorkspaceSettings.new,
    );
