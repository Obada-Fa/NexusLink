// Phone mic → PC: stream this phone's microphone into a virtual input
// device on the PC ("NexusLink Phone Mic"), so PC apps — AI voice modes,
// calls, recorders — hear the phone as if it were a real microphone.
//
// The session lives in a provider, not the section widget, so the mic keeps
// streaming while the user switches to Mirror or another tab.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:record/record.dart';

import '../rpc/rpc_client.dart';
import '../state/connection.dart';
import '../theme/nexus_theme.dart';
import '../theme/nx_widgets.dart';
import 'pc_actions.dart';
import 'pc_ui.dart';

/// Must match MIC_FRAME_MAGIC on the host ("NXMC").
const micFrameMagic = [0x4e, 0x58, 0x4d, 0x43];
const micSampleRate = 48000;

/// Prefix one PCM chunk with the frame magic the host routes on.
Uint8List micFrame(Uint8List pcm) {
  final out = Uint8List(micFrameMagic.length + pcm.length);
  out.setAll(0, micFrameMagic);
  out.setAll(micFrameMagic.length, pcm);
  return out;
}

/// Peak level of s16le PCM, 0..1, for the meter.
double pcmPeak(Uint8List pcm) {
  final data = ByteData.sublistView(pcm);
  var peak = 0;
  for (var i = 0; i + 1 < pcm.length; i += 2) {
    final v = data.getInt16(i, Endian.little).abs();
    if (v > peak) peak = v;
  }
  return math.min(1, peak / 32767);
}

enum MicPhase { off, starting, live }

class PhoneMicState {
  const PhoneMicState({
    this.phase = MicPhase.off,
    this.holdToTalk = false,
    this.holding = false,
    this.muted = false,
    this.makeDefault = true,
    this.level = 0,
    this.startedAt,
    this.error,
  });
  final MicPhase phase;
  final bool holdToTalk;
  final bool holding;
  final bool muted;
  final bool makeDefault;
  final double level;
  final DateTime? startedAt;
  final String? error;

  bool get live => phase == MicPhase.live;

  /// Audio actually reaches the PC right now.
  bool get transmitting => live && (holdToTalk ? holding : !muted);

  PhoneMicState copyWith({
    MicPhase? phase,
    bool? holdToTalk,
    bool? holding,
    bool? muted,
    bool? makeDefault,
    double? level,
    DateTime? startedAt,
    String? error,
    bool clearError = false,
  }) => PhoneMicState(
    phase: phase ?? this.phase,
    holdToTalk: holdToTalk ?? this.holdToTalk,
    holding: holding ?? this.holding,
    muted: muted ?? this.muted,
    makeDefault: makeDefault ?? this.makeDefault,
    level: level ?? this.level,
    startedAt: startedAt ?? this.startedAt,
    error: clearError ? null : (error ?? this.error),
  );
}

class PhoneMicNotifier extends Notifier<PhoneMicState> {
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _audio;
  StreamSubscription<RpcStatus>? _status;
  RpcClient? _client;

  @override
  PhoneMicState build() {
    ref.onDispose(() => unawaited(_teardown(notifyHost: true)));
    return const PhoneMicState();
  }

  void setHoldToTalk(bool value) =>
      state = state.copyWith(holdToTalk: value, holding: false, muted: false);
  void setMakeDefault(bool value) => state = state.copyWith(makeDefault: value);
  void setMuted(bool value) => state = state.copyWith(muted: value);
  void setHolding(bool value) {
    if (state.holding == value) return;
    if (value) HapticFeedback.lightImpact();
    state = state.copyWith(holding: value);
  }

