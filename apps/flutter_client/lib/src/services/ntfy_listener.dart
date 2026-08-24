import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'ntfy.dart';

/// In-process ntfy SSE subscriber for platforms that keep Dart running
/// (desktop). Android uses the native foreground service instead.
class NtfyListener {
  NtfyListener(this.onPayload);

  final void Function(NtfyPayload payload) onPayload;

  http.Client? _client;
  StreamSubscription<String>? _sub;
  Timer? _reconnect;
  bool _stopped = true;
  String? _topic;
  int _attempt = 0;

  bool get running => !_stopped;

  Future<void> start(String topic) async {
    if (_topic == topic && !_stopped) return;
    await stop();
    _stopped = false;
    _topic = topic;
    _attempt = 0;
    unawaited(_connect());
  }

  Future<void> stop() async {
    _stopped = true;
    _reconnect?.cancel();
    _reconnect = null;
    await _sub?.cancel();
    _sub = null;
    _client?.close();
    _client = null;
  }

  Future<void> _connect() async {
    final topic = _topic;
    if (_stopped || topic == null) return;
    final client = http.Client();
    _client = client;
    try {
      final req = http.Request('GET', Uri.parse(ntfySseUrlForTopic(topic)));
      req.headers['Accept'] = 'text/event-stream';
      req.headers['Cache-Control'] = 'no-cache';
      final resp = await client.send(req);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('ntfy sse ${resp.statusCode}');
      }
      _attempt = 0;
      _sub = resp.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          if (!line.startsWith('data:')) return;
          final payload = parseNtfyPayload(line.substring(5).trim());
          if (payload != null) onPayload(payload);
        },
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('[ntfy] sse connect failed: $e');
      client.close();
      if (identical(_client, client)) _client = null;
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_stopped) return;
    _sub = null;
    _client?.close();
    _client = null;
    final delayMs = (1000 * (1 << _attempt.clamp(0, 4))).clamp(1000, 16000);
    _attempt++;
    _reconnect?.cancel();
    _reconnect = Timer(Duration(milliseconds: delayMs), () {
      if (!_stopped) unawaited(_connect());
    });
  }
}
