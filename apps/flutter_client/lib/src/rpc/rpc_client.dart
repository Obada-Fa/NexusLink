// Dart port of the NexusLink RPC client (protocol contract:
// packages/rpc-types/src/index.ts, reference impl:
// apps/mobile-client/src/lib/rpc-client.ts).
//
// One WebSocket carries two planes:
//  - JSON `WsMessage` frames: rpc-request/rpc-response + topic pushes
//    (terminal-output, perf-update, stream-region, ...)
//  - Binary frames: mirror video (16-byte header: u32 magic 'NLF1' | u32
//    streamKey | f64 timestampMs, little-endian; JPEG payload follows).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import '../workspace/platform_bridge.dart';

import '../auth/pairing.dart';

const frameMagic = 0x4e4c4631; // 'NLF1'
const frameHeaderBytes = 16;

/// A parsed binary mirror frame.
class MirrorFrame {
  final int streamKey;
  final double timestampMs;
  final Uint8List jpeg;
  MirrorFrame(this.streamKey, this.timestampMs, this.jpeg);

  static MirrorFrame? parse(Uint8List raw) {
    if (raw.lengthInBytes <= frameHeaderBytes) return null;
    final view = ByteData.sublistView(raw);
    if (view.getUint32(0, Endian.little) != frameMagic) return null;
    return MirrorFrame(
      view.getUint32(4, Endian.little),
      view.getFloat64(8, Endian.little),
      Uint8List.sublistView(raw, frameHeaderBytes),
    );
  }
}

enum RpcStatus { disconnected, connecting, connected }

class RpcException implements Exception {
  final String message;
  final String? code;
  RpcException(this.message, [this.code]);
  @override
  String toString() => message;
}

/// Decode an RPC result that must be a JSON object. Older hosts ack unknown
/// methods with a null/missing result — that used to crash the Flutter client
/// with `type 'Null' is not a subtype of type 'Map<String, dynamic>'`.
Map<String, dynamic> expectMap(dynamic raw, String method) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return Map<String, dynamic>.from(raw);
  if (raw == null) {
    throw RpcException(
      'NexusLink on your PC is out of date (no result for $method). '
      'Update NexusLink on the PC and restart it, then try again.',
    );
  }
  throw RpcException('Unexpected $method result (${raw.runtimeType}).');
}

List<dynamic> expectList(dynamic raw, String method) {
  if (raw is List) return raw;
  if (raw == null) {
    throw RpcException(
      'NexusLink on your PC is out of date (no result for $method). '
      'Update NexusLink on the PC and restart it, then try again.',
    );
  }
  throw RpcException('Unexpected $method result (${raw.runtimeType}).');
}

/// Phone-facing copy for launch/mirror failures (hides Dart type-cast noise).
String friendlyLaunchError(Object error) {
  final raw = error is RpcException ? error.message : error.toString();
  if (raw.contains('Null') && raw.contains('Map<String')) {
    return 'NexusLink on your PC is out of date. Update NexusLink on the PC '
        'and restart it, then reopen this app.';
  }
  if (raw.contains('unknown method')) {
    return 'NexusLink on your PC is out of date. Update and restart NexusLink on the PC.';
  }
  if (raw.contains('unknown app session')) {
    return 'The app quit before it could show a window. '
        'If it is already open on the PC, close it there and try again.';
  }
  return raw.replaceFirst(RegExp(r'^RpcException:\s*'), '');
}

/// How this phone appears in the PC's list of paired devices.
String pairedDeviceName() {
  if (Platform.isAndroid) return 'Android phone';
  if (Platform.isIOS) return 'iPhone';
  return 'NexusLink on ${Platform.operatingSystem}';
}

/// Backoff for a dropped WebSocket: 1s, 2s, 4s, 8s, then cap at 30s.
int reconnectDelayMs(int attempts) {
  final exp = 1000 * (1 << attempts.clamp(0, 10));
  return exp.clamp(1000, 30000);
}

