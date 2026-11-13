// The Audio module's screen: three stream toggles with their phase and
// detail, a mic level meter, and inline banners for pairing and permission
// problems.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nexus_audio/nexus_audio.dart';

import '../../session/target.dart';
import '../../shell/module.dart';
import '../../shell/target_actions.dart';
import '../../theme/nexus_theme.dart';
import '../../theme/nx_widgets.dart';
import '../../pc/phone_mic.dart';
import '../../state/connection.dart';
import 'audio_messages.dart';
import 'audio_runtime.dart';

class AudioScreen extends ConsumerStatefulWidget {
  const AudioScreen({super.key, required this.ctx});
  final ModuleContext ctx;

  @override
  ConsumerState<AudioScreen> createState() => _AudioScreenState();
}

class _AudioScreenState extends ConsumerState<AudioScreen> {
  StreamSubscription<String>? _messages;

  @override
  void initState() {
    super.initState();
    _messages = AudioRuntime.messages.listen((m) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(m)));
    });
  }

  @override
  void dispose() {
    _messages?.cancel();
    super.dispose();
  }

  Future<void> _scan() => startPairing(context, ref);

  @override
  Widget build(BuildContext context) {
    final ctx = widget.ctx;
    final target = ctx.target;
    // PCs without Nexus Audio still get NexusLink's older phone mic here.
    final hasAudio = target.has(UtilityIds.audio);
    final online = ctx.isReachable(
      hasAudio ? UtilityIds.audio : UtilityIds.nexuslink,
    );
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: Listenable.merge([
            AudioRuntime.view,
            AudioRuntime.blocked,
          ]),
          builder: (context, _) {
            final view = AudioRuntime.view.value;
            final blocked = AudioRuntime.blockedFor(target.id);
            final ready = blocked == null;
            return ListView(
              key: const ValueKey('audio-screen'),
              padding: const EdgeInsets.only(bottom: 40),
              children: [
                _Header(
                  pc: target.name,
                  online: online,
                  live: view.onStreams.length,
                ),
                if (!hasAudio) ...[
                  const _LegacyMic(audioPaired: false),
                ] else ...[
                  if (blocked != null)
                    _Banner(
                      key: const ValueKey('audio-blocked'),
                      color: NX.waiting,
                      icon: Icons.key_off_rounded,
                      text: blocked,
                      actions: [
                        TextButton(
                          onPressed: _scan,
                          child: const Text('Scan QR'),
                        ),
                      ],
                    )
                  else if (view.pairAgain)
                    _Banner(
                      key: const ValueKey('audio-pair-again'),
                      color: NX.waiting,
                      icon: Icons.link_off,
                      text:
                          '${target.name} no longer accepts this phone for '
                          'Audio. Scan the QR code from Nexus Utilities to pair '
                          'again.',
                      actions: [
                        TextButton(
                          onPressed: _scan,
                          child: const Text('Scan QR'),
                        ),
                      ],
                    ),
                  if (view.problem case final p?)
                    _Banner(
                      key: const ValueKey('audio-problem'),
                      color: p.openSettings ? NX.waiting : NX.failed,
                      icon: p.openSettings
                          ? Icons.mic_off_rounded
                          : Icons.error_outline_rounded,
                      text: p.message,
                      actions: [
                        TextButton(
                          onPressed: AudioRuntime.dismissProblem,
                          child: const Text('Dismiss'),
                        ),
                        if (p.openSettings)
                          TextButton(
                            onPressed: AudioRuntime.openSettings,
                            child: const Text('Open settings'),
                          ),
                        if (p.pairAgain)
                          TextButton(
                            onPressed: _scan,
                            child: const Text('Scan QR'),
                          ),
                      ],
                    ),
                  const NxSectionHeader('Streams'),
                  for (final s in AudioStream.values)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        NX.pad,
                        0,
                        NX.pad,
                        NX.gap,
                      ),
                      child: StreamCard(
                        stream: s,
                        view: view,
                        pc: target.name,
                        enabled: ready,
                        onChanged: (on) => AudioRuntime.setStream(s, on),
                      ),
                    ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(NX.pad + 4, 4, NX.pad + 4, 0),
                    child: Text(
                      'Streams keep running when you leave the app. Stop them '
                      'here, from the live bar on the home screen, or from the '
                      'notification.',
                      style: TextStyle(
                        color: NX.textFaint,
                        fontSize: 12.5,
                        height: 1.4,
                      ),
                    ),
                  ),
                  const _LegacyMic(audioPaired: true),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.pc, required this.online, required this.live});
  final String pc;
  final bool online;
  final int live;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 6, NX.pad, 0),
    child: Row(
      children: [
        IconButton(
          tooltip: 'Back',
          onPressed: () => Navigator.maybePop(context),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Audio',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.3,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  LiveDot(
                    color: online ? NX.working : NX.idle,
                    size: 7,
                    pulse: false,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '$pc · ${online ? 'Online' : 'Not answering'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: online ? NX.working : NX.textDim,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (live > 0) NxPill('$live on', color: NX.working, live: true),
      ],
    ),
  );
}

