// Runtime permissions the Audio module asks for before NexusAudio.start.
// Behind an interface so tests don't need the permission_handler plugin.

import 'package:permission_handler/permission_handler.dart';

enum PermissionOutcome { granted, denied, permanentlyDenied }

abstract class AudioPermissions {
  /// RECORD_AUDIO (mic, and phone audio, which records through it).
  Future<PermissionOutcome> microphone();

  /// POST_NOTIFICATIONS (Android 13+; granted below).
  Future<PermissionOutcome> notifications();

  Future<bool> openSettings();
}

class SystemAudioPermissions implements AudioPermissions {
  const SystemAudioPermissions();

  static Future<PermissionOutcome> _ask(Permission p) async {
    var status = await p.status;
    if (!status.isGranted && !status.isPermanentlyDenied) {
      status = await p.request();
    }
    if (status.isGranted || status.isLimited) return PermissionOutcome.granted;
    return status.isPermanentlyDenied || status.isRestricted
        ? PermissionOutcome.permanentlyDenied
        : PermissionOutcome.denied;
  }

  @override
  Future<PermissionOutcome> microphone() => _ask(Permission.microphone);

  @override
  Future<PermissionOutcome> notifications() => _ask(Permission.notification);

  @override
  Future<bool> openSettings() => openAppSettings();
}
