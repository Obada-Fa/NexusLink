import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rpc/models.dart';

final launcherPreferencesProvider =
    FutureProvider.family<LauncherPreferences, String>((ref, host) async {
      final prefs = await SharedPreferences.getInstance();
      return LauncherPreferences(prefs, host);
    });

/// Favourites and mobile launch frequency are kept separately for each PC.
class LauncherPreferences {
  LauncherPreferences(this._prefs, String host)
    : _key = 'nexuslink-launcher:$host' {
    final raw = _prefs.getString(_key);
    if (raw == null) return;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      recent.addAll((data['recent'] as List? ?? []).cast<String>());
      removedDefaults.addAll(
        (data['removedDefaults'] as List? ?? []).cast<String>(),
      );
      favourites.addAll((data['favourites'] as List).cast<String>());
      usage.addAll(
        (data['usage'] as Map<String, dynamic>).map(
          (key, value) => MapEntry(key, (value as num).toInt()),
        ),
      );
    } catch (_) {
      favourites.clear();
      usage.clear();
    }
  }

  final SharedPreferences _prefs;
  final String _key;
  static const defaultFavourites = [
    'RustDesk',
    'AnyDesk',
    'ChatGPT',
    'Antigravity',
    'Claude',
    'NexusLink Server',
  ];
  final List<String> recent = [];
  final Set<String> removedDefaults = {};
  final Set<String> favourites = {};

  static String normalized(String name) =>
      name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  static String? defaultName(AppInfo app) {
    for (final name in defaultFavourites) {
      if (normalized(app.name) == normalized(name) ||
          normalized(app.appId) == normalized(name)) {
        return name;
      }
    }
    return null;
  }

  bool isFavourite(AppInfo app) =>
      favourites.contains(app.appId) ||
      (defaultName(app) != null && !removedDefaults.contains(app.appId));

  List<AppInfo> recentlyUsed(List<AppInfo> apps) => [
    for (final id in recent)
      for (final app in apps)
        if (app.appId == id) app,
  ];
  final Map<String, int> usage = {};

  List<AppInfo> mostUsed(List<AppInfo> apps) =>
      apps.where((app) => (usage[app.appId] ?? 0) > 0).toList()..sort((a, b) {
        final count = usage[b.appId]!.compareTo(usage[a.appId]!);
        return count != 0 ? count : a.name.compareTo(b.name);
      });

  Future<void> toggleFavourite(AppInfo app) async {
    if (isFavourite(app)) {
      favourites.remove(app.appId);
      removedDefaults.add(app.appId);
    } else {
      favourites.add(app.appId);
      removedDefaults.remove(app.appId);
    }
    await _save();
  }

  Future<void> recordUse(String appId) async {
    recent.remove(appId);
    recent.insert(0, appId);
    if (recent.length > 20) recent.removeLast();
    usage[appId] = (usage[appId] ?? 0) + 1;
    await _save();
  }

  Future<void> _save() async {
    if (!await _prefs.setString(
      _key,
      jsonEncode({
        'favourites': favourites.toList(),
        'usage': usage,
        'recent': recent,
        'removedDefaults': removedDefaults.toList(),
      }),
    )) {
      throw StateError('Could not save app preferences.');
    }
  }
}
