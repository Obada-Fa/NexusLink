/// Nexus Audio's PC streams (ABP v2 over TLS) as a Flutter plugin. Android only.
///
/// Contract: `docs/NEXUS-APP-PHASE1.md` §5. Permissions (microphone, notifications) are asked by the app
/// before [NexusAudio.start]; the plugin only checks them.
library;

import 'package:flutter/services.dart';

/// The three independent streams. Wire names: `mic`, `playHere`, `sendDevice`.
enum AudioStream {
  /// Phone mic → PC virtual mic.
  mic,

  /// PC speakers → this phone.
  playHere,

  /// Phone audio (MediaProjection) → PC speakers. Android 10+, asks for consent itself.
  sendDevice;

  /// The name used on the channels.
  String get wire => name;

  static AudioStream? fromWire(Object? v) {
    for (final s in values) {
      if (s.name == v) return s;
    }
    return null;
  }
}

/// Wire names: lower case (`off`, `connecting`, `live`, `retrying`).
enum StreamPhase {
  off,
  connecting,
  live,
  retrying;

  String get wire => name;

  /// Unknown or missing values read as [off].
  static StreamPhase fromWire(Object? v) {
    for (final p in values) {
      if (p.name == v) return p;
    }
    return off;
  }
}

/// Everything the engine needs to reach one paired PC, secrets included. Passed with every call; the
/// plugin stores no pairing.
class AudioPairing {
  const AudioPairing({
    required this.pcName,
    required this.hosts,
    required this.port,
    required this.fingerprint,
    required this.deviceId,
    required this.token,
  });

  final String pcName;

  /// Addresses to try in order (LAN IPs, mDNS name, ...).
  final List<String> hosts;
  final int port;

  /// SHA-256 of the PC's TLS certificate (hex), pinned on every connection.
  final String fingerprint;
  final String deviceId;
  final String token;

  Map<String, Object?> toMap() => {
        'pcName': pcName,
        'hosts': List<String>.of(hosts),
        'port': port,
        'fingerprint': fingerprint,
        'deviceId': deviceId,
        'token': token,
      };

  /// Never prints the token.
  @override
  String toString() => 'AudioPairing($pcName, $hosts:$port, device $deviceId)';
}

class AudioStreamStatus {
  const AudioStreamStatus({this.phase = StreamPhase.off, this.detail});

  static const AudioStreamStatus off = AudioStreamStatus();

  final StreamPhase phase;

  /// Human-readable status ("Connecting to Desk…", "48 kHz · stereo", why it stopped), or null.
  final String? detail;

  /// The stream is wanted (connecting, live or retrying).
  bool get on => phase != StreamPhase.off;

  factory AudioStreamStatus.fromMap(Object? m) {
    if (m is! Map) return off;
    final d = m['detail'];
    return AudioStreamStatus(phase: StreamPhase.fromWire(m['phase']), detail: d is String ? d : null);
  }

  @override
  bool operator ==(Object other) => other is AudioStreamStatus && other.phase == phase && other.detail == detail;

  @override
  int get hashCode => Object.hash(phase, detail);

  @override
  String toString() => 'AudioStreamStatus(${phase.name}${detail == null ? '' : ', $detail'})';
}

/// A one-off message that outlives the stream that raised it, e.g. "Desk no longer accepts this phone.
/// Pair again." ([pairAgain] true). The stream's [AudioStreamStatus.detail] carries the same text, so a
/// screen that wasn't listening still sees why it stopped.
class AudioNotice {
  const AudioNotice({required this.stream, required this.message, this.pairAgain = false});

  final AudioStream stream;
  final String message;
  final bool pairAgain;

  /// Null when the map has no known stream or no message.
  static AudioNotice? fromMap(Object? m) {
    if (m is! Map) return null;
    final stream = AudioStream.fromWire(m['stream']);
    final message = m['message'];
    if (stream == null || message is! String) return null;
    return AudioNotice(stream: stream, message: message, pairAgain: m['pairAgain'] == true);
  }

  @override
  String toString() => 'AudioNotice(${stream.name}, $message${pairAgain ? ', pairAgain' : ''})';
}

class AudioEngineState {
  const AudioEngineState({this.streams = const {}, this.micLevel = 0});

  static const AudioEngineState initial = AudioEngineState();

  /// Missing streams read as [AudioStreamStatus.off]; use [operator []].
  final Map<AudioStream, AudioStreamStatus> streams;

  /// Mic peak level 0..1 (0 while the mic is off).
  final double micLevel;

  AudioStreamStatus operator [](AudioStream s) => streams[s] ?? AudioStreamStatus.off;

  /// Any stream on.
  bool get anyOn => streams.values.any((s) => s.on);

