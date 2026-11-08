// Saved targets: one PC (or later TV/phone) and the utilities paired on it.
// Never holds a secret; tokens live in the CredentialVault (store.dart).

import '../state/wake_config.dart';

/// Utility ids from the NXU1 "u" map.
abstract final class UtilityIds {
  static const nexuslink = 'nexuslink';
  static const remote = 'remote';
  static const audio = 'audio';
  static const all = [nexuslink, remote, audio];
}

class TargetAddresses {
  const TargetAddresses({this.tailscale, this.lan = const []});
  final String? tailscale; // addr.ts
  final List<String> lan; // addr.lan

  /// Tailscale first, then LAN, de-duplicated.
  List<String> get ordered {
    final out = <String>[];
    final ts = tailscale;
    if (ts != null && ts.isNotEmpty) out.add(ts);
    for (final a in lan) {
      if (a.isNotEmpty && !out.contains(a)) out.add(a);
    }
    return out;
  }

  Map<String, dynamic> toJson() => {
    if (tailscale != null) 'ts': tailscale,
    'lan': lan,
  };

  factory TargetAddresses.fromJson(Map<String, dynamic> json) {
    final ts = json['ts'];
    final lan = json['lan'];
    return TargetAddresses(
      tailscale: ts is String && ts.isNotEmpty ? ts : null,
      lan: lan is List ? lan.whereType<String>().toList() : const [],
    );
  }
}

/// One paired utility on a target. Never holds a secret.
class UtilityLink {
  const UtilityLink({
    required this.utility,
    required this.port,
    this.hostId,
    this.fingerprint,
    this.deviceId,
    this.preferredHost,
    this.wsUrl,
    required this.pairedAt,
  });

  final String utility;
  final int port;
  final String? hostId;
  final String? fingerprint;
  final String? deviceId;
  final String? preferredHost;
  final String? wsUrl;
  final DateTime pairedAt;

  Map<String, dynamic> toJson() => {
    'utility': utility,
    'port': port,
    if (hostId != null) 'hostId': hostId,
    if (fingerprint != null) 'fingerprint': fingerprint,
    if (deviceId != null) 'deviceId': deviceId,
    if (preferredHost != null) 'preferredHost': preferredHost,
    if (wsUrl != null) 'wsUrl': wsUrl,
    'pairedAt': pairedAt.millisecondsSinceEpoch,
  };

  factory UtilityLink.fromJson(Map<String, dynamic> json) => UtilityLink(
    utility: json['utility'] as String,
    port: (json['port'] as num).toInt(),
    hostId: json['hostId'] as String?,
    fingerprint: json['fingerprint'] as String?,
    deviceId: json['deviceId'] as String?,
    preferredHost: json['preferredHost'] as String?,
    wsUrl: json['wsUrl'] as String?,
    pairedAt: DateTime.fromMillisecondsSinceEpoch(
      (json['pairedAt'] as num?)?.toInt() ?? 0,
    ),
  );
}

class SavedTarget {
  const SavedTarget({
    required this.id,
    required this.name,
    this.icon = 'desktop',
    this.kind = 'pc',
    this.addresses = const TargetAddresses(),
    this.utilities = const {},
    this.wake,
  });

  /// NXU1 "hub" id, or `legacy:<wsUrl>` for typed-code / migrated PCs.
  final String id;
  final String name;
  final String icon;
  final String kind;
  final TargetAddresses addresses;
  final Map<String, UtilityLink> utilities;
  final WakeConfig? wake;

  bool has(String utility) => utilities.containsKey(utility);

  SavedTarget copyWith({
    String? id,
    String? name,
    String? icon,
    String? kind,
    TargetAddresses? addresses,
    Map<String, UtilityLink>? utilities,
    WakeConfig? wake,
    bool clearWake = false,
  }) => SavedTarget(
    id: id ?? this.id,
    name: name ?? this.name,
    icon: icon ?? this.icon,
    kind: kind ?? this.kind,
    addresses: addresses ?? this.addresses,
    utilities: utilities ?? this.utilities,
    wake: clearWake ? null : wake ?? this.wake,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'icon': icon,
    'kind': kind,
    'addresses': addresses.toJson(),
    'utilities': {for (final e in utilities.entries) e.key: e.value.toJson()},
    if (wake != null) 'wake': wake!.toJson(),
  };

  factory SavedTarget.fromJson(Map<String, dynamic> json) {
    final u = json['utilities'];
    final links = <String, UtilityLink>{};
    if (u is Map) {
      for (final e in u.entries) {
        if (e.value is Map) {
          links[e.key as String] = UtilityLink.fromJson(
            Map<String, dynamic>.from(e.value as Map),
          );
        }
      }
    }
    return SavedTarget(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'My PC',
      icon: json['icon'] as String? ?? 'desktop',
      kind: json['kind'] as String? ?? 'pc',
      addresses: json['addresses'] is Map
          ? TargetAddresses.fromJson(
              Map<String, dynamic>.from(json['addresses'] as Map),
            )
          : const TargetAddresses(),
      utilities: links,
      wake: json['wake'] is Map
          ? WakeConfig.fromJson(Map<String, dynamic>.from(json['wake'] as Map))
          : null,
    );
  }
}
