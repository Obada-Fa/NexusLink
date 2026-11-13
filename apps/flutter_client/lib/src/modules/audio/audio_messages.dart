// Plain-words labels and error messages for the Audio module.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nexus_audio/nexus_audio.dart';

import '../../theme/nexus_theme.dart';

/// Toggle titles, in screen order.
String streamTitle(AudioStream s) => switch (s) {
  AudioStream.mic => 'Use as PC mic',
  AudioStream.playHere => 'Play PC audio here',
  AudioStream.sendDevice => 'Play phone audio on PC',
};

/// One line under each toggle title.
String streamDescription(AudioStream s, String pc) => switch (s) {
  AudioStream.mic => 'Your phone becomes $pc’s microphone.',
  AudioStream.playHere => 'Hear $pc’s speakers on this phone.',
  AudioStream.sendDevice => 'Music and apps on this phone play on $pc.',
};

/// Short name for tile dots and the live bar.
String streamShortName(AudioStream s) => switch (s) {
  AudioStream.mic => 'Mic',
  AudioStream.playHere => 'PC audio',
  AudioStream.sendDevice => 'Phone audio',
};

String liveActivityLabel(AudioStream s, String pc) => switch (s) {
  AudioStream.mic => 'Phone mic to $pc',
  AudioStream.playHere => '$pc audio here',
  AudioStream.sendDevice => 'Phone audio to $pc',
};

IconData streamIcon(AudioStream s) => switch (s) {
  AudioStream.mic => Icons.mic_rounded,
  AudioStream.playHere => Icons.headphones_rounded,
  AudioStream.sendDevice => Icons.cast_rounded,
};

String phaseLabel(StreamPhase p) => switch (p) {
  StreamPhase.off => 'Off',
  StreamPhase.connecting => 'Connecting',
  StreamPhase.live => 'Live',
  StreamPhase.retrying => 'Retrying',
};

Color phaseColor(StreamPhase p) => switch (p) {
  StreamPhase.off => NX.idle,
  StreamPhase.connecting => NX.accent,
  StreamPhase.live => NX.working,
  StreamPhase.retrying => NX.waiting,
};

/// What went wrong starting a stream, and what the screen can offer.
class AudioStartError {
  const AudioStartError(
    this.message, {
    this.openSettings = false,
    this.pairAgain = false,
  });
  final String message;

  /// Offer "Open settings" (a permission is off).
  final bool openSettings;

  /// Offer a fresh QR scan (the pairing is broken).
  final bool pairAgain;
}

/// Maps a [NexusAudio.start] failure to words a person can act on.
AudioStartError audioStartError(AudioStream stream, Object error) {
  final code = error is PlatformException ? error.code : null;
  return switch (code) {
    AudioErrors.micPermission => AudioStartError(
      stream == AudioStream.sendDevice
          ? 'Sharing phone audio records through the microphone permission, '
                'and Nexus doesn’t have it. Allow Microphone for Nexus in '
                'Settings, then try again.'
          : 'Nexus isn’t allowed to use the microphone. Allow Microphone for '
                'Nexus in Settings, then try again.',
      openSettings: true,
    ),
    AudioErrors.consentDenied => const AudioStartError(
      'Phone audio sharing wasn’t allowed. Turn it on again and choose '
      '“Start now”, with Nexus open on screen.',
    ),
    AudioErrors.unsupported => const AudioStartError(
      'Playing phone audio on the PC needs Android 10 or newer.',
    ),
    AudioErrors.badArgs => const AudioStartError(
      'The Audio pairing for this PC is incomplete. Scan the QR code from '
      'Nexus Utilities to pair again.',
      pairAgain: true,
    ),
    _ => AudioStartError(
      'Couldn’t start ${streamShortName(stream).toLowerCase()}: '
      '${error is PlatformException ? (error.message ?? error.code) : error}',
    ),
  };
}

/// Shown when the person refuses the microphone permission in the dialog.
String micRefusedMessage(AudioStream stream, {required bool permanently}) {
  final what = stream == AudioStream.sendDevice
      ? 'Playing phone audio on the PC needs the microphone permission '
            '(Android records app audio through it).'
      : 'Using the phone as the PC’s mic needs the microphone permission.';
  return permanently
      ? '$what It’s turned off for Nexus: open Settings → Permissions → '
            'Microphone and choose “Allow”.'
      : '$what Turn the switch on again and choose “Allow”.';
}

const notificationsRefusedMessage =
    'Notifications are off for Nexus, so the audio controls won’t show in '
    'the notification shade. Streams still run; stop them here or from '
    'the live bar.';
