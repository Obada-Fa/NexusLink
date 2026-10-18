import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexuslink/src/state/saved_devices.dart';
import 'package:nexuslink/src/state/last_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('migrates last connection once and respects removal', () async {
    await saveLastHostUrl('192.168.1.10');
    final devices = await SavedDevices.load();
    expect(devices.single.url, 'ws://192.168.1.10:45678/rpc');
    expect(devices.single.name, 'My PC');
    await SavedDevices.save([]);
    expect(await SavedDevices.load(), isEmpty);
  });

  test(
    'multiple devices persist and reconnect preserves custom name and icon',
    () async {
      await SavedDevices.save([
        const SavedDevice(
          url: 'ws://office:45678/rpc',
          name: 'Office',
          icon: 'laptop',
        ),
      ]);
      await SavedDevices.remember('home', name: 'Home PC');
      final devices = await SavedDevices.remember(
        'http://office:45678',
        name: 'Other name',
      );
      expect(devices.length, 2);
      expect(devices.first.name, 'Office');
      expect(devices.first.icon, 'laptop');
      expect(devices.last.name, 'Home PC');
    },
  );
}
