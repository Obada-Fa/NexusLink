import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/gestures/scale_to_host.dart';
import 'package:nexuslink/src/screens/mirror_fit.dart';

void main() {
  test('WebRTC upgrade is session-only', () {
    expect(shouldUpgradeWebrtc(isVirtual: false, sessionId: null), isFalse);
    expect(shouldUpgradeWebrtc(isVirtual: true, sessionId: null), isFalse);
    expect(shouldUpgradeWebrtc(isVirtual: true, sessionId: ''), isFalse);
    expect(
        shouldUpgradeWebrtc(isVirtual: false, sessionId: 'abc'), isFalse);
    expect(shouldUpgradeWebrtc(isVirtual: true, sessionId: 'abc'), isTrue);
  });

  test('adopted windows and virtual sessions fill the view', () {
    expect(mirrorFillsView(isVirtual: true, hasWindow: false), isTrue);
    expect(mirrorFillsView(isVirtual: false, hasWindow: true), isTrue);
    expect(mirrorFillsView(isVirtual: false, hasWindow: false), isFalse);
    expect(mirrorScaleFit(fill: true), ScaleFit.fill);
    expect(mirrorScaleFit(fill: false), ScaleFit.contain);
    expect(mirrorBoxFit(fill: true), BoxFit.fill);
    expect(mirrorBoxFit(fill: false), BoxFit.contain);
  });
}
