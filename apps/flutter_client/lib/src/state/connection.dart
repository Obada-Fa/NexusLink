// App-wide connection state. Holds the single active RpcClient and exposes it
// (plus live status) to the widget tree via Riverpod. Screens read
// `activeClientProvider` and watch `connectionStatusProvider`; the connect
// screen drives connect/disconnect.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rpc/rpc_client.dart';
import 'last_host.dart';

class ConnectionState {
  final RpcClient? client;
  final RpcStatus status;
  final String? hostUrl;
  final String? httpBase; // e.g. http://192.168.2.30:45678 for file transfer

  const ConnectionState({
    this.client,
    this.status = RpcStatus.disconnected,
    this.hostUrl,
    this.httpBase,
  });

  ConnectionState copyWith({
    RpcClient? client,
    RpcStatus? status,
    String? hostUrl,
    String? httpBase,
  }) =>
      ConnectionState(
        client: client ?? this.client,
        status: status ?? this.status,
        hostUrl: hostUrl ?? this.hostUrl,
        httpBase: httpBase ?? this.httpBase,
      );
}

class ConnectionNotifier extends Notifier<ConnectionState> {
  VoidCallback? _statusSub;
  bool _disposed = false;

  @override
  ConnectionState build() {
    ref.onDispose(() {
      _disposed = true;
      _statusSub?.call();
      state.client?.dispose();
    });
    return const ConnectionState();
  }

  /// Connect to a host ws URL. Derives the matching http base for file transfer.
  Future<void> connect(String wsUrl) async {
    _teardown();
    final client = RpcClient(wsUrl);
    final sub = client.statusStream.listen((s) {
      if (!_disposed) state = state.copyWith(status: s);
    });
    _statusSub = sub.cancel;
    state = state.copyWith(
      client: client,
      status: RpcStatus.connecting,
      hostUrl: wsUrl,
      httpBase: _httpBaseFromWs(wsUrl),
    );
    try {
      await client.connect();
      if (_disposed) {
        client.dispose();
        return;
      }
      await saveLastHostUrl(wsUrl);
      state = state.copyWith(status: RpcStatus.connected);
    } catch (_) {
      client.dispose();
      if (!_disposed) state = const ConnectionState();
      rethrow;
    }
  }

  void disconnect() {
    _teardown();
    if (!_disposed) state = const ConnectionState();
  }

  /// Reconnect using the current host URL, or the last saved host from prefs.
  Future<void> reconnect() async {
    final saved = state.hostUrl?.trim();
    if (saved != null && saved.isNotEmpty) {
      await connect(saved);
      return;
    }
    final last = await loadLastHostUrl();
    if (last == null || last.isEmpty) {
      throw StateError(
        'No saved PC — go back to the home screen and connect again.',
      );
    }
    await connect(last);
  }

  /// Silent reconnect used when the app returns to the foreground. Only runs
  /// if this session already had a host (explicit disconnect clears it).
  Future<void> ensureConnected() async {
    if (_disposed) return;
    if (state.status == RpcStatus.connected ||
        state.status == RpcStatus.connecting) {
      return;
    }
    final url = state.hostUrl?.trim();
    if (url == null || url.isEmpty) return;
    try {
      await connect(url);
    } catch (_) {}
  }

  void _teardown() {
    _statusSub?.call();
    _statusSub = null;
    state.client?.dispose();
  }

  static String _httpBaseFromWs(String wsUrl) {
    final uri = Uri.parse(wsUrl);
    final scheme = uri.scheme == 'wss' ? 'https' : 'http';
    return '$scheme://${uri.host}:${uri.port}';
  }
}

final connectionProvider =
    NotifierProvider<ConnectionNotifier, ConnectionState>(
        ConnectionNotifier.new);

/// The active client, or null when disconnected. Screens that require a
/// connection read this and guard on null.
final activeClientProvider =
    Provider<RpcClient?>((ref) => ref.watch(connectionProvider).client);

final connectionStatusProvider =
    Provider<RpcStatus>((ref) => ref.watch(connectionProvider).status);
