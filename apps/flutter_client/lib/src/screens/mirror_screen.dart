// App/desktop mirror viewport. Port of apps/mobile-client/src/app/mirror/page.tsx:
// auto (launch →) adopt → capture → render binary frames, with direct-
// manipulation touch via the ported GestureEngine (lib/src/gestures/).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../gestures/gesture_engine.dart';
import '../rpc/models.dart';
import '../rpc/rpc_client.dart';
import '../state/connection.dart';
import '../state/launcher.dart';
import '../widgets/open_apps_bar.dart';

/// What to show: an existing window (windowId), an app to launch (appId), or
/// neither → the full desktop (primary monitor).
class MirrorTarget {
  final String? windowId;
  final String? appId;
  final String? wmClass;
  final String? title;
  const MirrorTarget({this.windowId, this.appId, this.wmClass, this.title});
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
  Uint8List? _frame;
  CaptureRegion? _region;
  int _streamKey = -1;
  String? _streamId;
  String? _windowId;
  int _frameCount = 0;
  int _fps = 0;
  bool _keyboardOpen = false;
  bool _precision = false;

  final _kbController = TextEditingController();
  final _kbFocus = FocusNode();
  /// Last text value we already synced to the host (IME compose/diff baseline).
  String _kbSynced = '';
  StreamSubscription<MirrorFrame>? _frameSub;
  Timer? _fpsTimer;
  bool _started = false;

  // Gesture engine + a single monotonic clock shared by touch events and the
  // inertia ticker (they must agree on "now" or velocity math is wrong).
  late final GestureEngine _engine;
  late final Ticker _ticker;
  final _clock = Stopwatch();
  final _activePointers = <int, Offset>{};

  RpcClient? get _client => ref.read(activeClientProvider);

  double get _nowMs => _clock.elapsedMicroseconds / 1000.0;

