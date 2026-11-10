// Refine plan pass 1: grouped tools, recovery text, partial pairing summary,
// the per-PC "Continue" store, and the attention / continue cards on Home.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/main.dart';
import 'package:nexuslink/src/monitor/approvals.dart';
import 'package:nexuslink/src/session/enrollment/pairing_flow.dart';
import 'package:nexuslink/src/session/enrollment/pairing_progress_screen.dart';
import 'package:nexuslink/src/session/store.dart';
import 'package:nexuslink/src/session/target.dart';
import 'package:nexuslink/src/shell/home_screen.dart';
import 'package:nexuslink/src/shell/module_registry.dart';
import 'package:nexuslink/src/shell/reachability.dart';
import 'package:nexuslink/src/shell/resume_store.dart';
import 'package:nexuslink/src/shell/remote_setup.dart';
import 'package:nexuslink/src/shell/shell_controller.dart';
import 'package:nexuslink/src/shell/target_actions.dart';
import 'package:nexuslink/src/shell/tiles.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:nexuslink/src/state/wake_config.dart';
import 'package:nexuslink/src/workspace/platform_bridge.dart';
import 'package:nexuslink/src/workspace/workspace_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_connection.dart';
import 'fakes.dart';

const _url = 'ws://office:45678/rpc';
const _id = 'legacy:$_url';

class _FakeApprovals extends ApprovalsNotifier {
  _FakeApprovals(this.items);
  final List<ExternalApproval> items;
  @override
  ApprovalsState build() => ApprovalsState(items: items);
}

