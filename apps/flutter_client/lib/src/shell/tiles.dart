// Home grid tiles: which modules show for the current target and in what
// state (spec §1): paired + reachable → normal; paired + unreachable →
// dimmed "Offline"; not paired (or wrong platform) → no tile.

import 'package:flutter/material.dart';

import '../session/target.dart';
import '../theme/nexus_theme.dart';
import '../theme/nx_widgets.dart';
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
enum ToolGroup { workspace, pcTools }

String toolGroupTitle(ToolGroup g) => switch (g) {
  ToolGroup.workspace => 'Workspace',
  ToolGroup.pcTools => 'PC tools',
};

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

/// Lays tiles out two per row with equal heights, or one per row when the
/// screen is narrow or the text is large. Tiles grow to fit their text.
class ToolGrid extends StatelessWidget {
  const ToolGrid({super.key, required this.children});
  final List<Widget> children;

  /// One column below this width per tile (logical px, after text scaling).
  static const minTileWidth = 168.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final perTile = (constraints.maxWidth - NX.gap) / 2;
      final columns = scale > 1.3 || perTile < minTileWidth ? 1 : 2;
      final rows = <Widget>[];
      for (var i = 0; i < children.length; i += columns) {
        final row = children.sublist(
          i,
          (i + columns).clamp(0, children.length),
        );
        rows.add(
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : NX.gap),
            child: columns == 1
                ? row.single
                : IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: row[0]),
                        const SizedBox(width: NX.gap),
                        Expanded(
                          child: row.length > 1 ? row[1] : const SizedBox(),
                        ),
                      ],
                    ),
                  ),
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
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
    final accent = moduleAccent(module);
    final status = blocked != null ? TileStatus.offline : tile.status;
    final offline = status == TileStatus.offline;
    final subtitle = moduleSubtitle(module);
    final extra = blocked != null
        ? Text(
            blocked,
            key: ValueKey('tile-blocked-${module.id}'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: NX.waiting, fontSize: 12),
          )
        : module.buildTileExtra(context, ctx);
    final statusLabel = switch (status) {
      TileStatus.ready => 'Ready',
      TileStatus.checking => checkingLabel,
      TileStatus.offline => 'Offline',
    };
    return Semantics(
      button: true,
      label: blocked == null
          ? '${module.title}, $statusLabel'
          : '${module.title}, $statusLabel: $blocked',
      excludeSemantics: true,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 220),
        opacity: offline ? .5 : 1,
        child: NxCard(
          key: ValueKey('tile-${module.id}'),
          accent: offline ? null : accent.withValues(alpha: .7),
          color: offline ? NX.surface : NX.surface2,
          padding: const EdgeInsets.fromLTRB(16, 16, 14, 14),
          onTap: onTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _IconBadge(icon: module.icon, color: accent, muted: offline),
                  const Spacer(),
                  switch (status) {
                    TileStatus.ready => Icon(
                      Icons.arrow_outward_rounded,
                      size: 18,
                      color: accent.withValues(alpha: .8),
                    ),
                    TileStatus.checking => NxPill(
                      checkingLabel,
                      color: NX.waiting,
                      live: true,
                      dense: true,
                    ),
                    TileStatus.offline => const NxPill(
                      'Offline',
                      color: NX.idle,
                      icon: Icons.cloud_off_rounded,
                      dense: true,
                    ),
                  },
                ],
              ),
              const SizedBox(height: 14),
              Text(
                module.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.2,
                ),
              ),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: NX.textDim, fontSize: 12.5),
                ),
              ],
              if (extra != null) ...[const SizedBox(height: 8), extra],
            ],
          ),
        ),
      ),
    );
  }
}

class _IconBadge extends StatelessWidget {
  const _IconBadge({
    required this.icon,
    required this.color,
    this.muted = false,
  });
  final IconData icon;
  final Color color;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final c = muted ? NX.idle : color;
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(NX.radiusSm),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [c.withValues(alpha: .32), c.withValues(alpha: .12)],
        ),
        border: Border.all(color: c.withValues(alpha: .4)),
      ),
      child: Icon(icon, color: muted ? NX.textDim : c, size: 24),
    );
  }
}
