// Dart port of the NexusLink gesture-engine behavioural contract:
// packages/gesture-engine/src/__tests__/gesture-engine.test.ts and
// gesture-engine-v2.test.ts.
//
// All time is driven explicitly through millisecond timestamps — no real
// timers, no Tickers: the engine is fully deterministic.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/gestures/gesture_engine.dart';

TouchPoint tp(double x, double y, [int id = 0]) => TouchPoint(id, x, y);

/// Mirrors the TS test harness: 375x667 view, portrait 1080x1920 host
/// (~1:1 aspect with the view, so host deltas are ~2.879x view deltas).
(GestureEngine, List<GestureEvent>) setupEngine({
  GestureMode mode = GestureMode.direct,
  bool precision = false,
  double hostW = 1080,
  double hostH = 1920,
}) {
  final events = <GestureEvent>[];
  final engine = GestureEngine(
    onGesture: events.add,
    mode: mode,
    precision: precision,
  );
  engine.setHostDimensions(hostW, hostH);
  engine.setViewSize(375, 667);
  return (engine, events);
}

void main() {
  group('scaleToHost', () {
    test('scales with matching aspect ratio (no letterbox)', () {
      final result = scaleToHost(50, 50, 100, 100, 1920, 1080);
      expect(result.x, 960);
      expect(result.y, 540);
    });

    test('handles wider view than host (letterbox left/right)', () {
      final result = scaleToHost(100, 50, 200, 100, 1920, 1080);
      expect(result.x, 960);
      expect(result.y, 540);
    });

    test('handles taller view than host (letterbox top/bottom)', () {
      final result = scaleToHost(50, 100, 100, 200, 1920, 1080);
      expect(result.x, 960);
      expect(result.y, 540);
    });

    test('maps a tap on the painted content, not the letterbox, on a tall phone', () {
      final mid = scaleToHost(195, 390, 390, 780, 1920, 1080);
      expect(mid.x, 960);
      expect(mid.y, 540);
      final topBar = scaleToHost(195, 10, 390, 780, 1920, 1080);
      expect(topBar.y, 0);
    });

    test('clamps output to host bounds', () {
      final low = scaleToHost(-100, -100, 100, 100, 1920, 1080);
      expect(low.x, 0);
      expect(low.y, 0);

      final high = scaleToHost(500, 500, 100, 100, 1920, 1080);
      expect(high.x, 1920);
      expect(high.y, 1080);
    });

    test('returns zero for invalid dimensions', () {
      expect(scaleToHost(50, 50, 0, 100, 1920, 1080), (x: 0.0, y: 0.0));
      expect(scaleToHost(50, 50, 100, 0, 1920, 1080), (x: 0.0, y: 0.0));
      expect(scaleToHost(50, 50, 100, 100, 0, 1080), (x: 0.0, y: 0.0));
    });

    test('perfect square views map center correctly', () {
      final result = scaleToHost(100, 100, 200, 200, 1920, 1080);
      expect(result.x, 960);
      expect(result.y, 540);
    });

    test('fill fit maps the view corner to the host corner (no letterbox)', () {
      final result = scaleToHost(100, 200, 200, 400, 780, 1688, ScaleFit.fill);
      expect(result.x, 390);
      expect(result.y, 844);
    });
  });

  group('scroll physics', () {
    test('decayVelocity is identity at t=0 and monotonically decreasing', () {
      expect(decayVelocity(1000, 0), 1000);
      final a = decayVelocity(1000, 0.1);
      final b = decayVelocity(1000, 0.2);
      expect(a, lessThan(1000));
      expect(b, lessThan(a));
      expect(b, greaterThan(0));
    });

    test('decay matches the closed form e^(-lambda*t)', () {
      const t = 0.3;
      expect(
        decayVelocity(1000, t),
        closeTo(1000 * math.exp(-scrollInertiaLambda * t), 1e-6),
      );
    });

    test('inertiaDisplacement over [0,inf) equals total distance v0/lambda',
        () {
      const v0 = 900.0;
      final total = inertiaTotalDistance(v0);
      expect(total, closeTo(v0 / scrollInertiaLambda, 1e-6));
      expect(inertiaDisplacement(v0, 0, 100), closeTo(total, 1e-4));
    });

    test('inertiaDisplacement is additive across contiguous intervals', () {
      const v0 = 500.0;
      final whole = inertiaDisplacement(v0, 0, 1);
      final part =
          inertiaDisplacement(v0, 0, 0.4) + inertiaDisplacement(v0, 0.4, 1);
      expect(part, closeTo(whole, 1e-9));
    });

    test('ScrollVelocityTracker converges toward a sustained velocity', () {
      final tr = ScrollVelocityTracker();
      // 20 px every 10ms == 2000 px/s, sustained.
      var t = 0.0;
      tr.addSample(0, 0, t); // priming sample
      for (var i = 0; i < 30; i++) {
        t += 10;
        tr.addSample(0, 20, t);
      }
      expect(tr.vy, greaterThan(1500));
      expect(tr.vy, lessThan(2500));
      expect(tr.vx, closeTo(0, 1e-5));
      expect(tr.speed, greaterThan(1500));
    });

    test('InertiaScroller refuses to start below the fling threshold', () {
      final s = InertiaScroller();
      expect(s.start(0, scrollInertiaMinVelocity - 1, 0), isFalse);
      expect(s.isActive, isFalse);
      expect(s.tick(16), isNull);
    });

    test('InertiaScroller integrates a decaying fling to ~v0/lambda', () {
      final s = InertiaScroller();
      expect(s.start(0, 1000, 0), isTrue);

      var total = 0;
      final deltas = <int>[];
      var t = 0.0;
      var frames = 0;
      while (frames < 500) {
        t += 16;
        frames++;
        final d = s.tick(t);
        if (d == null) break;
        expect(d.dx, 0);
        total += d.dy;
        deltas.add(d.dy);
      }

      expect(s.isActive, isFalse);
      // Frame-quantised integration slightly undershoots the closed form.
      expect(total.toDouble(), closeTo(inertiaTotalDistance(1000), 15));
      // Exponential decay: early frames move much more than late frames.
      expect(deltas.first, greaterThan(10));
      expect(deltas.first, greaterThan(deltas.last + 5));
      // Fling of 1000 px/s should last well over a second at 60fps.
      expect(deltas.length, greaterThan(60));
      // Once stopped it stays stopped.
      expect(s.tick(t + 16), isNull);
    });
  });

  group('classifier helpers', () {
    test('resolveAxis returns none below the travel threshold', () {
      expect(resolveAxis(2, 3), Axis.none);
    });

    test('resolveAxis locks vertical / horizontal / free by angle', () {
      expect(resolveAxis(0, 40), Axis.vertical);
      expect(resolveAxis(0, -40), Axis.vertical);
      expect(resolveAxis(40, 0), Axis.horizontal);
      expect(resolveAxis(-40, 2), Axis.horizontal);
      expect(resolveAxis(30, 30), Axis.free); // 45deg diagonal
    });

    test('projectToAxis zeroes the off-axis component', () {
      expect(projectToAxis(5, 9, Axis.vertical), (dx: 0.0, dy: 9.0));
      expect(projectToAxis(5, 9, Axis.horizontal), (dx: 5.0, dy: 0.0));
      expect(projectToAxis(5, 9, Axis.free), (dx: 5.0, dy: 9.0));
    });

    test('isTap / isDoubleTap honour their boundaries', () {
      expect(isTap(120, 3), isTrue);
      expect(isTap(600, 3), isFalse);
      expect(isTap(120, 40), isFalse);
      expect(isDoubleTap(200, 5), isTrue);
      expect(isDoubleTap(400, 5), isFalse);
      expect(isDoubleTap(200, 50), isFalse);
    });

    test('constants match the TS contract', () {
      expect(panSensitivity, 5);
      expect(scrollSensitivity, 10);
      expect(longPressThresholdMs, 500);
      expect(longPressMaxMovePx, 10);
      expect(axisLockTravelPx, 12);
      expect(axisLockConeDeg, 22.5);
      expect(tapMaxMovePx, 8);
      expect(scrollInertiaLambda, 3.3);
      expect(scrollInertiaMinVelocity, 250);
      expect(scrollInertiaStopVelocity, 4);
      expect(velocityEmaAlpha, 0.4);
      expect(minSampleDtMs, 4);
    });
  });

  group('GestureEngine — taps', () {
    test('quick touch emits a single TapEvent in host coordinates', () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 200)], 0);
      engine.onTouchEnd([], 100);

      expect(events, hasLength(1));
      final tap = events.single as TapEvent;
      expect(tap.x, inInclusiveRange(0, 1080));
      expect(tap.y, inInclusiveRange(0, 1920));
      // ~2.879x scale from the 375x667 view onto the 1080x1920 host.
      expect(tap.y, closeTo(200 * (1920 / 667), 1.0));
    });

    test('two quick taps emit Tap then DoubleTap', () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 200)], 0);
      engine.onTouchEnd([], 100);
      engine.onTouchStart([tp(102, 202)], 150);
      engine.onTouchEnd([], 250);

      expect(events.whereType<TapEvent>(), hasLength(1));
      expect(events.whereType<DoubleTapEvent>(), hasLength(1));
    });

    test('taps outside the double-tap window stay single taps', () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 200)], 0);
      engine.onTouchEnd([], 100);
      // Gap measured from the previous tap's emit time (100): 500 > 300.
      engine.onTouchStart([tp(100, 200)], 500);
      engine.onTouchEnd([], 600);

      expect(events.whereType<TapEvent>(), hasLength(2));
      expect(events.whereType<DoubleTapEvent>(), isEmpty);
    });

    test('movement past the tap slop becomes a scroll, not a tap', () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 200)], 0);
      engine.onTouchMove([tp(150, 260)], 50);
      engine.onTouchEnd([], 100);

      expect(events.whereType<TapEvent>(), isEmpty);
      expect(events.whereType<ScrollEvent>(), isNotEmpty);
      expect(events.whereType<DragStartEvent>(), isEmpty);
    });

    test('setHostDimensions rescales tap coordinates', () {
      final (engine, events) = setupEngine(hostW: 3840, hostH: 2160);
      engine.onTouchStart([tp(50, 50)], 0);
      engine.onTouchEnd([], 100);

      final tap = events.single as TapEvent;
      expect(tap.x, inInclusiveRange(0, 3840));
      expect(tap.y, inInclusiveRange(0, 2160));
    });
  });

  group('GestureEngine — native touch scroll', () {
    test('one-finger vertical pan emits scroll, never MouseMove or Drag', () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(200, 600)], 0);
      engine.onTouchMove([tp(200, 540)], 16);
      engine.onTouchMove([tp(200, 480)], 32);
      engine.onTouchEnd([], 48);

      expect(events.whereType<ScrollEvent>(), isNotEmpty);
      expect(events.whereType<DragStartEvent>(), isEmpty);
      expect(events.whereType<MouseMoveEvent>(), isEmpty);
    });

    test('horizontal pan is also a scroll (not a cursor chase)', () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 300)], 0);
      engine.onTouchMove([tp(160, 300)], 16);
      engine.onTouchMove([tp(220, 302)], 32);
      engine.onTouchEnd([], 48);

      expect(events.whereType<ScrollEvent>(), isNotEmpty);
      expect(events.whereType<MouseMoveEvent>(), isEmpty);
      expect(events.whereType<DragStartEvent>(), isEmpty);
    });
  });

  group('GestureEngine — momentum', () {
    test('fast one-finger flick produces decaying inertial scrolls until stop',
        () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(200, 600)], 0);
      var y = 600.0;
      var t = 0.0;
      for (var i = 0; i < 5; i++) {
        t += 16;
        y -= 40;
        engine.onTouchMove([tp(200, y)], t);
      }
      engine.onTouchEnd([], t);
      expect(engine.inertiaActive, isTrue);

      // Pump deterministic frames until the fling decays to a stop.
      var frames = 0;
      while (frames < 500) {
        t += 16;
        frames++;
        if (!engine.tick(t)) break;
      }
      expect(engine.inertiaActive, isFalse);

      final inertial = events
          .whereType<ScrollEvent>()
          .where((s) => s.inertial)
          .toList();
      expect(inertial.length, greaterThan(5));
      // Deltas decay over the fling.
      expect(inertial.first.deltaY, greaterThan(inertial.last.deltaY));
      // Inertial scrolls stay anchored at the release point (no drift).
      expect(inertial.map((s) => s.x).toSet(), hasLength(1));
      // Further ticks emit nothing.
      final count = events.length;
      expect(engine.tick(t + 16), isFalse);
      expect(events.length, count);
    });

    test('a new touch finger-catches a running fling', () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(200, 600)], 0);
      var y = 600.0;
      var t = 0.0;
      for (var i = 0; i < 5; i++) {
        t += 16;
        y -= 40;
        engine.onTouchMove([tp(200, y)], t);
      }
      engine.onTouchEnd([], t);

      // A few inertial frames...
      for (var i = 0; i < 3; i++) {
        t += 16;
        engine.tick(t);
      }
      expect(
        events.whereType<ScrollEvent>().where((s) => s.inertial),
        isNotEmpty,
      );

      // ...then the finger comes back down: the fling stops instantly.
      t += 16;
      engine.onTouchStart([tp(200, 600)], t);
      expect(engine.inertiaActive, isFalse);
      final countBefore = events.length;
      for (var i = 0; i < 20; i++) {
        t += 16;
        expect(engine.tick(t), isFalse);
      }
      expect(events.length, countBefore);
    });

    test('slow one-finger pan below the fling threshold does not start inertia',
        () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(200, 600)], 0);
      var y = 600.0;
      var t = 0.0;
      for (var i = 0; i < 4; i++) {
        t += 200; // very slow: large dt => low velocity
        y -= 5;
        engine.onTouchMove([tp(200, y)], t);
      }
      engine.onTouchEnd([], t);

      expect(engine.inertiaActive, isFalse);
      for (var i = 0; i < 20; i++) {
        t += 16;
        expect(engine.tick(t), isFalse);
      }
      expect(
        events.whereType<ScrollEvent>().where((s) => s.inertial),
        isEmpty,
      );
    });
  });

  group('GestureEngine — long press and drag', () {
    test('still hold fires ContextEvent on release after the tick arms it', () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 200)], 0);
      engine.tick(longPressThresholdMs + 20);
      expect(events.whereType<ContextEvent>(), isEmpty);

      engine.onTouchEnd([], longPressThresholdMs + 100);
      expect(events.whereType<ContextEvent>(), hasLength(1));
      expect(events.whereType<TapEvent>(), isEmpty);
    });

    test('hold past the threshold fires context at release without a driver',
        () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 200)], 0);
      engine.onTouchEnd([], longPressThresholdMs + 100);

      expect(events.whereType<ContextEvent>(), hasLength(1));
      expect(events.whereType<TapEvent>(), isEmpty);
    });

    test('long-press then move emits a drag without a context click', () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 200)], 0);
      engine.onTouchMove([tp(140, 250)], longPressThresholdMs + 40);
      engine.onTouchMove([tp(170, 280)], longPressThresholdMs + 60);
      engine.onTouchEnd([], longPressThresholdMs + 80);

      expect(events.whereType<ContextEvent>(), isEmpty);
      expect(events.whereType<DragStartEvent>(), hasLength(1));
      expect(events.whereType<DragMoveEvent>(), isNotEmpty);
      expect(events.whereType<DragEndEvent>(), hasLength(1));
      expect(events.whereType<ScrollEvent>(), isEmpty);
    });

    test('significant movement cancels the pending long press and starts a scroll',
        () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 200)], 0);
      engine.onTouchMove([tp(120, 220)], 100);
      engine.tick(600);
      engine.onTouchEnd([], 650);

      expect(events.whereType<ContextEvent>(), isEmpty);
      expect(events.whereType<ScrollEvent>(), isNotEmpty);
      expect(events.whereType<DragStartEvent>(), isEmpty);
    });
  });

  group('GestureEngine — multi-touch', () {
    test('two-finger pinch outward zooms the local view in', () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 300), tp(200, 300, 1)], 0);
      engine.onTouchMove([tp(70, 300), tp(230, 300, 1)], 16);
      engine.onTouchEnd([], 32);

      final steps = events.whereType<ViewTransformEvent>().toList();
      expect(steps, isNotEmpty);
      // Ratio of finger spread: 160 / 100.
      expect(steps.first.scale, closeTo(1.6, 1e-9));
      expect(steps.first.focalX, 150);
      expect(events.whereType<ScrollEvent>(), isEmpty);
      expect(events.whereType<TwoFingerTapEvent>(), isEmpty);
    });

    test('touch mode two-finger pan pans the view and never scrolls the PC',
        () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 200), tp(150, 250, 1)], 0);
      engine.onTouchMove([tp(100, 260), tp(150, 310, 1)], 16);
      engine.onTouchEnd([], 32);

      final step = events.whereType<ViewTransformEvent>().single;
      expect(step.scale, closeTo(1, 1e-9));
      expect(step.dy, 60);
      expect(events.whereType<ScrollEvent>(), isEmpty);
    });

    test('a finger left after a pinch does not ghost-scroll', () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 300), tp(200, 300, 1)], 0);
      engine.onTouchMove([tp(70, 300), tp(230, 300, 1)], 16);
      engine.onTouchEnd([tp(70, 300)], 32);
      engine.onTouchMove([tp(70, 400)], 48);
      engine.onTouchEnd([], 64);

      expect(events.whereType<ScrollEvent>(), isEmpty);
      expect(events.whereType<TapEvent>(), isEmpty);
    });

    test('touch mode two-finger tap is a TwoFingerTapEvent (zoom reset)', () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 200), tp(140, 200, 1)], 0);
      engine.onTouchEnd([], 80);

      expect(events.whereType<TwoFingerTapEvent>(), hasLength(1));
      expect(events.whereType<ContextEvent>(), isEmpty);
    });

    test('three-finger tap does not emit a middle click', () {
      final (engine, events) = setupEngine();
      engine.onTouchStart(
        [tp(100, 200), tp(150, 200, 1), tp(200, 200, 2)],
        0,
      );
      engine.onTouchEnd([], 100);

      expect(events.whereType<MiddleClickEvent>(), isEmpty);
      expect(events.whereType<TapEvent>(), isEmpty);
    });
  });

  group('GestureEngine — trackpad and precision modes', () {
    test('trackpad mode emits relative MouseMoveEvents', () {
      final (engine, events) = setupEngine(mode: GestureMode.trackpad);
      engine.onTouchStart([tp(100, 200)], 0);
      // 15/20 view px ~= 43/58 host px, beyond panSensitivity.
      engine.onTouchMove([tp(115, 220)], 16);
      engine.onTouchEnd([], 32);

      expect(events.whereType<MouseMoveEvent>(), isNotEmpty);
      expect(events.whereType<ScrollEvent>(), isEmpty);
    });

    test('precision flag forces relative movement even in direct mode', () {
      final (engine, events) =
          setupEngine(mode: GestureMode.direct, precision: true);
      engine.onTouchStart([tp(200, 600)], 0);
      engine.onTouchMove([tp(200, 500)], 16);
      engine.onTouchEnd([], 32);

      expect(events.whereType<MouseMoveEvent>(), isNotEmpty);
      expect(events.whereType<ScrollEvent>(), isEmpty);
    });

    test('precision divides deltas by the precision divisor', () {
      final (engine, events) =
          setupEngine(mode: GestureMode.trackpad, precision: true);
      engine.onTouchStart([tp(100, 200)], 0);
      engine.onTouchMove([tp(100, 300)], 16); // ~288 host px down
      engine.onTouchEnd([], 32);

      final move = events.whereType<MouseMoveEvent>().single;
      // 100 view px * (1920/667) / 3 ~= 95.95 -> truncated to 95.
      expect(move.dy, closeTo(100 * (1920 / 667) / precisionDivisor, 1.0));
    });

    test('mouse mode one-finger pan moves the pointer by the full delta', () {
      final (engine, events) = setupEngine(mode: GestureMode.mouse);
      engine.onTouchStart([tp(100, 200)], 0);
      engine.onTouchMove([tp(101, 201)], 8); // inside the slop
      engine.onTouchMove([tp(100, 230)], 16);
      engine.onTouchMove([tp(100, 260)], 24);
      engine.onTouchEnd([], 32);

      final deltas = events.whereType<PointerDeltaEvent>().toList();
      expect(deltas, isNotEmpty);
      // Nothing lost to the tap slop: the sum is the whole finger travel.
      expect(deltas.fold<double>(0, (a, d) => a + d.dy), 60);
      expect(deltas.every((d) => !d.dragging), isTrue);
      expect(events.whereType<ScrollEvent>(), isEmpty);
      expect(events.whereType<DragStartEvent>(), isEmpty);
      expect(events.whereType<TapEvent>(), isEmpty);
    });

    test('mouse mode tap with a few px of finger jitter is still a click', () {
      // 1920-wide desktop: 1 view px is ~5 host px, past the host-px slop.
      final (engine, events) =
          setupEngine(mode: GestureMode.mouse, hostW: 1920, hostH: 1080);
      engine.onTouchStart([tp(100, 200)], 0);
      engine.onTouchMove([tp(103, 202)], 30);
      engine.onTouchEnd([], 90);

      expect(events.whereType<TapEvent>(), hasLength(1));
      expect(events.whereType<PointerDeltaEvent>(), isEmpty);
    });

    test('mouse mode tap-then-hold-and-move drags', () {
      final (engine, events) = setupEngine(mode: GestureMode.mouse);
      engine.onTouchStart([tp(100, 200)], 0);
      engine.onTouchEnd([], 60); // tap
      engine.onTouchStart([tp(180, 400)], 160); // finger lands elsewhere
      engine.onTouchMove([tp(180, 450)], 200);
      engine.onTouchEnd([], 260);

      expect(events.whereType<TapEvent>(), hasLength(1));
      expect(events.whereType<DragStartEvent>(), hasLength(1));
      expect(events.whereType<DragEndEvent>(), hasLength(1));
      final deltas = events.whereType<PointerDeltaEvent>().toList();
      expect(deltas, isNotEmpty);
      expect(deltas.every((d) => d.dragging), isTrue);
    });

    test('mouse mode two-finger pan scrolls; a pinch zooms the view', () {
      final (engine, events) = setupEngine(mode: GestureMode.mouse);
      engine.onTouchStart([tp(100, 200), tp(150, 200, 1)], 0);
      engine.onTouchMove([tp(100, 240), tp(150, 240, 1)], 16);
      engine.onTouchMove([tp(100, 280), tp(150, 290, 1)], 32);
      engine.onTouchEnd([], 48);
      expect(events.whereType<ScrollEvent>(), isNotEmpty);
      expect(events.whereType<ViewTransformEvent>(), isEmpty);
      expect(events.whereType<ContextEvent>(), isEmpty);

      events.clear();
      engine.onTouchStart([tp(100, 300), tp(200, 300, 1)], 1000);
      engine.onTouchMove([tp(80, 300), tp(220, 300, 1)], 1016);
      engine.onTouchMove([tp(70, 300), tp(230, 300, 1)], 1032);
      engine.onTouchEnd([], 1048);
      expect(events.whereType<ViewTransformEvent>(), isNotEmpty);
      expect(events.whereType<ScrollEvent>(), isEmpty);
      // A quick pinch is not mistaken for a two-finger tap (right click).
      expect(events.whereType<ContextEvent>(), isEmpty);
    });

    test('mouse mode two-finger tap is a right click', () {
      final (engine, events) = setupEngine(mode: GestureMode.mouse);
      engine.onTouchStart([tp(100, 200), tp(140, 200, 1)], 0);
      engine.onTouchEnd([], 80);

      expect(events.whereType<ContextEvent>(), hasLength(1));
    });

    test('view mode: one finger pans the picture, nothing reaches the PC', () {
      final (engine, events) = setupEngine(mode: GestureMode.view);
      engine.onTouchStart([tp(100, 200)], 0);
      engine.onTouchMove([tp(100, 260)], 16);
      engine.onTouchEnd([], 32);
      engine.onTouchStart([tp(100, 200)], 1000);
      engine.tick(1000 + longPressThresholdMs + 50);
      engine.onTouchEnd([], 1000 + longPressThresholdMs + 60);

      expect(events.whereType<ViewTransformEvent>(), isNotEmpty);
      expect(events.whereType<ScrollEvent>(), isEmpty);
      expect(events.whereType<ContextEvent>(), isEmpty);
    });
  });

  group('ViewZoom', () {
    // Landscape 1920x1080 desktop on a 400x800 portrait phone: the picture
    // is letterboxed to 400x225 at y=287.5.
    const viewW = 400.0, viewH = 800.0;
    final rect = fittedContentRect(viewW, viewH, 1920, 1080, ScaleFit.contain);

    test('fittedContentRect letterboxes contain and fills fill', () {
      expect(rect.w, 400);
      expect(rect.h, 225);
      expect(rect.y, 287.5);
      final fill = fittedContentRect(viewW, viewH, 1920, 1080, ScaleFit.fill);
      expect((fill.x, fill.y, fill.w, fill.h), (0.0, 0.0, viewW, viewH));
    });

    test('pinch keeps the content under the fingers in place', () {
      final z = ViewZoom();
      final before = z.toContent(250, 400);
      z.applyStep(
        ratio: 2,
        focalX: 250,
        focalY: 400,
        dx: 0,
        dy: 0,
        rect: rect,
        viewW: viewW,
        viewH: viewH,
      );
      expect(z.scale, 2);
      final after = z.toContent(250, 400);
      expect(after.x, closeTo(before.x, 1e-9));
      expect(after.y, closeTo(before.y, 1e-9));
    });

    test('zoom is clamped to [1, 8] and returning to 1 recentres', () {
      final z = ViewZoom();
      for (var i = 0; i < 10; i++) {
        z.applyStep(
          ratio: 2,
          focalX: 10,
          focalY: 300,
          dx: 0,
          dy: 0,
          rect: rect,
          viewW: viewW,
          viewH: viewH,
        );
      }
      expect(z.scale, maxViewScale);
      z.applyStep(
        ratio: 0.01,
        focalX: 10,
        focalY: 300,
        dx: 0,
        dy: 0,
        rect: rect,
        viewW: viewW,
        viewH: viewH,
      );
      expect((z.scale, z.panX, z.panY), (1.0, 0.0, 0.0));
    });

    test('the picture cannot be dragged off screen', () {
      final z = ViewZoom();
      z.applyStep(
        ratio: 3,
        focalX: 200,
        focalY: 400,
        dx: 0,
        dy: 0,
        rect: rect,
        viewW: viewW,
        viewH: viewH,
      );
      // Fling far right/down: the picture's left edge stops at the screen's.
      z.applyStep(
        ratio: 1,
        focalX: 5000,
        focalY: 5000,
        dx: 4800,
        dy: 4600,
        rect: rect,
        viewW: viewW,
        viewH: viewH,
      );
      expect(z.toView(rect.x, rect.y).x, closeTo(0, 1e-9));
      // 225*3 = 675 tall < 800: vertically it stays centred.
      final top = z.toView(rect.x, rect.y).y;
      final bottom = z.toView(rect.x, rect.y + rect.h).y;
      expect(top, closeTo(viewH - bottom, 1e-9));
    });

    test('follow pans just enough to keep a point inside the margin', () {
      final z = ViewZoom();
      z.applyStep(
        ratio: 4,
        focalX: 200,
        focalY: 400,
        dx: 0,
        dy: 0,
        rect: rect,
        viewW: viewW,
        viewH: viewH,
      );
      final panX = z.panX;
      z.follow(395, 400, 40, rect, viewW, viewH);
      expect(z.panX, closeTo(panX - 35, 1e-9));
      // Unzoomed: follow never moves the picture.
      final flat = ViewZoom()..follow(399, 799, 40, rect, viewW, viewH);
      expect((flat.panX, flat.panY), (0.0, 0.0));
    });
  });

  group('VirtualCursor', () {
    test('pointerGain rises with speed and is bounded', () {
      expect(pointerGain(0), closeTo(0.9, 1e-9));
      expect(pointerGain(0.5), greaterThan(pointerGain(0.2)));
      expect(pointerGain(10), closeTo(2.6, 1e-9));
    });

    test('slow strokes track ~1:1 (scaled to host px); edges clamp', () {
      final c = VirtualCursor()..placeAt(100, 100);
      // 1 view px per 16 ms is slow: gain ~0.9 * 4.8 host px per view px.
      c.moveBy(1, 0, 0, 4.8, 1920, 1080);
      expect(c.x, closeTo(100 + 0.9 * 4.8, 0.01));
      c.endStroke();
      c.moveBy(-10000, 10000, 100, 4.8, 1920, 1080);
      expect((c.x, c.y), (0.0, 1079.0));
    });

    test('a fast flick travels further than a slow stroke of equal length',
        () {
      final slow = VirtualCursor()..placeAt(0, 0);
      for (var i = 1; i <= 10; i++) {
        slow.moveBy(2, 0, i * 16.0, 1, 5000, 5000);
      }
      final fast = VirtualCursor()..placeAt(0, 0);
      for (var i = 1; i <= 10; i++) {
        fast.moveBy(20, 0, i * 8.0, 0.1, 5000, 5000);
      }
      // Same 20 host px of raw travel each; the flick is accelerated.
      expect(fast.x, greaterThan(slow.x * 2));
    });
  });
}
