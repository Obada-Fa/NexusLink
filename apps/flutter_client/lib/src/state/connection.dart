// App-wide connection state. Holds the single active RpcClient and exposes it
// (plus live status) to the widget tree via Riverpod. Screens read
// `activeClientProvider` and watch `connectionStatusProvider`; the connect
// screen drives connect/disconnect.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../chats/chat_cache.dart';
import '../workspace/platform_bridge.dart';

import '../rpc/rpc_client.dart';
import 'last_host.dart';

class ConnectionState {
  final RpcClient? client;
  final RpcStatus status;
  final String? hostUrl;
  final String? httpBase; // e.g. http://192.168.2.30:45678 for file transfer

  /// The PC no longer accepts this phone's pairing (credential revoked or
  /// missing). Automatic reconnects stop until the user pairs again.
  final bool authRequired;

  /// Phone-facing reason for the last failed connection attempt.
  final String? lastError;

  const ConnectionState({
    this.client,
    this.status = RpcStatus.disconnected,
    this.hostUrl,
    this.httpBase,
    this.authRequired = false,
    this.lastError,
  });

  ConnectionState copyWith({
    RpcClient? client,
    RpcStatus? status,
    String? hostUrl,
    String? httpBase,
    bool? authRequired,
    String? lastError,
    bool clearError = false,
  }) => ConnectionState(
    client: client ?? this.client,
    status: status ?? this.status,
    hostUrl: hostUrl ?? this.hostUrl,
    httpBase: httpBase ?? this.httpBase,
    authRequired: authRequired ?? this.authRequired,
    lastError: clearError ? null : lastError ?? this.lastError,
  );
}

/// True when [error] means the PC refused this phone's pairing.
bool isAuthError(Object error) =>
    error is RpcException && error.code == 'UNAUTHENTICATED';

/// Short, phone-facing explanation of a failed connection attempt.
String connectErrorMessage(Object error) {
  if (isAuthError(error)) {
    final message = (error as RpcException).message;
    if (message.toLowerCase().contains('pairing code')) return message;
    return 'This phone is no longer paired with that PC. Enter a new pairing '
        'code to pair again.';
  }
  final raw = error is RpcException ? error.message : '$error';
  final lower = raw.toLowerCase();
  if (lower.contains('timed out') ||
      lower.contains('connection refused') ||
      lower.contains('network is unreachable') ||
      lower.contains('no route to host') ||
      lower.contains('failed host lookup') ||
      lower.contains('socketexception') ||
      lower.contains('websocketexception') ||
      lower.contains('connection closed') ||
      lower.contains('disconnected before')) {
    return 'The PC didn’t answer. Check that it is on, NexusLink is running, '
        'and both devices are on the same network or Tailscale.';
  }
  return friendlyLaunchError(error);
}

class ConnectionNotifier extends Notifier<ConnectionState> {
  VoidCallback? _statusSub;
  RpcClient? _currentClient;
  bool _disposed = false;
  bool _explicitDisconnect = false;
  int _generation = 0;
  Future<void>? _inFlightConnect;

  /// The user ended the connection in this app run (Disconnect, Forget, or
  /// cancelling a connection). Cleared when the user connects again.
  bool get userDisconnected => _explicitDisconnect;

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
  Future<void> connect(String wsUrl, {String? pairingCode}) async {
    _explicitDisconnect = false;
    wsUrl = normalizeHostWsUrl(wsUrl);
    if (_inFlightConnect != null &&
        state.hostUrl == wsUrl &&
        pairingCode == null) {
      return _inFlightConnect!;
    }
    final run = _connect(wsUrl, pairingCode);
    _inFlightConnect = run;
    try {
      await run;
    } finally {
      if (identical(_inFlightConnect, run)) _inFlightConnect = null;
    }
  }

