import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'last_host.dart';

const savedDevicesKey = 'nexuslink-saved-devices';
const deviceIcons = ['desktop', 'laptop', 'server', 'gaming'];

class SavedDevice {
  const SavedDevice({
    required this.url,
    required this.name,
    this.icon = 'desktop',
  });
  final String url;
  final String name;
  final String icon;

  Map<String, String> toJson() => {'url': url, 'name': name, 'icon': icon};
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
