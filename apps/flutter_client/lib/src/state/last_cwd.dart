// Persists the last working directory chosen for a new agent chat.

import 'package:shared_preferences/shared_preferences.dart';

const lastAgentCwdKey = 'nexuslink-last-agent-cwd';

Future<String?> loadLastAgentCwd() async {
  final prefs = await SharedPreferences.getInstance();
  final path = prefs.getString(lastAgentCwdKey);
  if (path == null || path.trim().isEmpty) return null;
  return path.trim();
}

Future<void> saveLastAgentCwd(String path) async {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(lastAgentCwdKey, trimmed);
}

/// Last segment of a Unix path for display (e.g. `/home/you/project` → `project`).
String folderDisplayName(String path) {
  if (path.isEmpty) return path;
  final trimmed =
      path.endsWith('/') && path != '/' ? path.substring(0, path.length - 1) : path;
  final i = trimmed.lastIndexOf('/');
  return i < 0 ? trimmed : trimmed.substring(i + 1);
}

int comparePathNames(String a, String b) =>
    a.toLowerCase().compareTo(b.toLowerCase());