class RpcClient {
  RpcClient(this.wsUrl, {this.pairingCode});
  String? pairingCode;
  String? token;
  String? hostId;
  bool credentialRevoked = false;
  Map<String, dynamic> capabilities = {};
  String phase = 'disconnected';
  int _generation = 0;
  Future<void>? _connecting;
  final Map<String, int> _demands = {};

  /// True once the host refused this phone's pairing; automatic reconnects
  /// stop until the user pairs again.
  bool get authRequired => phase == 'authentication required';

  /// Host subscriptions such as `chat.subscribe` live on one socket. Remember
  /// the last requested state so a reconnect restores it.
  bool? _chatSubscribed;
  bool _everConnected = false;
  String? _credential;
  Timer? _authRefresh;
  bool supports(String feature) =>
      (capabilities['features'] as List?)?.contains(feature) == true ||
      (capabilities['methods'] as List?)?.contains(feature) == true;

  final String wsUrl;

  WebSocket? _ws;
  int _idCounter = 0;
  bool _closed = false;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;
  Timer? _heartbeat;
  Timer? _dialTimer;
  Completer<WebSocket>? _dialPending;

  final _pending = <String, Completer<dynamic>>{};
  final _topicSubs = <String, List<void Function(Map<String, dynamic>)>>{};
  final _frames = StreamController<MirrorFrame>.broadcast();
  final _status = StreamController<RpcStatus>.broadcast();

  RpcStatus _currentStatus = RpcStatus.disconnected;
  RpcStatus get status => _currentStatus;
  Stream<RpcStatus> get statusStream => _status.stream;

  /// Parsed binary mirror frames (all streams; filter by streamKey).
  Stream<MirrorFrame> get frames => _frames.stream;

  void _setStatus(RpcStatus s) {
    _currentStatus = s;
    if (!_status.isClosed) _status.add(s);
  }

  Future<void> connect() {
    final pending = _connecting;
    if (pending != null) return pending;
    final run = _connect();
    _connecting = run;
    return run.whenComplete(() {
      if (identical(_connecting, run)) _connecting = null;
    });
  }

