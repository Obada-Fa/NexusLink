import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('reconnect restores chat.subscribe and asks lists to resync; a revoked '
      'pairing surfaces as auth required instead of "offline"', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final perConnection = <List<String>>[];
    final sockets = <WebSocket>[];
    var revoke = false;
    server.listen((request) async {
      final ws = await WebSocketTransformer.upgrade(request);
      sockets.add(ws);
      final methods = <String>[];
      perConnection.add(methods);
      ws.listen((raw) {
        final req =
            jsonDecode(raw as String)['request'] as Map<String, dynamic>;
        final method = req['method'] as String;
        methods.add(method);
        Map<String, dynamic> reply(Object? result) => {
          'type': 'rpc-response',
          'response': {'id': req['id'], 'result': result},
        };
        if (method == 'session.resume' && revoke) {
          ws.add(
            jsonEncode({
              'type': 'rpc-response',
              'response': {
                'id': req['id'],
                'error': 'Pair this device with the PC again.',
                'code': 'UNAUTHENTICATED',
              },
            }),
          );
          return;
        }
        final expires = DateTime.now()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch;
        ws.add(
          jsonEncode(
            reply(switch (method) {
              'session.hello' => {'protocolVersion': 2},
              'session.enroll' => {
                'credential': 'test-only',
                'token': 'token-1',
                'hostId': 'pc',
                'expires': expires,
              },
              'session.resume' => {
                'token': 'token-2',
                'hostId': 'pc',
                'expires': expires,
              },
              'session.getCapabilities' => {
                'features': ['session.subscribe', 'chat.library.v1'],
                'methods': ['chat.subscribe'],
              },
              _ => {'ok': true, 'revision': 1},
            }),
          ),
        );
      });
    });
    final url = 'ws://127.0.0.1:${server.port}/rpc';
    final container = ProviderContainer();
    try {
      final notifier = container.read(connectionProvider.notifier);
      await notifier.connect(url, pairingCode: '12345678');
      final client = container.read(activeClientProvider)!;
      final pushes = <Map<String, dynamic>>[];
      client.subscribe('chat-library-update', pushes.add);
      await client.requestMap('chat.subscribe', {'enabled': true});

      // The socket drops; the same client reconnects by itself.
      await sockets.first.close();
      await client.statusStream
          .firstWhere((s) => s == RpcStatus.connected)
          .timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(identical(container.read(activeClientProvider), client), isTrue);
      expect(perConnection[1], contains('session.resume'));
      expect(perConnection[1], contains('chat.subscribe'));
      expect(pushes.where((p) => p['resync'] == true), hasLength(1));

      // The PC removes this phone's pairing; the next reconnect is refused.
      revoke = true;
      await sockets[1].close();
      await client.statusStream
          .firstWhere((_) => client.authRequired)
          .timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final state = container.read(connectionProvider);
      expect(state.authRequired, isTrue);
      expect(state.lastError, contains('no longer paired'));
      expect(container.read(connectionAuthRequiredProvider), isTrue);
      // No retry storm against a PC that refuses us.
      final connections = perConnection.length;
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(perConnection.length, connections);
      // Resume does not hammer it either.
      await notifier.ensureConnected();
      expect(perConnection.length, connections);
    } finally {
      container.dispose();
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
    }
  });
}
