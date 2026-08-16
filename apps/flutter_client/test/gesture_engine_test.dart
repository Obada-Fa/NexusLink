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
  GestureMode mode = GestureMode.touch,
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

    test('handles wider view than host (letterbox top/bottom)', () {
      final result = scaleToHost(100, 50, 200, 100, 1920, 1080);
      expect(result.x, 960);
      expect(result.y, greaterThan(0));
      expect(result.y, lessThan(1080));
    });

    test('handles taller view than host (letterbox left/right)', () {
      final result = scaleToHost(50, 100, 100, 200, 1920, 1080);
      expect(result.x, greaterThan(0));
      expect(result.x, lessThan(1920));
      expect(result.y, greaterThan(0));
      expect(result.y, lessThan(1080));
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

    test('movement past the tap slop suppresses the tap and starts a drag', () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 200)], 0);
      engine.onTouchMove([tp(150, 260)], 50);
      engine.onTouchEnd([], 100);

      expect(events.whereType<TapEvent>(), isEmpty);
      expect(events.whereType<DragStartEvent>(), hasLength(1));
      expect(events.whereType<DragEndEvent>(), hasLength(1));
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

  group('GestureEngine — touch-mode drag (RustDesk)', () {
    test('one-finger pan emits DragEvents, never Scroll or MouseMove', () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(200, 600)], 0);
      engine.onTouchMove([tp(200, 540)], 16);
      engine.onTouchMove([tp(200, 480)], 32);
      engine.onTouchEnd([], 48);

      expect(events.whereType<DragStartEvent>(), hasLength(1));
      expect(events.whereType<DragMoveEvent>(), isNotEmpty);
      expect(events.whereType<DragEndEvent>(), hasLength(1));
      expect(events.whereType<ScrollEvent>(), isEmpty);
      expect(events.whereType<MouseMoveEvent>(), isEmpty);
      expect(events.whereType<TapEvent>(), isEmpty);
      // Button-down anchors at the original touch point.
      final start = events.whereType<DragStartEvent>().single;
      expect(start.x, closeTo(200 * (1080 / 375), 1.0));
      expect(start.y, closeTo(600 * (1920 / 667), 1.0));
    });

    test('tiny jitter under tap slop still counts as a tap', () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 200)], 0);
      engine.onTouchMove([tp(101, 201)], 16); // ~3 host px
      engine.onTouchEnd([], 80);

      expect(events.whereType<TapEvent>(), hasLength(1));
      expect(events.whereType<DragStartEvent>(), isEmpty);
    });

    test('GestureMode.direct aliases touch (one-finger drag)', () {
      final (engine, events) = setupEngine(mode: GestureMode.direct);
      engine.onTouchStart([tp(200, 600)], 0);
      engine.onTouchMove([tp(200, 500)], 16);
      engine.onTouchEnd([], 32);

      expect(events.whereType<DragStartEvent>(), hasLength(1));
      expect(events.whereType<ScrollEvent>(), isEmpty);
    });
  });

  group('GestureEngine — two-finger scroll momentum', () {
    test('fast two-finger flick produces decaying inertial scrolls', () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 600), tp(150, 600, 1)], 0);
      var y = 600.0;
      var t = 0.0;
      for (var i = 0; i < 5; i++) {
        t += 16;
        y -= 40;
        engine.onTouchMove([tp(100, y), tp(150, y, 1)], t);
      }
      engine.onTouchEnd([], t);
      expect(engine.inertiaActive, isTrue);

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
      expect(inertial.first.deltaY, greaterThan(inertial.last.deltaY));
    });

    test('a new touch finger-catches a running fling', () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 600), tp(150, 600, 1)], 0);
      var y = 600.0;
      var t = 0.0;
      for (var i = 0; i < 5; i++) {
        t += 16;
        y -= 40;
        engine.onTouchMove([tp(100, y), tp(150, y, 1)], t);
      }
      engine.onTouchEnd([], t);

      for (var i = 0; i < 3; i++) {
        t += 16;
        engine.tick(t);
      }
      expect(
        events.whereType<ScrollEvent>().where((s) => s.inertial),
        isNotEmpty,
      );

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

    test('slow two-finger pan below the fling threshold does not start inertia',
        () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 600), tp(150, 600, 1)], 0);
      var y = 600.0;
      var t = 0.0;
      for (var i = 0; i < 4; i++) {
        t += 200;
        y -= 5;
        engine.onTouchMove([tp(100, y), tp(150, y, 1)], t);
      }
      engine.onTouchEnd([], t);

      expect(engine.inertiaActive, isFalse);
      expect(
        events.whereType<ScrollEvent>().where((s) => s.inertial),
        isEmpty,
      );
    });
  });

  group('GestureEngine — long press and drag', () {
    test('still hold fires ContextEvent from the tick driver', () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 200)], 0);
      engine.tick(longPressThresholdMs + 20);
      expect(events.whereType<ContextEvent>(), hasLength(1));

      // Release adds nothing further.
      engine.onTouchEnd([], longPressThresholdMs + 100);
      expect(events, hasLength(1));
    });

    test('hold past the threshold fires context at release without a driver',
        () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 200)], 0);
      engine.onTouchEnd([], longPressThresholdMs + 100);

      expect(events.whereType<ContextEvent>(), hasLength(1));
      expect(events.whereType<TapEvent>(), isEmpty);
    });

    test('long-press then move does NOT start a left-drag (RustDesk)', () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 200)], 0);
      engine.tick(longPressThresholdMs + 20);
      engine.onTouchMove([tp(140, 250)], longPressThresholdMs + 40);
      engine.onTouchMove([tp(170, 280)], longPressThresholdMs + 60);
      engine.onTouchEnd([], longPressThresholdMs + 80);

      expect(events.whereType<ContextEvent>(), hasLength(1));
      expect(events.whereType<DragStartEvent>(), isEmpty);
      expect(events.whereType<DragMoveEvent>(), isEmpty);
      expect(events.whereType<DragEndEvent>(), isEmpty);
    });

    test('significant movement cancels the pending long press and starts drag',
        () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 200)], 0);
      // >10 host px from the origin: cancels the long press, starts drag.
      engine.onTouchMove([tp(120, 220)], 100);
      engine.tick(600);
      engine.onTouchEnd([], 650);

      expect(events.whereType<ContextEvent>(), isEmpty);
      expect(events.whereType<DragStartEvent>(), hasLength(1));
      expect(events.whereType<DragEndEvent>(), hasLength(1));
    });
  });

  group('GestureEngine — multi-touch', () {
    test('two-finger pinch outward emits positive ZoomEvent', () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 300), tp(200, 300, 1)], 0);
      engine.onTouchMove([tp(70, 300), tp(230, 300, 1)], 16);
      engine.onTouchEnd([], 32);

      final zooms = events.whereType<ZoomEvent>().toList();
      expect(zooms, isNotEmpty);
      expect(zooms.first.scale, greaterThan(0));
    });

    test('two-finger pan emits ScrollEvents', () {
      final (engine, events) = setupEngine();
      engine.onTouchStart([tp(100, 200), tp(150, 250, 1)], 0);
      engine.onTouchMove([tp(100, 260), tp(150, 310, 1)], 16);
      engine.onTouchEnd([], 32);

      expect(events.whereType<ScrollEvent>(), isNotEmpty);
      expect(events.whereType<ZoomEvent>(), isEmpty);
    });

    test('three-finger tap emits a middle click', () {
      final (engine, events) = setupEngine();
      engine.onTouchStart(
        [tp(100, 200), tp(150, 200, 1), tp(200, 200, 2)],
        0,
      );
      engine.onTouchEnd([], 100);

      expect(events.whereType<MiddleClickEvent>(), hasLength(1));
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
      expect(events.whereType<DragStartEvent>(), isEmpty);
    });

    test('precision flag forces relative movement even in touch mode', () {
      final (engine, events) =
          setupEngine(mode: GestureMode.touch, precision: true);
      engine.onTouchStart([tp(200, 600)], 0);
      engine.onTouchMove([tp(200, 500)], 16);
      engine.onTouchEnd([], 32);

      expect(events.whereType<MouseMoveEvent>(), isNotEmpty);
      expect(events.whereType<ScrollEvent>(), isEmpty);
      expect(events.whereType<DragStartEvent>(), isEmpty);
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
  });
}