  Future<void> _connect() async {
    _closed = false;
    final generation = ++_generation;
    _reconnectTimer?.cancel();
    _stopHeartbeat();
    _failPending('Connection replaced');
    final previous = _ws;
    _ws = null;
    await previous?.close();
    phase = 'connecting';
    _setStatus(RpcStatus.connecting);
    try {
      final ws = await _dial();
      if (_closed || generation != _generation) {
        await ws.close();
        throw RpcException('Connection superseded', 'CONNECTION_REPLACED');
      }
      ws.pingInterval = const Duration(seconds: 20);
      _ws = ws;
      ws.listen(
        (message) {
          if (generation == _generation) _onMessage(message);
        },
        onDone: () {
          if (generation == _generation) _onClosed();
        },
        onError: (_) {
          if (generation == _generation) _onClosed();
        },
        cancelOnError: true,
      );
      phase = 'authenticating';
      dynamic hello;
      try {
        hello = await _requestRaw('session.hello', {});
      } on RpcException catch (e) {
        if (!e.message.contains('unknown method') &&
            !e.message.contains('not authenticated')) {
          rethrow;
        }
      }
      if (hello is Map && hello['protocolVersion'] == 2) {
        // An unauthenticated host ID is not proof of server identity. Bind the
        // credential to this saved address until a verified host key exists.
        final credential = await PlatformBridge.credential(wsUrl);
        Map<String, dynamic> auth;
        if (pairingCode?.isNotEmpty == true) {
          auth = expectMap(
            await _requestRaw('session.enroll', {
              'code': pairingCode,
              'name': pairedDeviceName(),
            }),
            'session.enroll',
          );
          _credential = auth['credential'] as String;
          await PlatformBridge.saveCredential(wsUrl, _credential!);
          pairingCode = null;
          credentialRevoked = false;
        } else {
          if (credential == null) {
            throw RpcException(
              'This phone is not paired with that PC yet. Enter the pairing '
                  'code shown by NexusLink on your PC.',
              'UNAUTHENTICATED',
            );
          }
          try {
            auth = expectMap(
              await _requestRaw('session.resume', {'credential': credential}),
              'session.resume',
            );
          } on RpcException catch (error) {
            if (error.code == 'UNAUTHENTICATED') credentialRevoked = true;
            rethrow;
          }
          _credential = credential;
        }
        token = auth['token'] as String;
        hostId = auth['hostId'] as String;
        _scheduleAuthRefresh(auth['expires'], generation);
        phase = 'synchronizing';
        capabilities = expectMap(
          await _requestRaw('session.getCapabilities', {}),
          'session.getCapabilities',
        );
        await _requestRaw('session.subscribe', {
          'topics': ['agents'],
        });
      } else {
        token = await performPairingHandshake(_requestRaw);
        capabilities = {};
        hostId = wsUrl;
        try {
          capabilities = expectMap(
            await _requestRaw('session.getCapabilities', {}),
            'session.getCapabilities',
          );
          if (capabilities['hostId'] is String) {
            hostId = capabilities['hostId'] as String;
          }
        } on RpcException {
          // Preserve access to NexusLink chats on hosts predating capabilities.
        }
      }
      if (_closed || generation != _generation || !identical(_ws, ws)) {
        throw RpcException(
          'Connection closed during authentication',
          'CONNECTION_REPLACED',
        );
      }
      _reconnectAttempts = 0;
      phase = 'connected';
      _setStatus(RpcStatus.connected);
      _startHeartbeat();
      await _updateDemands();
      await _restoreSubscriptions(resync: _everConnected);
      _everConnected = true;
    } catch (e) {
      if (generation != _generation || _closed) rethrow;
      ++_generation;
      final ws = _ws;
      _ws = null;
      await ws?.close();
      _stopHeartbeat();
      _authRefresh?.cancel();
      phase = e is RpcException && e.code == 'UNAUTHENTICATED'
          ? 'authentication required'
          : 'reconnecting';
      _setStatus(RpcStatus.disconnected);
      if (phase != 'authentication required') _scheduleReconnect();
      rethrow;
    }
  }

  Future<WebSocket> _dial() {
    final pending = Completer<WebSocket>();
    _dialPending = pending;
    _dialTimer = Timer(const Duration(seconds: 8), () {
      if (!pending.isCompleted) {
        pending.completeError(RpcException('Connection timed out'));
      }
    });
    WebSocket.connect(wsUrl).then(
      (socket) {
        if (pending.isCompleted) {
          socket.close();
          return;
        }
        pending.complete(socket);
      },
      onError: (Object error) {
        if (!pending.isCompleted) pending.completeError(error);
      },
    );
    return pending.future.whenComplete(() {
      if (identical(_dialPending, pending)) {
        _dialTimer?.cancel();
        _dialPending = null;
      }
    });
  }

  /// Session tokens expire (one hour on current hosts). Renew on the same
  /// socket a few minutes early so requests and pushes never hit an expired
  /// token, instead of waiting for the heartbeat to fail and reconnecting.
  void _scheduleAuthRefresh(Object? expires, int generation) {
    _authRefresh?.cancel();
    if (expires is! num || _credential == null) return;
    final lead = DateTime.fromMillisecondsSinceEpoch(
      expires.toInt(),
    ).difference(DateTime.now());
    final delay = lead - const Duration(minutes: 5);
    _authRefresh = Timer(
      delay < const Duration(seconds: 30) ? const Duration(seconds: 30) : delay,
      () => unawaited(_refreshAuth(generation)),
    );
  }

