import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/auth/pair_bundle.dart';
import 'package:nexuslink/src/session/enrollment/pairing_flow.dart';
import 'package:nexuslink/src/session/enrollment/pairing_progress_screen.dart';
import 'package:nexuslink/src/session/store.dart';
import 'package:nexuslink/src/session/target.dart';
import 'package:nexuslink/src/theme/nexus_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_servers.dart';

PairBundle bundleFor({
  required int remotePort,
  required int audioPort,
  String code = goodCode,
}) => PairBundle(
  hubId: 'hub-1',
  pcName: 'Office PC',
  expiresAt: DateTime(2100),
  addresses: const TargetAddresses(tailscale: '127.0.0.2', lan: ['127.0.0.1']),
  utilities: {
    UtilityIds.nexuslink: const BundleEntry(
      utility: UtilityIds.nexuslink,
      port: 45678,
      code: goodCode,
      hostId: 'nl-1',
    ),
    UtilityIds.remote: BundleEntry(
      utility: UtilityIds.remote,
      port: remotePort,
      code: code,
      fingerprint: fixtureFingerprint(),
    ),
    UtilityIds.audio: BundleEntry(
      utility: UtilityIds.audio,
      port: audioPort,
      code: code,
      fingerprint: fixtureFingerprint(),
      hostId: 'au-1',
    ),
  },
);

/// Futures started by widgets live in the fake-async zone and only advance on
/// pump, while the sockets need the real event loop: alternate the two.
Future<void> settle(WidgetTester tester, PairingRun run) async {
  for (var i = 0; i < 500 && run.busy; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pump();
  expect(
    run.busy,
    isFalse,
    reason:
        'unfinished: ${run.rows.map((r) => "${r.utility}:${r.state.name}:${r.message}")}',
  );
}

void main() {
  setUpAll(() => HttpOverrides.global = null); // real sockets to local fakes
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'enrollAll: each utility independent, ts first then lan, one target',
    () async {
      final remote = await fakeRemote();
      final audio = await fakeAudio();
      addTearDown(() => remote.close(force: true));
      addTearDown(audio.close);
      final tried = <String>[];
      final progress = <String>[];

      final target = await PairingFlow.enrollAll(
        bundleFor(remotePort: remote.port, audioPort: audio.port),
        enrollNexusLink: (ws, code) async {
          tried.add(ws);
          if (ws.contains('127.0.0.2')) throw StateError('unreachable');
        },
        onProgress: (p) => progress.add('${p.utility}:${p.state.name}'),
      );

      expect(tried, ['ws://127.0.0.2:45678/rpc', 'ws://127.0.0.1:45678/rpc']);
      expect(target!.id, 'hub-1');
      expect(target.name, 'Office PC');
      expect(target.utilities.keys.toSet(), {'nexuslink', 'remote', 'audio'});
      expect(target.utilities['nexuslink']!.wsUrl, 'ws://127.0.0.1:45678/rpc');
      expect(target.utilities['remote']!.hostId, 'rh-1');
      expect(target.utilities['remote']!.preferredHost, '127.0.0.1');
      expect(target.utilities['audio']!.deviceId, 'dev-1');
      expect(target.utilities['audio']!.fingerprint, fixtureFingerprint());
      expect(await CredentialVault.read('hub-1', 'remote'), 'remote-token');
      expect(await CredentialVault.read('hub-1', 'audio'), 'audio-token');
      expect(await TargetStore.currentId(), 'hub-1');
      expect((await TargetStore.load()).length, 1);
      expect(
        progress,
        containsAll(['nexuslink:done', 'remote:done', 'audio:done']),
      );
      // The target JSON must never carry a token.
      expect(target.toJson().toString(), isNot(contains('token')));
    },
  );

  test(
    'one failure never blocks the others; nothing enrolled → null',
    () async {
      final remote = await fakeRemote();
      final audio = await fakeAudio();
      addTearDown(() => remote.close(force: true));
      addTearDown(audio.close);
      final progress = <EnrollProgress>[];
      final target = await PairingFlow.enrollAll(
        bundleFor(remotePort: remote.port, audioPort: audio.port),
        enrollNexusLink: (ws, code) async => throw StateError('Wrong code'),
        onProgress: progress.add,
      );
      expect(target!.utilities.keys.toSet(), {'remote', 'audio'});
      final nl = progress.lastWhere((p) => p.utility == 'nexuslink');
      expect(nl.state, EnrollState.failed);
      expect(nl.message, 'Wrong code');

      SharedPreferences.setMockInitialValues({});
      final none = await PairingFlow.enrollAll(
        bundleFor(remotePort: remote.port, audioPort: audio.port, code: '0'),
        enrollNexusLink: (ws, code) async => throw StateError('no'),
      );
      expect(none, isNull);
      expect(await TargetStore.load(), isEmpty);
    },
  );

  testWidgets('progress list: one done, one failed with retry; screenshot', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1260, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final remote = await tester.runAsync(fakeRemote);
    final audio = await tester.runAsync(fakeAudio);
    addTearDown(() => remote!.close(force: true));
    addTearDown(audio!.close);

    var linkWorks = false;
    final run = PairingRun(
      bundleFor(remotePort: remote!.port, audioPort: audio.port),
      enrollNexusLink: (ws, code) async {
        if (!linkWorks) throw StateError('Wrong or expired code');
      },
    );
    final key = GlobalKey();
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        theme: nexusTheme(),
        home: const Scaffold(),
      ),
    );
    nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => RepaintBoundary(
          key: key,
          child: PairingProgressScreen(run: run, autoStart: false),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle(); // finish the route transition
    await tester.runAsync(run.start); // real sockets: outside the fake zone
    await tester.pumpAndSettle();

    final scratch = Platform.environment['NEXUS_SHOT_DIR'];
    if (scratch != null) {
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$scratch/pairing_progress.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      });
    }

    expect(find.text('NexusLink'), findsOneWidget);
    expect(find.text('Wrong or expired code'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Paired'), findsNWidgets(2));
    expect(find.text('Continue'), findsOneWidget);

    linkWorks = true;
    await tester.tap(find.text('Retry'));
    await settle(tester, run);
    expect(find.text('Paired'), findsNWidgets(3));
    expect(run.allDone, isTrue);
    expect(run.target!.id, 'hub-1');
    await tester.pump(const Duration(seconds: 2)); // auto-pop timer
  });
}
