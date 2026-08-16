// Persists the last successfully connected host WebSocket URL so the connect
// screen can suggest reconnecting without retyping the full link.

import 'package:shared_preferences/shared_preferences.dart';

const lastHostUrlKey = 'nexuslink-last-host-url';

Future<String?> loadLastHostUrl() async {
  final prefs = await SharedPreferences.getInstance();
  final url = prefs.getString(lastHostUrlKey);
  if (url == null || url.trim().isEmpty) return null;
  return url.trim();
}

Future<void> saveLastHostUrl(String wsUrl) async {
  final trimmed = wsUrl.trim();
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
