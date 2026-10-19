import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexuslink/src/services/wake_service.dart';
import 'package:nexuslink/src/state/wake_config.dart';
import 'package:nexuslink/src/state/saved_devices.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'magic packet contains sync bytes and the target MAC repeated 16 times',
    () {
      final packet = WakeService.magicPacket('BC:FC:E7:1A:1D:AA');
      expect(packet.length, 102);
      expect(packet.take(6), List.filled(6, 255));
      for (var i = 0; i < 16; i++) {
        expect(packet.sublist(6 + i * 6, 12 + i * 6), [
          188,
          252,
          231,
          26,
          29,
          170,
        ]);
      }
      expect(WakeService.magicPacket('bcfce71a1daa'), packet);
      expect(
        () => WakeService.magicPacket('bad-mac'),
        throwsA(isA<WakeException>()),
      );
    },
  );
  test(
    'direct wake transmits real UDP packets to the configured target',
    () async {
      final receiver = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final packets = <List<int>>[];
      final done = Completer<void>();
      final sub = receiver.listen((event) {
        if (event == RawSocketEvent.read) {
          final data = receiver.receive();
          if (data != null) packets.add(data.data);
          if (packets.length == 3 && !done.isCompleted) done.complete();
        }
      });
      try {
        await WakeService().wake(
          'ws://pc:45678/rpc',
          WakeConfig(
            mac: 'BC:FC:E7:1A:1D:AA',
            broadcast: '127.0.0.1',
            port: receiver.port,
          ),
        );
        await done.future.timeout(const Duration(seconds: 3));
        expect(packets, hasLength(3));
        expect(packets.every((p) => p.length == 102), isTrue);
      } finally {
        await sub.cancel();
        receiver.close();
      }
    },
  );
  test(
    'home-server request matches existing X-API-Key API and does not follow redirects',
    () async {
      final client = MockClient((request) async {
        expect(request.url.toString(), 'http://100.101.246.19:3050/wake');
        expect(request.method, 'POST');
        expect(request.followRedirects, isFalse);
        expect(request.headers['X-API-Key'], 'private-key');
        expect(request.headers.containsKey('Authorization'), isFalse);
        expect(jsonDecode(request.body), {'action': 'wake'});
        return http.Response('{}', 200);
      });
      await WakeService().sendHttp(
        const WakeConfig(
          method: 'webhook',
          endpoint: 'http://100.101.246.19:3050/wake',
        ),
        'private-key',
        client: client,
      );
    },
  );
  test(
    'Home Assistant Tapo action only turns the selected switch on',
    () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/api/services/switch/turn_on');
        expect(request.headers['Authorization'], 'Bearer private-key');
        expect(jsonDecode(request.body), {'entity_id': 'switch.pc_power'});
        return http.Response('[]', 200);
      });
      await WakeService().sendHttp(
        const WakeConfig(
          method: 'homeAssistant',
          endpoint: 'http://server:8123',
          entity: 'switch.pc_power',
        ),
        'private-key',
        client: client,
      );
      expect(
        () => WakeService.endpoint(
          const WakeConfig(
            method: 'homeAssistant',
            endpoint: 'http://server:8123',
            entity: 'switch.pc_power/turn_off',
          ),
        ),
        throwsA(isA<WakeException>()),
      );
    },
  );
  test(
    'HTTP errors report actionable messages without reflecting server secrets',
    () async {
      for (final status in [401, 403, 302, 500]) {
        await expectLater(
          WakeService().sendHttp(
            const WakeConfig(method: 'webhook', endpoint: 'http://server/wake'),
            'private-key',
            client: MockClient(
              (_) async => http.Response('sensitive-body', status),
            ),
          ),
          throwsA(
            isA<WakeException>().having(
              (e) => e.message,
              'message',
              isNot(contains('sensitive-body')),
            ),
          ),
        );
      }
    },
  );
  test(
    'saved PCs retain wake settings through edits and reconnects; tokens are never serialized',
    () async {
      SharedPreferences.setMockInitialValues({});
      const device = SavedDevice(
        url: 'ws://pc:45678/rpc',
        name: 'My PC',
        wake: WakeConfig(method: 'webhook', endpoint: 'http://server/wake'),
      );
      await SavedDevices.save([
        device.copyWith(name: 'Office', icon: 'gaming'),
      ]);
      final devices = await SavedDevices.remember('pc', name: 'Other');
      expect(devices.single.name, 'Office');
      expect(devices.single.wake!.endpoint, 'http://server/wake');
      expect(devices.single.toJson()['wake'], isNot(contains('token')));
      expect(devices.single.copyWith(clearWake: true).wake, isNull);
    },
  );
}