  Future<void> _refreshAuth(int generation) async {
    final credential = _credential;
    if (_closed || generation != _generation || credential == null) return;
    try {
      final auth = expectMap(
        await _requestRaw('session.resume', {'credential': credential}),
        'session.resume',
      );
      if (generation != _generation) return;
      token = auth['token'] as String? ?? token;
      _scheduleAuthRefresh(auth['expires'], generation);
    } on RpcException catch (error) {
      if (generation != _generation) return;
      if (error.code == 'UNAUTHENTICATED') {
        credentialRevoked = true;
        phase = 'authentication required';
        ++_generation;
        _stopHeartbeat();
        final ws = _ws;
        _ws = null;
        unawaited(ws?.close());
        _failPending('Pairing was removed on the PC');
        _setStatus(RpcStatus.disconnected);
        return;
      }
      // Transient failure: a fresh connection re-authenticates.
      unawaited(_ws?.close());
    } catch (_) {
      if (generation == _generation) unawaited(_ws?.close());
    }
  }

  Future<void> _restoreSubscriptions({required bool resync}) async {
    if (_chatSubscribed == true) {
      try {
        await _requestRaw('chat.subscribe', {'enabled': true});
      } catch (_) {}
    }
    // Pushes sent while the socket was down are gone; tell listeners to
    // refetch quietly instead of rebuilding their state from scratch.
    if (resync) {
      _dispatch('chat-library-update', {
        'type': 'chat-library-update',
        'revision': -1,
        'resync': true,
      });
    }
  }

  void _onClosed() {
    if (_closed) return;
    ++_generation;
    _stopHeartbeat();
    _authRefresh?.cancel();
    final previous = _ws;
    _ws = null;
    unawaited(previous?.close());
    _failPending('connection closed');
    phase = 'reconnecting';
    _setStatus(RpcStatus.disconnected);
    _scheduleReconnect();
  }

  void demand(String owner, int intervalMs) {
    if ((_demands[owner] ?? 0) == intervalMs) return;
    if (intervalMs <= 0) {
      _demands.remove(owner);
    } else {
      _demands[owner] = intervalMs;
    }
    unawaited(_updateDemands());
  }

  Future<void> _updateDemands() async {
    if (status != RpcStatus.connected || !supports('session.subscribe')) return;
    final metrics = _demands.entries
        .where((e) => e.key != 'windows' && !e.key.startsWith('monitor:'))
        .map((e) => e.value);
    // Mission-control snapshots (vitals, agent apps, remote health): `monitor:<owner>`.
    final monitor = supports('monitor.v1')
        ? _demands.entries
              .where((e) => e.key.startsWith('monitor:'))
              .map((e) => e.value)
        : const Iterable<int>.empty();
    try {
      await request('session.subscribe', {
        'topics': [
          'agents',
          if (metrics.isNotEmpty) 'metrics',
          if (_demands.containsKey('windows')) 'windows',
          if (monitor.isNotEmpty) 'monitor',
        ],
        'metricsInterval': metrics.isEmpty ? 5000 : metrics.reduce(min),
        if (monitor.isNotEmpty)
          'monitorInterval': monitor.reduce(min) <= 1000
              ? 1000
              : monitor.reduce(min) <= 2000
              ? 2000
              : 5000,
      });
    } catch (_) {}
  }

