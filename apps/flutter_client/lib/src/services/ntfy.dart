import 'dart:convert';
import 'dart:math';

const ntfyTopicPrefix = 'nexuslink-';
final _ntfyTopicRe = RegExp(r'^nexuslink-[0-9a-f]{32}$');

String generateNtfyTopic([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '$ntfyTopicPrefix$hex';
}

bool isNtfyTopic(String topic) => _ntfyTopicRe.hasMatch(topic);

String ntfyEndpointForTopic(String topic, {String host = 'https://ntfy.sh'}) {
  final base = host.endsWith('/') ? host.substring(0, host.length - 1) : host;
  return '$base/${Uri.encodeComponent(topic)}';
}

String ntfySseUrlForTopic(String topic, {String host = 'https://ntfy.sh'}) =>
    '${ntfyEndpointForTopic(topic, host: host)}/sse';

Map<String, dynamic> ntfyRegistrationPayload({
  required String topic,
  required String deviceName,
  String host = 'https://ntfy.sh',
}) {
  return {
    'token': topic,
    'provider': 'ntfy',
    'endpoint': ntfyEndpointForTopic(topic, host: host),
    'name': deviceName,
  };
}

String agentEventKey(String sessionId, int seq, String kind) =>
    '${sessionId}_${seq}_$kind';

class NtfyPayload {
  final String title;
  final String body;
  final String? agentSessionId;
  final String? sessionTitle;
  final String? kind;
  final int? seq;

  const NtfyPayload({
    required this.title,
    required this.body,
    this.agentSessionId,
    this.sessionTitle,
    this.kind,
    this.seq,
  });
}

int? _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

String? _asString(dynamic value) {
  if (value == null) return null;
  final s = value.toString();
  return s.isEmpty ? null : s;
}

NtfyPayload? parseNtfyPayload(dynamic raw) {
  Map<String, dynamic>? map;
  if (raw is Map<String, dynamic>) {
    map = raw;
  } else if (raw is Map) {
    map = Map<String, dynamic>.from(raw);
  } else if (raw is String) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed == 'open' || trimmed == 'keepalive') {
      return null;
    }
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        map = decoded;
      } else if (decoded is Map) {
        map = Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      return NtfyPayload(title: 'NexusLink', body: trimmed);
    }
  }
  if (map == null) return null;

  final event = map['event'] as String?;
  if (event == 'open' || event == 'keepalive') return null;

  Map<String, dynamic>? inner;
  final message = map['message'];
  if (message is String && message.trim().startsWith('{')) {
    try {
      final decoded = jsonDecode(message);
      if (decoded is Map<String, dynamic>) inner = decoded;
      if (decoded is Map) inner = Map<String, dynamic>.from(decoded);
    } catch (_) {}
  } else if (message is Map<String, dynamic>) {
    inner = message;
  } else if (message is Map) {
    inner = Map<String, dynamic>.from(message);
  }

  final src = inner ?? map;
  final title = _asString(src['title']) ?? _asString(map['title']) ?? 'NexusLink';
  final body = _asString(src['body']) ??
      (inner == null ? _asString(message) : null) ??
      '';
  if (title.isEmpty && body.isEmpty) return null;

  return NtfyPayload(
    title: title,
    body: body,
    agentSessionId: _asString(src['agentSessionId']),
    sessionTitle: _asString(src['sessionTitle']),
    kind: _asString(src['kind']),
    seq: _asInt(src['seq']),
  );
}
