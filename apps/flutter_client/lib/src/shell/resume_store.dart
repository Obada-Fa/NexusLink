// Where you last were on each PC, so Home can offer "Continue" there.
// Stored locally per target: `nexus-last-module:<targetId>` → JSON
// {"module": "<moduleId>", "at": <epoch ms>, "chatId"?, "title"?, "path"?,
//  "terminalId"?}. The optional fields say which task inside the module
// (the chat, the folder, the shell) so Continue reopens it, not just the tool.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'shell_controller.dart';

const lastModuleKeyPrefix = 'nexus-last-module:';

class LastDestination {
  const LastDestination(
    this.moduleId,
    this.at, {
    this.chatId,
    this.title,
    this.path,
    this.terminalId,
  });
  final String moduleId;
  final DateTime at;

  /// Agents: the chat that was open.
  final String? chatId;

  /// A human label for the task (the chat's title).
  final String? title;

  /// Files: the folder shown. Terminal: the shell's folder.
  final String? path;

  /// Terminal: the shell that was attached.
  final String? terminalId;

  bool get hasTask => chatId != null || path != null || terminalId != null;

  Map<String, dynamic> toJson() => {
    'module': moduleId,
    'at': at.millisecondsSinceEpoch,
    'chatId': ?chatId,
    'title': ?title,
    'path': ?path,
    'terminalId': ?terminalId,
  };

  static LastDestination? fromJson(Object? raw) {
    if (raw is! Map || raw['module'] is! String || raw['at'] is! num) {
      return null;
    }
    String? text(String key) => raw[key] is String ? raw[key] as String : null;
    return LastDestination(
      raw['module'] as String,
      DateTime.fromMillisecondsSinceEpoch((raw['at'] as num).toInt()),
      chatId: text('chatId'),
      title: text('title'),
      path: text('path'),
      terminalId: text('terminalId'),
    );
  }
}

/// Target id → last module opened on it. Loaded lazily per target.
class LastDestinations extends Notifier<Map<String, LastDestination>> {
  final _loading = <String>{};

  @override
  Map<String, LastDestination> build() => const {};

  /// Reads [targetId]'s entry from storage once.
  Future<void> load(String targetId) async {
    if (state.containsKey(targetId) || !_loading.add(targetId)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$lastModuleKeyPrefix$targetId');
      if (raw == null || state.containsKey(targetId)) return;
      final entry = LastDestination.fromJson(jsonDecode(raw));
      if (entry != null) state = {...state, targetId: entry};
    } catch (_) {
      // A corrupt entry just means no "Continue" card.
    } finally {
      _loading.remove(targetId);
    }
  }

  /// Records that [moduleId] was opened on [targetId]. Reopening the same
  /// module keeps the task noted in it (Continue → same chat).
  Future<void> record(String targetId, String moduleId, {DateTime? at}) {
    final old = state[targetId];
    final entry = old != null && old.moduleId == moduleId
        ? LastDestination(
            moduleId,
            at ?? DateTime.now(),
            chatId: old.chatId,
            title: old.title,
            path: old.path,
            terminalId: old.terminalId,
          )
        : LastDestination(moduleId, at ?? DateTime.now());
    return _save(targetId, entry);
  }

  /// Notes which task is open inside [moduleId]. Ignored unless [moduleId]
  /// is the module last opened from Home on [targetId], so a Files screen
  /// visited from inside a chat doesn't replace "Continue → that chat".
  Future<void> note(
    String targetId,
    String moduleId, {
    String? chatId,
    String? title,
    String? path,
    String? terminalId,
  }) async {
    final old = state[targetId];
    if (old == null || old.moduleId != moduleId) return;
    await _save(
      targetId,
      LastDestination(
        moduleId,
        DateTime.now(),
        chatId: chatId ?? old.chatId,
        title: chatId != null ? title : (title ?? old.title),
        path: path ?? old.path,
        terminalId: terminalId ?? old.terminalId,
      ),
    );
  }

  Future<void> _save(String targetId, LastDestination entry) async {
    state = {...state, targetId: entry};
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$lastModuleKeyPrefix$targetId',
      jsonEncode(entry.toJson()),
    );
  }

  /// Forgets [targetId] (it was removed).
  Future<void> forget(String targetId) async {
    state = {...state}..remove(targetId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$lastModuleKeyPrefix$targetId');
  }
}

final lastDestinationsProvider =
    NotifierProvider<LastDestinations, Map<String, LastDestination>>(
      LastDestinations.new,
    );

/// Notes the task open in [moduleId] on the current PC (see
/// [LastDestinations.note]). Safe to call from any screen; never throws.
void noteResume(
  WidgetRef ref,
  String moduleId, {
  String? chatId,
  String? title,
  String? path,
  String? terminalId,
}) {
  final targetId = ref.read(shellProvider).current?.id;
  if (targetId == null) return;
  unawaited(
    ref
        .read(lastDestinationsProvider.notifier)
        .note(
          targetId,
          moduleId,
          chatId: chatId,
          title: title,
          path: path,
          terminalId: terminalId,
        )
        .catchError((_) {}),
  );
}
