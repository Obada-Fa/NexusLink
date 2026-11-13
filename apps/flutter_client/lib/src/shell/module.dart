// The module contract (spec §4). Feature packages know nothing about the
// shell; small adapters in lib/src/modules/<id>/ implement this.

import 'package:flutter/widgets.dart';

import '../session/store.dart';
import '../session/target.dart';
import 'capabilities.dart';

class CapabilityRequirement {
  const CapabilityRequirement.anyOf(this.ids, {this.minVersion = 1});
  final List<String> ids;
  final int minVersion;

  bool isMetBy(Iterable<Capability> caps) =>
      caps.any((c) => ids.contains(c.id) && c.version >= minVersion);
}

/// What a module gets about the current target. Rebuilt when the target or its
/// reachability changes.
class ModuleContext {
  const ModuleContext({
    required this.target,
    required this.capabilities,
    required this.reachable,
  });
  final SavedTarget target;
  final List<Capability> capabilities; // paired capabilities of this target
  final Set<String> reachable; // utility ids that answered the last probe
  bool isReachable(String utility) => reachable.contains(utility);
  Future<String?> secret(String utility) =>
      CredentialVault.read(target.id, utility);
}

/// One running thing shown in the live bar (an audio stream, a connected
/// trackpad...).
class LiveActivity {
  const LiveActivity({
    required this.moduleId,
    required this.label,
    required this.icon,
    this.activityId,
    this.onTap,
    this.onStop,
  });
  final String moduleId;
  final String label;
  final IconData icon;

  /// Stable identifier within a module, independent of its displayed label.
  final String? activityId;
  final VoidCallback? onTap; // opens the module
  final VoidCallback? onStop; // stops it from the bar
}

abstract class NexusModule {
  const NexusModule();
  String get id; // 'desktop' | 'agents' | 'terminal' | 'remote' | 'audio'
  String get title;
  IconData get icon;
  CapabilityRequirement get requires;
  Set<TargetPlatform> get platforms => const {TargetPlatform.android};
  int get order => 100; // home grid order, low first

  /// Utilities this module needs reachable to open (for the dimmed/offline
  /// state).
  Set<String> utilitiesFor(ModuleContext ctx) => {
    for (final c in ctx.capabilities)
      if (requires.ids.contains(c.id)) c.utility,
  };

  /// Optional custom tile body (live badge, level meter). Null → the standard
  /// tile.
  Widget? buildTileExtra(BuildContext context, ModuleContext ctx) => null;

  /// The screen pushed when the tile is tapped.
  Widget buildEntry(BuildContext context, ModuleContext ctx);

  /// Optional settings section shown under the target's settings.
  Widget? buildSettings(BuildContext context, ModuleContext ctx) => null;

  /// Live activities while this module runs something. Null stream → none.
  Stream<List<LiveActivity>>? liveActivities(ModuleContext ctx) => null;

  /// Called when this target becomes current (ctx) or is left (null).
  /// Start/stop background work here.
  Future<void> onTargetChanged(ModuleContext? ctx) async {}
}
