// The Audio module's state for the current target. Static because modules
// are const; the streams themselves belong to the plugin's foreground
// service, so this only mirrors them and forwards toggles.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nexus_audio/nexus_audio.dart';

import '../../session/target.dart';
import '../../shell/module.dart';
import '../../shell/module_signals.dart';
import '../../shell/shell_navigator.dart';
import 'audio_messages.dart';
import 'audio_pairing.dart';
import 'audio_permissions.dart';

/// A problem the screen shows inline until dismissed or fixed.
class AudioProblem {
  const AudioProblem(
    this.message, {
    this.openSettings = false,
    this.pairAgain = false,
  });
  final String message;
  final bool openSettings;
  final bool pairAgain;
}

/// Everything the screen, tile and live bar draw.
@immutable
class AudioView {
  const AudioView({
    this.targetId,
    this.pcName = 'PC',
    this.engine = AudioEngineState.initial,
    this.details = const {},
    this.starting = const {},
    this.problem,
    this.pairAgain = false,
  });

  /// The target whose pairing the streams use (null when none is bound).
  final String? targetId;
  final String pcName;
  final AudioEngineState engine;

  /// Last non-null detail per stream, so text doesn't flicker while
  /// retrying.
  final Map<AudioStream, String> details;

  /// Streams whose start() is still in flight (permission or consent
  /// dialogs on screen).
  final Set<AudioStream> starting;
  final AudioProblem? problem;

  /// The PC refused this phone's Audio token.
  final bool pairAgain;

  AudioStreamStatus operator [](AudioStream s) => engine[s];

  /// The switch position: on while the engine has it on or a start is in
  /// flight.
  bool isOn(AudioStream s) => engine[s].on || starting.contains(s);

  /// Phase to show: a pending start reads as connecting.
  StreamPhase phaseOf(AudioStream s) {
    final p = engine[s].phase;
    return p == StreamPhase.off && starting.contains(s)
        ? StreamPhase.connecting
        : p;
  }

  String? detailOf(AudioStream s) {
    if (engine[s].phase == StreamPhase.off && starting.contains(s)) {
      return s == AudioStream.sendDevice
          ? 'Waiting for you to allow sharing…'
          : 'Starting…';
    }
    return details[s];
  }

  /// Streams that are on, in screen order.
  List<AudioStream> get onStreams => [
    for (final s in AudioStream.values)
      if (engine[s].on) s,
  ];

  AudioView copyWith({
    String? targetId,
    bool clearTarget = false,
    String? pcName,
    AudioEngineState? engine,
    Map<AudioStream, String>? details,
    Set<AudioStream>? starting,
    AudioProblem? problem,
    bool clearProblem = false,
    bool? pairAgain,
  }) => AudioView(
    targetId: clearTarget ? null : targetId ?? this.targetId,
    pcName: pcName ?? this.pcName,
    engine: engine ?? this.engine,
    details: details ?? this.details,
    starting: starting ?? this.starting,
    problem: clearProblem ? null : problem ?? this.problem,
    pairAgain: pairAgain ?? this.pairAgain,
  );
}

/// Applies new stream statuses to the sticky [details]: a non-null detail
/// replaces the old one; a null detail keeps it while connecting or
/// retrying (the engine briefly sends null between retries) and clears it
/// when the stream is live or off.
Map<AudioStream, String> mergeDetails(
  Map<AudioStream, String> old,
  AudioEngineState engine,
) {
  final next = <AudioStream, String>{};
  for (final s in AudioStream.values) {
    final st = engine[s];
    final d = st.detail;
    if (d != null && d.isNotEmpty) {
      next[s] = d;
    } else if (st.phase == StreamPhase.retrying ||
        st.phase == StreamPhase.connecting) {
      final kept = old[s];
      if (kept != null) next[s] = kept;
    }
  }
  return next;
}

abstract final class AudioRuntime {
  static final ValueNotifier<AudioView> view = ValueNotifier(const AudioView());

  /// Target id → why Audio can't start there (missing token...).
  static final ValueNotifier<Map<String, String>> blocked = ValueNotifier(
    const {},
  );

  /// One-off messages for a snackbar (plugin notices, start failures).
  static final StreamController<String> _messages =
      StreamController.broadcast();
  static Stream<String> get messages => _messages.stream;

  static final StreamController<List<LiveActivity>> _activities =
      StreamController.broadcast();
  static List<LiveActivity> _current = const [];

  static AudioPairing? _pairing;
  static StreamSubscription<AudioEngineState>? _stateSub;
  static StreamSubscription<AudioNotice>? _noticeSub;
  static bool _restorePending = false;
  static bool _notificationsExplained = false;
  static _Lifecycle? _lifecycle;

