import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/widgets/link_actions.dart';

void main() {
  group('reconnectDelayMs', () {
    test('starts at 1s and doubles, then caps at 30s', () {
      expect(reconnectDelayMs(0), 1000);
      expect(reconnectDelayMs(1), 2000);
      expect(reconnectDelayMs(2), 4000);
      expect(reconnectDelayMs(3), 8000);
      expect(reconnectDelayMs(4), 16000);
      expect(reconnectDelayMs(20), 30000);
    });
  });

  group('linkActionValue', () {
    test('prefers href over display text', () {
      expect(linkActionValue('my pc', 'http://192.168.2.30:45678'),
          'http://192.168.2.30:45678');
    });

    test('falls back to text when href is empty', () {
      expect(linkActionValue('192.168.2.30:45678', '  '), '192.168.2.30:45678');
    });
  });

  group('ipAutolinkPattern', () {
    test('matches IPv4 and optional port', () {
      expect(ipAutolinkPattern.hasMatch('192.168.1.1'), isTrue);
      expect(
        ipAutolinkPattern.firstMatch('open 192.168.2.30:45678 now')?.group(0),
        '192.168.2.30:45678',
      );
    });

    test('rejects octets above 255', () {
      expect(ipAutolinkPattern.hasMatch('999.1.1.1'), isFalse);
    });
  });
}
