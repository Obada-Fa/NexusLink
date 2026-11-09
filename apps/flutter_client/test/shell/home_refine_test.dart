// Refine plan pass 1: grouped tools, recovery text, partial pairing summary,
// the per-PC "Continue" store, and the attention / continue cards on Home.

import 'dart:convert';

import 'package:flutter/material.dart';
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
import 'package:nexuslink/src/shell/shell_controller.dart';
import 'package:nexuslink/src/shell/target_actions.dart';
import 'package:nexuslink/src/shell/tiles.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:nexuslink/src/state/wake_config.dart';
import 'package:nexuslink/src/workspace/platform_bridge.dart';
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

  group('groupTiles', () {
    test('Workspace (Agents, Terminal, Files) before PC tools', () {
      final tiles = [
        for (final m in moduleRegistry) HomeTile(m, TileStatus.ready),
      ];
      final groups = groupTiles(tiles);
      expect(groups.map((g) => g.$1), [ToolGroup.workspace, ToolGroup.pcTools]);
      expect(groups[0].$2.map((t) => t.module.id), [
        'agents',
        'terminal',
        'files',
      ]);
      expect(groups[1].$2.map((t) => t.module.id), [
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
