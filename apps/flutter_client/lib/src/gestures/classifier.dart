// Dart port of the NexusLink gesture classification helpers
// (packages/gesture-engine/src/classifier.ts) plus the touch FSM that lives
// in the `GestureEngine` class of packages/gesture-engine/src/index.ts.
//
// Pure Dart (`dart:math` only). Where the TS engine used DOM TouchEvents,
// performance.now() and setTimeout (long press), [TouchClassifier] takes
// plain method calls with explicit millisecond timestamps so behaviour is
// fully deterministic:
//  - onTouchStart / onTouchMove / onTouchEnd carry the active touch list.
//  - The long-press "timer" is evaluated lazily on each event; call
//    [TouchClassifier.evaluateLongPress] from a periodic driver (e.g. the
//    same Ticker that drives inertia) to fire it while the finger is still.

import 'dart:math' as math;

import 'scroll_physics.dart';

// --- Classification thresholds (classifier.ts) ---

/// Travel (px) a single-finger pan must accumulate before an axis is locked.
const double axisLockTravelPx = 12;

/// Half-angle (deg) of the cone around an axis that counts as "locked".
const double axisLockConeDeg = 22.5;

/// Max duration (ms) a touch may last and still count as a tap.
const double tapMaxDurationMs = 500;

/// Max movement (px) a touch may travel and still count as a tap.
const double tapMaxMovePx = 8;

/// Max gap (ms) between two taps for a double-tap.
const double doubleTapThresholdMs = 300;

/// Max distance (px) between two taps for a double-tap.
const double doubleTapMaxMovePx = 30;

// --- Engine tuning constants (index.ts) ---

/// Host-px of accumulated relative movement before a trackpad-mode
/// mouse-move is emitted.
const double panSensitivity = 5;

/// Legacy scroll tuning constant, preserved from the v1 public surface.
const double scrollSensitivity = 10;

/// Hold duration (ms) for a long-press context click.
const double longPressThresholdMs = 500;

/// Max movement (host px) from the touch origin before a pending long press
/// is cancelled.
const double longPressMaxMovePx = 10;

/// Precision mode divides relative cursor deltas by this for fine control.
const double precisionDivisor = 3;

/// Mouse mode: view px a two-finger gesture must spread/pinch (or travel)
/// before it locks as a view zoom (or a scroll) for the rest of the gesture.
const double twoFingerLockPx = 12;

/// Mouse mode tap slop in VIEW px. Host-px slop shrinks to ~2 finger px on a
/// big desktop, which turns ordinary tap jitter into pointer moves.
const double mouseTapSlopViewPx = 6;

/// 'direct' (default): phone-like. Tap = click, one-finger pan = scroll,
/// long-press = right click, long-press-then-move = drag, two fingers =
/// zoom/pan the local view.
/// 'mouse': RustDesk-style virtual trackpad. One finger moves a cursor
/// (relative), tap = click at the cursor, tap-then-hold-and-move = drag,
/// two-finger tap = right click, two fingers = scroll or zoom the view
/// (locked per gesture).
/// 'trackpad': legacy relative cursor (precision).
/// 'view': nothing reaches the host; one finger pans, two fingers zoom/pan.
enum GestureMode { direct, trackpad, mouse, view }

enum _TwoFingerLock { none, transform, scroll }

enum Axis { none, vertical, horizontal, free }

enum GestureState {
  idle,
  undecided,
  scrolling,
  panning,
  longPressPending,
  dragging,
  pinching,
}

/// Resolve the locked axis for a single-finger pan given total travel from
/// the touch origin. Returns [Axis.none] until travel exceeds
/// [axisLockTravelPx], then vertical / horizontal if within the cone, else
/// [Axis.free] (diagonal).
Axis resolveAxis(double totalDx, double totalDy) {
  final dist = math.sqrt(totalDx * totalDx + totalDy * totalDy);
  if (dist < axisLockTravelPx) return Axis.none;
  // 0deg == horizontal (+x), 90deg == vertical. abs() folds all quadrants
  // into [0, 180].
  final angle = (math.atan2(totalDy, totalDx) * 180 / math.pi).abs();
  const cone = axisLockConeDeg;
  if (angle <= cone || angle >= 180 - cone) return Axis.horizontal;
  if ((angle - 90).abs() <= cone) return Axis.vertical;
  return Axis.free;
}

