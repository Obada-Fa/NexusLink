// App/desktop mirror viewport. Port of apps/mobile-client/src/app/mirror/page.tsx:
// auto (launch →) adopt → capture → render binary frames, with direct-
// manipulation touch via the ported GestureEngine (lib/src/gestures/).

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../gestures/gesture_engine.dart';
import '../rpc/models.dart';
import '../rpc/rpc_client.dart';
import '../state/connection.dart';
import '../util/mjpeg_sink.dart';
import '../widgets/mirror_frame_painter.dart';
import '../widgets/not_connected_view.dart';
import 'mirror_fit.dart';

/// What to show: a virtual app session (sessionAppId launches a new one,
/// sessionId re-attaches), an existing window (windowId), an app to launch on
/// the real desktop (appId), or none of those → the full desktop.
class MirrorTarget {
  final String? windowId;
  final String? appId;
  final String? wmClass;
  final String? title;

  /// Launch this app into a NEW phone-shaped virtual display on the PC.
  final String? sessionAppId;

  /// Re-attach to an already-running virtual session.
  final String? sessionId;

  /// Whether this target is a web browser (built-in or desktop-adopted).
  final bool isBrowser;

  const MirrorTarget({
    this.windowId,
    this.appId,
    this.wmClass,
    this.title,
    this.sessionAppId,
    this.sessionId,
    this.isBrowser = false,
  });

  bool get isVirtual => sessionAppId != null || sessionId != null;
}

enum MirrorPhase { launching, adopting, streaming, error }

class MirrorScreen extends ConsumerStatefulWidget {
  const MirrorScreen({super.key, required this.target});

  final MirrorTarget target;

  @override
  ConsumerState<MirrorScreen> createState() => _MirrorScreenState();
}

