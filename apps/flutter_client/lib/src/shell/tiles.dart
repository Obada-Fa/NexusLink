// Home grid tiles: which modules show for the current target and in what
// state (spec §1): paired + reachable → normal; paired + unreachable →
// dimmed "Offline"; not paired (or wrong platform) → no tile.

import 'package:flutter/material.dart';

import '../session/target.dart';
import '../theme/nexus_theme.dart';
import 'home_art.dart';
import 'module.dart';
import 'module_extras.dart';
import 'module_registry.dart';

enum TileStatus { ready, checking, offline }

class HomeTile {
  const HomeTile(this.module, this.status);
  final NexusModule module;
  final TileStatus status;
}

/// [nexusLinkConnecting]: the shared connection is dialing this target.
/// [probedOnce]: false until the first reachability probe answered, so
/// tiles say "Checking…" instead of flashing "Offline".
TileStatus tileStatus(
  NexusModule module,
  ModuleContext ctx, {
  bool nexusLinkConnecting = false,
  bool probedOnce = true,
}) {
  final needed = module.utilitiesFor(ctx);
  if (needed.isEmpty || needed.any(ctx.isReachable)) return TileStatus.ready;
  if (nexusLinkConnecting && needed.contains(UtilityIds.nexuslink)) {
    return TileStatus.checking;
  }
  return probedOnce ? TileStatus.offline : TileStatus.checking;
}

List<HomeTile> homeTiles(
  Iterable<NexusModule> modules,
  ModuleContext ctx, {
  TargetPlatform? platform,
  bool nexusLinkConnecting = false,
  bool probedOnce = true,
}) => [
  for (final m in modulesFor(
    modules,
    capabilities: ctx.capabilities,
    platform: platform,
  ))
    HomeTile(
      m,
      tileStatus(
        m,
        ctx,
        nexusLinkConnecting: nexusLinkConnecting,
        probedOnce: probedOnce,
      ),
    ),
];

/// Home groups tools by what they're for (refine plan §1).
enum ToolGroup { pcTools, workspace }

/// Fixed order inside each group so positions stay put across PCs.
const toolGroupOrder = <ToolGroup, List<String>>{
  ToolGroup.workspace: ['agents', 'terminal', 'files'],
  ToolGroup.pcTools: ['desktop', 'remote', 'audio'],
};

ToolGroup toolGroupOf(NexusModule module) =>
    toolGroupOrder[ToolGroup.workspace]!.contains(module.id)
    ? ToolGroup.workspace
    : ToolGroup.pcTools;

/// [tiles] split into groups, in group order; empty groups are left out.
/// Known modules follow [toolGroupOrder]; unknown ones keep their relative
/// order at the end of PC tools.
List<(ToolGroup, List<HomeTile>)> groupTiles(List<HomeTile> tiles) {
  int rank(HomeTile t) {
    final order = toolGroupOrder[toolGroupOf(t.module)]!;
    final i = order.indexOf(t.module.id);
    return i < 0 ? order.length : i;
  }

  final result = <(ToolGroup, List<HomeTile>)>[];
  for (final g in ToolGroup.values) {
    final inGroup = [
      for (var i = 0; i < tiles.length; i++)
        if (toolGroupOf(tiles[i].module) == g) (i, tiles[i]),
    ];
    if (inGroup.isEmpty) continue;
    // Stable: equal ranks keep their incoming order.
    inGroup.sort((a, b) {
      final r = rank(a.$2).compareTo(rank(b.$2));
      return r != 0 ? r : a.$1.compareTo(b.$1);
    });
    result.add((g, [for (final e in inGroup) e.$2]));
  }
  return result;
}

/// Each group gets a row on a phone. Wider labels wrap into fewer columns.
class ToolGrid extends StatelessWidget {
  const ToolGrid({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final minimum = MediaQuery.textScalerOf(context).scale(84);
      final columns = (constraints.maxWidth / minimum).floor().clamp(1, 3);
      return Wrap(
        runSpacing: 4,
        children: [
          for (final child in children)
            SizedBox(width: constraints.maxWidth / columns, child: child),
        ],
      );
    },
  );
}

class ModuleTile extends StatelessWidget {
  const ModuleTile({
    super.key,
    required this.tile,
    required this.ctx,
    required this.onTap,
    this.checkingLabel = 'Checking…',
  });
  final HomeTile tile;
  final ModuleContext ctx;
  final VoidCallback onTap;
  final String checkingLabel;

  @override
  Widget build(BuildContext context) {
    final module = tile.module;
    if (module is BlockableModule) {
      return ListenableBuilder(
        listenable: (module as BlockableModule).blockedChanges,
        builder: (context, _) =>
            _build(context, moduleBlockedReason(module, ctx)),
      );
    }
    return _build(context, null);
  }

  Widget _build(BuildContext context, String? blocked) {
    final module = tile.module;
    final status = blocked == null ? tile.status : TileStatus.offline;
    final statusLabel = switch (status) {
      TileStatus.ready => 'Ready',
      TileStatus.checking => checkingLabel,
      TileStatus.offline => 'Offline',
    };
    return Semantics(
      button: true,
      label: [module.title, statusLabel, ?blocked].join(', '),
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('tile-${module.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedOpacity(
                duration: const Duration(milliseconds: 160),
                opacity: status == TileStatus.offline ? .5 : 1,
                child: toolGroupOrder[toolGroupOf(module)]!.contains(module.id)
                    ? HomeShortcutArt(moduleId: module.id, size: 54)
                    : Icon(module.icon, size: 54),
              ),
              const SizedBox(height: 5),
              Text(
                module.title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xfff8f3e8),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (status != TileStatus.ready)
                Text(
                  statusLabel,
                  key: blocked == null
                      ? null
                      : ValueKey('tile-blocked-${module.id}'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: NX.textDim, fontSize: 12),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
