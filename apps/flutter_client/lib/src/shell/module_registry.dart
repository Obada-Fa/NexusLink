// The compiled-in modules. The home grid shows the ones whose platforms
// include this phone and whose requirement the current target meets.

import 'package:flutter/foundation.dart';

import '../modules/agents/agents_module.dart';
import '../modules/desktop/desktop_module.dart';
import '../modules/terminal/terminal_module.dart';
import 'capabilities.dart';
import 'module.dart';

const List<NexusModule> moduleRegistry = [
  DesktopModule(),
  AgentsModule(),
  TerminalModule(),
  // Wave 2 (worker E): add RemoteModule() and AudioModule() here, from
  // lib/src/modules/remote/ and lib/src/modules/audio/.
];

/// Modules available on [platform] for a target with [capabilities], in home
/// grid order.
List<NexusModule> modulesFor(
  Iterable<NexusModule> modules, {
  required Iterable<Capability> capabilities,
  TargetPlatform? platform,
}) {
  final p = platform ?? defaultTargetPlatform;
  final caps = capabilities.toList();
  final shown = [
    for (final m in modules)
      if (m.platforms.contains(p) && m.requires.isMetBy(caps)) m,
  ];
  final index = {for (var i = 0; i < shown.length; i++) shown[i]: i};
  return shown..sort((a, b) {
    final byOrder = a.order.compareTo(b.order);
    return byOrder != 0 ? byOrder : index[a]!.compareTo(index[b]!);
  });
}
