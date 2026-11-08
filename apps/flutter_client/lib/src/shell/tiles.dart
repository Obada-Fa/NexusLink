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
    final accent = moduleAccent(module);
    final offline = tile.status == TileStatus.offline;
    final subtitle = moduleSubtitle(module);
    final extra = module.buildTileExtra(context, ctx);
    final statusLabel = switch (tile.status) {
      TileStatus.ready => 'Ready',
      TileStatus.checking => checkingLabel,
      TileStatus.offline => 'Offline',
    };
    return Semantics(
      button: true,
      label: '${module.title}, $statusLabel',
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _IconBadge(icon: module.icon, color: accent, muted: offline),
                  const Spacer(),
                  switch (tile.status) {
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
              const Spacer(),
              Text(
                module.title,
                maxLines: 1,
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
                  maxLines: 1,
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
