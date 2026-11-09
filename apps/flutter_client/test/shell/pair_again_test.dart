// Pair-again for Remote and Audio feeds the same home banner as NexusLink,
// the "Add Remote and Audio" card starts the scan, and re-pairing the
// current target re-notifies modules.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_audio/nexus_audio.dart';
import 'package:nexuslink/main.dart';
import 'package:nexuslink/src/modules/audio/audio_runtime.dart';
import 'package:nexuslink/src/modules/remote/remote_module.dart';
import 'package:nexuslink/src/screens/scan_pair_screen.dart';
import 'package:nexuslink/src/session/store.dart';
import 'package:nexuslink/src/session/target.dart';
import 'package:nexuslink/src/shell/module.dart';
import 'package:nexuslink/src/shell/module_extras.dart';
import 'package:nexuslink/src/shell/module_registry.dart';
import 'package:nexuslink/src/shell/module_signals.dart';
import 'package:nexuslink/src/shell/reachability.dart';
import 'package:nexuslink/src/shell/shell_controller.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:nexuslink/src/workspace/platform_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_connection.dart';
import 'fakes.dart';

const _permissions = MethodChannel('flutter.baseflow.com/permissions/methods');

class RemovalModule extends FakeModule implements TargetRemovalAware {
  RemovalModule() : super(id: 'removal', requiredCaps: ['mic']);
  final removed = <String>[];

  @override
  Future<void> onTargetRemoved(SavedTarget target) async =>
      removed.add(target.id);
}