  AudioEngineState copyWith({Map<AudioStream, AudioStreamStatus>? streams, double? micLevel}) =>
      AudioEngineState(streams: streams ?? this.streams, micLevel: micLevel ?? this.micLevel);

  /// Parses `{streams: {mic: {phase, detail}, ...}, micLevel}`; tolerates missing or odd fields.
  factory AudioEngineState.fromMap(Object? m) {
    if (m is! Map) return initial;
    return AudioEngineState(streams: parseStreams(m['streams']), micLevel: _level(m['micLevel']));
  }

  /// Every stream gets an entry (off when absent).
  static Map<AudioStream, AudioStreamStatus> parseStreams(Object? m) => {
        for (final s in AudioStream.values) s: AudioStreamStatus.fromMap(m is Map ? m[s.wire] : null),
      };

  static double _level(Object? v) => v is num ? v.toDouble().clamp(0.0, 1.0) : 0.0;

  /// Applies one `nexus/audio/events` event; returns this unchanged for events that don't touch state.
  AudioEngineState apply(Object? event) {
    if (event is! Map) return this;
    switch (event['type']) {
      case 'streams':
        final next = parseStreams(event['streams']);
        // The mic level is meaningless once the mic is off.
        return copyWith(streams: next, micLevel: next[AudioStream.mic]!.on ? micLevel : 0);
      case 'micLevel':
        return copyWith(micLevel: _level(event['level']));
    }
    return this;
  }

  @override
  String toString() => 'AudioEngineState(${streams.map((k, v) => MapEntry(k.name, v))}, mic $micLevel)';
}

/// Error codes of [NexusAudio.start] (as [PlatformException.code]).
abstract final class AudioErrors {
  /// RECORD_AUDIO not granted (mic, and also sendDevice: playback capture records through AudioRecord).
  static const micPermission = 'MIC_PERMISSION';

  /// MediaProjection consent refused (or there was no visible screen to ask on).
  static const consentDenied = 'CONSENT_DENIED';

  /// sendDevice below Android 10.
  static const unsupported = 'UNSUPPORTED';

  /// Unknown stream or incomplete pairing.
  static const badArgs = 'BAD_ARGS';
}

abstract final class NexusAudio {
  static const methods = MethodChannel('nexus/audio');
  static const events = EventChannel('nexus/audio/events');

  /// Starts one stream. Returns once it is connecting (then watch [stateStream]); for [AudioStream.sendDevice]
  /// that is after the user allowed MediaProjection. Throws [PlatformException] with an [AudioErrors] code.
  static Future<void> start(AudioStream stream, AudioPairing pairing) =>
      methods.invokeMethod<void>('start', {'stream': stream.wire, 'pairing': pairing.toMap()});

  /// Turns one stream off and forgets it for [restore].
  static Future<void> stop(AudioStream stream) => methods.invokeMethod<void>('stop', {'stream': stream.wire});

  static Future<void> stopAll() => methods.invokeMethod<void>('stopAll');

  static Future<AudioEngineState> state() async =>
      AudioEngineState.fromMap(await methods.invokeMethod<Object?>('state'));

  /// Restarts mic/playHere streams the user left on (sendDevice is never restored: it needs fresh consent).
  /// The mic only comes back when RECORD_AUDIO is granted. True if anything started.
  static Future<bool> restore(AudioPairing pairing) async =>
      await methods.invokeMethod<bool>('restore', {'pairing': pairing.toMap()}) ?? false;

  /// Forget which streams were on (e.g. after unpairing), so [restore] starts nothing.
  static Future<void> forgetWanted() => methods.invokeMethod<void>('forgetWanted');

  // One platform subscription shared by every listener: a second receiveBroadcastStream() would make the
  // platform side cancel the first.
  static Stream<Object?>? _raw;
  static Stream<Object?> get _events => _raw ??= events.receiveBroadcastStream();

  /// Engine state from the `streams` and `micLevel` events. The first event after listening is the current
  /// streams; call [state] for the full snapshot (mic level included) right away.
  static Stream<AudioEngineState> get stateStream {
    var current = AudioEngineState.initial;
    return _events.where(_isStateEvent).map((e) => current = current.apply(e));
  }

  /// From the `notice` events.
  static Stream<AudioNotice> get notices =>
      _events.where((e) => e is Map && e['type'] == 'notice').map(AudioNotice.fromMap).where((n) => n != null).cast<AudioNotice>();

  static bool _isStateEvent(Object? e) => e is Map && (e['type'] == 'streams' || e['type'] == 'micLevel');

  /// Tests only: drop the cached platform stream.
  static void debugReset() => _raw = null;
}