/// One toggle: icon, title, description, switch, then phase and detail (and
/// the level meter for the mic).
class StreamCard extends StatelessWidget {
  const StreamCard({
    super.key,
    required this.stream,
    required this.view,
    required this.pc,
    required this.onChanged,
    this.enabled = true,
  });
  final AudioStream stream;
  final AudioView view;
  final String pc;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final phase = view.phaseOf(stream);
    final color = phaseColor(phase);
    final on = view.isOn(stream);
    final detail = view.detailOf(stream);
    final showMeter = stream == AudioStream.mic && phase != StreamPhase.off;
    return NxCard(
      key: ValueKey('audio-card-${stream.name}'),
      accent: phase == StreamPhase.live
          ? NX.working
          : phase == StreamPhase.retrying
          ? NX.waiting
          : null,
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
      onTap: enabled ? () => onChanged(!on) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _StreamBadge(
                icon: streamIcon(stream),
                color: on ? color : NX.idle,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      streamTitle(stream),
                      style: const TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      streamDescription(stream, pc),
                      style: const TextStyle(
                        color: NX.textDim,
                        fontSize: 12.5,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                key: ValueKey('audio-switch-${stream.name}'),
                value: on,
                onChanged: enabled ? onChanged : null,
              ),
            ],
          ),
          if (phase != StreamPhase.off || detail != null) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                NxPill(
                  phaseLabel(phase),
                  key: ValueKey('audio-phase-${stream.name}'),
                  color: color,
                  live: phase != StreamPhase.off,
                  dense: true,
                ),
                const SizedBox(width: 8),
                if (detail != null)
                  Expanded(
                    child: Text(
                      detail,
                      key: ValueKey('audio-detail-${stream.name}'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: phase == StreamPhase.off ? NX.textDim : NX.text,
                        fontSize: 12.5,
                        height: 1.3,
                      ),
                    ),
                  ),
              ],
            ),
          ],
          if (showMeter) ...[
            const SizedBox(height: 12),
            MicLevelMeter(level: view.engine.micLevel),
          ],
        ],
      ),
    );
  }
}

class _StreamBadge extends StatelessWidget {
  const _StreamBadge({required this.icon, required this.color});
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 220),
    width: 42,
    height: 42,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(NX.radiusSm),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [color.withValues(alpha: .32), color.withValues(alpha: .12)],
      ),
      border: Border.all(color: color.withValues(alpha: .4)),
    ),
    child: Icon(icon, color: color, size: 22),
  );
}

/// A segmented peak meter for the phone mic.
class MicLevelMeter extends StatelessWidget {
  const MicLevelMeter({super.key, required this.level, this.segments = 28});
  final double level;
  final int segments;

  @override
  Widget build(BuildContext context) {
    // Peaks are linear amplitude; a square root reads closer to loudness.
    final lit = (math.sqrt(level.clamp(0.0, 1.0)) * segments).round();
    return Semantics(
      label: 'Mic level ${(level * 100).round()} percent',
      child: SizedBox(
        key: const ValueKey('audio-mic-meter'),
        height: 14,
        child: Row(
          children: [
            const Icon(Icons.mic_none_rounded, size: 14, color: NX.textFaint),
            const SizedBox(width: 8),
            for (var i = 0; i < segments; i++) ...[
              if (i > 0) const SizedBox(width: 2),
              Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 90),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(2),
                    color: i < lit ? _segmentColor(i / segments) : NX.surface3,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static Color _segmentColor(double at) => at < .65
      ? NX.working
      : at < .85
      ? NX.waiting
      : NX.failed;
}

class _Banner extends StatelessWidget {
  const _Banner({
    super.key,
    required this.color,
    required this.icon,
    required this.text,
    required this.actions,
  });
  final Color color;
  final IconData icon;
  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(NX.pad, 12, NX.pad, 0),
    child: NxCard(
      accent: color,
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(fontSize: 13.5, height: 1.35),
                ),
              ),
            ],
          ),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
        ],
      ),
    ),
  );
}

/// NexusLink's older phone-mic control: the only mic on PCs without Nexus
/// Audio, and a collapsed fallback on PCs that have it.
class _LegacyMic extends ConsumerWidget {
  const _LegacyMic({required this.audioPaired});
  final bool audioPaired;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(connectionStatusProvider);
    final client = ref.watch(activeClientProvider);
    final supported = client?.supports('mic.v1') == true;
    if (audioPaired) {
      if (!supported) return const SizedBox.shrink();
      return const Padding(
        padding: EdgeInsets.only(top: 16),
        child: ExpansionTile(
          key: ValueKey('legacy-mic'),
          tilePadding: EdgeInsets.symmetric(horizontal: NX.pad),
          shape: Border(),
          collapsedShape: Border(),
          title: Text('Use as PC mic (older method)'),
          subtitle: Text(
            'Through NexusLink, for when Audio isn’t working',
            style: TextStyle(color: NX.textDim, fontSize: 12.5),
          ),
          children: [PhoneMicSection(key: ValueKey('pc-mic'))],
        ),
      );
    }
    return Column(
      key: const ValueKey('legacy-mic'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(NX.pad, 8, NX.pad, 4),
          child: Text(
            'Nexus Audio isn’t set up on this PC. You can still use the '
            'phone as its microphone through NexusLink.',
            style: TextStyle(color: NX.textDim, fontSize: 13, height: 1.4),
          ),
        ),
        if (supported)
          const PhoneMicSection(key: ValueKey('pc-mic'))
        else
          const Padding(
            padding: EdgeInsets.fromLTRB(NX.pad, 12, NX.pad, 0),
            child: Text(
              'This PC’s NexusLink host doesn’t support the phone mic yet. '
              'Update it, or pair Nexus Audio from Nexus Utilities.',
              style: TextStyle(color: NX.textFaint, fontSize: 12.5),
            ),
          ),
      ],
    );
  }
}
