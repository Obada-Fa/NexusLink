// Reads the `NXU1:` pairing bundle shown as a QR code by Nexus Utilities on
// the PC (nexus-utilities SPEC §6.1). The text is a secret: never log it,
// copy it or put it in a URL.
//
//   NXU1:<base64url, no padding, of UTF-8 JSON>
//   {"v":1,"hub":"…","pc":"Office PC","exp":<ms>,
//    "addr":{"ts":"100.64.0.5","lan":["192.168.2.10"]},
//    "u":{"nexuslink":{"port":45678,"code":"54978453","host":"…"}, …}}

import 'dart:convert';

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

/// Parses [text] and returns the NexusLink entry, or throws
/// [PairBundleException] with a user-facing reason.
NexusLinkPairing parsePairBundle(String text, {DateTime? now}) {
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
  if (json is! Map || json['v'] != 1) {
    throw const PairBundleException(
      'This pairing code is from a newer Nexus Utilities. Update NexusLink.',
    );
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

  final utilities = json['u'];
  final entry = utilities is Map ? utilities['nexuslink'] : null;
  if (entry is! Map) {
    throw const PairBundleException(
      'This code doesn’t include NexusLink. Check that Tailscale is on '
      'and NexusLink is running on your PC, then make a new code.',
    );
  }
  final port = entry['port'];
  final code = entry['code'];
  if (port is! int || port <= 0 || port > 65535 || code is! String) {
    throw const PairBundleException('The pairing code is incomplete.');
  }

  final addr = json['addr'];
  String? address;
  if (addr is Map) {
    final ts = addr['ts'];
    if (ts is String && ts.isNotEmpty) {
      address = ts;
    } else if (addr['lan'] is List) {
      address = (addr['lan'] as List).whereType<String>().firstOrNull;
    }
  }
  if (address == null || address.isEmpty) {
    throw const PairBundleException(
      'Your PC didn’t share a network address. Turn on Tailscale on the PC '
      'and make a new code.',
    );
  }

  final host = address.contains(':') && !address.startsWith('[')
      ? '[$address]' // IPv6 literal
      : address;
  final pc = json['pc'];
  return NexusLinkPairing(
    pcName: pc is String && pc.trim().isNotEmpty ? pc.trim() : 'My PC',
    wsUrl: 'ws://$host:$port/rpc',
    code: code,
    expiresAt: expiresAt,
    hostId: entry['host'] is String ? entry['host'] as String : null,
  );
}