Future<void> _pumpHome(
  WidgetTester tester, {
  List<ExternalApproval> approvals = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionProvider.overrideWith(FakeConnection.new),
        reachabilityProberProvider.overrideWithValue(
          ReachabilityProber(connect: (_, _, _) async => false),
        ),
        approvalsProvider.overrideWith(() => _FakeApprovals(approvals)),
      ],
      child: const NexusApp(home: HomeScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _saveOffice() async {
  await TargetStore.save([
    SavedTarget(
      id: _id,
      name: 'Office PC',
      utilities: {
        UtilityIds.nexuslink: link(UtilityIds.nexuslink, wsUrl: _url),
      },
    ),
  ]);
  await TargetStore.setCurrent(_id);
}

void main() {
  setUp(() {
    FakeConnection.connects.clear();
    FakeConnection.failWith = null;
    resetAutoConnect();
  });

  testWidgets(
    'Home settings opens phone controls while the PC is offline and Back returns Home',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await _saveOffice();
      await _pumpHome(tester);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('home-settings')))
            .shortestSide,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(tester.widget<PcScreen>(find.byType(PcScreen)).phoneFirst, isTrue);
      expect(find.text('THIS PHONE'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('THIS PHONE')).dy,
        lessThan(tester.getTopLeft(find.text('THIS PC')).dy),
      );
      expect(find.text('PC status strip'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pc-selector')), findsOneWidget);
    },
  );

  testWidgets('Settings remains available before pairing a PC at large text', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pumpHome(tester);
    expect(find.byTooltip('Settings'), findsOneWidget);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(PcScreen), findsOneWidget);
    expect(find.text('THIS PHONE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Add Remote is in Device settings, away from the Home grid', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await _saveOffice();
    await _pumpHome(tester);
    expect(find.text('Add Remote'), findsNothing);
    expect(
      find.textContaining('scan the QR code from Nexus Utilities.'),
      findsNothing,
    );
    await tester.tap(find.byTooltip('Device settings'));
    await tester.pumpAndSettle();
    expect(find.text('Add Remote'), findsOneWidget);
    expect(find.text('Pair a utility'), findsOneWidget);
  });

  testWidgets(
    'unpaired Remote explains installation and copies PC setup instructions',
    (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      SharedPreferences.setMockInitialValues({});
      await _saveOffice();
      await _pumpHome(tester);
      expect(find.text('Set up'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tile-remote')));
      await tester.pumpAndSettle();
      expect(find.text('Set up Remote'), findsOneWidget);
      expect(find.textContaining('cannot tell whether'), findsOneWidget);
      await tester.tap(find.text('Install on PC'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Windows and Wayland'), findsOneWidget);
      await tester.ensureVisible(find.text('Copy PC installation link'));
      await tester.tap(find.text('Copy PC installation link'));
      await tester.pumpAndSettle();
      expect(copied, remoteSetupUrl);
    },
  );

  group('groupTiles', () {
    test('PC tools before Workspace', () {
      final tiles = [
        for (final m in moduleRegistry) HomeTile(m, TileStatus.ready),
      ];
      final groups = groupTiles(tiles);
      expect(groups.map((g) => g.$1), [ToolGroup.pcTools, ToolGroup.workspace]);
      expect(groups[1].$2.map((t) => t.module.id), [
        'agents',
        'terminal',
        'files',
      ]);
      expect(groups[0].$2.map((t) => t.module.id), [
        'desktop',
        'remote',
        'audio',
      ]);
    });

    test('empty groups are left out; unknown modules go last', () {
      final groups = groupTiles([
        HomeTile(FakeModule(id: 'zzz'), TileStatus.ready),
        HomeTile(FakeModule(id: 'remote'), TileStatus.offline),
      ]);
      expect(groups.single.$1, ToolGroup.pcTools);
      expect(groups.single.$2.map((t) => t.module.id), ['remote', 'zzz']);
    });
  });

  group('homeRecovery', () {
    final target = hubTarget();

    test('nothing while checking, busy, or when all answer', () {
      expect(
        homeRecovery(target, reachable: {}, probedOnce: false, busy: false),
        isNull,
      );
      expect(
        homeRecovery(target, reachable: {}, probedOnce: true, busy: true),
        isNull,
      );
      expect(
        homeRecovery(
          target,
          reachable: UtilityIds.all.toSet(),
          probedOnce: true,
          busy: false,
        ),
        isNull,
      );
    });

    test('all down: offline, wake only when configured', () {
      final r = homeRecovery(
        target,
        reachable: {},
        probedOnce: true,
        busy: false,
      )!;
      expect(r.title, 'Office PC is offline');
      expect(r.allDown, isTrue);
      expect(r.offerWake, isFalse);
      final withWake = homeRecovery(
        target.copyWith(wake: const WakeConfig(mac: 'aa:bb:cc:dd:ee:ff')),
        reachable: {},
        probedOnce: true,
        busy: false,
      )!;
      expect(withWake.offerWake, isTrue);
    });

    test('one utility down is named', () {
      final r = homeRecovery(
        target,
        reachable: {UtilityIds.nexuslink, UtilityIds.remote},
        probedOnce: true,
        busy: false,
      )!;
      expect(r.allDown, isFalse);
      expect(r.title, '${utilityName(UtilityIds.audio)} isn’t answering');
      expect(r.body, contains('Other tools on Office PC work'));
    });
  });

  test('pairingSummary names what is ready and what failed', () {
    const rows = [
      EnrollProgress(UtilityIds.nexuslink, EnrollState.done),
      EnrollProgress(UtilityIds.remote, EnrollState.done),
      EnrollProgress(UtilityIds.audio, EnrollState.failed, 'timeout'),
    ];
    expect(pairingSummary(rows, busy: true), isNull);
    expect(
      pairingSummary(rows, busy: false),
      startsWith('NexusLink and Nexus Remote are ready. Nexus Audio didn’t'),
    );
    expect(
      pairingSummary(const [
        EnrollProgress(UtilityIds.nexuslink, EnrollState.done),
      ], busy: false),
      isNull,
    );
  });

  test('shortAgo', () {
    final now = DateTime(2026, 11, 9, 12);
    expect(shortAgo(now, now: now), 'just now');
    expect(
      shortAgo(now.subtract(const Duration(minutes: 5)), now: now),
      '5 min ago',
    );
    expect(
      shortAgo(now.subtract(const Duration(hours: 3)), now: now),
      '3 h ago',
    );
    expect(
      shortAgo(now.subtract(const Duration(days: 2)), now: now),
      '2 d ago',
    );
  });

  test('offline PCs say when they were last seen', () {
    final now = DateTime(2026, 11, 9, 12);
    expect(offlineLabel(null, now: now), 'Offline');
    expect(
      offlineLabel(now.subtract(const Duration(hours: 2)), now: now),
      'Offline · seen 2 h ago',
    );
  });

  test('LastSeen persists per target, throttles writes and forgets', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final t0 = DateTime(2026, 11, 9, 12);
    await c.read(lastSeenProvider.notifier).seen('pc', at: t0);
    await c
        .read(lastSeenProvider.notifier)
        .seen('pc', at: t0.add(const Duration(seconds: 20)));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('${lastSeenKeyPrefix}pc'), t0.millisecondsSinceEpoch);
    final fresh = ProviderContainer();
    addTearDown(fresh.dispose);
    await fresh.read(lastSeenProvider.notifier).load('pc');
    expect(fresh.read(lastSeenProvider)['pc'], t0);
    await fresh.read(lastSeenProvider.notifier).forget('pc');
    expect(prefs.getInt('${lastSeenKeyPrefix}pc'), isNull);
  });

  test('LastDestinations round-trips per target and forgets', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final store = c.read(lastDestinationsProvider.notifier);
    await store.record('a', 'terminal', at: DateTime(2026, 11, 9));
    await store.record('b', 'files');

    final fresh = ProviderContainer();
    addTearDown(fresh.dispose);
    await fresh.read(lastDestinationsProvider.notifier).load('a');
    expect(fresh.read(lastDestinationsProvider)['a']?.moduleId, 'terminal');
    expect(fresh.read(lastDestinationsProvider)['b'], isNull, reason: 'lazy');

    await store.forget('a');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('${lastModuleKeyPrefix}a'), isNull);
    expect(prefs.getString('${lastModuleKeyPrefix}b'), isNotNull);
  });

  test('Continue keeps the task when the same tool is reopened', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final store = c.read(lastDestinationsProvider.notifier);
    await store.record('a', 'agents');
    await store.note('a', 'agents', chatId: 'c1', title: 'Fix login');
    // A Files screen visited from inside that chat doesn't replace it.
    await store.note('a', 'files', path: '/home/me/p');
    await store.record('a', 'agents');
    var entry = c.read(lastDestinationsProvider)['a']!;
    expect(entry.chatId, 'c1');
    expect(entry.title, 'Fix login');
    expect(entry.path, isNull);

    final fresh = ProviderContainer();
    addTearDown(fresh.dispose);
    await fresh.read(lastDestinationsProvider.notifier).load('a');
    expect(fresh.read(lastDestinationsProvider)['a']?.chatId, 'c1');

    // Opening another tool starts a new, empty task.
    await store.record('a', 'terminal');
    entry = c.read(lastDestinationsProvider)['a']!;
    expect(entry.hasTask, isFalse);
    await store.note('a', 'terminal', terminalId: 's1', path: '/home/me/p');
    entry = c.read(lastDestinationsProvider)['a']!;
    expect((entry.terminalId, entry.path), ('s1', '/home/me/p'));
  });

  test('continueLabel names the chat or folder before the project', () {
    final at = DateTime(2026, 11, 9);
    expect(
      continueLabel(
        LastDestination('agents', at, chatId: 'c1', title: 'Fix login'),
        project: 'NexusLink',
      ),
      'Fix login',
    );
    expect(
      continueLabel(
        LastDestination('files', at, path: '/home/me/projects/api'),
        project: 'NexusLink',
      ),
      'api',
    );
    expect(
      continueLabel(LastDestination('agents', at), project: 'NexusLink'),
      'NexusLink',
    );
  });

  testWidgets('an Audio-only PC has a reachable shortcut at double text size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    SharedPreferences.setMockInitialValues({});
    final target = hubTarget(utilities: {UtilityIds.audio});
    await TargetStore.save([target]);
    await TargetStore.setCurrent(target.id);
    await _pumpHome(tester);
    final audio = find.byKey(const ValueKey('tile-audio'));
    await tester.scrollUntilVisible(
      audio,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(
      audio.hitTestable(),
      findsOneWidget,
      reason: 'shortcut at ${tester.getRect(audio)}',
    );
    expect(find.byKey(const ValueKey('tile-desktop')), findsNothing);
    expect(find.byKey(const ValueKey('home-dock')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Continue names the chat you were in', (tester) async {
    SharedPreferences.setMockInitialValues({
      '$lastModuleKeyPrefix$_id': jsonEncode({
        'module': 'agents',
        'at': DateTime.now().millisecondsSinceEpoch,
        'chatId': 'c9',
        'title': 'Fix login',
      }),
    });
    await _saveOffice();
    await _pumpHome(tester);
    final card = find.byKey(const ValueKey('continue-card'));
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.textContaining('Fix login')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Home offers Continue to the last tool used on this PC', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      '$lastModuleKeyPrefix$_id': jsonEncode({
        'module': 'terminal',
        'at': DateTime.now()
            .subtract(const Duration(minutes: 7))
            .millisecondsSinceEpoch,
      }),
    });
    await _saveOffice();
    await _pumpHome(tester);
    expect(find.byKey(const ValueKey('continue-card')), findsOneWidget);
    expect(find.text('Last opened 7 min ago'), findsOneWidget);
    expect(find.byKey(const ValueKey('attention-card')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a live approval on the connected PC comes first', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      '$lastModuleKeyPrefix$_id': jsonEncode({
        'module': 'terminal',
        'at': DateTime.now().millisecondsSinceEpoch,
      }),
    });
    await _saveOffice();
    await PlatformBridge.saveCredential(_url, 'secret');
    addTearDown(() => PlatformBridge.removeCredential(_url));
    await _pumpHome(
      tester,
      approvals: [
        ExternalApproval({
          'id': 'a1',
          'chatId': 'c1',
          'kind': 'approval',
          'title': 'Run: npm test',
          'cwd': '/home/me/projects/NexusLink',
        }),
        ExternalApproval({'id': 'a2', 'chatId': 'c2', 'kind': 'question'}),
      ],
    );
    expect(FakeConnection.connects, [_url]);
    expect(find.byKey(const ValueKey('attention-card')), findsOneWidget);
    expect(find.text('Review approval · NexusLink'), findsOneWidget);
    expect(find.text('Run: npm test'), findsOneWidget);
    expect(find.text('NEEDS YOU · 2'), findsOneWidget);
    expect(find.byKey(const ValueKey('continue-card')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Device settings holds wake and rename; the selector switches', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await _saveOffice();
    await _pumpHome(tester);
    await tester.tap(find.byKey(const ValueKey('device-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Set up wake'), findsOneWidget);
    expect(find.text('Rename or remove'), findsOneWidget);
    expect(find.text('Switch device'), findsNothing);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pc-selector')));
    await tester.pumpAndSettle();
    expect(find.text('YOUR DEVICES'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