  static AudioPermissions permissions = const SystemAudioPermissions();

  /// Tests: pretend the Android plugin is (or isn't) there.
  @visibleForTesting
  static bool? debugEngineAvailable;

  static bool get engineAvailable =>
      debugEngineAvailable ?? (!kIsWeb && Platform.isAndroid);

  static AudioPairing? get pairing => _pairing;

  static String? blockedFor(String targetId) => blocked.value[targetId];

  /// Live activities, starting with the current list for each listener.
  static Stream<List<LiveActivity>> get activities => Stream.multi((c) {
    c.add(_current);
    final sub = _activities.stream.listen(c.add);
    c.onCancel = sub.cancel;
  });

  // -- target lifecycle -----------------------------------------------------

  /// The shell made [ctx]'s target current (or left it: null).
  static Future<void> switchTo(ModuleContext? ctx) async {
    if (ctx == null) {
      await _leave();
      return;
    }
    final target = ctx.target;
    if (view.value.targetId == target.id && _pairing != null) return;
    if (view.value.targetId != null && view.value.targetId != target.id) {
      await _leave();
    }
    view.value = AudioView(targetId: target.id, pcName: target.name)
        .copyWith(engine: view.value.engine, details: view.value.details);
    final token = await ctx.secret(UtilityIds.audio);
    if (view.value.targetId != target.id) return;
    final result = resolveAudioPairing(target, token);
    _setBlocked(target.id, result.problem);
    _pairing = result.pairing;
    if (_pairing == null || !engineAvailable) return;
    _listen();
    _restorePending = true;
    _ensureLifecycle();
    await _restoreIfForeground();
  }

  static Future<void> _leave() async {
    final had = view.value.targetId != null;
    _pairing = null;
    _restorePending = false;
    view.value = view.value.copyWith(
      clearTarget: true,
      starting: const {},
      clearProblem: true,
      pairAgain: false,
    );
    if (had && engineAvailable) {
      try {
        await NexusAudio.stopAll();
      } catch (e) {
        debugPrint('Audio stopAll failed: $e');
      }
    }
  }

  /// A saved target was removed. Its streams (if it is the bound one) stop
  /// and the engine forgets which streams to restore.
  static Future<void> targetRemoved(SavedTarget target) async {
    if (!target.has(UtilityIds.audio)) return;
    final bound = view.value.targetId;
    _setBlocked(target.id, null);
    // Another target's streams are running: the engine's wanted set is
    // theirs, leave it.
    if (bound != null && bound != target.id) return;
    if (bound == target.id) await _leave();
    if (!engineAvailable) return;
    try {
      await NexusAudio.stopAll();
      await NexusAudio.forgetWanted();
    } catch (e) {
      debugPrint('Audio forget failed: $e');
    }
  }

  /// Android refuses to start the audio foreground service from the
  /// background, so restore waits until the app is visible.
  static Future<void> _restoreIfForeground() async {
    final pairing = _pairing;
    if (!_restorePending || pairing == null) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _restorePending = false;
    try {
      await NexusAudio.restore(pairing);
    } catch (e) {
      debugPrint('Audio restore failed: $e');
    }
  }

  static void _ensureLifecycle() {
    if (_lifecycle != null) return;
    _lifecycle = _Lifecycle();
    WidgetsBinding.instance.addObserver(_lifecycle!);
  }

  // -- engine events ----------------------------------------------------------

  static void _listen() {
    if (_stateSub != null) return;
    _stateSub = NexusAudio.stateStream.listen(_onEngine, onError: (_) {});
    _noticeSub = NexusAudio.notices.listen(_onNotice, onError: (_) {});
    NexusAudio.state().then(_onEngine).catchError((Object e) {
      debugPrint('Audio state failed: $e');
    });
  }

  static void _onEngine(AudioEngineState engine) {
    final v = view.value;
    view.value = v.copyWith(
      engine: engine,
      details: mergeDetails(v.details, engine),
      // A stream the engine reports on is no longer "starting".
      starting: {
        for (final s in v.starting)
          if (!engine[s].on) s,
      },
    );
    _publish();
  }

  static void _onNotice(AudioNotice n) {
    final id = view.value.targetId;
    if (n.pairAgain) {
      view.value = view.value.copyWith(pairAgain: true);
      if (id != null) {
        ModuleSignals.requestPairAgain(id, UtilityIds.audio, message: n.message);
      }
    }
    _messages.add(n.message);
  }

  /// Feeds an engine state as if it came from the plugin (tests, previews).
  @visibleForTesting
  static void debugEngine(AudioEngineState engine) => _onEngine(engine);

