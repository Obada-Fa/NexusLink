import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/main.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/session/store.dart';
import 'package:nexuslink/src/session/target.dart';
import 'package:nexuslink/src/shell/home_screen.dart';
import 'package:nexuslink/src/shell/reachability.dart';
import 'package:nexuslink/src/shell/shell_controller.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:nexuslink/src/state/saved_devices.dart';
import 'package:nexuslink/src/workspace/platform_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_connection.dart';
import 'fakes.dart';

const officeUrl = 'ws://office:45678/rpc';
const laptopUrl = 'ws://laptop:45678/rpc';

void main() {
  setUp(() {
    FakeConnection.connects.clear();
    FakeConnection.failWith = null;
    resetAutoConnect();
  });

  testWidgets('legacy devices migrate into targets, end to end through the '
      'picker', (tester) async {
    SharedPreferences.setMockInitialValues({
      savedDevicesKey: jsonEncode([
        {'url': officeUrl, 'name': 'Office PC', 'icon': 'desktop'},
        {'url': laptopUrl, 'name': 'Laptop', 'icon': 'laptop'},
      ]),
      'nexuslink-last-host-url': laptopUrl,
    });
    // The laptop holds a NexusLink pairing, so cold start reconnects it.
    await PlatformBridge.saveCredential(laptopUrl, 'secret');
    addTearDown(() => PlatformBridge.removeCredential(laptopUrl));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionProvider.overrideWith(FakeConnection.new),
          reachabilityProberProvider.overrideWithValue(
            ReachabilityProber(connect: (_, _, _) async => false),
          ),
        ],
        child: const NexusApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Home opens on the last PC, reconnected automatically.
    expect(find.text('Laptop'), findsOneWidget);
    expect(find.textContaining('Connected'), findsOneWidget);
    expect(FakeConnection.connects, [laptopUrl]);
    for (final title in ['Desktop', 'Agents', 'Terminal']) {
      expect(find.text(title), findsOneWidget);
    }
    expect(find.text('Offline'), findsNothing);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(targetsKey), isNotNull);
    expect(prefs.getString(savedDevicesKey), isNotNull, reason: 'rollback');
    final targets = await TargetStore.load();
    expect(targets.map((t) => t.id), [
      'legacy:$officeUrl',
      'legacy:$laptopUrl',
    ]);
    expect(targets.last.icon, 'laptop');
    expect(targets.last.utilities[UtilityIds.nexuslink]?.wsUrl, laptopUrl);

    // Switch PCs through the picker.
    await tester.tap(find.byTooltip('Devices'));
    await tester.pumpAndSettle();
    expect(find.text('Office PC'), findsOneWidget);
    expect(find.text('Current'), findsOneWidget);
    await tester.tap(find.text('Office PC'));
    await tester.pumpAndSettle();
    expect(find.text('YOUR DEVICES'), findsNothing, reason: 'back on home');
    expect(find.text('Office PC'), findsOneWidget);
    expect(FakeConnection.connects.last, officeUrl);
    expect(await TargetStore.currentId(), 'legacy:$officeUrl');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('no auto-connect after an explicit disconnect', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await TargetStore.save([
      SavedTarget(
        id: 'legacy:$officeUrl',
        name: 'Office PC',
        utilities: {
          UtilityIds.nexuslink: link(UtilityIds.nexuslink, wsUrl: officeUrl),
        },
      ),
    ]);
    await TargetStore.setCurrent('legacy:$officeUrl');
    await PlatformBridge.saveCredential(officeUrl, 'secret');
    addTearDown(() => PlatformBridge.removeCredential(officeUrl));
    final container = ProviderContainer(
      overrides: [
        connectionProvider.overrideWith(FakeConnection.new),
        reachabilityProberProvider.overrideWithValue(
          ReachabilityProber(connect: (_, _, _) async => false),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(connectionProvider.notifier).disconnect();
    final dialed = await container.read(shellProvider.notifier).autoConnect();
    expect(dialed, isNull);
    expect(FakeConnection.connects, isEmpty);
    // The home still shows the current target (offline), not the picker.
    expect(container.read(shellProvider).current?.name, 'Office PC');
  });

  test('switching targets notifies modules and moves the connection', () async {
    SharedPreferences.setMockInitialValues({});
    final office = hubTarget();
    final tv = hubTarget(id: 'hub-tv', name: 'TV', utilities: {
      UtilityIds.remote,
    });
    await TargetStore.save([office, tv]);
    final remote = FakeModule(id: 'remote');
    final desktop = FakeModule(id: 'desk', requiredCaps: ['screen']);
    final container = ProviderContainer(
      overrides: [
        connectionProvider.overrideWith(FakeConnection.new),
        moduleListProvider.overrideWithValue([desktop, remote]),
        reachabilityProberProvider.overrideWithValue(
          ReachabilityProber(
            connect: (host, port, _) async => port == 45679,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final shell = container.read(shellProvider.notifier);

    await shell.select(office.id);
    await Future<void>.delayed(Duration.zero);
    expect(desktop.changes, ['hub-office']);
    expect(remote.changes, ['hub-office']);
    expect(FakeConnection.connects, ['ws://100.64.0.5:45678/rpc']);
    expect(
      container.read(connectionProvider).status,
      RpcStatus.connected,
    );
    await shell.probe(force: true);
    final ctx = container.read(moduleContextProvider)!;
    expect(ctx.reachable, {UtilityIds.nexuslink, UtilityIds.remote});

    await shell.select(tv.id);
    await Future<void>.delayed(Duration.zero);
    // Desktop isn't on the TV: it only hears that the office was left.
    expect(desktop.changes, ['hub-office', null]);
    expect(remote.changes, ['hub-office', null, 'hub-tv']);
    expect(container.read(connectionProvider).hostUrl, isNull);
    expect(await TargetStore.currentId(), 'hub-tv');
  });

  test('a refused pairing offers "Pair again" for that target', () async {
    SharedPreferences.setMockInitialValues({});
    await TargetStore.save([hubTarget()]);
    FakeConnection.failWith = RpcException('nope', 'UNAUTHENTICATED');
    final container = ProviderContainer(
      overrides: [
        connectionProvider.overrideWith(FakeConnection.new),
        reachabilityProberProvider.overrideWithValue(
          ReachabilityProber(connect: (_, _, _) async => false),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(shellProvider, (_, _) {});
    await container.read(shellProvider.notifier).select('hub-office');
    await Future<void>.delayed(Duration.zero);
    expect(container.read(shellProvider).pairAgainTargetId, 'hub-office');
    FakeConnection.failWith = null;
    await container.read(shellProvider.notifier).connectCurrent();
    expect(container.read(shellProvider).pairAgainTargetId, isNull);
  });

  testWidgets('typed address + code adds a PC and opens it on home', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionProvider.overrideWith(FakeConnection.new),
          reachabilityProberProvider.overrideWithValue(
            ReachabilityProber(connect: (_, _, _) async => false),
          ),
        ],
        child: const NexusApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('pc-address')), '10.0.0.7');
    await tester.enterText(
      find.byKey(const ValueKey('pairing-code')),
      '1234 5678',
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('connect')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('connect')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('connect')));
    await tester.pumpAndSettle();
    expect(FakeConnection.connects, ['ws://10.0.0.7:45678/rpc#12345678']);
    expect(find.text('My PC'), findsOneWidget);
    expect(find.text('Desktop'), findsOneWidget);
    final saved = (await TargetStore.load()).single;
    expect(saved.id, 'legacy:ws://10.0.0.7:45678/rpc');
    expect(await TargetStore.currentId(), saved.id);
    await tester.pumpWidget(const SizedBox());
  });
}
