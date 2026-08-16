// Launcher data providers: the PC's running windows (polled, since the WM has
// no push events on this path) and its installed apps (fetched once, cached).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rpc/models.dart';
import 'connection.dart';

/// Installed apps — one fetch per connection (apps.list is expensive: it scans
/// .desktop dirs and resolves icons host-side).
final appsProvider = FutureProvider<List<AppInfo>>((ref) async {
  final client = ref.watch(activeClientProvider);
  if (client == null) return [];
  final raw = await client.request(
      'apps.list', const {}, const Duration(seconds: 30)) as List<dynamic>;
  return raw.map((e) => AppInfo.fromJson(e as Map<String, dynamic>)).toList();
});

/// Virtual app sessions running on the PC ("running on your phone") —
/// polled with the windows and refreshed instantly on app-session-update
/// pushes (app launched/exited/closed).
final appSessionsProvider =
    NotifierProvider<AppSessionsNotifier, AsyncValue<List<AppSessionInfo>>>(
        AppSessionsNotifier.new);

class AppSessionsNotifier extends Notifier<AsyncValue<List<AppSessionInfo>>> {
  Timer? _timer;
  bool _disposed = false;
  void Function()? _unsub;

  @override
  AsyncValue<List<AppSessionInfo>> build() {
    final client = ref.watch(activeClientProvider);
    ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
      _unsub?.call();
    });
    if (client == null) return const AsyncValue.data([]);
    Future.microtask(refresh);
    _timer ??= Timer.periodic(const Duration(seconds: 5), (_) => refresh());
    _unsub ??= client.subscribe('app-session-update', (_) => refresh());
    return const AsyncValue.loading();
  }

  Future<void> refresh() async {
    final client = ref.read(activeClientProvider);
    if (client == null) return;
    try {
      final raw = await client.request('appSession.list') as List<dynamic>;
      final list = raw
          .map((e) => AppSessionInfo.fromJson(e as Map<String, dynamic>))
          .where((s) => s.status == 'running')
          .toList();
      if (!_disposed) state = AsyncValue.data(list);
    } catch (e, st) {
      if (!_disposed && state is! AsyncData) state = AsyncValue.error(e, st);
    }
  }
}

/// Running windows — refreshed every 5s while the launcher is on screen.
final windowsProvider =
    NotifierProvider<WindowsNotifier, AsyncValue<List<WindowInfo>>>(
        WindowsNotifier.new);

class WindowsNotifier extends Notifier<AsyncValue<List<WindowInfo>>> {
  Timer? _timer;
  bool _disposed = false;

  @override
  AsyncValue<List<WindowInfo>> build() {
    final client = ref.watch(activeClientProvider);
    ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
    });
    if (client == null) return const AsyncValue.data([]);
    // Kick off the first fetch + polling after this build returns.
    Future.microtask(refresh);
    _timer ??= Timer.periodic(const Duration(seconds: 5), (_) => refresh());
    return const AsyncValue.loading();
  }

  Future<void> refresh() async {
    final client = ref.read(activeClientProvider);
    if (client == null) return;
    try {
      final raw = await client.request('window.list') as List<dynamic>;
      final list =
          raw.map((e) => WindowInfo.fromJson(e as Map<String, dynamic>)).toList();
      if (!_disposed) state = AsyncValue.data(list);
    } catch (e, st) {
      if (!_disposed && state is! AsyncData) state = AsyncValue.error(e, st);
    }
  }
}
