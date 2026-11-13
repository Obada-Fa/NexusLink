// Reads the `NXU1:` pairing bundle shown as a QR code by Nexus Utilities on
// the PC (nexus-utilities SPEC §6.1). The text is a secret: never log it,
// copy it or put it in a URL.
//
//   NXU1:<base64url, no padding, of UTF-8 JSON>
//   {"v":1,"hub":"…","pc":"Office PC","exp":<ms>,
//    "addr":{"ts":"100.64.0.5","lan":["192.168.2.10"]},
//    "u":{"nexuslink":{"port":45678,"code":"54978453","host":"…"},
//         "remote":{"port":45679,"code":"…","fp":"AB12…","host":"…"},
//         "audio":{"port":8010,"code":"…","fp":"CD34…","host":"…"}}}

import 'dart:convert';

import '../session/target.dart';

const pairBundlePrefix = 'NXU1:';

/// What NexusLink needs from a scanned bundle.
class NexusLinkPairing {
  const NexusLinkPairing({
    required this.pcName,
    required this.wsUrl,
    required this.code,
    required this.expiresAt,
    this.hostId,
  });

  /// The PC's display name, used as the saved device name.
  final String pcName;

  /// `ws://<address>:<port>/rpc`, Tailscale address preferred.
  final String wsUrl;

  /// One-use eight-digit pairing code.
  final String code;

  final DateTime expiresAt;
  final String? hostId;
}

/// Why a scanned code can't be used. [message] is safe to show the user.
class PairBundleException implements Exception {
  const PairBundleException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// True when [text] looks like a Nexus pairing bundle (cheap prefix check,
/// so the scanner can ignore unrelated QR codes without an error).
bool isPairBundle(String text) => text.trim().startsWith(pairBundlePrefix);

/// One utility's entry in the bundle.
class BundleEntry {
  const BundleEntry({
    required this.utility,
    required this.port,
    required this.code,
    this.fingerprint,
    this.hostId,
  });
  final String utility;
  final int port;
  final String code;
  final String? fingerprint, hostId;
}

/// The whole scanned bundle.
class PairBundle {
  const PairBundle({
    required this.hubId,
    required this.pcName,
    required this.expiresAt,
    required this.addresses,
    required this.utilities,
  });

  final String hubId, pcName;
  final DateTime expiresAt;
  final TargetAddresses addresses;

  /// Only known utility ids; unknown keys are ignored.
  final Map<String, BundleEntry> utilities;

  /// The old NexusLink-only view (typed path and old callers). Throws
  /// [PairBundleException] when the bundle has no NexusLink entry.
  NexusLinkPairing get nexusLink {
    final entry = utilities[UtilityIds.nexuslink];
    if (entry == null) {
      throw const PairBundleException(
        'This code doesn’t include NexusLink. Check that Tailscale is on '
        'and NexusLink is running on your PC, then make a new code.',
      );
    }
    final address = addresses.ordered.firstOrNull;
    if (address == null) throw _noAddress;
    return NexusLinkPairing(
      pcName: pcName,
      wsUrl: 'ws://${hostForUrl(address)}:${entry.port}/rpc',
      code: entry.code,
      expiresAt: expiresAt,
      hostId: entry.hostId,
    );
  }
}

const _noAddress = PairBundleException(
  'Your PC didn’t share a network address. Turn on Tailscale on the PC '
  'and make a new code.',
);

/// Brackets an IPv6 literal for use in a URL.
String hostForUrl(String address) =>
    address.contains(':') && !address.startsWith('[') ? '[$address]' : address;

/// Parses [text], or throws [PairBundleException] with a user-facing reason.
PairBundle parsePairBundle(String text, {DateTime? now}) {
  final raw = text.trim();
  if (!raw.startsWith(pairBundlePrefix)) {
    throw const PairBundleException(
      'That isn’t a Nexus pairing code. On your PC open Nexus Utilities '
      'and choose Add phone.',
    );
  }
  final Object? json;
  try {
    var body = raw.substring(pairBundlePrefix.length);
    body += '=' * ((4 - body.length % 4) % 4);
    json = jsonDecode(utf8.decode(base64Url.decode(body)));
  } catch (_) {
    throw const PairBundleException(
      'The code couldn’t be read. Hold the phone steady and try again.',
    );
  }
  final v = json is Map ? json['v'] : null;
  if (json is! Map || v is! int || v > 1) {
    throw const PairBundleException(
      'This pairing code is from a newer Nexus Utilities. Update the Nexus app.',
    );
  }
  if (v < 1) {
    throw const PairBundleException('The code couldn’t be read.');
  }

  final exp = json['exp'];
  final expiresAt = exp is int
      ? DateTime.fromMillisecondsSinceEpoch(exp)
      : DateTime.fromMillisecondsSinceEpoch(0);
  if (!expiresAt.isAfter(now ?? DateTime.now())) {
    throw const PairBundleException(
      'This pairing code has expired. Choose New code on your PC.',
    );
  }

  final addr = json['addr'];
  final addresses = addr is Map
      ? TargetAddresses.fromJson(Map<String, dynamic>.from(addr))
      : const TargetAddresses();
  if (addresses.ordered.isEmpty) throw _noAddress;

  final entries = <String, BundleEntry>{};
  final u = json['u'];
  if (u is Map) {
    for (final id in UtilityIds.all) {
      final e = u[id];
      if (e is! Map) continue;
      final port = e['port'];
      final code = e['code'];
      if (port is! int || port <= 0 || port > 65535 || code is! String) {
        throw const PairBundleException('The pairing code is incomplete.');
      }
      final fp = e['fp'];
      final host = e['host'];
      entries[id] = BundleEntry(
        utility: id,
        port: port,
        code: code,
        fingerprint: fp is String && fp.isNotEmpty ? fp : null,
        hostId: host is String ? host : null,
      );
    }
  }
  if (entries.isEmpty) {
    throw const PairBundleException(
      'This code doesn’t include any Nexus utility. Check that the utilities '
      'are running on your PC, then make a new code.',
    );
  }

  final hub = json['hub'];
  final pc = json['pc'];
  return PairBundle(
    hubId: hub is String && hub.isNotEmpty
        ? hub
        : 'hub-${entries.values.first.hostId ?? entries.values.first.port}',
    pcName: pc is String && pc.trim().isNotEmpty ? pc.trim() : 'My PC',
    expiresAt: expiresAt,
    addresses: addresses,
    utilities: entries,
  );
}
