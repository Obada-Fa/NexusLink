// Persists the last successfully connected host WebSocket URL so the connect
// screen can suggest reconnecting without retyping the full link.

import 'package:shared_preferences/shared_preferences.dart';

const lastHostUrlKey = 'nexuslink-last-host-url';
const defaultRpcPort = 45678;
const defaultRpcPath = '/rpc';

/// Turn whatever the user pasted (QR HTTP URL, host:port, missing /rpc)
/// into the WebSocket URL the RPC client actually dials.
String normalizeHostWsUrl(String input) {
  var raw = input.trim();
  if (raw.isEmpty) return raw;

  if (!raw.contains('://')) {
    raw = 'ws://$raw';
  } else if (raw.startsWith('http://')) {
    raw = 'ws://${raw.substring('http://'.length)}';
  } else if (raw.startsWith('https://')) {
    raw = 'wss://${raw.substring('https://'.length)}';
  }

  final uri = Uri.tryParse(raw);
  if (uri == null || uri.host.isEmpty) return raw;

  final path = (uri.path.isEmpty || uri.path == '/') ? defaultRpcPath : uri.path;
  final port = uri.hasPort ? uri.port : defaultRpcPort;
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: port,
    path: path,
  ).toString();
}

Future<String?> loadLastHostUrl() async {
  final prefs = await SharedPreferences.getInstance();
  final url = prefs.getString(lastHostUrlKey);
  if (url == null || url.trim().isEmpty) return null;
  return normalizeHostWsUrl(url);
}

Future<void> saveLastHostUrl(String wsUrl) async {
  final trimmed = normalizeHostWsUrl(wsUrl);
  if (trimmed.isEmpty) return;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(lastHostUrlKey, trimmed);
}

Future<void> clearLastHostUrl() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(lastHostUrlKey);
}

/// Short label for UI chips (host:port), falling back to the raw URL.
String lastHostLabel(String wsUrl) {
  final uri = Uri.tryParse(wsUrl);
  if (uri == null || uri.host.isEmpty) return wsUrl;
  if (uri.hasPort) return '${uri.host}:${uri.port}';
  return uri.host;
}