  void _scheduleReconnect() {
    if (_closed) return;
    _reconnectTimer?.cancel();
    final delayMs =
        (reconnectDelayMs(_reconnectAttempts) *
                (0.8 + Random().nextDouble() * 0.2))
            .round();
    _reconnectAttempts++;
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (_closed) return;
      connect().catchError((_) {});
    });
  }

  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
      request(
        'session.heartbeat',
        const {},
        const Duration(seconds: 5),
      ).catchError((_) {
        _ws?.close();
        return null;
      });
    });
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  void disconnect() {
    _closed = true;
    ++_generation;
    phase = 'disconnected by user';
    _dialTimer?.cancel();
    final dial = _dialPending;
    if (dial != null && !dial.isCompleted) {
      dial.completeError(RpcException('Disconnected'));
    }
    _dialPending = null;
    _reconnectTimer?.cancel();
    _authRefresh?.cancel();
    _stopHeartbeat();
    _failPending('disconnected');
    _ws?.close();
    _ws = null;
    _setStatus(RpcStatus.disconnected);
  }

  void dispose() {
    disconnect();
    _frames.close();
    _status.close();
  }

  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 10),
  ]) async {
    if (_currentStatus == RpcStatus.connecting) {
      try {
        await statusStream
            .firstWhere((s) => s != RpcStatus.connecting)
            .timeout(timeout);
      } catch (_) {}
    }
    if (_ws == null || _currentStatus != RpcStatus.connected) {
      throw RpcException('not connected');
    }
    if (method == 'chat.subscribe' && params['enabled'] is bool) {
      _chatSubscribed = params['enabled'] as bool;
    }
    return _requestRaw(method, params, timeout);
  }

  Future<Map<String, dynamic>> requestMap(
    String method, [
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 10),
  ]) async {
    return expectMap(await request(method, params, timeout), method);
  }

  Future<List<dynamic>> requestList(
    String method, [
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 10),
  ]) async {
    return expectList(await request(method, params, timeout), method);
  }

  /// Ungated request used by the pairing handshake, which must run while the
  /// status is still `connecting`.
  Future<dynamic> _requestRaw(
    String method, [
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 10),
  ]) {
    final ws = _ws;
    if (ws == null) throw RpcException('not connected');
    final id = '${DateTime.now().millisecondsSinceEpoch}-${++_idCounter}';
    final completer = Completer<dynamic>();
    _pending[id] = completer;

    ws.add(
      jsonEncode({
        'type': 'rpc-request',
        'request': {'id': id, 'method': method, 'params': params},
      }),
    );

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw RpcException('request timeout: $method');
      },
    );
  }

  /// Fire-and-forget request for the latency-sensitive input path: no
  /// completer bookkeeping, response is matched to nothing and dropped.
  void notify(String method, Map<String, dynamic> params) {
    final ws = _ws;
    if (ws == null || _currentStatus != RpcStatus.connected) return;
    ws.add(
      jsonEncode({
        'type': 'rpc-request',
        'request': {
          'id': 'ff-${++_idCounter}',
          'method': method,
          'params': params,
        },
      }),
    );
  }

  /// Send one binary frame upstream (phone mic audio). Dropped while the
  /// socket is not connected, like [notify].
  bool sendBinary(Uint8List bytes) {
    final ws = _ws;
    if (ws == null || _currentStatus != RpcStatus.connected) return false;
    ws.add(bytes);
    return true;
  }

  /// Subscribe to a JSON topic (e.g. 'stream-region', 'terminal-output').
  /// Returns an unsubscribe callback.
  void Function() subscribe(
    String topic,
    void Function(Map<String, dynamic>) callback,
  ) {
    final subs = _topicSubs.putIfAbsent(topic, () => []);
    subs.add(callback);
    return () => subs.remove(callback);
  }

  void _onMessage(dynamic data) {
    if (data is List<int>) {
      if (!_frames.hasListener) return;
      final frame = MirrorFrame.parse(
        data is Uint8List ? data : Uint8List.fromList(data),
      );
      if (frame != null && !_frames.isClosed) _frames.add(frame);
      return;
    }
    if (data is! String) return;

    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final type = msg['type'];
    if (type == 'rpc-response' && msg['response'] is Map<String, dynamic>) {
      final resp = msg['response'] as Map<String, dynamic>;
      final completer = _pending.remove('${resp['id']}');
      if (completer == null) return; // fire-and-forget ack
      final error = resp['error'];
      if (error != null) {
        completer.completeError(
          RpcException('$error', resp['code'] as String?),
        );
      } else {
        completer.complete(resp['result']);
      }
      return;
    }
    if (type is String) _dispatch(type, msg);
  }

  void _dispatch(String topic, Map<String, dynamic> msg) {
    final subs = _topicSubs[topic];
    if (subs == null) return;
    for (final cb in List.of(subs)) {
      cb(msg);
    }
  }

  void _failPending(String reason) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(RpcException(reason));
      }
    }
    _pending.clear();
  }
}
