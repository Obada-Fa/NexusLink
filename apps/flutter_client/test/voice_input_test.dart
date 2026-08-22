import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/util/voice_input.dart';
import 'package:speech_to_text/speech_to_text.dart';

void main() {
  test('Android init skips Bluetooth SCO and does not force intent lookup', () {
    final names = speechInitOptions().map((o) => o.name).toList();
    expect(names, contains('noBluetooth'));
    expect(names, isNot(contains('intentLookup')));
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
    expect(speechErrorMessage('error_permission'), contains('Microphone'));
  });

  test('locale ids match what Android SpeechRecognizer expects', () {
    expect(speechLocaleId(const Locale('en', 'US')), 'en_US');
    expect(speechLocaleId(const Locale('nl', 'NL')), 'nl_NL');
    expect(speechLocaleId(const Locale('en')), 'en');
  });

  test('listening statuses include recording', () {
    expect(isSpeechStatusListening('listening'), isTrue);
    expect(isSpeechStatusListening('recording'), isTrue);
    expect(isSpeechStatusListening('done'), isFalse);
  });

  test('restarts after silence when the user still wants listen', () {
    expect(
      shouldRestartListen(
        userWantsListen: true,
        sessionWasActive: false,
        errorMsg: 'error_speech_timeout',
      ),
      isTrue,
    );
    expect(
      shouldRestartListen(
        userWantsListen: true,
        sessionWasActive: true,
        errorMsg: 'error_no_match',
      ),
      isTrue,
    );
    expect(
      shouldRestartListen(
        userWantsListen: true,
        sessionWasActive: true,
        status: 'done',
      ),
      isTrue,
    );
    expect(
      shouldRestartListen(
        userWantsListen: true,
        sessionWasActive: true,
        status: 'notListening',
      ),
      isTrue,
    );
  });

  test('does not restart after stop or hard errors', () {
    expect(
      shouldRestartListen(
        userWantsListen: false,
        sessionWasActive: true,
        status: 'done',
      ),
      isFalse,
    );
    expect(
      shouldRestartListen(
        userWantsListen: true,
        sessionWasActive: false,
        status: 'notListening',
      ),
      isFalse,
    );
    expect(
      shouldRestartListen(
        userWantsListen: true,
        sessionWasActive: true,
        status: 'listening',
      ),
      isFalse,
    );
    expect(
      shouldRestartListen(
        userWantsListen: true,
        sessionWasActive: true,
        errorMsg: 'error_client',
      ),
      isFalse,
    );
    expect(
      shouldRestartListen(
        userWantsListen: true,
        sessionWasActive: true,
        errorMsg: 'error_permission',
      ),
      isFalse,
    );
    expect(
      shouldRestartListen(
        userWantsListen: true,
        sessionWasActive: true,
        errorMsg: 'error_network',
      ),
      isFalse,
    );
  });

  test('commitSpeechPrefix concatenates finals without dropping the first', () {
    expect(commitSpeechPrefix('', 'hello'), 'hello ');
    expect(commitSpeechPrefix('hello ', 'world'), 'hello world ');
    expect(commitSpeechPrefix('hello', 'world'), 'hello world ');
    expect(commitSpeechPrefix('hello ', '  '), 'hello ');
  });
}
