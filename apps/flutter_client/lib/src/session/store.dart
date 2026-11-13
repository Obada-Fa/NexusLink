// Persistence for saved targets and the credential vault.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../state/last_host.dart';
import '../state/wake_config.dart';
import '../state/saved_devices.dart';
import '../workspace/platform_bridge.dart';
import 'target.dart';

const targetsKey = 'nexus-targets-v1';
const currentTargetKey = 'nexus-current-target';
const legacyTargetPrefix = 'legacy:';

/// SharedPreferences key 'nexus-targets-v1' (JSON list) and
/// 'nexus-current-target' (id).
class TargetStore {
  static Future<List<SavedTarget>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(targetsKey);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        return [
          for (final e in list)
            SavedTarget.fromJson(Map<String, dynamic>.from(e as Map)),
        ];
      } catch (_) {
        return [];
      }
    }
    return _migrate(prefs);
  }

  static Future<List<SavedTarget>> _migrate(SharedPreferences prefs) async {
    final targets = <SavedTarget>[];
    final legacyRaw = prefs.getString(savedDevicesKey);
    if (legacyRaw != null) {
      try {
        for (final item in jsonDecode(legacyRaw) as List) {
          final d = Map<String, dynamic>.from(item as Map);
          final url = normalizeHostWsUrl(d['url'] as String);
          targets.add(
            SavedTarget(
              id: '$legacyTargetPrefix$url',
              name: d['name'] as String? ?? 'My PC',
              icon: deviceIcons.contains(d['icon'])
                  ? d['icon'] as String
                  : 'desktop',
              wake: d['wake'] is Map
                  ? WakeConfig.fromJson(
                      Map<String, dynamic>.from(d['wake'] as Map),
                    )
                  : null,
              utilities: {UtilityIds.nexuslink: _legacyLink(url)},
            ),
          );
        }
      } catch (_) {
        // Unreadable legacy data: start empty; the old key is left alone.
      }
    }
    final last = await loadLastHostUrl();
    if (targets.isEmpty && last != null) {
      targets.add(
        SavedTarget(
          id: '$legacyTargetPrefix$last',
          name: 'My PC',
          utilities: {UtilityIds.nexuslink: _legacyLink(last)},
        ),
      );
    }
    await save(targets);
    if (last != null) {
      final match = targets
          .where((t) => t.utilities[UtilityIds.nexuslink]?.wsUrl == last)
          .firstOrNull;
      if (match != null) await prefs.setString(currentTargetKey, match.id);
    }
    return targets;
  }

  static UtilityLink _legacyLink(String wsUrl) {
    final uri = Uri.tryParse(wsUrl);
    return UtilityLink(
      utility: UtilityIds.nexuslink,
      port: uri != null && uri.hasPort ? uri.port : defaultRpcPort,
      wsUrl: wsUrl,
      preferredHost: uri?.host,
      pairedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  static Future<void> save(List<SavedTarget> targets) async {
    final prefs = await SharedPreferences.getInstance();
    final ok = await prefs.setString(
      targetsKey,
      jsonEncode([for (final t in targets) t.toJson()]),
    );
    if (!ok) throw StateError('Could not save your devices. Please try again.');
  }

  /// Merge by id; also folds a `legacy:<wsUrl>` target into a hub target with
  /// the same nexuslink wsUrl (the legacy name, icon and wake survive when the
  /// hub target has none of its own).
  static Future<SavedTarget> upsert(SavedTarget target) async {
    final targets = await load();
    final current = await currentId();
    var merged = target;

    final existing = targets.where((t) => t.id == target.id).firstOrNull;
    if (existing != null) merged = _merge(existing, merged);

    final wsUrl = merged.utilities[UtilityIds.nexuslink]?.wsUrl;
    String? replacedCurrent;
    if (wsUrl != null && !merged.id.startsWith(legacyTargetPrefix)) {
      final legacy = targets
          .where(
            (t) =>
                t.id.startsWith(legacyTargetPrefix) &&
                t.id != merged.id &&
                t.utilities[UtilityIds.nexuslink]?.wsUrl == wsUrl,
          )
          .toList();
      for (final l in legacy) {
        merged = _merge(l, merged);
        if (l.id == current) replacedCurrent = merged.id;
      }
      targets.removeWhere((t) => legacy.any((l) => l.id == t.id));
    }

    final i = targets.indexWhere((t) => t.id == merged.id);
    if (i >= 0) {
      targets[i] = merged;
    } else {
      targets.add(merged);
    }
    await save(targets);
    if (replacedCurrent != null) await setCurrent(replacedCurrent);
    return merged;
  }

  /// [base] is the older record, [over] wins on conflicts.
  static SavedTarget _merge(SavedTarget base, SavedTarget over) => SavedTarget(
    id: over.id,
    name: over.name,
    icon: over.icon == 'desktop' && base.icon != 'desktop'
        ? base.icon
        : over.icon,
    kind: over.kind,
    addresses: TargetAddresses(
      tailscale: over.addresses.tailscale ?? base.addresses.tailscale,
      lan: {...over.addresses.lan, ...base.addresses.lan}.toList(),
    ),
    utilities: {...base.utilities, ...over.utilities},
    wake: over.wake ?? base.wake,
  );

  /// Also wipes its vault secrets and the nexuslink credential.
  static Future<void> remove(String targetId) async {
    final targets = await load();
    final gone = targets.where((t) => t.id == targetId).firstOrNull;
    for (final u in UtilityIds.all) {
      try {
        await CredentialVault.delete(targetId, u);
      } catch (_) {}
    }
    final ws = gone?.utilities[UtilityIds.nexuslink]?.wsUrl;
    if (ws != null) {
      final shared = targets.any(
        (t) =>
            t.id != targetId && t.utilities[UtilityIds.nexuslink]?.wsUrl == ws,
      );
      if (!shared) {
        try {
          await PlatformBridge.removeCredential(ws);
        } catch (_) {}
      }
    }
    targets.removeWhere((t) => t.id == targetId);
    await save(targets);
    if (await currentId() == targetId) await setCurrent(null);
  }

  static Future<String?> currentId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(currentTargetKey);
  }

  static Future<void> setCurrent(String? targetId) async {
    final prefs = await SharedPreferences.getInstance();
    if (targetId == null) {
      await prefs.remove(currentTargetKey);
    } else {
      await prefs.setString(currentTargetKey, targetId);
    }
  }
}

/// Secrets in the Keystore-backed store behind PlatformBridge (in-memory off
/// Android).
class CredentialVault {
  static String keyFor(String targetId, String utility) =>
      'nxu/$targetId/$utility';

  static Future<String?> read(String targetId, String utility) =>
      PlatformBridge.credential(keyFor(targetId, utility));

  static Future<void> write(String targetId, String utility, String secret) =>
      PlatformBridge.saveCredential(keyFor(targetId, utility), secret);

  static Future<void> delete(String targetId, String utility) =>
      PlatformBridge.removeCredential(keyFor(targetId, utility));
}
