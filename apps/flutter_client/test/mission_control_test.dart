import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexuslink/src/chats/chat_cache.dart';
import 'package:nexuslink/src/chats/chat_models.dart';
import 'package:nexuslink/src/chats/chat_repository.dart';
import 'package:nexuslink/src/chats/chat_library_screen.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'workspace_terminal_test.dart' show TerminalHost;

class _Cache extends ChatCache {
  @override
  Future<List<Map<String, dynamic>>> summaries(String host) async => [];
  @override
  Future<int?> lastSync(String host) async => null;
}

Map<String, dynamic> _chat(
  String id,
  String source,
  String title,
  String execution,
  Map<String, dynamic>? live,
) => {
  'id': id,
  'hostId': 'pc',
  'source': source,
  'sourceName': source,
  'title': title,
  'folderId': 'f',
  'folderName': 'NexusLink',
  'activityAt': DateTime.now().millisecondsSinceEpoch,
  'capabilities': {'continue': true},
  'execution': execution,
  'live': ?live,
};

class _Repo extends ChatRepository {
  _Repo([RpcClient? client]) : super(client, 'test-pc', _Cache());
  @override
  bool get online => true;
  @override
  bool get supported => true;
  @override
  Future<String?> host() async => 'pc';
  @override
  Future<Map<String, dynamic>> list(
    Map<String, dynamic> query, {
    bool folders = false,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return {
      'items': [
        _chat('w', 'claude', 'Refactor the login flow', 'working', {
          'state': 'working',
          'step': 'Editing lib/main.dart',
          'activity': 'editing',
          'turnStartedAt': now - 125000,
          'todos': [
            {'text': 'Read code', 'state': 'done'},
            {'text': 'Write tests', 'state': 'active'},
            {'text': 'Ship', 'state': 'pending'},
          ],
          'lastText': 'Splitting the auth module first.',
        }),
        _chat('q', 'codex', 'Clean build cache', 'needsReply', {
          'state': 'waiting',
          'waitingFor': 'Approve: rm -rf build',
        }),
        _chat('d', 'antigravity', 'Blender export script', 'idle', {
          'state': 'done',
          'lastText': 'Exported 12 meshes.',
        }),
      ],
      'nextCursor': null,
      'sources': [],
    };
  }
}

class _BusyRepo extends _Repo {
  @override
  Future<Map<String, dynamic>> list(
    Map<String, dynamic> query, {
    bool folders = false,
  }) async => {
    'items': [
      for (var i = 0; i < 17; i++)
        _chat('busy-$i', 'codex', 'Busy task $i', 'working', {
          'state': 'working',
          'activity': 'editing',
        }),
    ],
    'nextCursor': null,
    'sources': [],
  };
}

Widget _app([RpcClient? client, ChatRepository? repository]) => ProviderScope(
  overrides: [
    chatRepositoryProvider.overrideWithValue(repository ?? _Repo(client)),
    if (client != null) activeClientProvider.overrideWithValue(client),
    connectionStatusProvider.overrideWithValue(RpcStatus.connected),
  ],
  child: MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: const ChatLibraryScreen(),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('live state unifies host execution and live fields', () {
    final waiting = ChatSummary(
      _chat('a', 'codex', 't', 'idle', {
        'state': 'waiting',
        'waitingFor': 'Approve',
      }),
    );
    expect(waiting.liveState, 'waiting');
    expect(waiting.needsAttention, isTrue);
    expect(waiting.stepLabel, 'Approve');
    final working = ChatSummary(
      _chat('b', 'claude', 't', 'idle', {
        'state': 'working',
        'step': 'Running: npm test',
      }),
    );
    expect(working.running, isTrue);
    expect(working.stepLabel, 'Running: npm test');
    expect(
      ChatSummary(_chat('c', 'claude', 't', 'working', null)).liveState,
      'working',
    );
    expect(formatElapsed(const Duration(seconds: 125)), '2m 05s');
    expect(formatElapsed(const Duration(minutes: 75)), '1h 15m');
  });

  testWidgets(
    'mission control groups needs-you, live and recent with plan progress',
    (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(find.text('Mission Control'), findsOneWidget);
      expect(find.text('NEEDS YOU'), findsOneWidget);
      expect(find.text('LIVE NOW'), findsOneWidget);
      expect(find.text('Approve: rm -rf build'), findsOneWidget);
      expect(find.text('Editing lib/main.dart'), findsOneWidget);
      expect(find.text('1/3'), findsOneWidget);
      expect(find.text('Write tests'), findsOneWidget);
      expect(find.text('2m 05s'), findsOneWidget);
      // Counters filter on the phone without another host query.
      await tester.tap(find.text('Needs you').first);
      await tester.pumpAndSettle();
      expect(find.text('Refactor the login flow'), findsNothing);
      expect(find.text('Clean build cache'), findsOneWidget);
      await tester.tap(find.text('Needs you').first);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Blender export script'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Blender export script'), findsOneWidget);
    },
  );

  testWidgets('arena groups agents in the office and remembers the view', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Arena'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('THE OFFICE'), findsOneWidget);
    expect(find.textContaining('needs you'), findsWidgets);
    expect(find.text('Refactor the login flow'), findsOneWidget);
    expect(find.text('Approve: rm -rf build'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('monitor-view'), 'arena');
  });

  testWidgets(
    'arena never drops active agents beyond the old twelve-agent limit',
    (tester) async {
      await tester.pumpWidget(_app(null, _BusyRepo()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Arena'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('17 agents'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Busy task 16'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Busy task 16'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mission control fits a 320 dp phone with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(_Repo()),
          connectionStatusProvider.overrideWithValue(RpcStatus.connected),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: true,
              textScaler: const TextScaler.linear(1.3),
            ),
            child: child!,
          ),
          home: const ChatLibraryScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Arena'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  test('a chat marked done or gone stale no longer needs attention', () {
    final cleared = ChatSummary({
      ..._chat('x', 'claude', 't', 'idle', {'state': 'idle'}),
      'attentionCleared': 'acknowledged',
      'taskState': 'failed',
    });
    expect(cleared.needsAttention, isFalse);
    expect(cleared.liveState, 'done');
    final stale = ChatSummary({
      ..._chat('y', 'claude', 't', 'idle', null),
      'attentionCleared': 'stale',
    });
    expect(stale.liveState, 'idle');
  });

  testWidgets('long-press marks a needs-you chat done on the PC', (
    tester,
  ) async {
    final host = TerminalHost();
    await tester.pumpWidget(_app(host));
    await tester.pumpAndSettle();
    expect(find.text('NEEDS YOU'), findsOneWidget);
    await tester.longPress(find.text('Clean build cache'));
    await tester.pumpAndSettle();
    expect(find.text('Mark as done'), findsOneWidget);
    await tester.tap(find.text('Mark as done'));
    await tester.pumpAndSettle();
    expect(host.calls, contains('chat.setState'));
    expect(find.text('NEEDS YOU'), findsNothing);
    expect(find.textContaining('Marked done'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    host.dispose();
  });

  testWidgets('swiping a needs-you card marks it done', (tester) async {
    final host = TerminalHost();
    await tester.pumpWidget(_app(host));
    await tester.pumpAndSettle();
    await tester.drag(find.text('Clean build cache'), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(host.calls, contains('chat.setState'));
    expect(find.text('NEEDS YOU'), findsNothing);
    expect(find.text('Clean build cache'), findsOneWidget); // now under Recent
    await tester.pumpWidget(const SizedBox());
    host.dispose();
  });
}
