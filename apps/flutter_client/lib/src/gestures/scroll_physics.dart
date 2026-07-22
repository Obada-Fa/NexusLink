// Dart port of the NexusLink scroll physics
// (packages/gesture-engine/src/scroll-physics.ts): EMA velocity estimation +
// momentum (inertia) integration.
//
// Pure, dependency-free math (`dart:math` only) so it is deterministically
// unit-testable. Where the TS engine drove inertia with requestAnimationFrame,
// [InertiaScroller] exposes an explicit `tick(nowMs)` the caller drives (a
// Flutter `Ticker` in production, plain calls in tests).

import 'dart:math' as math;

/// Deceleration constant (s^-1). ~300ms time constant, iOS-"normal"-like feel.
const double scrollInertiaLambda = 3.3;

/// Minimum release speed (host px/s) required to start an inertia fling.
const double scrollInertiaMinVelocity = 250;

/// Speed (host px/s) at which an inertia fling is considered stopped.
const double scrollInertiaStopVelocity = 4;

/// EMA smoothing factor for the velocity estimator (weight of newest sample).
const double velocityEmaAlpha = 0.4;

/// Max age (ms) of the newest velocity sample for a release to still fling.
/// A pan that pauses before lifting must not fling with pre-pause velocity.
const double flingMaxSampleAgeMs = 100;

/// Minimum sample interval (ms). Guards against divide-by-zero / spikes on
/// fast events.
const double minSampleDtMs = 4;

/// Remaining velocity after [dtSeconds] of exponential decay from [v0].
double decayVelocity(double v0, double dtSeconds,
    [double lambda = scrollInertiaLambda]) {
  return v0 * math.exp(-lambda * dtSeconds);
}

/// Closed-form displacement of an exponentially-decaying fling between two
/// times (seconds since release):
/// integral of v0*e^(-lambda*t) dt from t0 to t1
///   = (v0/lambda) * (e^(-lambda*t0) - e^(-lambda*t1)).
double inertiaDisplacement(double v0, double t0, double t1,
    [double lambda = scrollInertiaLambda]) {
  return (v0 / lambda) * (math.exp(-lambda * t0) - math.exp(-lambda * t1));
}

/// Total distance a fling of initial velocity [v0] will ever travel (t -> inf).
double inertiaTotalDistance(double v0, [double lambda = scrollInertiaLambda]) {
  return v0 / lambda;
}

/// Exponential-moving-average velocity estimator over per-move deltas.
/// Feed it host-space deltas + timestamps; read [vx]/[vy] at release time.
///
/// The first sample only primes the clock (its delta is discarded), matching
/// the TS `ScrollVelocityTracker`.
class ScrollVelocityTracker {
  double _vx = 0;
  double _vy = 0;
  double _lastT = 0;
  bool _primed = false;

  void reset() {
    _vx = 0;
    _vy = 0;
    _lastT = 0;
    _primed = false;
  }

  /// [dx],[dy]: delta since the previous sample (host px). [tMs]: timestamp.
  void addSample(double dx, double dy, double tMs) {
    if (!_primed) {
      _lastT = tMs;
      _primed = true;
      return;
    }
    final dtMs = math.max(minSampleDtMs, tMs - _lastT);
    _lastT = tMs;
    final dtSec = dtMs / 1000;
    final instVx = dx / dtSec;
    final instVy = dy / dtSec;
    _vx = velocityEmaAlpha * instVx + (1 - velocityEmaAlpha) * _vx;
    _vy = velocityEmaAlpha * instVy + (1 - velocityEmaAlpha) * _vy;
  }

  double get vx => _vx;
  double get vy => _vy;

  double get speed => math.sqrt(_vx * _vx + _vy * _vy);

  /// Timestamp of the newest sample (0 when unprimed). Lets the caller reject
  /// stale velocity at release time (see [flingMaxSampleAgeMs]).
  double get lastSampleTimeMs => _lastT;
}

/// Caller-driven momentum integrator (port of the `startInertia` frame loop
/// in packages/gesture-engine/src/index.ts).
///
/// Call [start] with the release velocity; then call [tick] once per frame
/// with a monotonic timestamp. Each tick returns the integer scroll delta to
/// emit for that frame (possibly `(0, 0)` while fractional pixels accumulate),
/// or `null` once the fling has decayed below [scrollInertiaStopVelocity].
class InertiaScroller {
  bool _active = false;
  double _vx0 = 0;
  double _vy0 = 0;
  double _speed0 = 0;
  double _startT = 0;
  double _lastT = 0;
  double _carryX = 0;
  double _carryY = 0;

  bool get isActive => _active;

  /// Begin a fling released at [nowMs] with velocity ([vx], [vy]) in host
  /// px/s. Returns false (and stays inactive) below the
  /// [scrollInertiaMinVelocity] start threshold.
  bool start(double vx, double vy, double nowMs) {
    final speed = math.sqrt(vx * vx + vy * vy);
    if (speed < scrollInertiaMinVelocity) return false;
    _active = true;
    _vx0 = vx;
    _vy0 = vy;
    _speed0 = speed;
    _startT = nowMs;
    _lastT = nowMs;
    _carryX = 0;
    _carryY = 0;
    return true;
  }

  /// Finger-catch: a new touch stops any running fling immediately.
  void cancel() {
    _active = false;
  }

  /// Advance the fling to [nowMs]. Returns the integer scroll delta for this
  /// frame, or `null` when inertia has stopped (or was never active).
  ({int dx, int dy})? tick(double nowMs) {
    if (!_active) return null;
    final dtSec = math.max(0.0, (nowMs - _lastT) / 1000);
    _lastT = nowMs;
    final elapsed = (nowMs - _startT) / 1000;
    if (decayVelocity(_speed0, elapsed) < scrollInertiaStopVelocity) {
      _active = false;
      return null;
    }
    final vxNow = _vx0 * math.exp(-scrollInertiaLambda * elapsed);
    final vyNow = _vy0 * math.exp(-scrollInertiaLambda * elapsed);
    _carryX += vxNow * dtSec;
    _carryY += vyNow * dtSec;
    final ix = _carryX.truncate();
    final iy = _carryY.truncate();
    if (ix != 0 || iy != 0) {
      _carryX -= ix;
      _carryY -= iy;
    }
    return (dx: ix, dy: iy);
  }
}
