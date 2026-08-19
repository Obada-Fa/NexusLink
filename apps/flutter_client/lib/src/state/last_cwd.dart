// Persists recent working directories chosen for new agent chats.

import 'package:shared_preferences/shared_preferences.dart';

const lastAgentCwdKey = 'nexuslink-last-agent-cwd';
const recentAgentCwdsKey = 'nexuslink-recent-agent-cwds';
const recentAgentCwdCap = 8;

List<String> mergeRecentAgentCwd(String path, List<String> existing) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return existing;
  return [
    trimmed,
    ...existing.where((p) => p != trimmed),
  ].take(recentAgentCwdCap).toList();
}

Future<List<String>> loadRecentAgentCwds() async {
  final prefs = await SharedPreferences.getInstance();
  final list = prefs.getStringList(recentAgentCwdsKey);
  if (list != null && list.isNotEmpty) {
    return list
        .where((p) => p.trim().isNotEmpty)
        .map((p) => p.trim())
        .take(recentAgentCwdCap)
        .toList();
  }
  final legacy = prefs.getString(lastAgentCwdKey);
  if (legacy == null || legacy.trim().isEmpty) return [];
  return [legacy.trim()];
}

Future<void> saveLastAgentCwd(String path) async {
  final next = mergeRecentAgentCwd(path, await loadRecentAgentCwds());
  if (next.isEmpty) return;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(recentAgentCwdsKey, next);
  await prefs.setString(lastAgentCwdKey, next.first);
}

/// Last segment of a host path for display (`D:/projects/foo` → `foo`).
String folderDisplayName(String path) {
  if (path.isEmpty || path == '/') return path.isEmpty ? path : 'This PC';
  final trimmed =
      path.endsWith('/') && path != '/' ? path.substring(0, path.length - 1) : path;
  if (RegExp(r'^[A-Za-z]:$').hasMatch(trimmed)) return trimmed;
  final i = trimmed.lastIndexOf('/');
  return i < 0 ? trimmed : trimmed.substring(i + 1);
}

int comparePathNames(String a, String b) =>
    a.toLowerCase().compareTo(b.toLowerCase());
