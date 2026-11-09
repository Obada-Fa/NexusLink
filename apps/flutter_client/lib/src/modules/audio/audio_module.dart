// Audio: the phone as the PC's mic, PC audio on the phone, phone audio on
// the PC, over the nexus_audio plugin (Android only).

import 'package:flutter/material.dart';
import 'package:nexus_audio/nexus_audio.dart';

import '../../session/target.dart';
import '../../shell/module.dart';
import '../../shell/module_extras.dart';
import '../../theme/nexus_theme.dart';
import '../../theme/nx_widgets.dart';
import 'audio_messages.dart';
import 'audio_runtime.dart';
import 'audio_screen.dart';

class AudioModule extends NexusModule
    implements DescribedModule, BlockableModule, TargetRemovalAware {
  const AudioModule();

  @override
  String get id => 'audio';

  @override
  String get title => 'Audio';

  @override
  String get subtitle => 'PC mic · PC audio · Phone audio';

  @override
  Color get accent => NX.stuck;

  @override
  IconData get icon => Icons.graphic_eq_rounded;

  @override
  int get order => 50;

  @override
  CapabilityRequirement get requires =>
      const CapabilityRequirement.anyOf(['audio.source', 'audio.sink', 'mic']);

  @override
  Set<TargetPlatform> get platforms => const {TargetPlatform.android};

  @override
  Widget buildEntry(BuildContext context, ModuleContext ctx) =>
      AudioScreen(ctx: ctx);

  @override
  Widget? buildTileExtra(BuildContext context, ModuleContext ctx) =>
      const AudioTileDots();

  @override
  Stream<List<LiveActivity>>? liveActivities(ModuleContext ctx) =>
      AudioRuntime.activities;

  @override
  Listenable get blockedChanges => AudioRuntime.blocked;

  @override
  String? blockedReason(ModuleContext ctx) =>
      AudioRuntime.blockedFor(ctx.target.id);

  @override
  Future<void> onTargetChanged(ModuleContext? ctx) => AudioRuntime.switchTo(ctx);

  @override
  Future<void> onTargetRemoved(SavedTarget target) =>
      AudioRuntime.targetRemoved(target);
}

/// Small live dots on the home tile, one per running stream.
class AudioTileDots extends StatelessWidget {
  const AudioTileDots({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AudioView>(
    valueListenable: AudioRuntime.view,
    builder: (context, view, _) {
      final on = view.onStreams;
      if (on.isEmpty) return const SizedBox.shrink();
      return Row(
        key: const ValueKey('audio-tile-dots'),
        children: [
          for (final s in on) ...[
            LiveDot(
              color: phaseColor(view[s].phase),
              size: 6,
              pulse: view[s].phase != StreamPhase.live,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                streamShortName(s),
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  color: phaseColor(view[s].phase),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ],
      );
    },
  );
}
