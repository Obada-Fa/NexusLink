import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/gestures/scale_to_host.dart';
import 'package:nexuslink/src/screens/mirror_fit.dart';

void main() {
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