  Future<void> start() async {
    if (state.phase != MicPhase.off) return;
    final client = ref.read(activeClientProvider);
    if (client == null) {
      state = state.copyWith(error: 'Connect to the PC first.');
      return;
    }
    state = state.copyWith(phase: MicPhase.starting, clearError: true);
    final recorder = AudioRecorder();
    _recorder = recorder;
    try {
      if (!await recorder.hasPermission()) {
        throw const _MicError(
          'Microphone permission is needed. Allow it in Android settings.',
        );
      }
      await client.request('mic.start', {
        'sampleRate': micSampleRate,
        'channels': 1,
        'makeDefault': state.makeDefault,
      });
      _client = client;
      final stream = await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: micSampleRate,
          numChannels: 1,
          echoCancel: true,
          noiseSuppress: true,
          autoGain: true,
          audioInterruption: AudioInterruptionMode.none,
        ),
      );
      _audio = stream.listen(
        _onPcm,
        onError: (Object e) => _fail('The phone mic stopped: $e'),
        onDone: () {
          if (state.live) _fail('The phone mic stopped.');
        },
      );
      _status = client.statusStream.listen((s) {
        if (s != RpcStatus.connected && state.live) {
          _fail('Connection to the PC dropped, so the mic was turned off.');
        }
      });
      state = state.copyWith(
        phase: MicPhase.live,
        startedAt: DateTime.now(),
        holding: false,
        muted: false,
      );
    } catch (e) {
      await _teardown(notifyHost: _client != null);
      state = state.copyWith(
        phase: MicPhase.off,
        error: e is _MicError ? e.message : pcActionError(e),
      );
    }
  }

  Future<void> stop() async {
    if (state.phase == MicPhase.off) return;
    await _teardown(notifyHost: true);
    state = state.copyWith(phase: MicPhase.off, level: 0, holding: false);
  }

  void _onPcm(Uint8List pcm) {
    final transmitting = state.transmitting;
    if (transmitting) _client?.sendBinary(micFrame(pcm));
    final level = transmitting ? pcmPeak(pcm) : 0.0;
    // Smooth decay keeps the meter readable without rebuilding per chunk.
    final next = level > state.level ? level : state.level * .82;
    if ((next - state.level).abs() > .015) state = state.copyWith(level: next);
  }

  void _fail(String message) {
    unawaited(_teardown(notifyHost: true));
    state = state.copyWith(
      phase: MicPhase.off,
      level: 0,
      holding: false,
      error: message,
    );
  }

  Future<void> _teardown({required bool notifyHost}) async {
    final audio = _audio, status = _status, recorder = _recorder;
    final client = _client;
    _audio = null;
    _status = null;
    _recorder = null;
    _client = null;
    await audio?.cancel();
    await status?.cancel();
    if (recorder != null) {
      try {
        await recorder.stop();
      } catch (_) {}
      unawaited(recorder.dispose());
    }
    if (notifyHost && client != null) {
      try {
        await client.request('mic.stop', const {});
      } catch (_) {}
    }
  }
}

class _MicError implements Exception {
  const _MicError(this.message);
  final String message;
}

final phoneMicProvider = NotifierProvider<PhoneMicNotifier, PhoneMicState>(
  PhoneMicNotifier.new,
);