/// Project a delta onto a locked axis (zeroes the off-axis component).
({double dx, double dy}) projectToAxis(double dx, double dy, Axis axis) {
  switch (axis) {
    case Axis.vertical:
      return (dx: 0, dy: dy);
    case Axis.horizontal:
      return (dx: dx, dy: 0);
    case Axis.none:
    case Axis.free:
      return (dx: dx, dy: dy);
  }
}

bool isTap(double durationMs, double movePx) {
  return durationMs < tapMaxDurationMs && movePx < tapMaxMovePx;
}

bool isDoubleTap(double gapMs, double movePx) {
  return gapMs < doubleTapThresholdMs && movePx < doubleTapMaxMovePx;
}

/// A single active touch point in view (widget-local) coordinates.
class TouchPoint {
  final int id;
  final double x;
  final double y;
  const TouchPoint(this.id, this.x, this.y);
}

// --- Gesture events (the TS `GestureEvent` union as a sealed hierarchy) ---
//
// TS mapping: mouse-click/left -> Tap, mouse-click/right -> Context,
// mouse-click/middle -> MiddleClick, mouse-dbl-click -> DoubleTap,
// mouse-scroll -> Scroll, mouse-move -> MouseMove, drag-* -> Drag*.
// Coordinates are in HOST pixel space unless an event says otherwise.

sealed class GestureEvent {
  const GestureEvent();
}

/// Left click at an absolute host coordinate (TS `mouse-click`, left).
final class TapEvent extends GestureEvent {
  final double x;
  final double y;
  const TapEvent(this.x, this.y);
}

/// Double left click (TS `mouse-dbl-click`).
final class DoubleTapEvent extends GestureEvent {
  final double x;
  final double y;
  const DoubleTapEvent(this.x, this.y);
}

/// Right click from a long press (TS `mouse-click`, right).
final class ContextEvent extends GestureEvent {
  final double x;
  final double y;
  const ContextEvent(this.x, this.y);
}

/// Middle click from a three-finger tap (TS `mouse-click`, middle).
final class MiddleClickEvent extends GestureEvent {
  final double x;
  final double y;
  const MiddleClickEvent(this.x, this.y);
}

/// Whole-pixel scroll at an absolute host coordinate (TS `mouse-scroll`).
final class ScrollEvent extends GestureEvent {
  final int deltaX;
  final int deltaY;
  final double x;
  final double y;
  final bool inertial;
  const ScrollEvent(this.deltaX, this.deltaY, this.x, this.y,
      {this.inertial = false});
}

/// Relative cursor movement in trackpad / precision mode (TS `mouse-move`).
final class MouseMoveEvent extends GestureEvent {
  final int dx;
  final int dy;
  const MouseMoveEvent(this.dx, this.dy);
}

final class DragStartEvent extends GestureEvent {
  final double x;
  final double y;
  const DragStartEvent(this.x, this.y);
}

final class DragMoveEvent extends GestureEvent {
  final double x;
  final double y;
  const DragMoveEvent(this.x, this.y);
}

final class DragEndEvent extends GestureEvent {
  final double x;
  final double y;
  const DragEndEvent(this.x, this.y);
}

/// Local view zoom/pan step (never reaches the host). VIEW px: [scale] is the
/// ratio to the previous step, the focal point moved by ([dx], [dy]) to
/// ([focalX], [focalY]).
final class ViewTransformEvent extends GestureEvent {
  final double scale;
  final double focalX;
  final double focalY;
  final double dx;
  final double dy;
  const ViewTransformEvent(
    this.scale,
    this.focalX,
    this.focalY,
    this.dx,
    this.dy,
  );
}

/// Mouse mode finger motion in VIEW px; the owner moves its virtual cursor.
/// [dragging] is true between [DragStartEvent] and [DragEndEvent].
final class PointerDeltaEvent extends GestureEvent {
  final double dx;
  final double dy;
  final double timestampMs;
  final bool dragging;
  const PointerDeltaEvent(
    this.dx,
    this.dy,
    this.timestampMs, {
    this.dragging = false,
  });
}

/// Two-finger tap outside mouse mode (where it is a right click instead).
final class TwoFingerTapEvent extends GestureEvent {
  const TwoFingerTapEvent();
}

