// Cold-start decision with saved targets. Same rules as the old
// decideAutoConnect: only the current target, only once per app run, never
// after the user disconnected, and only when this phone holds its pairing.

import '../session/target.dart';
import '../state/last_host.dart';
import '../state/saved_devices.dart' show AutoConnectReason;

export '../state/saved_devices.dart' show AutoConnectReason;

/// The NexusLink ws URL of [target], normalized, or null.
String? nexusLinkUrlOf(SavedTarget? target) {
  final url = target?.utilities[UtilityIds.nexuslink]?.wsUrl;
  return url == null || url.isEmpty ? null : normalizeHostWsUrl(url);
}

Future<({SavedTarget? target, AutoConnectReason reason})>
decideTargetAutoConnect({
  required List<SavedTarget> targets,
  required String? currentId,
  required bool userDisconnected,
  required bool alreadyAttempted,
  required Future<bool> Function(String wsUrl) hasCredential,
}) async {
  if (alreadyAttempted) {
    return (target: null, reason: AutoConnectReason.alreadyTried);
  }
  if (userDisconnected) {
    return (target: null, reason: AutoConnectReason.userDisconnected);
  }
  if (currentId == null || targets.isEmpty) {
    return (target: null, reason: AutoConnectReason.noSavedPc);
  }
  final target = targets.where((t) => t.id == currentId).firstOrNull;
  if (target == null) {
    return (target: null, reason: AutoConnectReason.lastPcNotSaved);
  }
  final url = nexusLinkUrlOf(target);
  if (url == null) {
    // Nothing to dial over NexusLink (e.g. only Remote/Audio paired).
    return (target: null, reason: AutoConnectReason.notPaired);
  }
  bool paired;
  try {
    paired = await hasCredential(url);
  } catch (_) {
    paired = false;
  }
  if (!paired) return (target: null, reason: AutoConnectReason.notPaired);
  return (target: target, reason: AutoConnectReason.connect);
}
