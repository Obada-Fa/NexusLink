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

import 'package:flutter/foundation.dart';

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
  RpcException(this.message);
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

/// Backoff for a dropped WebSocket: 1s, 2s, 4s, 8s, then cap at 15s.
int reconnectDelayMs(int attempts) {
  final exp = 1000 * (1 << attempts.clamp(0, 10));
  return exp.clamp(1000, 15000);
}

class RpcClient {
  RpcClient(this.wsUrl);

  final String wsUrl;

  WebSocket? _ws;
  int _idCounter = 0;
  bool _closed = false;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;
  Timer? _heartbeat;

  final _pending = <String, Completer<dynamic>>{};
  final _topicSubs = <String, List<void Function(Map<String, dynamic>)>>{};
  final _frames = StreamController<MirrorFrame>.broadcast();
  final _status = StreamController<RpcStatus>.broadcast();

  RpcStatus _currentStatus = RpcStatus.disconnected;
  RpcStatus get status => _currentStatus;
  Stream<RpcStatus> get statusStream => _status.stream;

  bool get isClosed => _closed;
  bool get socketOpen =>
      _ws != null && _ws!.readyState == WebSocket.open;

  Future<void>? _connectInFlight;
  bool _replacingSocket = false;
  bool _reconnectQueued = false;

  /// Parsed binary mirror frames (all streams; filter by streamKey).
  Stream<MirrorFrame> get frames => _frames.stream;

  void _setStatus(RpcStatus s) {
    _currentStatus = s;
    if (!_status.isClosed) _status.add(s);
  }

  Future<void> connect() async {
    if (_connectInFlight != null) {
      await _connectInFlight;
      return;
    }
    if (!_closed &&
        _currentStatus == RpcStatus.connected &&
        socketOpen) {
      return;
    }
    final op = _connectInternal();
    _connectInFlight = op;
    try {
      await op;
    } finally {
      if (identical(_connectInFlight, op)) _connectInFlight = null;
    }
  }

  Future<void> _connectInternal() async {
    _closed = false;
    _reconnectQueued = false;
    _reconnectTimer?.cancel();
    _stopHeartbeat();
    _setStatus(RpcStatus.connecting);
    _replacingSocket = true;
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;
    _replacingSocket = false;
    try {
      final ws = await WebSocket.connect(wsUrl)
          .timeout(const Duration(seconds: 8));
      // Ping frames keep NAT mappings and phone radios from dropping an idle
      // socket. Without this the session dies after ~30–60s of no traffic.
      ws.pingInterval = const Duration(seconds: 20);
      _ws = ws;
      ws.listen(
        _onMessage,
        onDone: _onClosed,
        onError: (_) => _onClosed(),
        cancelOnError: true,
      );
      // The host rejects every RPC until the ECDH/TOTP handshake succeeds, so
      // authenticate before reporting connected. Running it here (not in the
      // UI layer) means reconnects re-authenticate too.
      await performPairingHandshake(_requestRaw);
      _reconnectAttempts = 0;
      _reconnectQueued = false;
      _startHeartbeat();
      _setStatus(RpcStatus.connected);
    } catch (e) {
      _ws?.close();
      _ws = null;
      _stopHeartbeat();
      _setStatus(RpcStatus.disconnected);
      if (!_closed) _scheduleReconnect();
      rethrow;
    }
  }

  void _onClosed() {
    if (_replacingSocket) return;
    _stopHeartbeat();
    _ws = null;
    _failPending('connection closed');
    _setStatus(RpcStatus.disconnected);
    if (!_closed) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_closed || _reconnectQueued) return;
    _reconnectQueued = true;
    _reconnectTimer?.cancel();
    final delayMs = reconnectDelayMs(_reconnectAttempts);
    _reconnectAttempts++;
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      _reconnectQueued = false;
      if (_closed) return;
      connect().catchError((_) {});
    });
  }

  @visibleForTesting
  void debugSetStatus(RpcStatus s) => _setStatus(s);

  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
      notify('session.heartbeat', const {});
    });
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  void disconnect() {
    _closed = true;
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

    ws.add(jsonEncode({
      'type': 'rpc-request',
      'request': {'id': id, 'method': method, 'params': params},
    }));

    return completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      throw RpcException('request timeout: $method');
    });
  }

  /// Fire-and-forget request for the latency-sensitive input path: no
  /// completer bookkeeping, response is matched to nothing and dropped.
  void notify(String method, Map<String, dynamic> params) {
    final ws = _ws;
    if (ws == null || _currentStatus != RpcStatus.connected) return;
    ws.add(jsonEncode({
      'type': 'rpc-request',
      'request': {'id': 'ff-${++_idCounter}', 'method': method, 'params': params},
    }));
  }

  /// Subscribe to a JSON topic (e.g. 'stream-region', 'terminal-output').
  /// Returns an unsubscribe callback.
  void Function() subscribe(
      String topic, void Function(Map<String, dynamic>) callback) {
    final subs = _topicSubs.putIfAbsent(topic, () => []);
    subs.add(callback);
    return () => subs.remove(callback);
  }

  void _onMessage(dynamic data) {
    if (data is List<int>) {
      final frame =
          MirrorFrame.parse(data is Uint8List ? data : Uint8List.fromList(data));
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
        completer.completeError(RpcException('$error'));
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