  Future<void> _connect(String wsUrl, String? pairingCode) async {
    final generation = ++_generation;
    _teardown();
    final client = RpcClient(wsUrl, pairingCode: pairingCode);
    _currentClient = client;
    final sub = client.statusStream.listen((s) {
      if (_disposed || generation != _generation) return;
      if (s == RpcStatus.disconnected && client.authRequired) {
        // A background reconnect was refused: surface it instead of looking
        // like an ordinary offline PC.
        state = state.copyWith(
          status: s,
          authRequired: true,
          lastError: connectErrorMessage(
            RpcException('Pairing was removed on the PC', 'UNAUTHENTICATED'),
          ),
        );
        if (client.credentialRevoked) unawaited(_forgetCredential(wsUrl));
        return;
      }
      state = state.copyWith(status: s);
    });
    _statusSub = sub.cancel;
    state = ConnectionState(
      client: client,
      status: RpcStatus.connecting,
      hostUrl: wsUrl,
      httpBase: _httpBaseFromWs(wsUrl),
    );
    try {
      await client.connect();
      if (_disposed || generation != _generation) {
        client.dispose();
        return;
      }
      if (client.status != RpcStatus.connected) {
        throw RpcException('PC disconnected before synchronization finished');
      }
      await saveLastHostUrl(wsUrl);
      state = state.copyWith(
        status: RpcStatus.connected,
        authRequired: false,
        clearError: true,
      );
    } catch (error) {
      client.dispose();
      final authRequired = client.credentialRevoked || isAuthError(error);
      if (client.credentialRevoked) await _forgetCredential(wsUrl);
      if (generation == _generation) {
        _currentClient = null;
        if (!_disposed) {
          state = ConnectionState(
            hostUrl: wsUrl,
            httpBase: _httpBaseFromWs(wsUrl),
            authRequired: authRequired,
            lastError: connectErrorMessage(error),
          );
        }
      }
      rethrow;
    }
  }

  Future<void> _forgetCredential(String wsUrl) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final host = prefs.getString('chat-host:$wsUrl');
      if (host != null) await ChatCache().clear(host, includeDrafts: true);
      await PlatformBridge.removeCredential(wsUrl);
    } catch (error) {
      debugPrint('Could not clear revoked pairing: $error');
    }
  }

  void disconnect() {
    _explicitDisconnect = true;
    ++_generation;
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
  /// Failures are recorded in [ConnectionState.lastError] /
  /// [ConnectionState.authRequired] rather than thrown.
  Future<void> ensureConnected() async {
    if (_disposed || _explicitDisconnect || state.authRequired) return;
    final client = state.client;
    if (client != null) {
      switch (client.status) {
        case RpcStatus.connected:
          try {
            // Foregrounding can leave a half-open socket that still reports
            // "connected". Probe once so resume paths can recover.
            await client.request(
              'session.heartbeat',
              const {},
              const Duration(seconds: 3),
            );
            return;
          } catch (_) {
            await _reconnectInPlace(client);
            return;
          }
        case RpcStatus.connecting:
          await _waitWhileConnecting();
          return;
        case RpcStatus.disconnected:
          // The client is waiting out its backoff; retry right away.
          await _reconnectInPlace(client);
          return;
      }
    }
    final inflight = _inFlightConnect;
    if (inflight != null) {
      try {
        await inflight;
      } catch (_) {}
      return;
    }
    var url = state.hostUrl?.trim();
    if (url == null || url.isEmpty) {
      url = await loadLastHostUrl();
    }
    if (url == null || url.isEmpty) return;
    try {
      await connect(url);
    } catch (_) {
      // State already carries lastError / authRequired for the UI.
    }
  }

  /// Re-dial the existing client so its topic listeners, demands and the
  /// widgets bound to it (chat lists, terminals) survive the reconnect.
  Future<void> _reconnectInPlace(RpcClient client) async {
    final generation = _generation;
    try {
      await client.connect();
      if (generation == _generation && !_disposed) {
        state = state.copyWith(status: client.status, clearError: true);
      }
    } catch (error) {
      if (generation != _generation || _disposed) return;
      state = state.copyWith(
        status: client.status,
        authRequired: client.authRequired || isAuthError(error),
        lastError: connectErrorMessage(error),
      );
    }
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
    return Uri(
      scheme: scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    ).toString();
  }
}

final connectionProvider =
    NotifierProvider<ConnectionNotifier, ConnectionState>(
      ConnectionNotifier.new,
    );

/// The active client, or null when disconnected. Screens that require a
/// connection read this and guard on null.
final activeClientProvider = Provider<RpcClient?>(
  (ref) => ref.watch(connectionProvider).client,
);

final connectionStatusProvider = Provider<RpcStatus>(
  (ref) => ref.watch(connectionProvider).status,
);

/// The PC refused this phone's pairing; show a "Pair again" path.
final connectionAuthRequiredProvider = Provider<bool>(
  (ref) => ref.watch(connectionProvider.select((s) => s.authRequired)),
);
