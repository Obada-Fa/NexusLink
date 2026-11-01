import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:nexuslink/src/state/launcher.dart';

class _Host extends RpcClient {
  _Host() : super('ws://pc/rpc');

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

  test('a rebuild keeps the last known lists until the refresh lands', () async {
    container.listen(appSessionsProvider, (_, _) {});
    container.listen(windowsProvider, (_, _) {});
    await _settle();

    host.gate = Completer<void>();
    container.invalidate(appSessionsProvider);
    container.invalidate(windowsProvider);

    expect(container.read(appSessionsProvider).value, hasLength(1));
    expect(container.read(windowsProvider).value, hasLength(1));
    host.gate!.complete();
  });
}