class _MirrorScreenState extends ConsumerState<MirrorScreen>
    with SingleTickerProviderStateMixin {
  MirrorPhase _phase = MirrorPhase.launching;
  String _errorMsg = '';
  final _decoded = ValueNotifier<ui.Image?>(null);
  MirrorFrameSink? _sink;
  CaptureRegion? _region;
  int _streamKey = -1;
  String? _streamId;
  String? _windowId;
  int _frameCount = 0;
  int _fps = 0;
  double _lastDecodeMs = 0;
  bool _keyboardOpen = false;
  bool _mouseMode = false;
  bool _chromeVisible = true;
  Offset _canvasPan = Offset.zero;
  double _canvasScale = 1;
  Offset? _cursorHost;
  Size _viewSize = Size.zero;
  int? _queuedDragX;
  int? _queuedDragY;
  final _pointerView = ValueNotifier<Offset?>(null);

  // Virtual session state (Tier 1).
  AppSessionInfo? _session;
  final List<void Function()> _unsubs = [];

  // WebRTC upgrade path: H.264/Opus from the host's GStreamer agent. MJPEG
  // keeps streaming until the RTC track renders, then it is stopped.
  String? _webrtcId;
  RTCPeerConnection? _pc;
  RTCVideoRenderer? _renderer;
  bool _rtcLive = false;

  final _kbController = TextEditingController();
  final _kbFocus = FocusNode();
  StreamSubscription<MirrorFrame>? _frameSub;
  Timer? _fpsTimer;
  Timer? _chromeHideTimer;
  bool _started = false;

  // Gesture engine + a single monotonic clock shared by touch events and the
  // inertia ticker (they must agree on "now" or velocity math is wrong).
  late final GestureEngine _engine;
  late final Ticker _ticker;
  final _clock = Stopwatch();
  final _activePointers = <int, Offset>{};

  RpcClient? get _client => ref.read(activeClientProvider);

  double get _nowMs => _clock.elapsedMicroseconds / 1000.0;

  bool get _fillFrame => mirrorFillsView(
    isVirtual: widget.target.isVirtual,
    hasWindow: _windowId != null,
  );

  ScaleFit get _scaleFit => mirrorScaleFit(fill: _fillFrame);

  BoxFit get _boxFit => mirrorBoxFit(fill: _fillFrame);

  @override
  void initState() {
    super.initState();
    _clock.start();
    _engine = GestureEngine(onGesture: _onGesture);
    _ticker = createTicker((_) {
      // Drive long-press evaluation + inertia on a shared clock. Keep ticking
      // while streaming so a pending long-press fires even without new frames.
      _engine.tick(_nowMs);
      _flushQueuedDrag();
    })..start();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    if (_started) return;
    _started = true;
    final client = _client;
    if (client == null) {
      setState(() {
        _phase = MirrorPhase.error;
        _errorMsg = 'Not connected to the PC.';
        _chromeVisible = true;
      });
      return;
    }
    try {
      // Virtual session: the app runs on its own headless display sized
      // EXACTLY like this phone. Nothing moves on the PC's real desktop.
      if (widget.target.isVirtual) {
        await _startVirtual(client);
        return;
      }

      var windowId = widget.target.windowId;

      // Launch flow: start the app, poll window.list until its window appears.
      if (windowId == null && widget.target.appId != null) {
        setState(() => _phase = MirrorPhase.launching);
        final launched = await client.requestMap('apps.launch', {
          'appId': widget.target.appId,
        });
        if (launched['ok'] != true) {
          throw 'The host could not launch this app.';
        }
        final nCls = normClass(
          widget.target.wmClass ??
              (launched['wmClass'] as String?) ??
              widget.target.appId!,
        );
        final deadline = DateTime.now().add(const Duration(seconds: 25));
        while (DateTime.now().isBefore(deadline) && mounted) {
          await Future.delayed(const Duration(milliseconds: 800));
          final wins = await client.requestList('window.list');
          for (final raw in wins) {
            final w = WindowInfo.fromJson(raw as Map<String, dynamic>);
            final nWin = normClass(w.wmClass.split('.').last);
            if ((w.appId != null && w.appId == widget.target.appId) ||
                (nWin.length >= 4 &&
                    nCls.length >= 4 &&
                    (nCls.contains(nWin) || nWin.contains(nCls)))) {
              windowId = w.windowId;
              break;
            }
          }
          if (windowId != null) break;
        }
        if (windowId == null) {
          throw 'The app started but no window appeared. Go back and tap it under "Open on your PC".';
        }
      }
      if (!mounted) return;

      var params = <String, dynamic>{'quality': 'medium', 'fps': 24};
      if (windowId != null) {
        setState(() => _phase = MirrorPhase.adopting);
        _windowId = windowId;
        final media = MediaQuery.of(context);
        await client.request('window.adopt', {
          'windowId': windowId,
          'viewportW': media.size.width.round(),
          'viewportH': media.size.height.round(),
        });
        params['windowId'] = windowId;
      }

      final cap = await client.requestMap('screen.startCapture', params);
      _streamId = cap['streamId'] as String?;
      _streamKey = (cap['streamKey'] as num?)?.toInt() ?? -1;
      if (cap['region'] != null) {
        _setRegion(
          CaptureRegion.fromJson(cap['region'] as Map<String, dynamic>),
        );
      }

      _attachMjpeg(client);
      _unsubs.add(
        client.subscribe('stream-region', (msg) {
          if (msg['streamId'] != _streamId) return;
          final r = msg['region'];
          if (r is Map<String, dynamic> && mounted) {
            _setRegion(CaptureRegion.fromJson(r));
          }
        }),
      );
      _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _fps = _frameCount);
        final sid = _streamId;
        if (sid != null && !_rtcLive) {
          _client?.notify('screen.reportStats', {
            'streamId': sid,
            'fps': _frameCount,
            'frameAgeMs': _lastDecodeMs.round(),
          });
        }
        _frameCount = 0;
      });

      if (mounted) setState(() => _phase = MirrorPhase.streaming);
      _scheduleHideChrome();
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = MirrorPhase.error;
          _errorMsg = friendlyLaunchError(e);
          _chromeVisible = true;
        });
      }
    }
  }

  Future<void> _startVirtual(RpcClient client) async {
    setState(() => _phase = MirrorPhase.launching);
    final readyIds = <String>{};
    _unsubs.add(
      client.subscribe('app-session-ready', (msg) {
        final sid = msg['sessionId'];
        if (sid is String) readyIds.add(sid);
      }),
    );

    AppSessionInfo session;
    if (widget.target.sessionId != null) {
      final raw = await client.requestList('appSession.list');
      final hit = raw
          .map((e) => AppSessionInfo.fromJson(e as Map<String, dynamic>))
          .where(
            (s) =>
                s.sessionId == widget.target.sessionId && s.status == 'running',
          )
          .toList();
      if (hit.isEmpty) {
        throw 'That app session has ended. Launch the app again.';
      }
      session = hit.first;
    } else {
      final media = MediaQuery.of(context);
      // Full phone stage: chrome overlays the stream, so the virtual monitor
      // must match the whole screen or the picture letterboxes vertically.
      var w = media.size.width;
      var h = media.size.height;
      if (h < 200) h = media.size.height;
      // Phone-OS virtual monitors are portrait; the host letterboxes if you
      // rotate. Sending landscape here is what produced a strip at the top.
      if (w > h) {
        final tmp = w;
        w = h;
        h = tmp;
      }
      final created = await client.requestMap('appSession.create', {
        'appId': widget.target.sessionAppId,
        'width': w.round(),
        'height': h.round(),
        'dpr': media.devicePixelRatio,
      }, const Duration(seconds: 45));
      session = AppSessionInfo.fromJson(created);
      await _waitForSessionReady(readyIds, session.sessionId);
    }
    if (!mounted) return;
    _session = session;
    // Map touch to the framebuffer immediately — don't wait for capture,
    // and don't leave the engine on its 1920×1080 default.
    _setRegion(CaptureRegion(0, 0, session.width, session.height));

    await _beginCapture(client, {
      'quality': 'medium',
      'fps': 24,
      'sessionId': session.sessionId,
    });
    _unsubs.add(
      client.subscribe('app-session-update', (msg) {
        final s = msg['session'];
        if (s is! Map<String, dynamic>) return;
        if (s['sessionId'] != _session?.sessionId) return;
        if (s['status'] == 'exited' && mounted) {
          setState(() {
            _phase = MirrorPhase.error;
            _errorMsg = 'The app has exited.';
            _chromeVisible = true;
          });
        }
      }),
    );
    if (mounted) setState(() => _phase = MirrorPhase.streaming);
    _scheduleHideChrome();
    if (shouldUpgradeWebrtc(isVirtual: true, sessionId: session.sessionId)) {
      unawaited(_tryWebrtc(client, session.sessionId));
    }
  }

  Future<void> _waitForSessionReady(
    Set<String> readyIds,
    String sessionId,
  ) async {
    if (readyIds.contains(sessionId)) return;
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (mounted &&
        !readyIds.contains(sessionId) &&
        DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> _beginCapture(
    RpcClient client,
    Map<String, dynamic> params,
  ) async {
    final cap = await client.requestMap('screen.startCapture', params);
    _streamId = cap['streamId'] as String?;
    _streamKey = (cap['streamKey'] as num?)?.toInt() ?? -1;
    if (cap['region'] != null) {
      _setRegion(CaptureRegion.fromJson(cap['region'] as Map<String, dynamic>));
    }
    _attachMjpeg(client);
    _unsubs.add(
      client.subscribe('stream-region', (msg) {
        if (msg['streamId'] != _streamId) return;
        final r = msg['region'];
        if (r is Map<String, dynamic> && mounted) {
          _setRegion(CaptureRegion.fromJson(r));
        }
      }),
    );
    _fpsTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _fps = _frameCount);
      final sid = _streamId;
      if (sid != null && !_rtcLive) {
        _client?.notify('screen.reportStats', {
          'streamId': sid,
          'fps': _frameCount,
          'frameAgeMs': _lastDecodeMs.round(),
        });
      }
      _frameCount = 0;
    });
  }

  void _attachMjpeg(RpcClient client) {
    _sink?.dispose();
    _sink = MirrorFrameSink(
      onDecodeAge: (ms) => _lastDecodeMs = ms.toDouble(),
      onDisplayed: () => _frameCount++,
      onImage: (img) {
        if (!mounted || _rtcLive) {
          img.dispose();
          return;
        }
        final old = _decoded.value;
        _decoded.value = img;
        old?.dispose();
      },
    );
    _syncDecodeWidth();
    _frameSub?.cancel();
    _frameSub = client.frames.listen((f) {
      if (_rtcLive || f.streamKey != _streamKey) return;
      _sink?.pushJpeg(f.jpeg);
    });
  }

  void _syncDecodeWidth() {
    if (!mounted) return;
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1;
    final w = _viewSize.width * dpr;
    if (w >= 32) _sink?.targetWidth = w.round();
  }

  void _stopMjpeg() {
    _frameSub?.cancel();
    _frameSub = null;
    _sink?.dispose();
    _sink = null;
    final old = _decoded.value;
    _decoded.value = null;
    old?.dispose();
    final id = _streamId;
    _streamId = null;
    if (id != null) _client?.notify('screen.stopCapture', {'streamId': id});
  }

  /// Best-effort WebRTC upgrade for virtual sessions only. Failures leave MJPEG.
  Future<void> _tryWebrtc(RpcClient client, String? sessionId) async {
    if (!shouldUpgradeWebrtc(
      isVirtual: widget.target.isVirtual,
      sessionId: sessionId,
    )) {
      return;
    }
    try {
      final res = await client.requestMap('webrtc.start', {
        'sessionId': ?sessionId,
        'fps': 24,
      });
      if (res['available'] != true || res['webrtcId'] is! String) return;
      _webrtcId = res['webrtcId'] as String;

      final renderer = RTCVideoRenderer();
      await renderer.initialize();
      if (!mounted) {
        renderer.dispose();
        return;
      }
      _renderer = renderer;

      final pc = await createPeerConnection({
        'sdpSemantics': 'unified-plan',
        'iceServers': [
          {
            'urls': ['stun:stun.l.google.com:19302'],
          },
        ],
      });
      _pc = pc;
      pc.onTrack = (event) {
        if (event.streams.isEmpty) return;
        renderer.srcObject = event.streams[0];
        if (!mounted) return;
        setState(() => _rtcLive = true);
        _stopMjpeg();
      };
      pc.onIceCandidate = (c) {
        if (c.candidate == null || _webrtcId == null) return;
        client.notify('webrtc.signal', {
          'webrtcId': _webrtcId,
          'data': {
            'kind': 'ice',
            'candidate': c.candidate,
            'sdpMLineIndex': c.sdpMLineIndex ?? 0,
          },
        });
      };

      _unsubs.add(
        client.subscribe('webrtc-signal', (msg) {
          if (msg['webrtcId'] != _webrtcId) return;
          final data = msg['data'];
          if (data is! Map) return;
          unawaited(_onWebrtcSignal(Map<String, dynamic>.from(data)));
        }),
      );
    } catch (_) {
      // Native WebRTC isn't available on this platform; MJPEG stays up.
    }
  }

  Future<void> _onWebrtcSignal(Map<String, dynamic> data) async {
    final pc = _pc;
    final client = _client;
    final webrtcId = _webrtcId;
    if (pc == null || client == null || webrtcId == null) return;
    try {
      final kind = data['kind'];
      if (kind == 'offer' && data['sdp'] is String) {
        await pc.setRemoteDescription(
          RTCSessionDescription(data['sdp'] as String, 'offer'),
        );
        final answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        client.notify('webrtc.signal', {
          'webrtcId': webrtcId,
          'data': {'kind': 'answer', 'sdp': answer.sdp},
        });
      } else if (kind == 'ice' && data['candidate'] is String) {
        await pc.addCandidate(
          RTCIceCandidate(
            data['candidate'] as String,
            '',
            (data['sdpMLineIndex'] as num?)?.toInt() ?? 0,
          ),
        );
      }
    } catch (_) {
      // Drop a bad candidate; the next one may still connect.
    }
  }

  Map<String, dynamic> _sid([Map<String, dynamic>? extra]) {
    final sid = _session?.sessionId;
    return {...?extra, 'sessionId': ?sid};
  }

  /// Touch space IS the captured region: the engine maps view→region-local, and
  /// we add the region origin to reach absolute host coordinates for injection.
  void _setRegion(CaptureRegion r) {
    _region = r;
    _engine.setHostDimensions(r.width.toDouble(), r.height.toDouble());
    _engine.setFit(_scaleFit);
    _cursorHost ??= Offset(r.width / 2, r.height / 2);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frameSub?.cancel();
    _fpsTimer?.cancel();
    _chromeHideTimer?.cancel();
    _sink?.dispose();
    final leftover = _decoded.value;
    _decoded.value = null;
    leftover?.dispose();
    _decoded.dispose();
    _pointerView.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    for (final u in _unsubs) {
      u();
    }
    _unsubs.clear();
    _kbController.dispose();
    _kbFocus.dispose();
    final client = _client;
    final id = _streamId;
    final win = _windowId;
    final webrtcId = _webrtcId;
    if (client != null) {
      if (id != null) client.notify('screen.stopCapture', {'streamId': id});
      if (win != null) client.notify('window.release', {'windowId': win});
      if (webrtcId != null)
        client.notify('webrtc.stop', {'webrtcId': webrtcId});
    }
    // Home keeps the virtual session alive (like backgrounding a phone app).
    unawaited(_pc?.close() ?? Future.value());
    _renderer?.dispose();
    super.dispose();
  }

  void _closeSession() {
    final client = _client;
    final sid = _session?.sessionId;
    if (client != null && sid != null) {
      client.notify('appSession.close', {'sessionId': sid});
    }
    Navigator.of(context).maybePop();
  }

  // --- gesture engine → input RPC -------------------------------------------

  void _onGesture(GestureEvent e) {
    final client = _client;
    if (client == null) return;
    final ox = _region?.x ?? 0;
    final oy = _region?.y ?? 0;
    int hx(double x) => (x + ox).round();
    int hy(double y) => (y + oy).round();

    switch (e) {
      case TapEvent():
        _cursorHost = Offset(e.x, e.y);
        _syncPointerFromHost();
        client.notify(
          'input.mouseClick',
          _sid({'button': 'left', 'x': hx(e.x), 'y': hy(e.y)}),
        );
      case DoubleTapEvent():
        _cursorHost = Offset(e.x, e.y);
        _syncPointerFromHost();
        final x = hx(e.x), y = hy(e.y);
        client.notify(
          'input.mouseClick',
          _sid({'button': 'left', 'x': x, 'y': y}),
        );
        Future.delayed(const Duration(milliseconds: 50), () {
          client.notify(
            'input.mouseClick',
            _sid({'button': 'left', 'x': x, 'y': y}),
          );
        });
      case ContextEvent():
        HapticFeedback.mediumImpact();
        _cursorHost = Offset(e.x, e.y);
        _syncPointerFromHost();
        client.notify(
          'input.mouseClick',
          _sid({'button': 'right', 'x': hx(e.x), 'y': hy(e.y)}),
        );
      case MiddleClickEvent():
        client.notify(
          'input.mouseClick',
          _sid({'button': 'middle', 'x': hx(e.x), 'y': hy(e.y)}),
        );
      case ScrollEvent():
        client.notify(
          'input.mouseScroll',
          _sid({
            'deltaX': e.deltaX,
            'deltaY': e.deltaY,
            if (!_mouseMode) 'x': hx(e.x),
            if (!_mouseMode) 'y': hy(e.y),
          }),
        );
      case MouseMoveEvent():
        client.notify('input.mouseMove', _sid({'dx': e.dx, 'dy': e.dy}));
      case DragStartEvent():
        _cursorHost = Offset(e.x, e.y);
        _syncPointerFromHost();
        client.notify(
          'input.buttonDown',
          _sid({'button': 'left', 'x': hx(e.x), 'y': hy(e.y)}),
        );
      case DragMoveEvent():
        _queuedDragX = hx(e.x);
        _queuedDragY = hy(e.y);
        _cursorHost = Offset(e.x, e.y);
        _syncPointerFromHost();
      case DragEndEvent():
        _flushQueuedDrag();
        client.notify(
          'input.buttonUp',
          _sid({'button': 'left', 'x': hx(e.x), 'y': hy(e.y)}),
        );
      case ZoomEvent():
        if (_mouseMode) {
          setState(() {
            _canvasScale = (_canvasScale * (1 + e.scale)).clamp(1.0, 4.0);
          });
          _syncCanvasTransform();
        } else {
          client.notify(
            'input.mouseScroll',
            _sid({
              'deltaX': 0,
              'deltaY': (-e.scale * 160).round(),
              'x': hx(e.x),
              'y': hy(e.y),
              'modifiers': ['ctrl'],
            }),
          );
        }
      case CanvasPanEvent():
        setState(() => _canvasPan += Offset(e.dx, e.dy));
        _syncCanvasTransform();
    }
  }

  void _syncCanvasTransform() {
    _engine.setCanvasTransform(_canvasPan.dx, _canvasPan.dy, _canvasScale);
  }

  void _flushQueuedDrag() {
    final x = _queuedDragX;
    final y = _queuedDragY;
    if (x == null || y == null) return;
    _queuedDragX = null;
    _queuedDragY = null;
    _client?.notify('input.mouseMoveAbs', _sid({'x': x, 'y': y}));
  }

  List<TouchPoint> get _touches => _activePointers.entries
      .map((e) => TouchPoint(e.key, e.value.dx, e.value.dy))
      .toList();

  void _syncPointerFromHost() {
    final region = _region;
    final cursor = _cursorHost;
    if (region == null || cursor == null || _viewSize == Size.zero) return;
    final mapped = hostToView(
      cursor.dx,
      cursor.dy,
      _viewSize.width,
      _viewSize.height,
      region.width.toDouble(),
      region.height.toDouble(),
      _scaleFit,
    );
    _pointerView.value = Offset(
      mapped.x * _canvasScale + _canvasPan.dx,
      mapped.y * _canvasScale + _canvasPan.dy,
    );
  }

  void _showChrome() {
    _chromeHideTimer?.cancel();
    if (!_chromeVisible && mounted) setState(() => _chromeVisible = true);
    _scheduleHideChrome();
  }

  void _scheduleHideChrome() {
    _chromeHideTimer?.cancel();
    if (_phase != MirrorPhase.streaming) return;
    _chromeHideTimer = Timer(const Duration(milliseconds: 1600), () {
      if (!mounted || _keyboardOpen) return;
      setState(() => _chromeVisible = false);
    });
  }

  void _onPointerDown(PointerDownEvent e) {
    _activePointers[e.pointer] = e.localPosition;
    _pointerView.value = e.localPosition;
    if (!_chromeVisible && e.localPosition.dy < 28) _showChrome();
    _engine.onTouchStart(_touches, _nowMs);
  }

  void _onPointerMove(PointerMoveEvent e) {
    _activePointers[e.pointer] = e.localPosition;
    _pointerView.value = e.localPosition;
    _engine.onTouchMove(_touches, _nowMs);
  }

  void _onPointerUp(int pointer) {
    _activePointers.remove(pointer);
    // onTouchEnd receives the touches STILL down, matching TouchEvent.touches.
    _engine.onTouchEnd(_touches, _nowMs);
  }

  static final _browserRe = RegExp(
    r'brave|chrom(e|ium)|msedge|microsoft.edge|nexus\.chrome',
    caseSensitive: false,
  );

  bool get _isBrowserSession {
    if (widget.target.isBrowser) return true;
    final sessionAppId = widget.target.sessionAppId ?? _session?.appId ?? '';
    if (_browserRe.hasMatch(sessionAppId)) return true;
    final appId = widget.target.appId ?? '';
    final wmClass = widget.target.wmClass ?? '';
    return _browserRe.hasMatch(appId) || _browserRe.hasMatch(wmClass);
  }

  void _sendKey(String key) =>
      _client?.notify('input.keyEvent', _sid({'key': key}));

  void _sendKeyMods(String key, List<String> mods) =>
      _client?.notify('input.keyEvent', _sid({'key': key, 'modifiers': mods}));

  void _toggleKeyboard() {
    setState(() => _keyboardOpen = !_keyboardOpen);
    if (_keyboardOpen) {
      _kbFocus.requestFocus();
      _chromeHideTimer?.cancel();
    } else {
      _scheduleHideChrome();
    }
  }

  void _focusBrowserAddressBar() {
    _client?.notify(
      'input.keyEvent',
      _sid({
        'key': 'l',
        'modifiers': ['ctrl'],
      }),
    );
    setState(() => _keyboardOpen = true);
    _kbFocus.requestFocus();
    _chromeHideTimer?.cancel();
  }

  void _onKbChanged(String value) {
    if (value.isEmpty) return;
    _client?.notify('input.typeText', _sid({'text': value}));
    _kbController.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: _stage()),
          if (_chromeVisible)
            Positioned(top: 0, left: 0, right: 0, child: _chromeBar()),
          if (!_chromeVisible && _phase == MirrorPhase.streaming)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 28,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _showChrome,
                onVerticalDragUpdate: (d) {
                  if (d.delta.dy > 4) _showChrome();
                },
              ),
            ),
          if (_keyboardOpen)
            Positioned(left: 0, right: 0, bottom: 0, child: _keyboardBar()),
        ],
      ),
    );
  }

  Widget _chromeBar() {
    return _isBrowserSession ? _browserBar() : _genericBar();
  }

  Widget _browserBar() {
    final title = widget.target.title ?? _session?.name ?? 'Browser';
    return Material(
      color: const Color(0xCC0A0A0F),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.home_outlined, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              IconButton(
                tooltip: 'Back',
                icon: const Icon(
                  Icons.arrow_back_ios_new,
                  size: 18,
                  color: Colors.white,
                ),
                onPressed: () => _sendKeyMods('Left', ['alt']),
              ),
              IconButton(
                tooltip: 'Forward',
                icon: const Icon(
                  Icons.arrow_forward_ios,
                  size: 18,
                  color: Colors.white,
                ),
                onPressed: () => _sendKeyMods('Right', ['alt']),
              ),
              Expanded(child: _urlBarTile(title)),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh, color: Colors.white),
                onPressed: () => _sendKey('F5'),
              ),
              IconButton(
                tooltip: _mouseMode
                    ? 'Mouse mode: pan the picture, tap to click'
                    : 'Touch mode: tap where you press, swipe to scroll',
                icon: Icon(
                  _mouseMode ? Icons.mouse : Icons.touch_app,
                  color: _mouseMode ? const Color(0xFF2A6AFF) : Colors.white,
                ),
                onPressed: () {
                  setState(() {
                    _mouseMode = !_mouseMode;
                    if (!_mouseMode) {
                      _canvasPan = Offset.zero;
                      _canvasScale = 1;
                    }
                  });
                  _engine.setMode(
                    _mouseMode ? GestureMode.mouse : GestureMode.direct,
                  );
                  _syncCanvasTransform();
                  _scheduleHideChrome();
                },
              ),
              IconButton(
                icon: Icon(
                  Icons.keyboard,
                  color: _keyboardOpen ? const Color(0xFF2A6AFF) : Colors.white,
                ),
                onPressed: _toggleKeyboard,
              ),
              if (_session != null)
                IconButton(
                  tooltip: 'Quit this app',
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: _closeSession,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _urlBarTile(String appTitle) {
    return GestureDetector(
      onTap: _focusBrowserAddressBar,
      child: Container(
        height: 32,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E2E),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF2E2E44)),
        ),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            const Icon(Icons.lock_outline, size: 12, color: Colors.white38),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                appTitle,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF2A6AFF).withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(3),
                border: Border.all(
                  color: const Color(0xFF2A6AFF).withValues(alpha: 0.5),
                  width: 0.8,
                ),
              ),
              child: const Text(
                'BETA',
                style: TextStyle(
                  fontSize: 7.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: Color(0xFF7AA2FF),
                ),
              ),
            ),
            const Icon(Icons.search, size: 14, color: Colors.white38),
          ],
        ),
      ),
    );
  }

  Widget _genericBar() {
    final title =
        widget.target.title ??
        _session?.name ??
        (widget.target.windowId != null ||
                widget.target.appId != null ||
                widget.target.isVirtual
            ? 'App'
            : 'Desktop');
    return Material(
      color: const Color(0xCC0A0A0F),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.home_outlined, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              Expanded(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        _phase == MirrorPhase.streaming
                            ? '$title · ${_rtcLive ? 'live' : '$_fps fps'}'
                            : title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1.5,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A6AFF).withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: const Color(0xFF2A6AFF).withValues(alpha: 0.5),
                          width: 0.8,
                        ),
                      ),
                      child: const Text(
                        'BETA',
                        style: TextStyle(
                          fontSize: 8.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: Color(0xFF7AA2FF),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: _mouseMode
                    ? 'Mouse mode: pan the picture, tap to click'
                    : 'Touch mode: tap where you press, swipe to scroll',
                icon: Icon(
                  _mouseMode ? Icons.mouse : Icons.touch_app,
                  color: _mouseMode ? const Color(0xFF2A6AFF) : Colors.white,
                ),
                onPressed: () {
                  setState(() {
                    _mouseMode = !_mouseMode;
                    if (!_mouseMode) {
                      _canvasPan = Offset.zero;
                      _canvasScale = 1;
                    }
                  });
                  _engine.setMode(
                    _mouseMode ? GestureMode.mouse : GestureMode.direct,
                  );
                  _syncCanvasTransform();
                  _scheduleHideChrome();
                },
              ),
              IconButton(
                icon: Icon(
                  Icons.keyboard,
                  color: _keyboardOpen ? const Color(0xFF2A6AFF) : Colors.white,
                ),
                onPressed: _toggleKeyboard,
              ),
              if (_session != null)
                IconButton(
                  tooltip: 'Quit this app',
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: _closeSession,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stage() {
    switch (_phase) {
      case MirrorPhase.streaming:
        return LayoutBuilder(
          builder: (context, constraints) {
            _viewSize = Size(constraints.maxWidth, constraints.maxHeight);
            _engine.setViewSize(constraints.maxWidth, constraints.maxHeight);
            _syncDecodeWidth();
            return Listener(
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: (e) => _onPointerUp(e.pointer),
              onPointerCancel: (e) => _onPointerUp(e.pointer),
              child: Container(
                color: Colors.black,
                width: double.infinity,
                height: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Transform(
                      transform: Matrix4.identity()
                        ..translate(_canvasPan.dx, _canvasPan.dy)
                        ..scale(_canvasScale),
                      child: _rtcLive && _renderer != null
                          ? RTCVideoView(
                              _renderer!,
                              objectFit: RTCVideoViewObjectFit
                                  .RTCVideoViewObjectFitContain,
                            )
                          : ValueListenableBuilder<ui.Image?>(
                              valueListenable: _decoded,
                              builder: (context, img, _) {
                                if (img == null) {
                                  return const Center(
                                    child: CircularProgressIndicator(),
                                  );
                                }
                                return CustomPaint(
                                  painter: MirrorFramePainter(
                                    image: img,
                                    fit: _boxFit,
                                    repaint: _decoded,
                                  ),
                                  child: const SizedBox.expand(),
                                );
                              },
                            ),
                    ),
                    _cursorOverlay(),
                  ],
                ),
              ),
            );
          },
        );
      case MirrorPhase.error:
        if (looksLikeConnectionError(_errorMsg)) {
          return NotConnectedView(
            message: _errorMsg,
            onReconnected: () {
              setState(() {
                _started = false;
                _errorMsg = '';
                _phase = MirrorPhase.launching;
              });
              _start();
            },
          );
        }
        return _centered(
          Icons.warning_amber,
          _errorMsg,
          action: 'Back to apps',
        );
      default:
        return _centered(
          null,
          _phase == MirrorPhase.launching
              ? 'Opening on your PC (Beta)…'
              : 'Fitting the app to your screen (Beta)…',
        );
    }
  }

  Widget _cursorOverlay() {
    return ValueListenableBuilder<Offset?>(
      valueListenable: _pointerView,
      builder: (context, finger, _) {
        var pos = finger;
        final region = _region;
        final cursor = _cursorHost;
        if (pos == null &&
            _mouseMode &&
            region != null &&
            cursor != null &&
            _viewSize != Size.zero) {
          final mapped = hostToView(
            cursor.dx,
            cursor.dy,
            _viewSize.width,
            _viewSize.height,
            region.width.toDouble(),
            region.height.toDouble(),
            _scaleFit,
          );
          pos = Offset(
            mapped.x * _canvasScale + _canvasPan.dx,
            mapped.y * _canvasScale + _canvasPan.dy,
          );
        }
        if (pos == null) return const SizedBox.shrink();
        return IgnorePointer(
          child: Stack(
            children: [
              Positioned(
                left: pos.dx - 7,
                top: pos.dy - 7,
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0x88FFFFFF),
                    border: Border.all(color: Colors.black87, width: 1.5),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _centered(IconData? icon, String text, {String? action}) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            Icon(icon, size: 36, color: Colors.white54)
          else
            const CircularProgressIndicator(),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
          if (action != null) ...[
            const SizedBox(height: 14),
            FilledButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: Text(action),
            ),
          ],
        ],
      ),
    );
  }

  Widget _keyboardBar() {
    return Container(
      color: const Color(0xFF0F0F1A),
      padding: EdgeInsets.only(
        left: 10,
        right: 10,
        top: 8,
        bottom: 8 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _kbController,
              focusNode: _kbFocus,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: _onKbChanged,
              onSubmitted: (_) => _sendKey('Return'),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Type — sent to the PC',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
          _kbKey('⌫', () => _sendKey('BackSpace')),
          _kbKey('⏎', () => _sendKey('Return')),
          _kbKey('Esc', () => _sendKey('Escape')),
        ],
      ),
    );
  }

  Widget _kbKey(String label, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.only(left: 6),
    child: OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      child: Text(label),
    ),
  );
}
