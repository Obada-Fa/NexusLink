// Builds the plugin's AudioPairing from a saved target's `audio` link and the
// token in the credential vault.

import 'package:nexus_audio/nexus_audio.dart';

import '../../session/target.dart';

/// Either a usable [pairing] or, when something is missing, a plain-words
/// [problem] for the tile and the screen.
class AudioPairingResult {
  const AudioPairingResult.ok(AudioPairing this.pairing) : problem = null;
  const AudioPairingResult.problem(String this.problem) : pairing = null;
  final AudioPairing? pairing;
  final String? problem;
}

/// Hosts in the order the engine tries them: the address that answered at
/// enrollment, then Tailscale, then LAN; de-duplicated, blanks dropped.
List<String> audioHostsFor(SavedTarget target) {
  final link = target.utilities[UtilityIds.audio];
  final seen = <String>{};
  return [
    for (final h in [?link?.preferredHost, ...target.addresses.ordered])
      if (h.trim().isNotEmpty && seen.add(h.trim())) h.trim(),
  ];
}

AudioPairingResult resolveAudioPairing(SavedTarget target, String? token) {
  final link = target.utilities[UtilityIds.audio];
  final pc = target.name;
  if (link == null) {
    return AudioPairingResult.problem('Audio isn’t paired with $pc.');
  }
  if (token == null || token.isEmpty) {
    return AudioPairingResult.problem(
      'This phone has lost its Audio key for $pc. Pair again.',
    );
  }
  final fingerprint = link.fingerprint;
  final deviceId = link.deviceId;
  if (fingerprint == null ||
      fingerprint.isEmpty ||
      deviceId == null ||
      deviceId.isEmpty) {
    return AudioPairingResult.problem(
      'The Audio pairing for $pc is incomplete. Pair again.',
    );
  }
  final hosts = audioHostsFor(target);
  if (hosts.isEmpty) {
    return AudioPairingResult.problem(
      'No address is saved for $pc. Pair again.',
    );
  }
  return AudioPairingResult.ok(
    AudioPairing(
      pcName: pc,
      hosts: hosts,
      port: link.port,
      fingerprint: fingerprint,
      deviceId: deviceId,
      token: token,
    ),
  );
}
