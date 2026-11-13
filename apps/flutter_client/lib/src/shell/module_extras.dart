// Optional extras a module can offer the shell beyond the §4 contract.
// Modules that don't implement them get sensible defaults.

import 'package:flutter/material.dart';

import '../session/target.dart';
import '../theme/nexus_theme.dart';
import 'module.dart';

/// A one-line description under the tile title and a brand colour for its
/// icon badge.
abstract interface class DescribedModule {
  String get subtitle;
  Color get accent;
}

String moduleSubtitle(NexusModule module) =>
    module is DescribedModule ? (module as DescribedModule).subtitle : '';

Color moduleAccent(NexusModule module) =>
    module is DescribedModule ? (module as DescribedModule).accent : NX.accent;

/// A module that can be unusable for a reason other than reachability, e.g.
/// its secret is missing from the vault. The tile then shows "Offline" with
/// [blockedReason], and tapping it explains.
abstract interface class BlockableModule {
  /// Fires when [blockedReason] may have changed.
  Listenable get blockedChanges;

  /// Why the module can't run on [ctx]'s target, or null when it can.
  String? blockedReason(ModuleContext ctx);
}

String? moduleBlockedReason(NexusModule module, ModuleContext ctx) =>
    module is BlockableModule
    ? (module as BlockableModule).blockedReason(ctx)
    : null;

/// A module that holds state per saved target beyond the current one (e.g.
/// the audio engine's "wanted streams"). Told when a target is removed, even
/// when it isn't current.
abstract interface class TargetRemovalAware {
  Future<void> onTargetRemoved(SavedTarget target);
}
