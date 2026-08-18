// Launcher data providers: the PC's running windows (polled, since the WM has
// no push events on this path) and its installed apps (fetched once, cached).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rpc/models.dart';
import '../rpc/rpc_client.dart';
import 'connection.dart';

/// Installed apps — fetched on connect, cached across navigation and reconnects,
/// and updated seamlessly on apps-update pushes when new apps are added to the PC.
final appsProvider =
    NotifierProvider<AppsNotifier, AsyncValue<List<AppInfo>>>(
        AppsNotifier.new);

class AppsNotifier extends Notifier<AsyncValue<List<AppInfo>>> {
  static List<AppInfo>? _cache;
  bool _disposed = false;
  void Function()? _unsub;

  @override
  AsyncValue<List<AppInfo>> build() {
    final client = ref.watch(activeClientProvider);
    final status = ref.watch(connectionStatusProvider);
    ref.onDispose(() {
      _disposed = true;
      _unsub?.call();
    });

    if (client == null) {
      return AsyncValue.data(_cache ?? const []);
    }

    if (status == RpcStatus.connected) {
      _unsub?.call();
      _unsub = client.subscribe('apps-update', (msg) {
        final raw = msg['apps'];
        if (raw is List) {
          final list = raw
              .map((e) => AppInfo.fromJson(e as Map<String, dynamic>))
              .toList();
          _cache = list;
          if (!_disposed) state = AsyncValue.data(list);
        }
      });
      Future.microtask(refresh);
    }

    if (_cache != null) {
      return AsyncValue.data(_cache!);
    }
    return status == RpcStatus.connecting || status == RpcStatus.connected
        ? const AsyncValue.loading()
        : const AsyncValue.data([]);
  }

  Future<void> refresh() async {
    final client = ref.read(activeClientProvider);
    final status = ref.read(connectionStatusProvider);
    if (client == null || status != RpcStatus.connected) return;
    try {
      final raw = await client.requestList(
          'apps.list', const {}, const Duration(seconds: 30));
      final list =
          raw.map((e) => AppInfo.fromJson(e as Map<String, dynamic>)).toList();
      _cache = list;
      if (!_disposed) state = AsyncValue.data(list);
    } catch (e, st) {
      if (!_disposed) {
        if (_cache != null) {
          state = AsyncValue.data(_cache!);
        } else if (state is! AsyncData) {
          state = AsyncValue.error(e, st);
        }
      }
    }
  }
}

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
    final status = ref.watch(connectionStatusProvider);
    ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
      _unsub?.call();
    });

    if (client == null) return const AsyncValue.data([]);

    if (status == RpcStatus.connected) {
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 5), (_) => refresh());
      _unsub?.call();
      _unsub = client.subscribe('app-session-update', (_) => refresh());
      Future.microtask(refresh);
    }

    return AsyncValue.data(state.value ?? const []);
  }

  Future<void> refresh() async {
    final client = ref.read(activeClientProvider);
    final status = ref.read(connectionStatusProvider);
    if (client == null || status != RpcStatus.connected) return;
    try {
      final raw = await client.requestList('appSession.list');
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
    final status = ref.watch(connectionStatusProvider);
    ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
    });

    if (client == null) return const AsyncValue.data([]);

    if (status == RpcStatus.connected) {
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 5), (_) => refresh());
      Future.microtask(refresh);
    }

    return AsyncValue.data(state.value ?? const []);
  }

  Future<void> refresh() async {
    final client = ref.read(activeClientProvider);
    final status = ref.read(connectionStatusProvider);
    if (client == null || status != RpcStatus.connected) return;
    try {
      final raw = await client.requestList('window.list');
      final list =
          raw.map((e) => WindowInfo.fromJson(e as Map<String, dynamic>)).toList();
      if (!_disposed) state = AsyncValue.data(list);
    } catch (e, st) {
      if (!_disposed && state is! AsyncData) state = AsyncValue.error(e, st);
    }
  }
}
