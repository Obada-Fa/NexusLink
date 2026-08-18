import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nexuslink/src/state/last_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('save and load last host URL', () async {
    expect(await loadLastHostUrl(), isNull);
    await saveLastHostUrl('  ws://192.168.1.10:45678/rpc  ');
    expect(await loadLastHostUrl(), 'ws://192.168.1.10:45678/rpc');
  });

  test('clear removes last host URL', () async {
    await saveLastHostUrl('ws://192.168.1.10:45678/rpc');
    await clearLastHostUrl();
    expect(await loadLastHostUrl(), isNull);
  });

  test('empty save is ignored', () async {
    await saveLastHostUrl('   ');
    expect(await loadLastHostUrl(), isNull);
  });

  test('lastHostLabel extracts host:port', () {
    expect(lastHostLabel('ws://192.168.1.10:45678/rpc'), '192.168.1.10:45678');
    expect(lastHostLabel('not-a-url'), 'not-a-url');
  });

  test('normalizeHostWsUrl accepts QR HTTP URLs and bare host:port', () {
    expect(
      normalizeHostWsUrl('http://100.108.139.27:45678'),
      'ws://100.108.139.27:45678/rpc',
    );
    expect(
      normalizeHostWsUrl('https://100.108.139.27:45678/'),
      'wss://100.108.139.27:45678/rpc',
    );
    expect(
      normalizeHostWsUrl('100.108.139.27:45678'),
      'ws://100.108.139.27:45678/rpc',
    );
    expect(
      normalizeHostWsUrl('ws://192.168.1.10:45678/rpc'),
      'ws://192.168.1.10:45678/rpc',
    );
    expect(normalizeHostWsUrl('  '), '');
  });
}
