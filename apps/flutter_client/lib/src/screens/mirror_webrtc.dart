import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../rpc/rpc_client.dart';

enum MirrorCodec { mjpeg, connecting, h264 }

/// Deadlines use the receiver's monotonic clock.
class MirrorPlayback {
  static const startTimeout = Duration(seconds: 6);
  static const stallTimeout = Duration(seconds: 5);
  MirrorCodec codec = MirrorCodec.mjpeg;
  Duration? _deadline;

  void begin(Duration now) {
    codec = MirrorCodec.connecting;
    _deadline = now + startTimeout;
  }

  bool firstPicture(Duration now) {
    if (codec != MirrorCodec.connecting || expired(now)) return false;
    codec = MirrorCodec.h264;
    pictureProgress(now);
    return true;
  }

  void pictureProgress(Duration now) {
    if (codec == MirrorCodec.h264) _deadline = now + stallTimeout;
  }

  bool expired(Duration now) => _deadline != null && now >= _deadline!;

  void fallback() {
    codec = MirrorCodec.mjpeg;
    _deadline = null;
  }
}

/// When to try H.264 again after it fell back to MJPEG. A transient stall on
/// mobile data must not leave the rest of the session on MJPEG.
class MirrorRetryPolicy {
  static const delays = [
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(minutes: 2),
  ];

  /// An attempt that played this long counts as healthy and resets the backoff.
  static const healthyRun = Duration(seconds: 60);
  int _failures = 0;

  /// Null means do not retry; [Duration.zero] means retry now.
  Duration? afterFallback(String? code, Duration livedFor) {
    if (code == 'capture-ended' || code == 'unavailable') return null;
    if (code == 'region-changed') return Duration.zero;
    if (livedFor >= healthyRun) _failures = 0;
    final delay = delays[math.min(_failures, delays.length - 1)];
    _failures++;
    return delay;
  }
}

class MirrorRtcCounters {
  const MirrorRtcCounters({
    required this.at,
    required this.id,
    required this.bytes,
    required this.frames,
    required this.received,
    required this.lost,
    required this.jitterMs,
    this.rttMs,
  });

  final Duration at;
  final String id;
  final int bytes, frames, received, lost;
  final double jitterMs;
  final double? rttMs;

  MirrorRtcRates? since(MirrorRtcCounters before) {
    final seconds = (at - before.at).inMicroseconds / 1e6;
    if (id != before.id ||
        seconds <= 0 ||
        bytes < before.bytes ||
        frames < before.frames ||
        received < before.received) {
      return null;
    }
    final losses = math.max(0, lost - before.lost);
    final packets = received - before.received + losses;
    return MirrorRtcRates(
      (bytes - before.bytes) * 8 / (seconds * 1000),
      (frames - before.frames) / seconds,
      packets == 0 ? 0 : losses / packets,
      jitterMs,
      rttMs,
    );
  }
}

class MirrorRtcRates {
  const MirrorRtcRates(
    this.kbitPerSecond,
    this.fps,
    this.loss,
    this.jitterMs,
    this.rttMs,
  );

  final double kbitPerSecond, fps, loss, jitterMs;
  final double? rttMs;
}

/// Owns one upgrade attempt and its native resources. The caller keeps MJPEG
/// visible until this attempt confirms that a decoded picture reached its renderer.
class MirrorWebrtc {
  MirrorWebrtc({
    required this.client,
    required this.streamId,
    required this.sessionId,
    required this.onChanged,
    required this.onRates,
    required this.onFallback,
  });

  final RpcClient client;
  final String streamId;
  final String? sessionId;
  final VoidCallback onChanged;
  final ValueChanged<MirrorRtcRates> onRates;
  final void Function(String reason, String? code) onFallback;

  final _playback = MirrorPlayback();
  final _clock = Stopwatch()..start();
  bool get live => _playback.codec == MirrorCodec.h264;
  Duration? _liveAt, _endedAt;

  /// How long this attempt showed H.264 pictures (zero if it never did).
  Duration get livedFor {
    final since = _liveAt;
    if (since == null) return Duration.zero;
    return (_endedAt ?? _clock.elapsed) - since;
  }
  RTCVideoRenderer? renderer;
  RTCPeerConnection? _peer;
  String? _id;
  bool _closed = false;
  bool _zoomed = false;
  bool _rendered = false;
  bool _remoteDescriptionSet = false;
  final _pendingIce = <RTCIceCandidate>[];
  final _earlySignals = <Map<String, dynamic>>[];
  Future<void> _signalQueue = Future.value();
  void Function()? _unsubscribe;
  Timer? _watchdog;
  Future<MirrorRtcCounters?>? _statsInFlight;
  MirrorRtcCounters? _lastCounters;
  Duration? _lastFeedbackAt;