/// Maps a view-space coordinate to host-space (see scale_to_host.dart).
typedef HostMapper = ({double x, double y}) Function(
    double viewX, double viewY);

typedef GestureCallback = void Function(GestureEvent event);

/// Called when a one-finger direct scroll is released with velocity; the
/// engine decides whether it clears [scrollInertiaMinVelocity] and starts a
/// fling anchored at the given host coordinate.
typedef FlingCallback = void Function(
    double vx, double vy, double anchorX, double anchorY, double timestampMs);

/// Touch FSM: tap / double-tap / one-finger scroll / long-press context /
/// long-press drag / pinch / two-finger pan. Faithful port of the recognizer
/// in packages/gesture-engine/src/index.ts.
class TouchClassifier {
  TouchClassifier({
    required this._toHost,
    required this._onGesture,
    this._onFlingStart,
    this.mode = GestureMode.direct,
    this.precision = false,
  });

  final HostMapper _toHost;
  final GestureCallback _onGesture;
  final FlingCallback? _onFlingStart;

  GestureMode mode;

  /// Force relative-cursor control with reduced sensitivity (overrides mode).
  bool precision;

  GestureState _state = GestureState.idle;
  GestureState get state => _state;

  // Long-press bookkeeping. `_armed` mirrors "the TS setTimeout is pending":
  // it is set on single-touch start and cleared wherever the TS cleared the
  // timer. The deadline is evaluated lazily against event timestamps.
  bool _longPressArmed = false;
  bool _longPressFired = false;

  ({double x, double y})? _startPos; // host px
  double _startTime = 0;
  ({double x, double y})? _lastPos; // host px
  ({double x, double y})? _lastView; // view px
  double _lastTapTime = 0;
  ({double x, double y})? _lastTapPos;

  bool _dragStarted = false;
  int _maxTouches = 0;

  /// Mouse mode: this touch began right after a tap, so moving drags.
  bool _tapDragArmed = false;

  // Scroll accumulation (fractional host px carried between emits).
  double _scrollCarryX = 0;
  double _scrollCarryY = 0;
  double _moveAccumDx = 0;
  double _moveAccumDy = 0;
  final ScrollVelocityTracker _velocity = ScrollVelocityTracker();

  // Two-finger state (view px, as in the TS which used clientX/clientY).
  ({double x, double y})? _prevScrollMid;
  double _prevPinchDist = 0;
  ({double x, double y})? _twoStartMid;
  double _twoStartDist = 0;
  _TwoFingerLock _twoLock = _TwoFingerLock.none;

  /// Largest spread change or midpoint travel (view px) this gesture.
  double _twoMaxMove = 0;

  /// Effective mode: precision forces relative-cursor (trackpad) behaviour.
  GestureMode get _effectiveMode =>
      precision ? GestureMode.trackpad : mode;

  void _emit(GestureEvent event) => _onGesture(event);

