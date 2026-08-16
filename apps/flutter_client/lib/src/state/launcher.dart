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

/// Running windows — refreshed while connected (launcher + mirror both watch).
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
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => refresh());
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
      // Keep the last good list so the taskbar does not vanish on a blip.
      if (!_disposed && state is! AsyncData) {
        state = AsyncValue.error(e, st);
      }
    }
  }
}
