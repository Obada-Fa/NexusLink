import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'last_host.dart';
import 'wake_config.dart';

const savedDevicesKey = 'nexuslink-saved-devices';
const deviceIcons = ['desktop', 'laptop', 'server', 'gaming'];

class SavedDevice {
  const SavedDevice({
    required this.url,
    required this.name,
    this.icon = 'desktop',
    this.wake,
  });
  final String url;
  final String name;
  final String icon;
  final WakeConfig? wake;
  SavedDevice copyWith({
    String? name,
    String? icon,
    WakeConfig? wake,
    bool clearWake = false,
  }) => SavedDevice(
    url: url,
    name: name ?? this.name,
    icon: icon ?? this.icon,
    wake: clearWake ? null : wake ?? this.wake,
  );

  Map<String, dynamic> toJson() => {
    'url': url,
    'name': name,
    'icon': icon,
    if (wake != null) 'wake': wake!.toJson(),
  };
}

/// Why the app did (or did not) reconnect on its own at launch.
enum AutoConnectReason {
  connect,
  noSavedPc,
  lastPcNotSaved,
  notPaired,
  userDisconnected,
  alreadyTried,
}

/// Cold-start decision: reconnect to the last PC this phone successfully used,
/// but only when it is still a saved device with a stored pairing, the user
/// has not disconnected in this run, and we have not already tried once.
Future<({SavedDevice? device, AutoConnectReason reason})> decideAutoConnect({
  required List<SavedDevice> devices,
  required String? lastHostUrl,
  required bool userDisconnected,
  required bool alreadyAttempted,
  required Future<bool> Function(String url) hasCredential,
}) async {
  if (alreadyAttempted) {
    return (device: null, reason: AutoConnectReason.alreadyTried);
  }
  if (userDisconnected) {
    return (device: null, reason: AutoConnectReason.userDisconnected);
  }
  final last = lastHostUrl == null ? '' : normalizeHostWsUrl(lastHostUrl);
  if (last.isEmpty || devices.isEmpty) {
    return (device: null, reason: AutoConnectReason.noSavedPc);
  }
  final device = devices.where((d) => d.url == last).firstOrNull;
  if (device == null) {
    return (device: null, reason: AutoConnectReason.lastPcNotSaved);
  }
  bool paired;
  try {
    paired = await hasCredential(device.url);
  } catch (_) {
    paired = false;
  }
  if (!paired) return (device: null, reason: AutoConnectReason.notPaired);
  return (device: device, reason: AutoConnectReason.connect);
}

class SavedDevices {
  static Future<List<SavedDevice>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(savedDevicesKey);
    if (raw != null) {
      final items = jsonDecode(raw) as List;
      return items.map((item) {
        final data = item as Map<String, dynamic>;
        return SavedDevice(
          url: normalizeHostWsUrl(data['url'] as String),
          name: data['name'] as String,
          wake: data['wake'] is Map
              ? WakeConfig.fromJson(
                  Map<String, dynamic>.from(data['wake'] as Map),
                )
              : null,
          icon: deviceIcons.contains(data['icon'])
              ? data['icon'] as String
              : 'desktop',
        );
      }).toList();
    }
    final last = await loadLastHostUrl();
    if (last == null) {
      await save([]);
      return [];
    }
    final devices = [SavedDevice(url: last, name: 'My PC')];
    await save(devices);
    return devices;
  }

  static Future<void> save(List<SavedDevice> devices) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(
      savedDevicesKey,
      jsonEncode(devices.map((device) => device.toJson()).toList()),
    )) {
      throw StateError('Could not save your devices. Please try again.');
    }
  }

  static Future<List<SavedDevice>> remember(String url, {String? name}) async {
    final normalized = normalizeHostWsUrl(url);
    final devices = await load();
    if (!devices.any((device) => device.url == normalized)) {
      devices.add(
        SavedDevice(
          url: normalized,
          name: name?.trim().isNotEmpty == true
              ? name!.trim()
              : 'My PC ${devices.length + 1}',
        ),
      );
      await save(devices);
    }
    return devices;
  }
}
