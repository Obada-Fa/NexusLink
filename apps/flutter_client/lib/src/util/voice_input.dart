// Android SpeechRecognizer returns ERROR_CLIENT ("error_client") when
// listen extras or Bluetooth SCO steal the mic. Keep this config conservative:
// no pauseFor (maps to EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS),
// no dictation-only extras, no Bluetooth voice routing.

import 'dart:ui' show Locale;

import 'package:speech_to_text/speech_to_text.dart';

/// Plugin init flags that avoid OEM recognizer and Bluetooth SCO failures.
List<SpeechConfigOption> speechInitOptions() => [
      SpeechToText.androidNoBluetooth,
      SpeechToText.androidIntentLookup,
    ];

/// Listen flags that Google's online recognizer actually accepts.
SpeechListenOptions speechListenOptions() => SpeechListenOptions(
      listenMode: ListenMode.confirmation,
      partialResults: true,
      cancelOnError: false,
      onDevice: false,
      listenFor: const Duration(seconds: 60),
    );

/// BCP-47-ish id for [SpeechToText.listen] (`en_US`, or `en` if no region).
String speechLocaleId(Locale locale) {
  final country = locale.countryCode;
  if (country == null || country.isEmpty) return locale.languageCode;
  return '${locale.languageCode}_$country';
}

bool isSpeechStatusListening(String status) =>
    status == 'listening' || status == 'recording';

bool isBenignSpeechError(String errorMsg) {
  switch (errorMsg) {
    case 'error_speech_timeout':
    case 'error_no_match':
      return true;
    default:
      return false;
  }
}

String speechErrorMessage(String errorMsg) {
  switch (errorMsg) {
    case 'error_client':
    case 'error_audio':
      return 'Could not start the microphone. Try again.';
    case 'error_permission':
    case 'error_insufficient_permissions':
      return 'Microphone permission is required for voice input.';
    case 'error_network':
    case 'error_network_timeout':
    case 'error_server':
    case 'error_server_disconnected':
      return 'Speech recognition needs a network connection.';
    case 'error_busy':
      return 'Speech recognition is busy. Try again in a moment.';
    default:
      return 'Speech recognition error: $errorMsg';
  }
}
