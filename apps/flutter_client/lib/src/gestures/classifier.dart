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

/// Minimum pinch-distance change (px) before a two-finger gesture reads as
/// zoom.
const double pinchMinDeltaPx = 6;

/// Screen-px -> zoom-scale factor per pinch step.
const double pinchZoomScale = 0.005;

/// 'direct' (default): one-finger pan = momentum scroll at the absolute host
/// coordinate under the finger. 'trackpad': legacy relative-cursor movement
/// (a.k.a. Precision mode behaviour).
enum GestureMode { direct, trackpad }

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
// mouse-scroll -> Scroll, mouse-move -> MouseMove, drag-* -> Drag*,
// zoom -> Zoom. Coordinates are in HOST pixel space.

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

/// Pinch zoom step (TS `zoom`). [scale] is signed: positive = zoom in.
final class ZoomEvent extends GestureEvent {
  final double scale;
  final double x;
  final double y;
  const ZoomEvent(this.scale, this.x, this.y);
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

/// Touch FSM: tap / double-tap / scroll / long-press context / drag / pinch /
/// two-finger pan / three-finger tap. Faithful port of the recognizer in
/// packages/gesture-engine/src/index.ts.
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
  double _lastTapTime = 0;
  ({double x, double y})? _lastTapPos;

  Axis _axis = Axis.none;
  bool _dragStarted = false;
  int _maxTouches = 0;

  // Scroll accumulation (fractional host px carried between emits).
  double _scrollCarryX = 0;
  double _scrollCarryY = 0;
  double _moveAccumDx = 0;
  double _moveAccumDy = 0;
  final ScrollVelocityTracker _velocity = ScrollVelocityTracker();

  // Two-finger state (view px, as in the TS which used clientX/clientY).
  ({double x, double y})? _prevScrollMid;
  double _prevPinchDist = 0;

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
    _prevScrollMid = null;
    _prevPinchDist = 0;
    _moveAccumDx = 0;
    _moveAccumDy = 0;
    _scrollCarryX = 0;
    _scrollCarryY = 0;
    _longPressFired = false;
    _longPressArmed = false;
    _dragStarted = false;
    _axis = Axis.none;
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
    final start = _startPos;
    if (start != null) {
      _emit(ContextEvent(start.x, start.y));
    }
    return true;
  }

  void _beginSingleTouch(TouchPoint touch, double timestampMs) {
    final host = _toHost(touch.x, touch.y);
    _startPos = host;
    _startTime = timestampMs;
    _lastPos = host;
    _axis = Axis.none;
    _scrollCarryX = 0;
    _scrollCarryY = 0;
    _moveAccumDx = 0;
    _moveAccumDy = 0;
    _longPressFired = false;
    _dragStarted = false;
    _velocity.reset();
    _state = GestureState.undecided;
    _longPressArmed = true;
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
      // Anchor + start time so a 3-finger tap (no movement) can resolve to a
      // click.
      _startPos = _toHost(t0.x, t0.y);
      _startTime = timestampMs;
      _lastPos = _startPos;
      _prevScrollMid = (x: (t0.x + t1.x) / 2, y: (t0.y + t1.y) / 2);
      final dx = t0.x - t1.x;
      final dy = t0.y - t1.y;
      _prevPinchDist = math.sqrt(dx * dx + dy * dy);
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

    if (_effectiveMode == GestureMode.direct) {
      _state = GestureState.scrolling;
      // Lock axis once travel is decisive.
      if (_axis == Axis.none) {
        _axis = resolveAxis(host.x - start.x, host.y - start.y);
      }
      final proj = projectToAxis(rawDx, rawDy, _axis);
      // Content tracks the finger: scroll delta is opposite to finger travel.
      final sdx = -proj.dx;
      final sdy = -proj.dy;
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
    } else {
      // Trackpad: relative cursor movement.
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
  }

  void _handleMultiMove(TouchPoint t0, TouchPoint t1, double timestampMs) {
    _longPressArmed = false;
    _state = GestureState.pinching;

    final midX = (t0.x + t1.x) / 2;
    final midY = (t0.y + t1.y) / 2;
    final pdx = t0.x - t1.x;
    final pdy = t0.y - t1.y;
    final pinchDist = math.sqrt(pdx * pdx + pdy * pdy);

    final prevMid = _prevScrollMid;
    final panDx = prevMid != null ? midX - prevMid.x : 0.0;
    final panDy = prevMid != null ? midY - prevMid.y : 0.0;
    final pinchDelta = pinchDist - _prevPinchDist;

    final host = _toHost(t0.x, t0.y);

    // Pinch dominates over pan -> zoom; otherwise two-finger pan -> scroll.
    // Trackpad/precision mode never zooms: two fingers always scroll, like a
    // laptop trackpad (per-event zoom/scroll flapping reads as glitching).
    if (_effectiveMode != GestureMode.trackpad &&
        pinchDelta.abs() >= pinchMinDeltaPx &&
        pinchDelta.abs() > math.sqrt(panDx * panDx + panDy * panDy)) {
      _emit(ZoomEvent(pinchDelta * pinchZoomScale, host.x, host.y));
    } else {
      // Content tracks the fingers.
      _scrollCarryX += -panDx;
      _scrollCarryY += -panDy;
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

    // Long press already emitted its context click; nothing more on release.
    if (_longPressFired) {
      _resetState();
      return;
    }

    final start = _startPos;

    // Three-finger tap -> middle click.
    if (_maxTouches >= 3 && start != null && _state != GestureState.scrolling) {
      final moved = _lastPos != null ? _dist(start, _lastPos!) : 0.0;
      final duration = timestampMs - _startTime;
      if (isTap(duration, moved)) {
        _emit(MiddleClickEvent(start.x, start.y));
        _resetState();
        return;
      }
    }

    if (start != null && _state != GestureState.pinching) {
      final moved = _lastPos != null ? _dist(start, _lastPos!) : 0.0;
      final duration = timestampMs - _startTime;

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

      // A one-finger direct scroll that ended with velocity -> momentum
      // fling (the engine checks the start threshold). A finger that paused
      // before lifting has stale velocity — flinging then feels haunted.
      if (_effectiveMode == GestureMode.direct &&
          _state == GestureState.scrolling &&
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
