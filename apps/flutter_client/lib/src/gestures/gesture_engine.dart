// Dart port of the NexusLink `GestureEngine` facade
// (packages/gesture-engine/src/index.ts).
//
// Direct-manipulation touch translation (architecture.md Module C). The
// default `direct` mode treats the finger as touching content at an absolute
// host coordinate: a one-finger pan is a momentum scroll, not a cursor drag.
// The legacy relative-cursor behaviour survives as `trackpad` mode (a.k.a.
// Precision mode).
//
// Differences from the TS class, dictated by the Flutter environment:
//  - No DOM attach/detach; the owning widget forwards pointer events via
//    [onTouchStart] / [onTouchMove] / [onTouchEnd] with explicit timestamps.
//  - No requestAnimationFrame; drive [tick] from a Flutter `Ticker` (it also
//    evaluates the pending long press, replacing the TS setTimeout).
//  - View size comes from [setViewSize] instead of getBoundingClientRect /
//    ResizeObserver.
//
// All emitted coordinates are in HOST pixel space via scale_to_host.dart.

import 'classifier.dart';
import 'scale_to_host.dart';
import 'scroll_physics.dart';

export 'classifier.dart';
export 'scale_to_host.dart';
export 'scroll_physics.dart';

class GestureEngine {
  GestureEngine({
    required this._onGesture,
    GestureMode mode = GestureMode.direct,
    bool precision = false,
  }) {
    _classifier = TouchClassifier(
      toHost: _toHost,
      onGesture: _onGesture,
      onFlingStart: _startInertia,
      mode: mode,
      precision: precision,
    );
  }

  final GestureCallback _onGesture;
  late final TouchClassifier _classifier;
  final InertiaScroller _inertia = InertiaScroller();

  // Same defaults as the TS engine.
  double _hostWidth = 1920;
  double _hostHeight = 1080;
  double _viewWidth = 0;
  double _viewHeight = 0;

  // Host coordinate a fling stays anchored at (last finger position).
  double _anchorX = 0;
  double _anchorY = 0;

  void setHostDimensions(double width, double height) {
    _hostWidth = width;
    _hostHeight = height;
  }

  /// Flutter replacement for getBoundingClientRect + ResizeObserver: the
  /// owning widget reports its render size (and any changes) here.
  void setViewSize(double width, double height) {
    _viewWidth = width;
    _viewHeight = height;
  }

  void setMode(GestureMode mode) {
    _classifier.mode = mode;
  }

  void setPrecision(bool precision) {
    _classifier.precision = precision;
  }

  GestureState get state => _classifier.state;

  bool get inertiaActive => _inertia.isActive;

  ({double x, double y}) _toHost(double viewX, double viewY) {
    return scaleToHost(
        viewX, viewY, _viewWidth, _viewHeight, _hostWidth, _hostHeight);
  }

  void onTouchStart(List<TouchPoint> touches, double timestampMs) {
    _inertia.cancel(); // finger-catch: a new touch stops any running fling
    _classifier.onTouchStart(touches, timestampMs);
  }

  void onTouchMove(List<TouchPoint> touches, double timestampMs) {
    _classifier.onTouchMove(touches, timestampMs);
  }

  /// [touches] are the touches STILL DOWN after the lift (empty when the
  /// gesture ends), mirroring TouchEvent.touches in the TS engine.
  void onTouchEnd(List<TouchPoint> touches, double timestampMs) {
    _classifier.onTouchEnd(touches, timestampMs);
  }

  void _startInertia(
      double vx, double vy, double anchorX, double anchorY, double timestampMs) {
    _anchorX = anchorX;
    _anchorY = anchorY;
    _inertia.start(vx, vy, timestampMs); // no-op below the start threshold
  }

  /// Frame driver (call from a Flutter `Ticker` with a monotonic ms clock).
  /// Fires a due long-press context click and advances momentum scrolling,
  /// emitting inertial [ScrollEvent]s. Returns true while inertia is still
  /// running (i.e. the caller should keep ticking).
  bool tick(double nowMs) {
    _classifier.evaluateLongPress(nowMs);
    final delta = _inertia.tick(nowMs);
    if (delta == null) return false;
    if (delta.dx != 0 || delta.dy != 0) {
      _onGesture(
          ScrollEvent(delta.dx, delta.dy, _anchorX, _anchorY, inertial: true));
    }
    return true;
  }
}
