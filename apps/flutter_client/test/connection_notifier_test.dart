import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/state/connection.dart';

class FakeRpcClient extends RpcClient {
  FakeRpcClient(
    super.wsUrl, {
    this.connectHandler,
    this.failConnect = false,
    this.failHeartbeat = false,
  });

  final Future<void> Function()? connectHandler;
  bool failConnect;
  bool failHeartbeat;
  int connectCount = 0;
  int disposeCount = 0;
  bool _fakeClosed = false;
  bool fakeSocketOpen = true;

  @override
  bool get isClosed => _fakeClosed;

  @override
  bool get socketOpen => fakeSocketOpen && !_fakeClosed;

  @override
  Future<void> connect() async {
    connectCount++;
    _fakeClosed = false;
    debugSetStatus(RpcStatus.connecting);
    if (connectHandler != null) await connectHandler!();
    if (failConnect) {
      debugSetStatus(RpcStatus.disconnected);
      throw RpcException('connect failed');
    }
    debugSetStatus(RpcStatus.connected);
  }

  @override
  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 10),
  ]) async {
    if (failHeartbeat) throw RpcException('heartbeat timeout');
    return null;
  }

  @override
  void disconnect() {
    _fakeClosed = true;
    debugSetStatus(RpcStatus.disconnected);
  }

  @override
  void dispose() {
    disposeCount++;
    disconnect();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  const url = 'ws://192.168.1.8:45678/rpc';

  ProviderContainer containerWith(FakeRpcClient Function(String url) factory) {
    return ProviderContainer(
      overrides: [
        connectionProvider.overrideWith(
          () => ConnectionNotifier(createClient: factory),
        ),
      ],
    );
  }

  test('failed connect keeps the host URL and does not dispose the client',
      () async {
    late FakeRpcClient fake;
    final container = containerWith((ws) {
      fake = FakeRpcClient(ws, failConnect: true);
      return fake;
    });
    addTearDown(container.dispose);

    await expectLater(
      container.read(connectionProvider.notifier).connect(url),
      throwsA(isA<RpcException>()),
    );

    final state = container.read(connectionProvider);
    expect(state.hostUrl, url);
    expect(state.status, RpcStatus.disconnected);
    expect(fake.disposeCount, 0);
  });

  test('concurrent connect calls share one client', () async {
    var created = 0;
    late FakeRpcClient fake;
    final gate = Completer<void>();
    final container = containerWith((ws) {
      created++;
      fake = FakeRpcClient(ws, connectHandler: () => gate.future);
      return fake;
    });
    addTearDown(container.dispose);

    final first = container.read(connectionProvider.notifier).connect(url);
    final second = container.read(connectionProvider.notifier).connect(url);
    gate.complete();
    await Future.wait([first, second]);

    expect(created, 1);
    expect(fake.connectCount, 1);
    expect(container.read(connectionProvider).status, RpcStatus.connected);
  });

  test('ensureConnected does not replace a client that is still retrying',
      () async {
    var created = 0;
    late FakeRpcClient fake;
    final container = containerWith((ws) {
      created++;
      fake = FakeRpcClient(ws, failConnect: true);
      return fake;
    });
    addTearDown(container.dispose);

    await expectLater(
      container.read(connectionProvider.notifier).connect(url),
      throwsA(isA<RpcException>()),
    );
    fake.failConnect = false;
    await container.read(connectionProvider.notifier).ensureConnected();

    expect(created, 1);
    expect(fake.disposeCount, 0);
  });

  test('slow heartbeat does not tear down an open socket', () async {
    late FakeRpcClient fake;
    final container = containerWith((ws) {
      fake = FakeRpcClient(ws);
      return fake;
    });
    addTearDown(container.dispose);

    await container.read(connectionProvider.notifier).connect(url);
    fake.failHeartbeat = true;
    fake.fakeSocketOpen = true;
    await container.read(connectionProvider.notifier).ensureConnected();

    expect(fake.disposeCount, 0);
    expect(container.read(connectionProvider).status, RpcStatus.connected);
    expect(container.read(connectionProvider).client, same(fake));
  });
}
