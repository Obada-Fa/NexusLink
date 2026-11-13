import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:nexuslink/src/state/launcher.dart';

class _Host extends RpcClient {
  _Host([super.wsUrl = 'ws://pc/rpc']);

  final responses = <String, List<dynamic>>{
    'appSession.list': [
      {
        'sessionId': 's1',
        'appId': 'editor',
        'name': 'Editor',
        'status': 'running',
      },
    ],
    'window.list': [
      {
        'windowId': '0x1',
        'title': 'Document',
        'wmClass': 'editor',
        'desktop': 0,
      },
    ],
  };
  Completer<void>? gate;

  @override
  bool supports(String feature) => true;

  @override
  void Function() subscribe(
    String topic,
    void Function(Map<String, dynamic>) callback,
  ) => () {};

  @override
  Future<List<dynamic>> requestList(
    String method, [
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 10),
  ]) async {
    await gate?.future;
    return responses[method] ?? const [];
  }
}

class _SwitchConnection extends ConnectionNotifier {
  @override
  ConnectionState build() => const ConnectionState();
  void use(_Host host) => state = ConnectionState(
    client: host,
    hostUrl: host.wsUrl,
    status: RpcStatus.connected,
  );
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late _Host host;
  late ProviderContainer container;

  setUp(() {
    host = _Host();
    container = ProviderContainer(
      overrides: [
        activeClientProvider.overrideWithValue(host),
        connectionStatusProvider.overrideWithValue(RpcStatus.connected),
      ],
    );
    addTearDown(container.dispose);
  });

  test('running apps build while connected, then load', () async {
    container.listen(appSessionsProvider, (_, _) {});
    expect(container.read(appSessionsProvider).value, isEmpty);
    await _settle();
    expect(container.read(appSessionsProvider).value, hasLength(1));
  });

  test('windows build while connected, then load', () async {
    container.listen(windowsProvider, (_, _) {});
    expect(container.read(windowsProvider).value, isEmpty);
    await _settle();
    expect(container.read(windowsProvider).value, hasLength(1));
  });

  test(
    'a rebuild keeps the last known lists until the refresh lands',
    () async {
      container.listen(appSessionsProvider, (_, _) {});
      container.listen(windowsProvider, (_, _) {});
      await _settle();

      host.gate = Completer<void>();
      container.invalidate(appSessionsProvider);
      container.invalidate(windowsProvider);

      expect(container.read(appSessionsProvider).value, hasLength(1));
      expect(container.read(windowsProvider).value, hasLength(1));
      host.gate!.complete();
    },
  );
  test(
    'switching PCs clears apps and running lists and ignores old responses',
    () async {
      final first = _Host('ws://first/rpc');
      first.responses['apps.list'] = [
        {'appId': 'first', 'name': 'First app'},
      ];
      final second = _Host('ws://second/rpc');
      second.gate = Completer<void>();
      second.responses['apps.list'] = [
        {'appId': 'second', 'name': 'Second app'},
      ];
      second.responses['window.list'] = [];
      second.responses['appSession.list'] = [];
      final scope = ProviderContainer(
        overrides: [connectionProvider.overrideWith(_SwitchConnection.new)],
      );
      addTearDown(scope.dispose);
      final connection =
          scope.read(connectionProvider.notifier) as _SwitchConnection;
      connection.use(first);
      scope.listen(appsProvider, (_, _) {});
      scope.listen(windowsProvider, (_, _) {});
      scope.listen(appSessionsProvider, (_, _) {});
      await _settle();
      expect(scope.read(appsProvider).value!.single.name, 'First app');
      expect(scope.read(windowsProvider).value, hasLength(1));
      first.gate = Completer<void>();
      final oldRequests = Future.wait([
        scope.read(appsProvider.notifier).refresh(),
        scope.read(windowsProvider.notifier).refresh(),
        scope.read(appSessionsProvider.notifier).refresh(),
      ]);
      connection.use(second);
      expect(scope.read(appsProvider).value ?? [], isEmpty);
      expect(scope.read(windowsProvider).value, isEmpty);
      expect(scope.read(appSessionsProvider).value, isEmpty);
      await _settle();
      first.gate!.complete();
      await oldRequests;
      expect(scope.read(appsProvider).value ?? [], isEmpty);
      expect(scope.read(windowsProvider).value, isEmpty);
      second.gate!.complete();
      await _settle();
      expect(scope.read(appsProvider).value!.single.name, 'Second app');
      expect(scope.read(windowsProvider).value, isEmpty);
    },
  );
}