/// PC tab section: turn the phone into a PC microphone.
class PhoneMicSection extends ConsumerWidget {
  const PhoneMicSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(activeClientProvider);
    ref.watch(connectionStatusProvider);
    final mic = ref.watch(phoneMicProvider);
    if (client == null || !client.supports('mic.v1')) {
      return const SizedBox.shrink();
    }
    final ctl = ref.read(phoneMicProvider.notifier);
    final color = mic.transmitting
        ? NX.working
        : mic.live
        ? NX.waiting
        : NX.accent;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PcSectionHeader(
          'Phone mic',
          trailing: mic.live
              ? NxPill(
                  mic.transmitting ? 'On air' : 'Muted',
                  color: color,
                  live: mic.transmitting,
                  dense: true,
                )
              : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: NX.pad),
          child: NxCard(
            accent: mic.transmitting ? NX.working : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    _MicButton(state: mic, color: color, ctl: ctl),
                    const SizedBox(width: 16),
                    Expanded(child: _MicInfo(state: mic, color: color)),
                  ],
                ),
                if (mic.live) ...[
                  const SizedBox(height: 14),
                  _LevelMeter(level: mic.level, color: color),
                ],
                if (mic.error != null) ...[
                  const SizedBox(height: 12),
                  PcNote(
                    mic.error!,
                    color: NX.failed,
                    icon: Icons.error_outline_rounded,
                  ),
                ],
                const SizedBox(height: 8),
                _Toggle(
                  key: const ValueKey('mic-hold'),
                  label: 'Hold to talk',
                  hint: 'Only send audio while you hold the mic button.',
                  value: mic.holdToTalk,
                  onChanged: ctl.setHoldToTalk,
                ),
                _Toggle(
                  key: const ValueKey('mic-default'),
                  label: "Make it the PC's default mic",
                  hint: mic.live
                      ? 'Applies next time you turn the mic on.'
                      : 'Switches back to your usual mic when you stop.',
                  value: mic.makeDefault,
                  onChanged: ctl.setMakeDefault,
                ),
                if (mic.live) ...[
                  const SizedBox(height: 6),
                  OutlinedButton.icon(
                    key: const ValueKey('mic-stop'),
                    onPressed: ctl.stop,
                    icon: const Icon(Icons.stop_rounded),
                    label: const Text('Turn off phone mic'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MicButton extends StatelessWidget {
  const _MicButton({
    required this.state,
    required this.color,
    required this.ctl,
  });
  final PhoneMicState state;
  final Color color;
  final PhoneMicNotifier ctl;

  @override
  Widget build(BuildContext context) {
    final starting = state.phase == MicPhase.starting;
    final ptt = state.live && state.holdToTalk;
    final icon = !state.live
        ? Icons.mic_none_rounded
        : state.transmitting
        ? Icons.mic_rounded
        : Icons.mic_off_rounded;
    final size = 72.0 + (state.transmitting ? state.level * 10 : 0);

    Widget button = AnimatedContainer(
      duration: const Duration(milliseconds: 90),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: state.transmitting ? .28 : .14),
        border: Border.all(color: color.withValues(alpha: .6), width: 2),
        boxShadow: state.transmitting
            ? [
                BoxShadow(
                  color: color.withValues(alpha: .35),
                  blurRadius: 18 * (0.4 + state.level),
                ),
              ]
            : null,
      ),
      child: starting
          ? Padding(
              padding: const EdgeInsets.all(24),
              child: CircularProgressIndicator(strokeWidth: 2.5, color: color),
            )
          : Icon(icon, size: 32, color: color),
    );

    final label = !state.live
        ? 'Turn on phone mic'
        : ptt
        ? 'Hold to talk'
        : state.muted
        ? 'Unmute'
        : 'Mute';

    if (ptt) {
      button = Listener(
        onPointerDown: (_) => ctl.setHolding(true),
        onPointerUp: (_) => ctl.setHolding(false),
        onPointerCancel: (_) => ctl.setHolding(false),
        child: button,
      );
    } else {
      button = InkResponse(
        radius: 44,
        onTap: starting
            ? null
            : !state.live
            ? ctl.start
            : () => ctl.setMuted(!state.muted),
        child: button,
      );
    }
    return Semantics(
      button: true,
      label: label,
      child: SizedBox(
        width: 84,
        height: 84,
        child: Center(child: button),
      ),
    );
  }
}

class _MicInfo extends StatelessWidget {
  const _MicInfo({required this.state, required this.color});
  final PhoneMicState state;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final title = switch (state.phase) {
      MicPhase.off => 'Use this phone as a PC mic',
      MicPhase.starting => 'Connecting mic…',
      MicPhase.live =>
        state.transmitting
            ? 'The PC hears you'
            : state.holdToTalk
            ? 'Hold the mic to talk'
            : 'Muted',
    };
    final body = state.live
        ? 'Pick "NexusLink Phone Mic" in any PC app'
              '${state.makeDefault ? ' (it is the default mic right now)' : ''}.'
        : 'Tap the mic. PC apps hear your voice through "NexusLink Phone Mic", '
              'e.g. an AI voice chat you control from here.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 15.5,
            fontWeight: FontWeight.w800,
            color: state.live ? color : NX.text,
          ),
        ),
        const SizedBox(height: 4),
        Text(body, style: const TextStyle(color: NX.textDim, fontSize: 12.5)),
      ],
    );
  }
}

class _LevelMeter extends StatelessWidget {
  const _LevelMeter({required this.level, required this.color});
  final double level;
  final Color color;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(4),
    child: LinearProgressIndicator(
      value: level.clamp(0, 1),
      minHeight: 6,
      color: color,
      backgroundColor: NX.surface3,
    ),
  );
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    super.key,
    required this.label,
    required this.hint,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final String hint;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile.adaptive(
    contentPadding: EdgeInsets.zero,
    dense: true,
    value: value,
    onChanged: onChanged,
    title: Text(
      label,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
    ),
    subtitle: Text(
      hint,
      style: const TextStyle(color: NX.textFaint, fontSize: 12),
    ),
  );
}