  @override
  void initState() {
    super.initState();
    _clock.start();
    _engine = GestureEngine(onGesture: _onGesture);
    _ticker = createTicker((_) {
      // Drive long-press evaluation + inertia on a shared clock. Keep ticking
      // while streaming so a pending long-press fires even without new frames.
      _engine.tick(_nowMs);
    })..start();
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
      });
      return;
    }
    try {
      var windowId = widget.target.windowId;

      // Launch flow: start the app, poll window.list until its window appears.
      if (windowId == null && widget.target.appId != null) {
        setState(() => _phase = MirrorPhase.launching);
        final launched = await client.request(
            'apps.launch', {'appId': widget.target.appId}) as Map<String, dynamic>;
        if (launched['ok'] != true) {
          throw 'The host could not launch this app.';
        }
        final nCls = normClass(widget.target.wmClass ??
            (launched['wmClass'] as String?) ??
            widget.target.appId!);
        final deadline = DateTime.now().add(const Duration(seconds: 25));
        while (DateTime.now().isBefore(deadline) && mounted) {
          await Future.delayed(const Duration(milliseconds: 800));
          final wins = await client.request('window.list') as List<dynamic>;
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
        // Use adopt's returned region immediately so touch mapping is correct
        // even before the first capture frame / stream-region push.
        final adopt = await client.request('window.adopt', {
          'windowId': windowId,
          'viewportW': media.size.width.round(),
          'viewportH': media.size.height.round(),
        }) as Map<String, dynamic>;
        if (adopt['region'] != null) {
          _setRegion(
              CaptureRegion.fromJson(adopt['region'] as Map<String, dynamic>));
        }
        params['windowId'] = windowId;
      }

      final cap = await client.request('screen.startCapture', params)
          as Map<String, dynamic>;
      _streamId = cap['streamId'] as String?;
      _streamKey = (cap['streamKey'] as num?)?.toInt() ?? -1;
      if (cap['region'] != null) {
        _setRegion(CaptureRegion.fromJson(cap['region'] as Map<String, dynamic>));
      }

      _frameSub = client.frames.listen((f) {
        if (f.streamKey != _streamKey) return;
        _frameCount++;
        if (mounted) setState(() => _frame = f.jpeg);
      });
      // Host re-grabs if the window moves; keep the region in sync for mapping.
      client.subscribe('stream-region', (msg) {
        if (msg['streamId'] != _streamId) return;
        final r = msg['region'];
        if (r is Map<String, dynamic> && mounted) {
          _setRegion(CaptureRegion.fromJson(r));
        }
      });
      _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _fps = _frameCount);
        _frameCount = 0;
      });

      if (mounted) setState(() => _phase = MirrorPhase.streaming);
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = MirrorPhase.error;
          _errorMsg = e.toString();
        });
      }
    }
  }

  /// Touch space IS the captured region: the engine maps view→region-local, and
  /// we add the region origin to reach absolute host coordinates for injection.
  void _setRegion(CaptureRegion r) {
    _region = r;
    _engine.setHostDimensions(r.width.toDouble(), r.height.toDouble());
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frameSub?.cancel();
    _fpsTimer?.cancel();
    _kbController.dispose();
    _kbFocus.dispose();
    final client = _client;
    final id = _streamId;
    final win = _windowId;
    if (client != null) {
      if (id != null) client.notify('screen.stopCapture', {'streamId': id});
      if (win != null) client.notify('window.release', {'windowId': win});
    }
    super.dispose();
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
        client.notify('input.mouseClick',
            {'button': 'left', 'x': hx(e.x), 'y': hy(e.y)});
      case DoubleTapEvent():
        final x = hx(e.x), y = hy(e.y);
        client.notify('input.mouseClick', {'button': 'left', 'x': x, 'y': y});
        Future.delayed(const Duration(milliseconds: 50), () {
          client.notify('input.mouseClick', {'button': 'left', 'x': x, 'y': y});
        });
      case ContextEvent():
        HapticFeedback.mediumImpact();
        client.notify('input.mouseClick',
            {'button': 'right', 'x': hx(e.x), 'y': hy(e.y)});
      case MiddleClickEvent():
        client.notify('input.mouseClick',
            {'button': 'middle', 'x': hx(e.x), 'y': hy(e.y)});
      case ScrollEvent():
        // Trackpad mode scrolls at the cursor's current position (real
        // trackpad semantics) — warping the pointer to the fingers on every
        // two-finger scroll would fight the one-finger cursor control.
        client.notify('input.mouseScroll', {
          'deltaX': e.deltaX,
          'deltaY': e.deltaY,
          if (!_precision) 'x': hx(e.x),
          if (!_precision) 'y': hy(e.y),
        });
      case MouseMoveEvent():
        client.notify('input.mouseMove', {'dx': e.dx, 'dy': e.dy});
      case DragStartEvent():
        client.notify('input.buttonDown',
            {'button': 'left', 'x': hx(e.x), 'y': hy(e.y)});
      case DragMoveEvent():
        client.notify('input.mouseMoveAbs', {'x': hx(e.x), 'y': hy(e.y)});
      case DragEndEvent():
        client.notify('input.buttonUp',
            {'button': 'left', 'x': hx(e.x), 'y': hy(e.y)});
      case ZoomEvent():
        // Pinch → Ctrl+wheel at the midpoint. scale>0 = zoom in = wheel up.
        client.notify('input.mouseScroll', {
          'deltaX': 0,
          'deltaY': (-e.scale * 400).round(),
          'x': hx(e.x),
          'y': hy(e.y),
          'modifiers': ['ctrl'],
        });
    }
  }

  // --- raw pointer → engine touch events ------------------------------------

  List<TouchPoint> get _touches => _activePointers.entries
      .map((e) => TouchPoint(e.key, e.value.dx, e.value.dy))
      .toList();

  void _onPointerDown(PointerDownEvent e) {
    _activePointers[e.pointer] = e.localPosition;
    _engine.onTouchStart(_touches, _nowMs);
  }

  void _onPointerMove(PointerMoveEvent e) {
    _activePointers[e.pointer] = e.localPosition;
    _engine.onTouchMove(_touches, _nowMs);
  }

  void _onPointerUp(int pointer) {
    _activePointers.remove(pointer);
    // onTouchEnd receives the touches STILL down, matching TouchEvent.touches.
    _engine.onTouchEnd(_touches, _nowMs);
  }

  void _sendKey(String key) =>
      _client?.notify('input.keyEvent', {'key': key});

  /// RustDesk-style soft keyboard: keep field text, skip inject while the IME
  /// is composing, then diff old→new and batch `input.typeText` / BackSpace.
  void _onKbChanged(String newValue) {
    final editing = _kbController.value;
    if (editing.isComposingRangeValid) {
      // Still composing (suggestions / glide) — wait for a commit.
      return;
    }

    final oldValue = _kbSynced;
    if (newValue == oldValue) return;

    var common = 0;
    final maxCommon =
        oldValue.length < newValue.length ? oldValue.length : newValue.length;
    while (common < maxCommon && oldValue[common] == newValue[common]) {
      common++;
    }

    for (var i = 0; i < oldValue.length - common; i++) {
      _sendKey('BackSpace');
    }
    final insert = newValue.substring(common);
    if (insert.isNotEmpty) {
      _client?.notify('input.typeText', {'text': insert});
    }
    _kbSynced = newValue;

    // Bound local buffer so the field does not grow forever.
    if (newValue.length > 200) {
      _kbSynced = '';
      _kbController.value = const TextEditingValue(text: '');
    }
  }

  void _onKbBackspace() {
    if (_kbController.text.isNotEmpty) {
      final t = _kbController.text;
      final next = t.substring(0, t.length - 1);
      _kbController.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
      _onKbChanged(next);
    } else {
      _sendKey('BackSpace');
    }
  }

  void _toggleKeyboard() {
    setState(() => _keyboardOpen = !_keyboardOpen);
    if (_keyboardOpen) {
      _kbSynced = '';
      _kbController.value = const TextEditingValue(text: '');
      _kbFocus.requestFocus();
    } else {
      _kbFocus.unfocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.target.title ??
        (widget.target.windowId != null || widget.target.appId != null
            ? 'App'
            : 'Desktop');
    final windows = ref.watch(windowsProvider).value ?? [];
    final apps = ref.watch(appsProvider).value ?? [];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0F),
        leading: IconButton(
          icon: const Icon(Icons.home_outlined),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          _phase == MirrorPhase.streaming ? '$title · $_fps fps' : title,
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          IconButton(
            tooltip: 'Trackpad mode: 1 finger moves the cursor, 2 fingers scroll',
            icon: Icon(Icons.mouse,
                color: _precision ? const Color(0xFF2A6AFF) : null),
            onPressed: () {
              setState(() => _precision = !_precision);
              _engine.setPrecision(_precision);
            },
          ),
          IconButton(
            icon: Icon(Icons.keyboard,
                color: _keyboardOpen ? const Color(0xFF2A6AFF) : null),
            onPressed: _toggleKeyboard,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _stage()),
          if (_keyboardOpen) _keyboardBar(),
          if (!_keyboardOpen && windows.isNotEmpty)
            OpenAppsBar(
              windows: windows,
              apps: apps,
              compact: true,
              activeWindowId: _windowId,
              onTap: (w) {
                if (w.windowId == _windowId) return;
                Navigator.of(context).pushReplacement(MaterialPageRoute(
                  builder: (_) => MirrorScreen(
                    target: MirrorTarget(
                      windowId: w.windowId,
                      title: bestWindowName(w, apps),
                    ),
                  ),
                ));
              },
            ),
        ],
      ),
    );
  }

  Widget _stage() {
    switch (_phase) {
      case MirrorPhase.streaming:
        return LayoutBuilder(builder: (context, constraints) {
          _engine.setViewSize(constraints.maxWidth, constraints.maxHeight);
          return Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: (e) => _onPointerUp(e.pointer),
            onPointerCancel: (e) => _onPointerUp(e.pointer),
            child: Container(
              color: Colors.black,
              width: double.infinity,
              height: double.infinity,
              alignment: Alignment.center,
              child: _frame == null
                  ? const CircularProgressIndicator()
                  : Image.memory(_frame!,
                      gaplessPlayback: true, fit: BoxFit.contain),
            ),
          );
        });
      case MirrorPhase.error:
        return _centered(Icons.warning_amber, _errorMsg, action: 'Back to apps');
      default:
        return _centered(
          null,
          _phase == MirrorPhase.launching
              ? 'Opening on your PC…'
              : 'Fitting the app to your screen…',
        );
    }
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
            child: Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70)),
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
              // Leave suggestions on so glide typing / autocomplete can compose.
              autocorrect: true,
              enableSuggestions: true,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              maxLines: null,
              onChanged: _onKbChanged,
              onSubmitted: (_) => _sendKey('Return'),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Type — suggestions & glide OK',
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
          _kbKey('⌫', _onKbBackspace),
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
              padding: const EdgeInsets.symmetric(horizontal: 12)),
          child: Text(label),
        ),
      );
}
