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
      'The PC host is out of date (no result for $method). '
      'On the PC, stop NexusLink, update the repo, and run `bun run lan`.',
    );
  }
  throw RpcException('Unexpected $method result (${raw.runtimeType}).');
}

List<dynamic> expectList(dynamic raw, String method) {
  if (raw is List) return raw;
  if (raw == null) {
    throw RpcException(
      'The PC host is out of date (no result for $method). '
      'On the PC, stop NexusLink, update the repo, and run `bun run lan`.',
    );
  }
  throw RpcException('Unexpected $method result (${raw.runtimeType}).');
}

/// Phone-facing copy for launch/mirror failures (hides Dart type-cast noise).
String friendlyLaunchError(Object error) {
  final raw = error is RpcException ? error.message : error.toString();
  if (raw.contains('Null') && raw.contains('Map<String')) {
    return 'The PC host is out of date. On the PC, stop NexusLink, '
        'update the repo, and run `bun run lan`. Then reopen this app.';
  }
  if (raw.contains('unknown method')) {
    return 'The PC host is out of date. Restart NexusLink on the PC with `bun run lan`.';
  }
  if (raw.contains('unknown app session')) {
    return 'The app quit before it could show a window. '
        'If it is already open on the PC, close it there and try again.';
  }
  return raw.replaceFirst(RegExp(r'^RpcException:\s*'), '');
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
  bool supports(String feature) =>
      (capabilities['features'] as List?)?.contains(feature) == true;

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
              'name': 'Android NexusLink',
            }),
            'session.enroll',
          );
          await PlatformBridge.saveCredential(
            wsUrl,
            auth['credential'] as String,
          );
          pairingCode = null;
        } else {
          if (credential == null) {
            throw RpcException(
              'Enter the pairing code from bun run host:pair on your PC.',
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
        }
        token = auth['token'] as String;
        hostId = auth['hostId'] as String;
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
    } catch (e) {
      if (generation != _generation || _closed) rethrow;
      ++_generation;
      final ws = _ws;
      _ws = null;
      await ws?.close();
      _stopHeartbeat();
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

  void _onClosed() {
    if (_closed) return;
    ++_generation;
    _stopHeartbeat();
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
        .where((e) => e.key != 'windows')
        .map((e) => e.value);
    try {
      await request('session.subscribe', {
        'topics': [
          'agents',
          if (metrics.isNotEmpty) 'metrics',
          if (_demands.containsKey('windows')) 'windows',
        ],
        'metricsInterval': metrics.isEmpty ? 5000 : metrics.reduce(min),
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
    if (type is String) {
      final subs = _topicSubs[type];
      if (subs != null) {
        for (final cb in List.of(subs)) {
          cb(msg);
        }
      }
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
