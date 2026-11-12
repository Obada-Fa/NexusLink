import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/rpc/models.dart';
import 'package:nexuslink/src/screens/agent_screen.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:nexuslink/src/chats/chat_repository.dart';
import 'package:nexuslink/src/chats/chat_cache.dart';
import 'package:nexuslink/src/chats/chat_models.dart';
import 'package:nexuslink/src/widgets/chat_permission_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_running_state_test.dart' show RunningHost, settle, teardown;

class PermissionsHost extends RunningHost {
  String? permissionMode;
  bool supported = true;
  bool fail = false;
  bool materialized = false;
  final changes = <Map<String, dynamic>>[];

  @override
  bool supports(String feature) => feature == 'agent.setPermissionMode'
      ? supported
      : super.supports(feature);

  @override
  Map<String, dynamic> get session => {
    ...super.session,
    'agent': 'codex',
    'permissionMode': permissionMode,
  };

  @override
  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 10),
  ]) async {
    if (method == 'agent.list') {
      return [
        {'id': 'codex', 'name': 'Codex', 'available': true},
      ];
    }
    if (method == 'agent.openHostChat') {
      materialized = true;
      return session;
    }
    if (method == 'agent.setPermissionMode') {
      changes.add(Map.of(params));
      if (fail) return {'ok': false, 'reason': 'PC rejected this change'};
      permissionMode = params['mode'] as String;
      return {'ok': true, 'session': session};
    }
    return super.request(method, params, timeout);
  }
}

class PermissionsCache extends ChatCache {
  @override
  Future<Map<String, Object?>?> draft(String host, String id) async => null;
  @override
  Future<void> saveDraft(
    String host,
    String id,
    String text, {
    double? position,
  }) async {}
}

class PermissionsRepository extends ChatRepository {
  PermissionsRepository(this.pc) : super(pc, 'pc', PermissionsCache());
  final PermissionsHost pc;
  Map<String, dynamic> get summary => {
    'id': 'library-chat',
    'hostId': 'pc',
    'source': 'codex',
    'nativeId': 'native-thread',
    'title': 'Saved chat',
    'folderPath': '/project',
    'execution': 'idle',
    'capabilities': {'continue': true},
    if (pc.materialized) 'agentSessionId': 'task-1',
    'permissionMode': pc.permissionMode,
  };
  @override
  bool get supported => true;
  @override
  Future<Map<String, dynamic>> history(
    ChatSummary chat, {
    String? olderCursor,
  }) async => {
    'chat': summary,
    'events': [],
    'revision': 'one',
    'completeness': 'complete',
  };
}

Future<void> openChat(
  WidgetTester tester,
  PermissionsHost pc, {
  double scale = 1,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeClientProvider.overrideWithValue(pc),
        connectionStatusProvider.overrideWithValue(RpcStatus.connected),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const AgentScreen(initialTaskId: 'task-1'),
      ),
    ),
  );
  await settle(tester);
}

Future<void> openMenu(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await settle(tester);
  await tester.tap(
    find.byTooltip('Photo, model, thinking, permissions, folder…'),
  );
  await settle(tester);
  await tester.scrollUntilVisible(
    find.widgetWithText(ListTile, 'Permissions'),
    150,
    scrollable: find
        .descendant(
          of: find.byType(BottomSheet).last,
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await settle(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'plus menu saves a chat permission mode and shows it on reopening',
    (tester) async {
      final pc = PermissionsHost();
      await openChat(tester, pc);
      await openMenu(tester);
      expect(find.text('Using PC settings'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, 'Permissions'));
      await settle(tester);
      await tester.tap(find.widgetWithText(ListTile, 'Ask for approval'));
      await settle(tester);
      expect(pc.changes.single, {'agentSessionId': 'task-1', 'mode': 'ask'});
      await openMenu(tester);
      expect(find.text('Ask for approval'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, 'Permissions'));
      await settle(tester);
      await tester.tap(find.widgetWithText(ListTile, 'Full access'));
      await settle(tester);
      expect(pc.changes.last['mode'], 'full-access');
      await openMenu(tester);
      expect(find.text('Full access'), findsOneWidget);
      await teardown(tester);
    },
  );

  testWidgets('failed save reports the error and keeps the previous mode', (
    tester,
  ) async {
    final pc = PermissionsHost()..fail = true;
    await openChat(tester, pc);
    await openMenu(tester);
    await tester.tap(find.widgetWithText(ListTile, 'Permissions'));
    await settle(tester);
    await tester.tap(find.widgetWithText(ListTile, 'Ask for approval'));
    await settle(tester);
    expect(find.textContaining('PC rejected this change'), findsOneWidget);
    await openMenu(tester);
    expect(find.text('Using PC settings'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('older host explains the required update', (tester) async {
    final pc = PermissionsHost()..supported = false;
    await openChat(tester, pc);
    await openMenu(tester);
    expect(
      find.text('Update NexusLink on your PC to change permissions'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<ListTile>(find.widgetWithText(ListTile, 'Permissions'))
          .enabled,
      isFalse,
    );
    expect(pc.changes, isEmpty);
    await teardown(tester);
  });

  testWidgets('permissions cannot change while a reply runs', (tester) async {
    final pc = PermissionsHost()..busy = true;
    await openChat(tester, pc);
    await openMenu(tester);
    expect(
      tester
          .widget<ListTile>(find.widgetWithText(ListTile, 'Permissions'))
          .enabled,
      isFalse,
    );
    await teardown(tester);
  });

  testWidgets('permission choices cancel without saving', (tester) async {
    final pc = PermissionsHost();
    await openChat(tester, pc);
    await openMenu(tester);
    await tester.tap(find.widgetWithText(ListTile, 'Permissions'));
    await settle(tester);
    await tester.ensureVisible(find.widgetWithText(ListTile, 'Full access'));
    expect(tester.takeException(), isNull);
    Navigator.of(tester.element(find.text('Permissions'))).pop();
    await settle(tester);
    expect(pc.changes, isEmpty);
    await teardown(tester);
  });

  testWidgets('permission sheet fits a narrow phone at double text size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: const Scaffold(body: ChatPermissionSheet()),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.widgetWithText(ListTile, 'Full access'),
      150,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'permissions work before the first Nexus reply to a saved PC chat',
    (tester) async {
      final pc = PermissionsHost();
      final repo = PermissionsRepository(pc);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeClientProvider.overrideWithValue(pc),
            connectionStatusProvider.overrideWithValue(RpcStatus.connected),
            chatRepositoryProvider.overrideWithValue(repo),
            chatCacheProvider.overrideWithValue(repo.cache),
          ],
          child: MaterialApp(
            home: AgentScreen(libraryChat: ChatSummary(repo.summary)),
          ),
        ),
      );
      await settle(tester);
      await openMenu(tester);
      await tester.tap(find.widgetWithText(ListTile, 'Permissions'));
      await settle(tester);
      await tester.tap(find.widgetWithText(ListTile, 'Ask for approval'));
      await settle(tester);
      expect(pc.materialized, isTrue);
      expect(pc.changes.single, {'agentSessionId': 'task-1', 'mode': 'ask'});
      await openMenu(tester);
      expect(find.text('Ask for approval'), findsOneWidget);
      await teardown(tester);
    },
  );

  test('session copies retain permission mode', () {
    final session = AgentSessionInfo.fromJson({
      'agentSessionId': 'one',
      'permissionMode': 'ask',
    });
    expect(session.copyWith(busy: true).permissionMode, 'ask');
  });
}
