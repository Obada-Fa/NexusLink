import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexuslink/src/chats/chat_cache.dart';
import 'package:nexuslink/src/chats/chat_models.dart';
import 'package:nexuslink/src/chats/chat_repository.dart';
import 'package:nexuslink/src/chats/chat_library_screen.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';

class MemoryCache extends ChatCache {
  @override
  Future<List<Map<String, dynamic>>> summaries(String host) async => [];
  @override
  Future<int?> lastSync(String host) async => null;
}

class FakeRepository extends ChatRepository {
  FakeRepository() : super(null, 'test-pc', MemoryCache());
  final queries = <Map<String, dynamic>>[];
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
    queries.add(Map.of(query));
    return {
      'items': folders
          ? [
              {
                'id': 'folder',
                'name': 'NexusLink',
                'path': r'D:\projects\mobile\NexusLink',
                'count': 2,
                'latestTitle': 'Fix login',
              },
            ]
          : [
              if (!(query['query'] as String? ?? '').contains('missing'))
                {
                  'id': 'chat',
                  'hostId': 'pc',
                  'source': 'codex',
                  'sourceName': 'Codex',
                  'title': 'Fix login',
                  'preview': 'Ready for review',
                  'folderId': 'folder',
                  'folderName': 'NexusLink',
                  'folderPath': r'D:\projects\mobile\NexusLink',
                  'activityAt': DateTime.now().millisecondsSinceEpoch,
                  'capabilities': {'continue': false},
                  'execution': 'unknown',
                },
            ],
      'nextCursor': null,
      'sources': [],
    };
  }
}

class DelayedRepository extends FakeRepository {
  final oldSearch = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> list(
    Map<String, dynamic> query, {
    bool folders = false,
  }) {
    if (query['query'] == 'old') return oldSearch.future;
    return super.list(query, folders: folders);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('a delayed older search cannot replace the current results', (
    tester,
  ) async {
    final repository = DelayedRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(home: ChatLibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'old');
    await tester.pump(const Duration(milliseconds: 260));
    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pumpAndSettle();
    expect(find.text('No search results'), findsOneWidget);
    repository.oldSearch.complete({
      'items': [
        {
          'id': 'stale',
          'title': 'Expired search',
          'source': 'codex',
          'sourceName': 'Codex',
          'hostId': 'pc',
        },
      ],
      'sources': [],
      'nextCursor': null,
    });
    await tester.pumpAndSettle();
    expect(find.text('Expired search'), findsNothing);
    expect(find.text('No search results'), findsOneWidget);
  });
  test(
    'date groups use local calendar boundaries including daylight saving',
    () {
      final now = DateTime(2026, 10, 4, 1);
      expect(chatDateGroup(DateTime(2026, 10, 4), now: now), 'Today');
      expect(chatDateGroup(DateTime(2026, 10, 3, 23), now: now), 'Yesterday');
      expect(chatDateGroup(DateTime(2026, 9, 29), now: now), 'Last 7 days');
      expect(chatDateGroup(null, now: now), 'Older');
    },
  );
  testWidgets(
    'Recent opens first and folder navigation preserves recorded Windows paths',
    (tester) async {
      final repository = FakeRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatRepositoryProvider.overrideWithValue(repository),
            connectionStatusProvider.overrideWithValue(RpcStatus.connected),
          ],
          child: const MaterialApp(home: ChatLibraryScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Fix login'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      expect(find.textContaining('Codex · NexusLink'), findsOneWidget);
      await tester.tap(find.text('Folders'));
      await tester.pumpAndSettle();
      expect(find.text('2 chats'), findsOneWidget);
      expect(
        find.textContaining(r'D:\projects\mobile\NexusLink'),
        findsOneWidget,
      );
      await tester.tap(find.text('NexusLink'));
      await tester.pumpAndSettle();
      expect(repository.queries.last['folderId'], 'folder');
      expect(find.text('Fix login'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('2 chats'), findsOneWidget);
    },
  );
  testWidgets('search debounces and distinguishes no search results', (
    tester,
  ) async {
    final repository = FakeRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(home: ChatLibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final before = repository.queries.length;
    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pump(const Duration(milliseconds: 200));
    expect(repository.queries.length, before);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pumpAndSettle();
    expect(find.text('No search results'), findsOneWidget);
  });
  testWidgets('chat rows fit at 320 dp with large accessible text', (
    tester,
  ) async {
    final repository = FakeRepository();
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: const ChatLibraryScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('Fix login'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Fix login'), findsOneWidget);
  });
}