  double _dist(({double x, double y}) a, ({double x, double y}) b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  void _resetState() {
    _startPos = null;
    _lastPos = null;
    _lastView = null;
    _prevScrollMid = null;
    _prevPinchDist = 0;
    _twoStartMid = null;
    _twoStartDist = 0;
    _twoLock = _TwoFingerLock.none;
    _twoMaxMove = 0;
    _tapDragArmed = false;
    _moveAccumDx = 0;
    _moveAccumDy = 0;
    _scrollCarryX = 0;
    _scrollCarryY = 0;
    _longPressFired = false;
    _longPressArmed = false;
    _dragStarted = false;
    _maxTouches = 0;
    _state = GestureState.idle;
  }

  /// Fire the pending long press if its deadline has passed. Equivalent to
  /// the TS setTimeout callback; call this from a periodic driver so a
  /// perfectly still finger gets its context click while still held (event
  /// handlers also evaluate it, so held-then-move works without a driver).
  /// Returns true if the context click fired now.
  bool evaluateLongPress(double timestampMs) {
    if (!_longPressArmed || _longPressFired) return false;
    if (timestampMs - _startTime < longPressThresholdMs) return false;
    _longPressFired = true;
    _longPressArmed = false;
    _state = GestureState.longPressPending;
    return true;
  }

  void _beginSingleTouch(TouchPoint touch, double timestampMs) {
    final host = _toHost(touch.x, touch.y);
    _startPos = host;
    _startTime = timestampMs;
    _lastPos = host;
    _lastView = (x: touch.x, y: touch.y);
    _scrollCarryX = 0;
    _scrollCarryY = 0;
    _moveAccumDx = 0;
    _moveAccumDy = 0;
    _longPressFired = false;
    _dragStarted = false;
    _velocity.reset();
    _state = GestureState.undecided;
    _longPressArmed = _effectiveMode != GestureMode.view;
    // Mouse mode: only timing matters (the cursor, not the finger, is the
    // target), so a second touch anywhere soon after a tap can drag.
    _tapDragArmed =
        _effectiveMode == GestureMode.mouse &&
        _lastTapTime > 0 &&
        timestampMs - _lastTapTime < doubleTapThresholdMs;
  }

  void onTouchStart(List<TouchPoint> touches, double timestampMs) {
    _maxTouches = math.max(_maxTouches, touches.length);

    if (touches.length == 1) {
      _beginSingleTouch(touches[0], timestampMs);
    } else if (touches.length >= 2) {
      _longPressArmed = false;
      _longPressFired = false;
      _state = GestureState.pinching;
      final t0 = touches[0];
      final t1 = touches[1];
      _startPos = _toHost(t0.x, t0.y);
      _startTime = timestampMs;
      _lastPos = _startPos;
      _lastView = (x: t0.x, y: t0.y);
      _prevScrollMid = (x: (t0.x + t1.x) / 2, y: (t0.y + t1.y) / 2);
      final dx = t0.x - t1.x;
      final dy = t0.y - t1.y;
      _prevPinchDist = math.sqrt(dx * dx + dy * dy);
      _twoStartMid = _prevScrollMid;
      _twoStartDist = _prevPinchDist;
      _twoLock = switch (_effectiveMode) {
        GestureMode.direct || GestureMode.view => _TwoFingerLock.transform,
        GestureMode.trackpad => _TwoFingerLock.scroll,
        GestureMode.mouse => _TwoFingerLock.none,
      };
    }
  }

  void onTouchMove(List<TouchPoint> touches, double timestampMs) {
    _maxTouches = math.max(_maxTouches, touches.length);

    if (touches.length == 1) {
      _handleSingleMove(touches[0], timestampMs);
    } else if (touches.length >= 2) {
      _handleMultiMove(touches[0], touches[1], timestampMs);
    }
  }

  void _handleSingleMove(TouchPoint touch, double timestampMs) {
    // The TS long-press timer would have fired before this event arrived.
    evaluateLongPress(timestampMs);

    final host = _toHost(touch.x, touch.y);

    // A finger left over from a two-finger gesture must not scroll or move
    // the cursor (it reads as a ghost scroll after a pinch).
    if (_maxTouches >= 2 && _effectiveMode != GestureMode.view) {
      _lastPos = host;
      _lastView = (x: touch.x, y: touch.y);
      return;
    }

    if (_effectiveMode == GestureMode.mouse) {
      _handleMouseMove(touch, host, timestampMs);
      return;
    }

    // Held-then-move => drag (long press already emitted its context click).
    if (_longPressFired) {
      if (!_dragStarted) {
        _dragStarted = true;
        _state = GestureState.dragging;
        _emit(DragStartEvent(host.x, host.y));
      } else {
        _emit(DragMoveEvent(host.x, host.y));
      }
      _lastPos = host;
      return;
    }

    final last = _lastPos;
    final start = _startPos;
    if (last == null || start == null) {
      _lastPos = host;
      return;
    }

    // Any real movement past the long-press slop cancels the pending press.
    if (_dist(host, start) > longPressMaxMovePx) {
      _longPressArmed = false;
    }

    final rawDx = host.x - last.x;
    final rawDy = host.y - last.y;
    final lastView = _lastView;
    final viewDx = lastView != null ? touch.x - lastView.x : 0.0;
    final viewDy = lastView != null ? touch.y - lastView.y : 0.0;

    if (_effectiveMode == GestureMode.direct) {
      if (_dist(host, start) > tapMaxMovePx) {
        _emitFingerScroll(viewDx, viewDy, host, timestampMs);
      }
    } else if (_effectiveMode == GestureMode.view) {
      if (_state == GestureState.panning || _dist(host, start) > tapMaxMovePx) {
        _state = GestureState.panning;
        _emit(ViewTransformEvent(1, touch.x, touch.y, viewDx, viewDy));
      }
    } else {
      _state = GestureState.panning;
      final divisor = precision ? precisionDivisor : 1;
      _moveAccumDx += rawDx / divisor;
      _moveAccumDy += rawDy / divisor;
      if (_moveAccumDx.abs() >= panSensitivity ||
          _moveAccumDy.abs() >= panSensitivity) {
        final dx = _moveAccumDx.truncate();
        final dy = _moveAccumDy.truncate();
        if (dx != 0 || dy != 0) {
          _emit(MouseMoveEvent(dx, dy));
        }
        _moveAccumDx -= dx;
        _moveAccumDy -= dy;
      }
    }

    _lastPos = host;
    _lastView = (x: touch.x, y: touch.y);
  }

  /// Mouse mode one-finger motion: relative cursor moves, or a drag when the
  /// touch followed a tap (tap-then-hold) or a long press.
  void _handleMouseMove(
    TouchPoint touch,
    ({double x, double y}) host,
    double timestampMs,
  ) {
    final start = _startPos;
    final lastView = _lastView;
    if (start == null || lastView == null) return;
    // Under the slop nothing moves yet, and _lastView stays at the touch
    // origin so the first real delta includes the slop (no lost motion).
    final slop = math.sqrt(math.pow(touch.x - lastView.x, 2) +
        math.pow(touch.y - lastView.y, 2));
    if (_state == GestureState.undecided &&
        !_longPressFired &&
        slop <= mouseTapSlopViewPx) {
      return;
    }
    _longPressArmed = false;
    if (!_dragStarted && (_tapDragArmed || _longPressFired)) {
      _dragStarted = true;
      _state = GestureState.dragging;
      _emit(DragStartEvent(start.x, start.y));
    } else if (!_dragStarted) {
      _state = GestureState.panning;
    }
    final dx = touch.x - lastView.x;
    final dy = touch.y - lastView.y;
    if (dx != 0 || dy != 0) {
      _emit(PointerDeltaEvent(dx, dy, timestampMs, dragging: _dragStarted));
    }
    _lastPos = host;
    _lastView = (x: touch.x, y: touch.y);
  }

  void _emitFingerScroll(
    double viewDx,
    double viewDy,
    ({double x, double y}) host,
    double timestampMs,
  ) {
    _state = GestureState.scrolling;
    final sdx = -viewDx;
    final sdy = -viewDy;
    _velocity.addSample(sdx, sdy, timestampMs);
    _scrollCarryX += sdx;
    _scrollCarryY += sdy;
    final ix = _scrollCarryX.truncate();
    final iy = _scrollCarryY.truncate();
    if (ix != 0 || iy != 0) {
      _scrollCarryX -= ix;
      _scrollCarryY -= iy;
      _emit(ScrollEvent(ix, iy, host.x, host.y));
    }
  }

  void _handleMultiMove(TouchPoint t0, TouchPoint t1, double timestampMs) {
    _longPressArmed = false;

    final midX = (t0.x + t1.x) / 2;
    final midY = (t0.y + t1.y) / 2;
    final pdx = t0.x - t1.x;
    final pdy = t0.y - t1.y;
    final pinchDist = math.sqrt(pdx * pdx + pdy * pdy);

    final prevMid = _prevScrollMid;
    final panDx = prevMid != null ? midX - prevMid.x : 0.0;
    final panDy = prevMid != null ? midY - prevMid.y : 0.0;

    final host = _toHost(t0.x, t0.y);

    // Mouse mode locks the whole gesture as zoom or scroll on whichever
    // threshold it crosses first: per-event zoom/scroll flapping reads as
    // glitching. Other modes are locked from the start.
    final startMid = _twoStartMid ?? (x: midX, y: midY);
    final tdx = midX - startMid.x;
    final tdy = midY - startMid.y;
    final travel = math.sqrt(tdx * tdx + tdy * tdy);
    final spread = (pinchDist - _twoStartDist).abs();
    _twoMaxMove = math.max(_twoMaxMove, math.max(travel, spread));
    if (_twoLock == _TwoFingerLock.none) {
      if (spread >= twoFingerLockPx) {
        _twoLock = _TwoFingerLock.transform;
      } else if (travel >= twoFingerLockPx) {
        _twoLock = _TwoFingerLock.scroll;
      } else {
        // Undecided: keep the previous sample at the touch origin so the
        // first locked step carries everything moved so far.
        return;
      }
    }

    if (_twoLock == _TwoFingerLock.transform) {
      _state = GestureState.pinching;
      final ratio = _prevPinchDist > 0 ? pinchDist / _prevPinchDist : 1.0;
      _emit(ViewTransformEvent(ratio, midX, midY, panDx, panDy));
    } else {
      _state = GestureState.scrolling;
      final sdx = -panDx;
      final sdy = -panDy;
      _velocity.addSample(sdx, sdy, timestampMs);
      _scrollCarryX += sdx;
      _scrollCarryY += sdy;
      final ix = _scrollCarryX.truncate();
      final iy = _scrollCarryY.truncate();
      if (ix != 0 || iy != 0) {
        _scrollCarryX -= ix;
        _scrollCarryY -= iy;
        _emit(ScrollEvent(ix, iy, host.x, host.y));
      }
    }

    _prevScrollMid = (x: midX, y: midY);
    _prevPinchDist = pinchDist;
  }

  void onTouchEnd(List<TouchPoint> touches, double timestampMs) {
    if (touches.isEmpty) {
      _finishGesture(timestampMs);
    } else if (touches.length == 1) {
      // Lifted from multi-touch back to single: restart a fresh track.
      _prevScrollMid = null;
      _beginSingleTouch(touches[0], timestampMs);
      // The finger lingering after a two-finger gesture must not turn into a
      // long-press right click (taps are already blocked via _maxTouches).
      if (_maxTouches >= 2) _longPressArmed = false;
    }
  }

  void _finishGesture(double timestampMs) {
    // A still finger held past the threshold gets its context click on
    // release at the latest (the TS timer fired while held).
    evaluateLongPress(timestampMs);
    _longPressArmed = false;

    // Drag release.
    if (_dragStarted) {
      final p = _lastPos ?? _startPos;
      if (p != null) _emit(DragEndEvent(p.x, p.y));
      _resetState();
      return;
    }

    // Long-press held still: right click on release (move-after-hold is a drag).
    if (_longPressFired) {
      final start = _startPos;
      if (start != null) _emit(ContextEvent(start.x, start.y));
      _resetState();
      return;
    }

    final start = _startPos;
    final moved = start != null && _lastPos != null ? _dist(start, _lastPos!) : 0.0;
    final duration = timestampMs - _startTime;

    // A two-finger tap never locked into a zoom or scroll.
    if (start != null &&
        isTap(duration, moved) &&
        _maxTouches == 2 &&
        _twoMaxMove < twoFingerLockPx) {
      if (_effectiveMode == GestureMode.mouse) {
        _emit(ContextEvent(start.x, start.y));
      } else if (_effectiveMode != GestureMode.trackpad) {
        _emit(const TwoFingerTapEvent());
      }
      _resetState();
      return;
    }

    if (start != null && _state != GestureState.pinching) {
      if (isTap(duration, moved) && _maxTouches < 2) {
        final gap = timestampMs - _lastTapTime;
        final tapDist =
            _lastTapPos != null ? _dist(start, _lastTapPos!) : double.infinity;

        if (_lastTapTime > 0 && isDoubleTap(gap, tapDist)) {
          _emit(DoubleTapEvent(start.x, start.y));
          _lastTapTime = 0;
          _lastTapPos = null;
          _resetState();
          return;
        }

        _emit(TapEvent(start.x, start.y));
        _lastTapTime = timestampMs;
        _lastTapPos = (x: start.x, y: start.y);
        _resetState();
        return;
      }

      if (_state == GestureState.scrolling &&
          timestampMs - _velocity.lastSampleTimeMs <= flingMaxSampleAgeMs) {
        _onFlingStart?.call(
          _velocity.vx,
          _velocity.vy,
          _lastPos?.x ?? 0,
          _lastPos?.y ?? 0,
          timestampMs,
        );
      }
    }

    _resetState();
  }
}