  Future<void> start() async {
    _playback.begin(_clock.elapsed);
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    try {
      final video = RTCVideoRenderer();
      try {
        await video.initialize();
      } catch (_) {
        await _release(video.dispose());
        rethrow;
      }
      if (_closed) {
        await _release(video.dispose());
        return;
      }
      renderer = video;
      video.onFirstFrameRendered = () {
        _rendered = true;
        _firstPicture();
      };
      video.onResize = () {
        if (kIsWeb) _rendered = true;
        _firstPicture();
      };
      onChanged();

      final peer = await createPeerConnection({
        'sdpSemantics': 'unified-plan',
        'iceServers': [
          {
            'urls': ['stun:stun.l.google.com:19302'],
          },
        ],
      });
      if (_closed) {
        await _release(peer.dispose());
        return;
      }
      _peer = peer;
      peer.onTrack = (event) {
        if (_closed || event.track.kind != 'video' || event.streams.isEmpty) {
          return;
        }
        unawaited(_attachTrack(video, event));
      };
      peer.onConnectionState = (state) {
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          _fail('WebRTC connection ended');
        } else if (state ==
            RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          _send({'kind': 'keyframe'});
        }
      };
      peer.onIceCandidate = (candidate) {
        if (candidate.candidate?.isNotEmpty != true) return;
        _send({
          'kind': 'ice',
          'candidate': candidate.candidate,
          'sdpMLineIndex': candidate.sdpMLineIndex ?? 0,
        });
      };

      // Subscribe before start so a fast offer or startup error cannot race
      // past the RPC reply or native peer initialization.
      _unsubscribe = client.subscribe('webrtc-signal', _onSignal);
      final reply = await client.requestMap('webrtc.start', {
        'streamId': streamId,
        'sessionId': ?sessionId,
      }, MirrorPlayback.startTimeout);
      final id = reply['webrtcId'];
      if (_closed) {
        if (id is String) client.notify('webrtc.stop', {'webrtcId': id});
        return;
      }
      if (reply['available'] != true || id is! String) {
        _fail(
          reply['reason']?.toString() ?? 'H.264 is unavailable on the host',
          'unavailable',
        );
        return;
      }
      _id = id;
      for (final message in _earlySignals) {
        _onSignal(message);
      }
      _earlySignals.clear();
    } catch (_) {
      _fail('Could not start H.264 playback');
    }
  }

  Future<void> _attachTrack(RTCVideoRenderer video, RTCTrackEvent event) async {
    try {
      await video.setSrcObject(
        stream: event.streams.first,
        trackId: event.track.id,
      );
    } catch (_) {
      _fail('Could not attach the H.264 video track');
    }
  }

  void _onSignal(Map<String, dynamic> message) {
    if (_closed) return;
    if (_id == null) {
      if (_earlySignals.length < 128) _earlySignals.add(message);
      return;
    }
    if (message['webrtcId'] != _id) return;
    final data = message['data'];
    if (data is! Map<String, dynamic>) return;
    if (data['kind'] == 'error') {
      _fail(
        data['reason']?.toString() ?? 'H.264 stream ended',
        data['code'] as String?,
      );
      return;
    }
    _signalQueue = _signalQueue.then((_) => _handleSignal(data));
  }

  Future<void> _handleSignal(Map<String, dynamic> data) async {
    final peer = _peer;
    if (_closed || peer == null) return;
    if (data['kind'] == 'offer' && data['sdp'] is String) {
      try {
        await peer.setRemoteDescription(
          RTCSessionDescription(data['sdp'] as String, 'offer'),
        );
        if (_closed) return;
        _remoteDescriptionSet = true;
        final answer = await peer.createAnswer();
        if (_closed) return;
        await peer.setLocalDescription(answer);
        _send({'kind': 'answer', 'sdp': answer.sdp});
        for (final candidate in _pendingIce) {
          if (_closed) return;
          await _addIce(peer, candidate);
        }
        _pendingIce.clear();
      } catch (_) {
        _fail('Could not negotiate H.264 playback');
      }
    } else if (data['kind'] == 'ice' && data['candidate'] is String) {
      final candidate = RTCIceCandidate(
        data['candidate'] as String,
        null,
        (data['sdpMLineIndex'] as num?)?.toInt() ?? 0,
      );
      if (_remoteDescriptionSet) {
        await _addIce(peer, candidate);
      } else if (_pendingIce.length < 128) {
        _pendingIce.add(candidate);
      }
    }
  }

  Future<void> _addIce(
    RTCPeerConnection peer,
    RTCIceCandidate candidate,
  ) async {
    try {
      await peer.addCandidate(candidate);
    } catch (_) {
      // One unusable candidate can coexist with other working network paths.
    }
  }

  void _firstPicture() {
    final video = renderer;
    if (_closed ||
        !_rendered ||
        video == null ||
        video.videoWidth <= 0 ||
        video.videoHeight <= 0 ||
        !_playback.firstPicture(_clock.elapsed)) {
      return;
    }
    _liveAt = _clock.elapsed;
    _send({'kind': 'playing'});
    if (_zoomed) _send({'kind': 'zoom', 'zoomed': true});
    onChanged();
  }

  void zoom(bool value) {
    if (value == _zoomed) return;
    _zoomed = value;
    if (live) _send({'kind': 'zoom', 'zoomed': value});
  }

  Future<void> _tick() async {
    if (_closed) return;
    if (live) {
      final counters = await _readStats();
      if (_closed) return;
      final last = _lastCounters;
      if (counters != null) {
        _lastCounters = counters;
        if (last == null ||
            counters.id != last.id ||
            counters.frames > last.frames) {
          _playback.pictureProgress(counters.at);
        }
        final rates = last == null ? null : counters.since(last);
        if (rates != null) {
          onRates(rates);
          if (_lastFeedbackAt == null ||
              counters.at - _lastFeedbackAt! >=
                  const Duration(milliseconds: 1850)) {
            _lastFeedbackAt = counters.at;
            _send({
              'kind': 'stats',
              'fps': rates.fps,
              'loss': rates.loss,
              'jitterMs': rates.jitterMs,
              'rttMs': ?rates.rttMs,
            });
          }
        }
      }
    }
    if (_playback.expired(_clock.elapsed)) {
      _fail(
        live ? 'H.264 playback stalled' : 'H.264 did not deliver a picture',
      );
    }
  }

  Future<MirrorRtcCounters?> _readStats() => _statsInFlight ??= _collectStats()
      .whenComplete(() => _statsInFlight = null);

  Future<MirrorRtcCounters?> _collectStats() async {
    try {
      final stats = await _peer?.getStats().timeout(
        const Duration(milliseconds: 750),
      );
      if (stats == null) return null;
      StatsReport? video;
      double? rttMs;
      for (final report in stats) {
        final values = report.values;
        if (report.type == 'inbound-rtp' &&
            (values['kind'] ?? values['mediaType']) == 'video' &&
            values['framesDecoded'] is num) {
          if (video == null ||
              (values['framesDecoded'] as num) >
                  (video.values['framesDecoded'] as num)) {
            video = report;
          }
        }
        if (report.type == 'candidate-pair' &&
            values['nominated'] == true &&
            values['state'] == 'succeeded') {
          rttMs = (values['currentRoundTripTime'] as num?)?.toDouble();
          if (rttMs != null) rttMs *= 1000;
        }
      }
      if (video == null) return null;
      final values = video.values;
      return MirrorRtcCounters(
        at: _clock.elapsed,
        id: video.id,
        bytes: (values['bytesReceived'] as num?)?.toInt() ?? 0,
        frames: (values['framesDecoded'] as num).toInt(),
        received: (values['packetsReceived'] as num?)?.toInt() ?? 0,
        lost: (values['packetsLost'] as num?)?.toInt() ?? 0,
        jitterMs: ((values['jitter'] as num?)?.toDouble() ?? 0) * 1000,
        rttMs: rttMs,
      );
    } catch (_) {
      return null;
    }
  }

  /// Approximate time to a later decoded picture. Sampling cannot determine
  /// whether the click caused a change in an arbitrary app.
  Future<double?> estimateTapToFrame() async {
    final started = _clock.elapsed;
    final before = await _readStats();
    if (before == null) return null;
    while (!_closed && _clock.elapsed - started < const Duration(seconds: 1)) {
      await Future<void>.delayed(const Duration(milliseconds: 45));
      if (_closed) return null;
      final next = await _readStats();
      if (next != null && next.id == before.id && next.frames > before.frames) {
        return (next.at - started).inMicroseconds / 1000;
      }
    }
    return null;
  }

  void _send(Map<String, dynamic> data) {
    if (!_closed && _id != null) {
      client.notify('webrtc.signal', {'webrtcId': _id, 'data': data});
    }
  }

  void _fail(String reason, [String? code]) {
    if (_closed) return;
    dispose();
    onFallback(reason, code);
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _endedAt = _clock.elapsed;
    _playback.fallback();
    _watchdog?.cancel();
    _unsubscribe?.call();
    if (_id != null) client.notify('webrtc.stop', {'webrtcId': _id});
    final video = renderer;
    renderer = null;
    if (video != null) {
      video.onFirstFrameRendered = null;
      video.onResize = null;
      unawaited(_release(video.dispose()));
    }
    final peer = _peer;
    _peer = null;
    if (peer != null) unawaited(_release(peer.dispose()));
  }

  Future<void> _release(Future<void> operation) async {
    try {
      await operation;
    } catch (_) {
      // The native resource may already have gone with its peer.
    }
  }
}
