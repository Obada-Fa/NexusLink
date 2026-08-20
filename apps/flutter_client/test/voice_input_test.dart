import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/util/voice_input.dart';
import 'package:speech_to_text/speech_to_text.dart';

void main() {
  test('Android init skips Bluetooth SCO and looks up the recognizer', () {
    final names = speechInitOptions().map((o) => o.name).toList();
    expect(names, containsAll(['noBluetooth', 'intentLookup']));
  });

  test('listen options omit pauseFor extras that trigger error_client', () {
    final opts = speechListenOptions();
    expect(opts.pauseFor, isNull);
    expect(opts.listenMode, ListenMode.confirmation);
    expect(opts.onDevice, isFalse);
    expect(opts.cancelOnError, isFalse);
    expect(opts.listenFor, const Duration(seconds: 60));
  });

  test('timeouts are silent; client errors stay visible', () {
    expect(isBenignSpeechError('error_speech_timeout'), isTrue);
    expect(isBenignSpeechError('error_no_match'), isTrue);
    expect(isBenignSpeechError('error_client'), isFalse);
    expect(speechErrorMessage('error_client'), contains('microphone'));
  });
}