  @visibleForTesting
  static void debugNotice(AudioNotice n) => _onNotice(n);

  static void _publish() {
    final v = view.value;
    final next = [
      for (final s in v.onStreams)
        LiveActivity(
          moduleId: 'audio',
          label: switch (v[s].phase) {
            StreamPhase.retrying =>
              '${liveActivityLabel(s, v.pcName)} · reconnecting',
            StreamPhase.connecting =>
              '${liveActivityLabel(s, v.pcName)} · connecting',
            _ => liveActivityLabel(s, v.pcName),
          },
          icon: streamIcon(s),
          onTap: () => ShellNavigator.instance.openModule('audio'),
          onStop: () => unawaited(setStream(s, false)),
        ),
    ];
    if (_sameActivities(next, _current)) return;
    _current = next;
    _activities.add(next);
  }

  static bool _sameActivities(List<LiveActivity> a, List<LiveActivity> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].label != b[i].label) return false;
    }
    return true;
  }

  // -- toggles ----------------------------------------------------------------

  /// Turns [stream] on or off. Asks for permissions first; problems end up in
  /// [AudioView.problem] or [messages], never thrown.
  static Future<void> setStream(AudioStream stream, bool on) async {
    if (!on) {
      view.value = view.value.copyWith(
        starting: {...view.value.starting}..remove(stream),
      );
      try {
        await NexusAudio.stop(stream);
      } catch (e) {
        debugPrint('Audio stop failed: $e');
      }
      return;
    }
    final pairing = _pairing;
    if (pairing == null) {
      final id = view.value.targetId;
      _problem(
        AudioProblem(
          (id == null ? null : blockedFor(id)) ??
              'Audio isn’t ready for this PC yet.',
          pairAgain: true,
        ),
      );
      return;
    }
    if (view.value.starting.contains(stream) || view.value[stream].on) return;
    _setStarting(stream, true);
    view.value = view.value.copyWith(clearProblem: true);
    try {
      if (stream != AudioStream.playHere) {
        final mic = await permissions.microphone();
        if (mic != PermissionOutcome.granted) {
          _setStarting(stream, false);
          _problem(
            AudioProblem(
              micRefusedMessage(
                stream,
                permanently: mic == PermissionOutcome.permanentlyDenied,
              ),
              openSettings: mic == PermissionOutcome.permanentlyDenied,
            ),
          );
          return;
        }
      }
      final notes = await permissions.notifications();
      if (notes != PermissionOutcome.granted && !_notificationsExplained) {
        _notificationsExplained = true;
        _messages.add(notificationsRefusedMessage);
      }
      if (_pairing != pairing) {
        _setStarting(stream, false); // target changed meanwhile
        return;
      }
      await NexusAudio.start(stream, pairing);
      // The engine's "streams" event clears [starting]; if it never comes,
      // don't leave the switch stuck on.
      Timer(const Duration(seconds: 3), () {
        if (!view.value[stream].on) _setStarting(stream, false);
      });
    } catch (e) {
      _setStarting(stream, false);
      final err = audioStartError(stream, e);
      _problem(
        AudioProblem(
          err.message,
          openSettings: err.openSettings,
          pairAgain: err.pairAgain,
        ),
      );
    }
  }

  static Future<void> openSettings() async {
    try {
      await permissions.openSettings();
    } catch (_) {}
  }

  static void dismissProblem() =>
      view.value = view.value.copyWith(clearProblem: true);

  static void _problem(AudioProblem p) =>
      view.value = view.value.copyWith(problem: p);

  static void _setStarting(AudioStream s, bool on) {
    final next = {...view.value.starting};
    on ? next.add(s) : next.remove(s);
    view.value = view.value.copyWith(starting: next);
  }

  static void _setBlocked(String targetId, String? reason) {
    final next = {...blocked.value};
    if (reason == null) {
      if (!next.containsKey(targetId)) return;
      next.remove(targetId);
    } else {
      if (next[targetId] == reason) return;
      next[targetId] = reason;
    }
    blocked.value = next;
  }

  @visibleForTesting
  static void debugReset() {
    _stateSub?.cancel();
    _noticeSub?.cancel();
    _stateSub = null;
    _noticeSub = null;
    if (_lifecycle != null) WidgetsBinding.instance.removeObserver(_lifecycle!);
    _lifecycle = null;
    _pairing = null;
    _restorePending = false;
    _notificationsExplained = false;
    _current = const [];
    view.value = const AudioView();
    blocked.value = const {};
    permissions = const SystemAudioPermissions();
  }
}

class _Lifecycle with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(AudioRuntime._restoreIfForeground());
    }
  }
}
