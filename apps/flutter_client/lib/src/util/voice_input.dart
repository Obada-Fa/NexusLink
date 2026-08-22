// Android SpeechRecognizer returns ERROR_CLIENT ("error_client") when
// listen extras or Bluetooth SCO steal the mic. Keep this config conservative:
// no pauseFor (maps to EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS),
// no dictation-only extras, no Bluetooth voice routing.

import 'dart:ui' show Locale;

import 'package:speech_to_text/speech_to_text.dart';

/// Plugin init flags that avoid OEM recognizer and Bluetooth SCO failures.
List<SpeechConfigOption> speechInitOptions() => [
      SpeechToText.androidNoBluetooth,
    ];

/// Error message when the speech recognition *service* lacks mic access or fails
/// to bind, distinct from the *app* lacking RECORD_AUDIO permission.
const String speechServicePermissionErrorMessage =
    'Speech recognition failed. On GrapheneOS or privacy-focused Android, '
    'ensure "Speech Services by Google" (or your voice input provider) '
    'has microphone permission, then try again.';

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

bool isSpeechStatusEnded(String status) =>
    status == 'done' || status == 'notListening';

bool isBenignSpeechError(String errorMsg) {
  switch (errorMsg) {
    case 'error_speech_timeout':
    case 'error_no_match':
      return true;
    default:
      return false;
  }
}

/// Google's recognizer ends on silence. Restart until the user taps Stop.
bool shouldRestartListen({
  required bool userWantsListen,
  required bool sessionWasActive,
  String? status,
  String? errorMsg,
}) {
  if (!userWantsListen) return false;
  if (errorMsg != null && errorMsg.isNotEmpty) {
    return isBenignSpeechError(errorMsg);
  }
  if (!sessionWasActive) return false;
  if (status == null || status.isEmpty) return false;
  if (isSpeechStatusListening(status)) return false;
  return isSpeechStatusEnded(status);
}

/// Freeze a final utterance so the next OS session appends instead of replacing.
String commitSpeechPrefix(String committed, String recognizedWords) {
  final words = recognizedWords.trim();
  if (words.isEmpty) return committed;
  if (committed.isEmpty) return '$words ';
  if (committed.endsWith(' ')) return '$committed$words ';
  return '$committed $words ';
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
