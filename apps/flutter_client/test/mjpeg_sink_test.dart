import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nexuslink/src/util/mjpeg_sink.dart';

void main() {
  test('LatestJpegGate keeps only the newest frame', () {
    final gate = LatestJpegGate();
    gate.offer(Uint8List.fromList([1]));
    gate.offer(Uint8List.fromList([2, 2]));
    final taken = gate.take();
    expect(taken, isNotNull);
    expect(taken!.length, 2);
    expect(gate.take(), isNull);
  });

  test('LatestJpegGate reports pending while a JPEG is queued', () {
    final gate = LatestJpegGate();
    expect(gate.hasPending, isFalse);
    gate.offer(Uint8List.fromList([9]));
    expect(gate.hasPending, isTrue);
    gate.take();
    expect(gate.hasPending, isFalse);
  });
}
