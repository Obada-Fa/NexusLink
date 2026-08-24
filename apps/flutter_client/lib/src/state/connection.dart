// App-wide connection state. Holds the single active RpcClient and exposes it
// (plus live status) to the widget tree via Riverpod. Screens read
// `activeClientProvider` and watch `connectionStatusProvider`; the connect
// screen drives connect/disconnect.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rpc/rpc_client.dart';
import 'connection_policy.dart';
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
  ConnectionNotifier({RpcClient Function(String wsUrl)? createClient})
      : _createClient = createClient ?? RpcClient.new;

  final RpcClient Function(String wsUrl) _createClient;

  VoidCallback? _statusSub;
  RpcClient? _currentClient;
  bool _disposed = false;
  Future<void>? _inFlightConnect;
  Future<void>? _inFlightEnsure;

  @override
  ConnectionState build() {
    ref.onDispose(() {
      _disposed = true;
      _statusSub?.call();
      _statusSub = null;
      _currentClient?.dispose();
      _currentClient = null;
    });
    return const ConnectionState();
  }

  /// Connect to a host ws URL. Derives the matching http base for file transfer.
  Future<void> connect(String wsUrl) async {
    wsUrl = normalizeHostWsUrl(wsUrl);
    final previous = _inFlightConnect;
    final run = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {}
        if (_disposed) return;
        if (state.status == RpcStatus.connected && state.hostUrl == wsUrl) {
          return;
        }
      }
      await _connect(wsUrl);
    }();
    _inFlightConnect = run;
    try {
      await run;
    } finally {
      if (identical(_inFlightConnect, run)) _inFlightConnect = null;
    }
  }

  Future<void> _connect(String wsUrl) async {
    final existing = _currentClient;
    if (existing != null &&
        shouldReuseRpcClient(
          targetUrl: wsUrl,
          currentUrl: state.hostUrl,
          clientClosed: existing.isClosed,
        )) {
      if (existing.status == RpcStatus.connected && existing.socketOpen) {
        if (!_disposed) {
          state = state.copyWith(status: RpcStatus.connected, hostUrl: wsUrl);
        }
        return;
      }
      try {
        await existing.connect();
        if (_disposed) return;
        await saveLastHostUrl(wsUrl);
        state = state.copyWith(status: RpcStatus.connected, hostUrl: wsUrl);
        return;
      } catch (_) {
        if (!_disposed) {
          state = state.copyWith(
            client: existing,
            status: RpcStatus.disconnected,
            hostUrl: wsUrl,
            httpBase: _httpBaseFromWs(wsUrl),
          );
        }
        rethrow;
      }
    }

    _teardown();
    final client = _createClient(wsUrl);
    _currentClient = client;
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
      if (_disposed) {
        client.dispose();
        rethrow;
      }
      // Keep the client so its backoff reconnect can recover, and keep the
      // host URL so resume/retry still know where to dial.
      _currentClient = client;
      state = ConnectionState(
        client: client,
        status: RpcStatus.disconnected,
        hostUrl: wsUrl,
        httpBase: _httpBaseFromWs(wsUrl),
      );
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
    final existingEnsure = _inFlightEnsure;
    if (existingEnsure != null) {
      try {
        await existingEnsure;
      } catch (_) {}
      return;
    }
    final run = _ensureConnected();
    _inFlightEnsure = run;
    try {
      await run;
    } finally {
      if (identical(_inFlightEnsure, run)) _inFlightEnsure = null;
    }
  }

  Future<void> _ensureConnected() async {
    if (_disposed) return;
    if (state.status == RpcStatus.connected) {
      final client = state.client;
      if (client == null) return;
      try {
        // Foregrounding can leave a half-open socket that still reports
        // "connected". Probe once so resume paths can recover and catch up.
        await client.request(
          'session.heartbeat',
          const {},
          livenessProbeTimeout,
        );
        return;
      } catch (_) {
        if (!shouldReplaceLiveSocket(
          status: client.status,
          socketOpen: client.socketOpen,
          probeFailed: true,
        )) {
          return;
        }
        if (!client.isClosed) {
          try {
            await client.connect();
          } catch (_) {}
          return;
        }
      }
    }
    final inflight = _inFlightConnect;
    if (inflight != null) {
      try {
        await inflight;
      } catch (_) {}
      return;
    }
    if (state.status == RpcStatus.connecting) {
      await _waitWhileConnecting();
      return;
    }
    final existing = state.client ?? _currentClient;
    if (existing != null && !existing.isClosed) {
      if (existing.status == RpcStatus.connecting) {
        await _waitWhileConnecting();
      }
      // Auto-reconnect is already scheduled. Do not replace the client.
      return;
    }
    final url = state.hostUrl?.trim();
    if (url == null || url.isEmpty) return;
    try {
      await connect(url);
    } catch (_) {}
  }

  Future<void> _waitWhileConnecting() async {
    final client = state.client;
    if (client == null || client.status != RpcStatus.connecting) return;
    try {
      await client.statusStream
          .firstWhere((s) => s != RpcStatus.connecting)
          .timeout(const Duration(seconds: 15));
    } catch (_) {}
  }

  void _teardown() {
    _statusSub?.call();
    _statusSub = null;
    _currentClient?.dispose();
    _currentClient = null;
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
