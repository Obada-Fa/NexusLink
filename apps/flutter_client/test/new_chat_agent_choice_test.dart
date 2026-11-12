import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/screens/agent_screen.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_running_state_test.dart' show RunningHost, settle, teardown;

class NewChatHost extends RunningHost {
  final created = <Map<String, dynamic>>[];
  bool available = true;

  @override
  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 10),
  ]) async {
    switch (method) {
      case 'agent.list':
        return [
          {'id': 'claude', 'name': 'Claude Code', 'available': available},
          {'id': 'cursor', 'name': 'Cursor', 'available': available},
          {'id': 'codex', 'name': 'Codex', 'available': false},
        ];
      case 'agent.listSessions':
        return [];
      case 'agent.createSession':
        created.add(Map.of(params));
        return {
          'agentSessionId': 'new-task',
          'agent': params['agent'],
          'cwd': params['cwd'],
          'title': params['title'],
        };
      default:
        return super.request(method, params, timeout);
    }
  }
}

Future<void> openNewChat(WidgetTester tester, NewChatHost pc) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeClientProvider.overrideWithValue(pc),
        connectionStatusProvider.overrideWithValue(RpcStatus.connected),
      ],
      child: const MaterialApp(
        home: AgentScreen(startNew: true, initialFolder: '/chosen/project'),
      ),
    ),
  );
  await settle(tester);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'chat-last-source:pc': 'claude'});
  });
  for (final name in ['Cursor', 'Claude Code']) {
    testWidgets('New chat waits for the user to choose $name', (tester) async {
      final pc = NewChatHost();
      await openNewChat(tester, pc);
      expect(find.text('Choose agent'), findsOneWidget);
      expect(pc.created, isEmpty);
      expect(find.text('Cursor'), findsWidgets);
      expect(find.text('Claude Code'), findsWidgets);
      expect(
        tester.widget<ListTile>(find.widgetWithText(ListTile, 'Codex')).enabled,
        isFalse,
      );
      await tester.tap(find.widgetWithText(ListTile, name));
      await settle(tester);
      expect(pc.created, hasLength(1));
      expect(
        pc.created.single['agent'],
        name == 'Cursor' ? 'cursor' : 'claude',
      );
      expect(pc.created.single['cwd'], '/chosen/project');
      await teardown(tester);
    });
  }
  testWidgets('dismissing agent choice creates no chat', (tester) async {
    final pc = NewChatHost();
    await openNewChat(tester, pc);
    Navigator.of(tester.element(find.text('Choose agent'))).pop();
    await settle(tester);
    expect(pc.created, isEmpty);
    expect(find.text('Choose agent'), findsNothing);
    await teardown(tester);
  });
  testWidgets('explains when no agents are available', (tester) async {
    final pc = NewChatHost()..available = false;
    await openNewChat(tester, pc);
    expect(find.text('No agents available'), findsOneWidget);
    expect(pc.created, isEmpty);
    await teardown(tester);
  });
}
