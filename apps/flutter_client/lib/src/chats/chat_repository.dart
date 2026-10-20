import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../rpc/rpc_client.dart';
import '../state/connection.dart';
import 'chat_cache.dart';
import 'chat_models.dart';

final chatCacheProvider = Provider((ref) => ChatCache());

/// Rebuilt only when the client object or PC address changes. Status flips
/// (connecting / connected / reconnecting on the same client) keep the same
/// repository, so lists bound to it do not reset or flicker; `online` reads
/// the live client status on every call.
final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  final (client, address) = ref.watch(
    connectionProvider.select((s) => (s.client, s.hostUrl)),
  );
  final repository = ChatRepository(
    client,
    address,
    ref.read(chatCacheProvider),
  );
  ref.onDispose(repository.dispose);
  return repository;
});

class ChatRepository {
  final RpcClient? client;
  final String? address;
  final ChatCache cache;
  bool _disposed = false;
  ChatRepository(this.client, this.address, this.cache);
  bool get online => client?.status == RpcStatus.connected;
  bool get supported => client?.supports('chat.library.v1') == true;
  Future<String?> host() async {
    final prefs = await SharedPreferences.getInstance();
    if (online && supported && client?.hostId != null) {
      final id = client!.hostId!;
      await prefs.setString('chat-host:$address', id);
      await prefs.setString('chat-last-host', id);
      return id;
    }
    // Never display a different PC's cache while connecting to a new address.
    return address != null
        ? prefs.getString('chat-host:$address')
        : prefs.getString('chat-last-host');
  }

  Future<Map<String, dynamic>> list(
    Map<String, dynamic> query, {
    bool folders = false,
  }) async {
    final hostId = await host();
    if (online && supported) {
      final page = await client!.requestMap(
        folders ? 'chat.folders' : 'chat.list',
        query,
      );
      if (!_disposed && !folders && hostId != null) {
        await cache.saveSummaries(
          hostId,
          (page['items'] as List)
              .map((row) => Map<String, dynamic>.from(row as Map))
              .toList(),
        );
      }
      return page;
    }
    var rows = hostId == null
        ? <ChatSummary>[]
        : (await cache.summaries(hostId)).map(ChatSummary.new).toList();
    final text = (query['query'] as String? ?? '').toLowerCase();
    rows = rows
        .where(
          (row) =>
              row.archived == (query['archived'] == true) &&
              (query['source'] == null || row.source == query['source']) &&
              (!query.containsKey('folderId') ||
                  row.folderId == query['folderId']) &&
              [
                row.title,
                row.preview,
                row.sourceName,
                row.folderPath ?? '',
              ].join(' ').toLowerCase().contains(text),
        )
        .toList();
    if (folders) {
      final grouped = <String?, List<ChatSummary>>{};
      for (final row in rows) {
        grouped.putIfAbsent(row.folderId, () => []).add(row);
      }
      final items = grouped.entries
          .map(
            (entry) => <String, dynamic>{
              'id': entry.key,
              'name': entry.value.first.folderName,
              'path': entry.value.first.folderPath,
              'count': entry.value.length,
              'activityAt': entry.value.first.json['activityAt'],
              'latestTitle': entry.value.first.title,
            },
          )
          .toList();
      if (query['sort'] == 'name') {
        items.sort(
          (a, b) => (a['name'] as String).compareTo(b['name'] as String),
        );
      }
      return {'items': items, 'nextCursor': null, 'sources': [], 'saved': true};
    }
    rows = rows
        .where(
          (row) =>
              row.matchesMonitor(query['monitorFilter'] as String? ?? 'all'),
        )
        .toList();
    if (query['sort'] == 'monitor') rows.sort(compareMonitorChats);
    return {
      'items': rows.map((row) => row.json).toList(),
      'nextCursor': null,
      'sources': [],
      'saved': true,
    };
  }

  Future<Map<String, dynamic>> history(
    ChatSummary chat, {
    String? olderCursor,
  }) async {
    if (online && supported) {
      final page = await client!.requestMap('chat.historyPage', {
        'chatId': chat.id,
        'olderCursor': ?olderCursor,
      });
      if (!_disposed &&
          page['restart'] != true &&
          page['completeness'] != 'unavailable') {
        await cache.saveHistory(chat.hostId, chat.id, page);
      }
      return page;
    }
    final saved = await cache.history(chat.hostId, chat.id);
    return saved == null
        ? {
            'events': [],
            'completeness': 'unavailable',
            'reason':
                'This conversation’s messages have not been saved on this phone.',
            'saved': true,
          }
        : {...saved, 'saved': true};
  }

  Future<Map<String, dynamic>> send(
    ChatSummary chat,
    String text,
    String operationId, {
    List<Map<String, dynamic>> images = const [],
    String? model,
    String? thinking,
    String? mode,
    bool interrupt = false,
  }) async {
    if (!online) {
      throw RpcException(
        'PC offline. Your draft is saved; reconnect to send it.',
      );
    }
    return client!.requestMap('chat.send', {
      'chatId': chat.id,
      'text': text,
      'operationId': operationId,
      if (images.isNotEmpty) 'images': images,
      'model': ?model,
      'thinking': ?thinking,
      'mode': ?mode,
      if (interrupt) 'interrupt': true,
    });
  }

  /// Asks the PC to stop this conversation's current turn. Returns true when
  /// the PC stopped it, false when it cannot be stopped from the phone (for
  /// example a chat started outside NexusLink). Throws when the PC is
  /// unreachable, so callers never report a stop that did not happen.
  Future<bool> cancel(ChatSummary chat) async {
    if (!online) {
      throw RpcException('PC offline. Reconnect to stop this conversation.');
    }
    if (!supported) return false;
    final result = await client!.requestMap('chat.cancel', {'chatId': chat.id});
    return result['ok'] != false;
  }

  Future<void> refresh() async {
    if (online && supported) await client!.requestMap('chat.refresh', {});
  }

  void dispose() {
    _disposed = true;
  }
}
