import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nexuslink/src/chats/chat_cache.dart';
import 'package:nexuslink/src/chats/chat_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late ChatCache cache;
  setUp(() {
    sqfliteFfiInit();
    cache = ChatCache(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async => (await cache.database).close());
  test(
    'keeps older managed history when a live reply advances the revision',
    () async {
      await cache.saveHistory('pc', 'chat', {
        'revision': '100',
        'appendOnly': true,
        'events': [
          {'id': 'old', 'seq': 1, 'kind': 'text', 'text': 'Older page'},
        ],
      });
      await cache.saveHistory('pc', 'chat', {
        'revision': '101',
        'appendOnly': true,
        'events': [
          {'id': 'new', 'seq': 101, 'kind': 'text', 'text': 'New reply'},
        ],
      });
      expect((await cache.history('pc', 'chat'))?['events'], hasLength(2));
    },
  );
  test(
    'scopes saved summaries and drafts by PC, retaining only 500 summaries',
    () async {
      await cache.saveSummaries('pc-a', [
        for (var i = 0; i < 510; i++)
          {'id': 'chat-$i', 'activityAt': i, 'title': 'Task $i'},
      ]);
      await cache.saveSummaries('pc-b', [
        {'id': 'chat-1', 'title': 'Other PC', 'activityAt': 999},
      ]);
      expect(await cache.summaries('pc-a'), hasLength(500));
      expect((await cache.summaries('pc-b')).single['title'], 'Other PC');
      await cache.saveDraft('pc-a', 'chat-1', 'Saved reply', position: 123);
      await cache.saveOperation('pc-a', 'chat-1', 'uncertain-operation');
      await cache.clear('pc-a');
      expect(await cache.summaries('pc-a'), isEmpty);
      expect((await cache.draft('pc-a', 'chat-1'))?['text'], 'Saved reply');
      expect(
        (await cache.draft('pc-a', 'chat-1'))?['operation'],
        'uncertain-operation',
      );
      expect(await cache.draft('pc-b', 'chat-1'), isNull);
      await cache.clear('pc-a', includeDrafts: true);
      expect(await cache.draft('pc-a', 'chat-1'), isNull);
    },
  );
  test(
    'merges received history pages without duplicates and evicts least recently accessed conversations',
    () async {
      Map<String, dynamic> page(int start) => {
        'revision': 'one',
        'events': [
          for (var i = start; i < start + 100; i++)
            {
              'id': 'event-$i',
              'seq': i,
              'kind': 'text',
              'ts': i,
              'text': 'Message $i',
            },
        ],
        'completeness': 'complete',
      };
      await cache.saveHistory('pc', 'chat', page(1));
      await cache.saveHistory('pc', 'chat', page(51));
      expect((await cache.history('pc', 'chat'))?['events'], hasLength(150));
      await cache.saveDraft('pc', 'chat', 'Do not evict');
      for (var i = 0; i < 21; i++) {
        await cache.saveHistory('pc', 'other-$i', page(1));
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(await cache.history('pc', 'chat'), isNull);
      expect((await cache.draft('pc', 'chat'))?['text'], 'Do not evict');
      expect(await cache.history('pc', 'other-20'), isNotNull);
    },
  );
  test(
    'bounds each transcript to 2 MiB and replaces an expired history revision',
    () async {
      final events = [
        for (var i = 0; i < 100; i++)
          {
            'id': 'event-$i',
            'seq': i,
            'kind': 'text',
            'ts': i,
            'text': 'x' * 40000,
          },
      ];
      await cache.saveHistory('pc', 'chat', {
        'revision': 'one',
        'events': events,
      });
      final saved = await cache.history('pc', 'chat');
      expect(
        utf8.encode(jsonEncode(saved)).length,
        lessThanOrEqualTo(2 * 1024 * 1024),
      );
      expect(saved?['completeness'], 'partial');
      await cache.saveHistory('pc', 'chat', {
        'revision': 'two',
        'events': [
          {'id': 'new', 'seq': 1, 'kind': 'text', 'text': 'Changed'},
        ],
      });
      expect((await cache.history('pc', 'chat'))?['events'], hasLength(1));
    },
  );
  test(
    'offline repositories use only the authenticated host saved for the requested address',
    () async {
      SharedPreferences.setMockInitialValues({
        'chat-host:pc-a': 'host-a',
        'chat-last-host': 'host-b',
      });
      await cache.saveSummaries('host-a', [
        {
          'id': 'a',
          'hostId': 'host-a',
          'source': 'codex',
          'sourceName': 'Codex',
          'title': 'Known PC',
          'activityAt': 1,
        },
      ]);
      await cache.saveSummaries('host-b', [
        {
          'id': 'b',
          'hostId': 'host-b',
          'source': 'claude',
          'sourceName': 'Claude Code',
          'title': 'Other PC',
          'activityAt': 2,
        },
      ]);
      final known = ChatRepository(null, 'pc-a', cache);
      final unknown = ChatRepository(null, 'new-pc', cache);
      expect(
        ((await known.list({}))['items'] as List).single['title'],
        'Known PC',
      );
      expect((await unknown.list({}))['items'], isEmpty);
    },
  );
}
