import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexuslink/src/chats/chat_models.dart';
import 'package:nexuslink/src/chats/chat_library_screen.dart';
import 'package:nexuslink/src/chats/chat_repository.dart';
import 'package:nexuslink/src/chats/monitor_conversation_card.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'chat_library_test.dart' show FakeRepository;
import 'workspace_terminal_test.dart' show TerminalHost;

Map<String, dynamic> conversation(String id, String execution, int time) => {
  'id': id,
  'hostId': 'pc',
  'source': 'codex',
  'sourceName': 'Codex',
  'title': id,
  'folderName': 'NexusLink',
  'execution': execution,
  'activityAt': time,
  'capabilities': {'continue': false},
};

class MonitorRepository extends FakeRepository {
  List<Map<String, dynamic>> rows = [
    conversation('Recent conversation', 'idle', 300),
    {
      ...conversation('Fix authentication', 'working', 100),
      'activity': 'editing',
    },
    conversation('Review deployment', 'needsReply', 200),
  ];
  @override
  Future<Map<String, dynamic>> list(
    Map<String, dynamic> query, {
    bool folders = false,
  }) async => {'items': rows, 'sources': [], 'nextCursor': null};
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('attention wins over work and unknown idle never implies success', () {
    final failed = ChatSummary({
      ...conversation('failed', 'working', 1),
      'taskState': 'failed',
    });
    expect(failed.needsAttention, isTrue);
    expect(failed.running, isFalse);
    expect(ChatSummary(conversation('idle', 'idle', 2)).monitorStatus, 'Idle');
    expect(
      ChatSummary(conversation('unknown', 'unknown', 2)).monitorStatus,
      'Status unavailable',
    );
  });
  testWidgets(
    'monitor filters live work and moves completed conversations to recent',
    (tester) async {
      final host = TerminalHost();
      final repository = MonitorRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatRepositoryProvider.overrideWithValue(repository),
            activeClientProvider.overrideWithValue(host),
            connectionStatusProvider.overrideWithValue(RpcStatus.connected),
          ],
          child: const MaterialApp(home: ChatLibraryScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Needs attention'), findsOneWidget);
      expect(find.text('Review deployment'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Running'));
      await tester.pumpAndSettle();
      expect(find.text('Fix authentication'), findsOneWidget);
      expect(find.text('Review deployment'), findsNothing);
      expect(find.text('Editing files'), findsOneWidget);
      repository.rows = [
        {
          ...conversation('Fix authentication', 'idle', 400),
          'taskState': 'completed',
        },
      ];
      host.emit('chat-library-update', {});
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('No agents running right now'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Recent'));
      await tester.pumpAndSettle();
      expect(find.text('Fix authentication'), findsOneWidget);
      expect(find.text('Finished'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      host.dispose();
    },
  );
  testWidgets('offline cards identify stale work and fit large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.8)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: MonitorConversationCard(
              chat: ChatSummary(
                conversation(
                  'Long conversation title about deployment and monitoring',
                  'working',
                  1,
                ),
              ),
              offline: true,
              onOpen: () {},
            ),
          ),
        ),
      ),
    );
    expect(find.text('Working · last known'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