void main() {
  const office = 'ws://100.64.0.5:45678/rpc';
  VoidCallback? unauthorized;

  setUp(() async {
    resetAutoConnect();
    FakeConnection.connects.clear();
    FakeConnection.failWith = null;
    SharedPreferences.setMockInitialValues({});
    await PlatformBridge.saveCredential(office, 'secret');
    await CredentialVault.write('hub-office', UtilityIds.remote, 'r-token');
    await CredentialVault.write('hub-office', UtilityIds.audio, 'a-token');
    unauthorized = null;
    RemoteRuntime.debugSessionFactory = (endpoint, onUnauthorized) {
      unauthorized = onUnauthorized;
      return FakeRemoteSession(endpoint, onUnauthorized: onUnauthorized);
    };
    // The scan screen asks for the camera; answer "denied" so no camera
    // plugin is needed.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _permissions,
          (call) async => switch (call.method) {
            'checkPermissionStatus' => 0,
            'requestPermissions' => {1: 0},
            _ => null,
          },
        );
  });

  tearDown(() async {
    PlatformBridge.removeCredential(office);
    await CredentialVault.delete('hub-office', UtilityIds.remote);
    await CredentialVault.delete('hub-office', UtilityIds.audio);
    RemoteRuntime.debugReset();
    RemoteRuntime.debugSessionFactory = null;
    AudioRuntime.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_permissions, null);
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionProvider.overrideWith(FakeConnection.new),
          moduleListProvider.overrideWithValue(moduleRegistry),
          reachabilityProberProvider.overrideWithValue(
            ReachabilityProber(connect: (_, _, _) async => true),
          ),
        ],
        child: const NexusApp(),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('Remote and Audio refusals show the home pair-again banner', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412 * 2, 915 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await TargetStore.save([hubTarget()]);
    await TargetStore.setCurrent('hub-office');
    await pumpApp(tester);
    expect(find.byKey(const ValueKey('pair-again-banner')), findsNothing);
    expect(unauthorized, isNotNull, reason: 'Remote session was created');

    unauthorized!();
    await tester.pump();
    await tester.pump();
    expect(
      find.text(
        'Office PC no longer accepts this phone for Remote. Scan the QR code '
        'from Nexus Utilities to pair again.',
      ),
      findsOneWidget,
    );
    expect(find.text('Type code'), findsNothing);

    AudioRuntime.debugNotice(
      const AudioNotice(
        stream: AudioStream.mic,
        message: 'Office PC no longer accepts this phone. Pair again.',
        pairAgain: true,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('for Remote and Audio.'), findsOneWidget);

    // The action rescans with PairingFlow.run (the scan screen opens).
    await tester.tap(find.text('Scan QR'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ScanPairScreen), findsOneWidget);
    await tester.pageBack();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    await tester.tap(find.text('Later'));
    await tester.pump();
    expect(find.byKey(const ValueKey('pair-again-banner')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a NexusLink-only target offers "Add Remote and Audio"', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412 * 2, 915 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await TargetStore.save([hubTarget(utilities: {UtilityIds.nexuslink})]);
    await TargetStore.setCurrent('hub-office');
    await pumpApp(tester);
    final card = find.text(
      'Add Remote and Audio: scan the QR code from Nexus Utilities.',
    );
    await tester.scrollUntilVisible(
      card,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(card, findsOneWidget);
    expect(find.byKey(const ValueKey('tile-remote')), findsNothing);
    await tester.tap(card);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ScanPairScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('re-pairing the current target re-notifies its modules', () async {
    await TargetStore.save([hubTarget(utilities: {UtilityIds.nexuslink})]);
    final audio = FakeModule(id: 'audio', requiredCaps: ['mic']);
    final desk = FakeModule(id: 'desk', requiredCaps: ['screen']);
    final container = ProviderContainer(
      overrides: [
        connectionProvider.overrideWith(FakeConnection.new),
        moduleListProvider.overrideWithValue([desk, audio]),
        reachabilityProberProvider.overrideWithValue(
          ReachabilityProber(connect: (_, _, _) async => false),
        ),
      ],
    );
    addTearDown(container.dispose);
    final shell = container.read(shellProvider.notifier);
    await shell.select('hub-office', connect: false);
    expect(desk.changes, ['hub-office']);
    expect(audio.changes, isEmpty, reason: 'Audio not paired yet');

    // The pairing flow added Audio to the same hub.
    final paired = await TargetStore.upsert(hubTarget());
    await shell.adoptPaired(paired);
    expect(audio.changes, ['hub-office']);
    expect(desk.changes, ['hub-office', null, 'hub-office']);
  });

  test('module pair-again flags merge per target and clear on re-pair', () async {
    await TargetStore.save([hubTarget()]);
    final container = ProviderContainer(
      overrides: [
        connectionProvider.overrideWith(FakeConnection.new),
        moduleListProvider.overrideWithValue(const <NexusModule>[]),
        reachabilityProberProvider.overrideWithValue(
          ReachabilityProber(connect: (_, _, _) async => false),
        ),
      ],
    );
    addTearDown(container.dispose);
    final shell = container.read(shellProvider.notifier);
    await shell.select('hub-office', connect: false);
    AudioRuntime.debugNotice(
      const AudioNotice(stream: AudioStream.mic, message: 'x', pairAgain: true),
    );
    await Future<void>.delayed(Duration.zero);
    // Not bound to a target: no request.
    expect(container.read(shellProvider).pairAgainTargetId, isNull);

    // Signals from modules land in the shell state.
    for (final u in [UtilityIds.remote, UtilityIds.audio]) {
      ModuleSignals.requestPairAgain('hub-office', u);
    }
    await Future<void>.delayed(Duration.zero);
    final state = container.read(shellProvider);
    expect(state.pairAgainTargetId, 'hub-office');
    expect(state.pairAgainUtilities, {UtilityIds.remote, UtilityIds.audio});

    await shell.adoptPaired(hubTarget());
    expect(container.read(shellProvider).pairAgainTargetId, isNull);
    expect(container.read(shellProvider).pairAgainUtilities, isEmpty);
  });

  test('removing a target tells removal-aware modules, current or not', () async {
    await TargetStore.save([
      hubTarget(),
      hubTarget(id: 'hub-tv', name: 'TV'),
    ]);
    final removal = RemovalModule();
    final container = ProviderContainer(
      overrides: [
        connectionProvider.overrideWith(FakeConnection.new),
        moduleListProvider.overrideWithValue([removal]),
        reachabilityProberProvider.overrideWithValue(
          ReachabilityProber(connect: (_, _, _) async => false),
        ),
      ],
    );
    addTearDown(container.dispose);
    final shell = container.read(shellProvider.notifier);
    await shell.select('hub-office', connect: false);
    await shell.remove('hub-tv');
    expect(removal.removed, ['hub-tv']);
    expect(removal.changes, ['hub-office'], reason: 'current one untouched');
    await shell.remove('hub-office');
    expect(removal.removed, ['hub-tv', 'hub-office']);
    expect(removal.changes, ['hub-office', null]);
  });
}
