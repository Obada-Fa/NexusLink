// Explicit, read-only integration test against a paired Linux host.
// Run with NEXUSLINK_LIVE_TEST_URL=ws://HOST:45678/rpc and a fresh
// NEXUSLINK_LIVE_TEST_CODE from `bun run host:pair`.
// The default test suite never touches a personal host or starts capture.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nexuslink/src/rpc/rpc_client.dart';

void main() {
  test('paired live host exposes capabilities and guards file HTTP', () async {
    final url = Platform.environment['NEXUSLINK_LIVE_TEST_URL'];
    final code = Platform.environment['NEXUSLINK_LIVE_TEST_CODE'];
    if (url == null || code == null) {
      markTestSkipped('set explicit live host URL and one-use pairing code');
      return;
    }

    final client = RpcClient(url, pairingCode: code);
    try {
      await client.connect();
      expect(client.status, RpcStatus.connected);
      expect(client.hostId, isNotEmpty);
      expect(client.capabilities['protocolVersion'], 2);
      final info = await client.requestMap('system.getInfo');
      expect(info['hostname'], isNotEmpty);

      final ws = Uri.parse(url);
      final httpUrl = ws.replace(
        scheme: ws.scheme == 'wss' ? 'https' : 'http',
        path: '/files',
        queryParameters: {'path': '/tmp/nexuslink-live-test-unpaired'},
      );
      final response = await http.head(httpUrl);
      expect(response.statusCode, 401);
    } finally {
      client.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 1)));
}
