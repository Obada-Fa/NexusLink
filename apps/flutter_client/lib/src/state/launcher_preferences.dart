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
  final Set<String> favourites = {};
  final Map<String, int> usage = {};

  List<AppInfo> mostUsed(List<AppInfo> apps) =>
      apps.where((app) => (usage[app.appId] ?? 0) > 0).toList()..sort((a, b) {
        final count = usage[b.appId]!.compareTo(usage[a.appId]!);
        return count != 0 ? count : a.name.compareTo(b.name);
      });

  Future<void> toggleFavourite(String appId) async {
    if (!favourites.remove(appId)) favourites.add(appId);
    await _save();
  }

  Future<void> recordUse(String appId) async {
    usage[appId] = (usage[appId] ?? 0) + 1;
    await _save();
  }

  Future<void> _save() async {
    if (!await _prefs.setString(
      _key,
      jsonEncode({'favourites': favourites.toList(), 'usage': usage}),
    )) {
      throw StateError('Could not save app preferences.');
    }
  }
}
