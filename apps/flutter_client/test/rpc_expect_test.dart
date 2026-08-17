import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';

void main() {
  group('expectMap', () {
    test('returns a JSON object', () {
      expect(expectMap({'sessionId': 'abc'}, 'appSession.create')['sessionId'],
          'abc');
    });

    test('turns a null result into a host-out-of-date error', () {
      expect(
        () => expectMap(null, 'appSession.create'),
        throwsA(isA<RpcException>().having(
          (e) => e.message,
          'message',
          contains('out of date'),
        )),
      );
    });

    test('rejects a list where a map was required', () {
      expect(() => expectMap(<dynamic>[], 'appSession.create'),
          throwsA(isA<RpcException>()));
    });
  });

  group('friendlyLaunchError', () {
    test('rewrites the Dart null-cast the phone used to show', () {
      const dartCast =
          "type 'Null' is not a subtype of type 'Map<String, dynamic>' in type cast";
      expect(friendlyLaunchError(dartCast), contains('out of date'));
    });

    test('rewrites unknown-method from a current host', () {
      expect(
        friendlyLaunchError(RpcException('Error: unknown method: appSession.create')),
        contains('out of date'),
      );
    });

    test('passes through a real host error', () {
      expect(friendlyLaunchError(RpcException('unknown app: foo')),
          'unknown app: foo');
    });
  });
}
