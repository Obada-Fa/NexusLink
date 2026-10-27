import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/chats/chat_repository.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:nexuslink/src/state/saved_devices.dart';

const office = SavedDevice(url: 'ws://office:45678/rpc', name: 'Office PC');
const laptop = SavedDevice(url: 'ws://laptop:45678/rpc', name: 'Laptop');

Future<({SavedDevice? device, AutoConnectReason reason})> decide({
  List<SavedDevice> devices = const [office, laptop],
  String? last = 'ws://office:45678/rpc',
  bool userDisconnected = false,
  bool alreadyAttempted = false,
  Set<String> paired = const {'ws://office:45678/rpc'},
}) => decideAutoConnect(
  devices: devices,
  lastHostUrl: last,
  userDisconnected: userDisconnected,
  alreadyAttempted: alreadyAttempted,
  hasCredential: (url) async => paired.contains(url),
);

/// Lets a test drive connection state directly.
class ScriptedConnection extends ConnectionNotifier {
  @override
  ConnectionState build() => const ConnectionState();
  void set(ConnectionState next) => state = next;
}

void main() {
  group('auto-connect at launch', () {
    test('reconnects to the last PC that is saved and still paired', () async {
      final result = await decide();
      expect(result.reason, AutoConnectReason.connect);
      expect(result.device?.name, 'Office PC');
    });

    test(
      'matches the last host even when it was stored un-normalized',
      () async {
        final result = await decide(last: 'http://office:45678');
        expect(result.device?.url, office.url);
      },
    );

    test('respects an explicit disconnect in this run', () async {
      final result = await decide(userDisconnected: true);
      expect(result.device, isNull);
      expect(result.reason, AutoConnectReason.userDisconnected);
    });

    test('tries only once per run', () async {
      final result = await decide(alreadyAttempted: true);
      expect(result.device, isNull);
      expect(result.reason, AutoConnectReason.alreadyTried);
    });

    test('skips a PC whose pairing is gone', () async {
      final result = await decide(paired: const {});
      expect(result.reason, AutoConnectReason.notPaired);
      final failing = await decideAutoConnect(
        devices: const [office],
        lastHostUrl: office.url,
        userDisconnected: false,
        alreadyAttempted: false,
        hasCredential: (_) async => throw StateError('keystore locked'),
      );
      expect(failing.reason, AutoConnectReason.notPaired);
    });

    test('skips a last PC the user removed, and first launches', () async {
      expect(
        (await decide(devices: const [laptop])).reason,
        AutoConnectReason.lastPcNotSaved,
      );
      expect((await decide(last: null)).reason, AutoConnectReason.noSavedPc);
      expect(
        (await decide(devices: const [])).reason,
        AutoConnectReason.noSavedPc,
      );
    });
  });

  group('connection errors', () {
    test('revoked pairing is reported as auth, not as an offline PC', () {
      final error = RpcException('Pair this device again.', 'UNAUTHENTICATED');
      expect(isAuthError(error), isTrue);
      expect(connectErrorMessage(error), contains('no longer paired'));
      expect(isAuthError(RpcException('Connection timed out')), isFalse);
      expect(
        connectErrorMessage(RpcException('Connection timed out')),
        contains('didn’t answer'),
      );
    });
  });

  group('chat repository', () {
    test('is not rebuilt when only the connection status flips', () {
      final container = ProviderContainer(
        overrides: [connectionProvider.overrideWith(ScriptedConnection.new)],
      );
      addTearDown(container.dispose);
      final client = RpcClient('ws://office:45678/rpc');
      addTearDown(client.dispose);
      final connection =
          container.read(connectionProvider.notifier) as ScriptedConnection;
      var builds = 0;
      container.listen(
        chatRepositoryProvider,
        (_, _) => builds++,
        fireImmediately: true,
      );
      connection.set(
        ConnectionState(
          client: client,
          status: RpcStatus.connecting,
          hostUrl: office.url,
        ),
      );
      final first = container.read(chatRepositoryProvider);
      expect(builds, 2);
      for (final status in [
        RpcStatus.connected,
        RpcStatus.disconnected,
        RpcStatus.connecting,
        RpcStatus.connected,
      ]) {
        connection.set(
          ConnectionState(client: client, status: status, hostUrl: office.url),
        );
      }
      expect(identical(container.read(chatRepositoryProvider), first), isTrue);
      expect(builds, 2);

      final replacement = RpcClient('ws://office:45678/rpc');
      addTearDown(replacement.dispose);
      connection.set(ConnectionState(client: replacement, hostUrl: office.url));
      expect(container.read(chatRepositoryProvider).client, replacement);
      expect(builds, 3);
    });
  });
}
