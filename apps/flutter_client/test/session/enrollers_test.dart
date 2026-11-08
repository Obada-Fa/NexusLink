import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/session/enrollment/enrollers.dart';

import 'fake_servers.dart';

void main() {
  final pin = fixtureFingerprint();
  final wrongPin = 'AB' * 32;

  group('Remote', () {
    test('pinned enroll returns token, host id and pin', () async {
      final bodies = <String>[];
      final s = await fakeRemote(bodies: bodies);
      addTearDown(() => s.close(force: true));
      final r = await RemoteEnroller.enroll(
        addresses: ['127.0.0.1'],
        port: s.port,
        code: goodCode,
        fingerprint: pin,
        deviceName: 'Pixel',
      );
      expect(r.token, 'remote-token');
      expect(r.hostId, 'rh-1');
      expect(r.fingerprint, pin);
      expect(jsonDecode(bodies.single), {
        'code': goodCode,
        'device_name': 'Pixel',
      });
    });

    test('accepts colon-separated lower-case pin', () async {
      final s = await fakeRemote();
      addTearDown(() => s.close(force: true));
      final spaced = [
        for (var i = 0; i < pin.length; i += 2) pin.substring(i, i + 2),
      ].join(':').toLowerCase();
      final r = await RemoteEnroller.enroll(
        addresses: ['127.0.0.1'],
        port: s.port,
        code: goodCode,
        fingerprint: spaced,
      );
      expect(r.fingerprint, pin);
    });

    test('empty pin trusts what the server presents and reports it', () async {
      final s = await fakeRemote();
      addTearDown(() => s.close(force: true));
      final r = await RemoteEnroller.enroll(
        addresses: ['127.0.0.1'],
        port: s.port,
        code: goodCode,
      );
      expect(r.fingerprint, pin);
    });

    test('pin mismatch is rejected', () async {
      final s = await fakeRemote();
      addTearDown(() => s.close(force: true));
      await expectLater(
        RemoteEnroller.enroll(
          addresses: ['127.0.0.1'],
          port: s.port,
          code: goodCode,
          fingerprint: wrongPin,
        ),
        throwsA(
          isA<EnrollException>().having(
            (e) => e.message,
            'm',
            contains('certificate'),
          ),
        ),
      );
    });

    test('bad code surfaces the server message', () async {
      final s = await fakeRemote();
      addTearDown(() => s.close(force: true));
      await expectLater(
        RemoteEnroller.enroll(
          addresses: ['127.0.0.1'],
          port: s.port,
          code: '00000000',
          fingerprint: pin,
        ),
        throwsA(
          isA<EnrollException>().having(
            (e) => e.message,
            'm',
            'Wrong or expired code',
          ),
        ),
      );
    });

    test('unreachable first address, second works', () async {
      final s = await fakeRemote();
      addTearDown(() => s.close(force: true));
      final r = await RemoteEnroller.enroll(
        addresses: ['127.0.0.2', '127.0.0.1'],
        port: s.port,
        code: goodCode,
        fingerprint: pin,
      );
      expect(r.address, '127.0.0.1');
    });

    test('all addresses unreachable', () async {
      await expectLater(
        RemoteEnroller.enroll(
          addresses: ['127.0.0.2'],
          port: 1,
          code: goodCode,
        ),
        throwsA(
          isA<EnrollException>().having(
            (e) => e.message,
            'm',
            contains('reach'),
          ),
        ),
      );
    });
  });

  group('Audio', () {
    test(
      'pinned enroll sends one JSON line and returns device + token',
      () async {
        final lines = <String>[];
        final s = await fakeAudio(lines: lines);
        addTearDown(s.close);
        final r = await AudioEnroller.enroll(
          addresses: ['127.0.0.1'],
          port: s.port,
          code: goodCode,
          fingerprint: pin,
          deviceName: 'Pixel',
        );
        expect(r.deviceId, 'dev-1');
        expect(r.token, 'audio-token');
        expect(r.fingerprint, pin);
        expect(jsonDecode(lines.single), {
          'abp': 2,
          'op': 'enroll',
          'code': goodCode,
          'deviceName': 'Pixel',
        });
      },
    );

    test('pin mismatch is rejected', () async {
      final s = await fakeAudio();
      addTearDown(s.close);
      await expectLater(
        AudioEnroller.enroll(
          addresses: ['127.0.0.1'],
          port: s.port,
          code: goodCode,
          fingerprint: wrongPin,
        ),
        throwsA(
          isA<EnrollException>().having(
            (e) => e.message,
            'm',
            contains('certificate'),
          ),
        ),
      );
    });

    test('bad code reply', () async {
      final s = await fakeAudio();
      addTearDown(s.close);
      await expectLater(
        AudioEnroller.enroll(
          addresses: ['127.0.0.1'],
          port: s.port,
          code: '1',
          fingerprint: pin,
        ),
        throwsA(
          isA<EnrollException>().having(
            (e) => e.message,
            'm',
            'Wrong or expired code',
          ),
        ),
      );
    });

    test('unreachable first address, second works', () async {
      final s = await fakeAudio();
      addTearDown(s.close);
      final r = await AudioEnroller.enroll(
        addresses: ['127.0.0.2', '127.0.0.1'],
        port: s.port,
        code: goodCode,
        fingerprint: pin,
      );
      expect(r.address, '127.0.0.1');
    });

    test('no pin: trusts and reports the presented fingerprint', () async {
      final s = await fakeAudio();
      addTearDown(s.close);
      final r = await AudioEnroller.enroll(
        addresses: ['127.0.0.1'],
        port: s.port,
        code: goodCode,
      );
      expect(r.fingerprint, pin);
    });
  });
}
