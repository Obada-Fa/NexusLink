// "Start on PC": a Remote Control session started in an ordinary Nexus
// terminal shell on the PC, so the owner can follow it in the Claude app.
//
// No host protocol change: the shell is created with terminal.create, the
// command is typed with terminal.input, and this phone remembers which shells
// it started this way (per PC). The host's terminal.list is the truth for
// whether a shell still runs; the terminal's output is never parsed.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rpc/rpc_client.dart';
import '../state/connection.dart';
import '../state/last_cwd.dart';
import '../workspace/platform_bridge.dart';
import '../workspace/terminal_repository.dart';

/// Google Play package id of the Claude Android app.
const claudeAppPackage = 'com.anthropic.claude';

const maxSessionNameLength = 80;

/// Removes control characters (newlines, escapes, NUL…) so a name can only
/// ever be one line of plain text, collapses whitespace and caps the length.
String cleanSessionName(String raw) {
  var name = raw
      .replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f  ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (name.runes.length > maxSessionNameLength) {
    name = String.fromCharCodes(
      name.runes.take(maxSessionNameLength),
    ).trimRight();
  }
  return name;
}

/// The default session name for [cwd]: the folder's name.
String defaultSessionName(String cwd) => cleanSessionName(folderDisplayName(cwd));

/// POSIX single-quoting: nothing inside single quotes is special to sh, bash,
/// zsh or dash, and an embedded `'` becomes `'\''`.
String shellSingleQuote(String value) =>
    "'${value.replaceAll("'", r"'\''")}'";

/// The exact text typed into the new shell. `exec` makes the shell's life the
/// session's life, so "Running" on the phone means Remote Control is running.
/// `--name=` keeps a name that starts with `-` a value, never an option. The
/// folder never appears here: the shell is created in it by the host.
String remoteControlCommand(String name) =>
    'exec claude remote-control --name=${shellSingleQuote(cleanSessionName(name))}\r';

/// Windows hosts run a different shell; the command above is POSIX only.
bool isWindowsHostPath(String path) => RegExp(r'^[A-Za-z]:').hasMatch(path);

enum ClaudeAppSessionState { running, ended }

class ClaudeAppSession {
  const ClaudeAppSession({
    required this.terminalId,
    required this.name,
    required this.cwd,
    required this.startedAt,
    this.state = ClaudeAppSessionState.running,
  });
  final String terminalId, name, cwd;
  final int startedAt;
  final ClaudeAppSessionState state;
  bool get running => state == ClaudeAppSessionState.running;

  ClaudeAppSession withState(ClaudeAppSessionState next) => ClaudeAppSession(
    terminalId: terminalId,
    name: name,
    cwd: cwd,
    startedAt: startedAt,
    state: next,
  );

  Map<String, dynamic> toJson() => {
    'terminalId': terminalId,
    'name': name,
    'cwd': cwd,
    'startedAt': startedAt,
  };

  static ClaudeAppSession? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['terminalId'], name = raw['name'], cwd = raw['cwd'];
    if (id is! String || name is! String || cwd is! String) return null;
    return ClaudeAppSession(
      terminalId: id,
      name: name,
      cwd: cwd,
      startedAt: (raw['startedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

class ClaudeAppSessionsState {
  const ClaudeAppSessionsState({
    this.host,
    this.sessions = const [],
    this.reconciled = false,
  });
  final String? host;

  /// Newest first. Only meaningful once [reconciled] against the host.
  final List<ClaudeAppSession> sessions;
  final bool reconciled;
}

String _hostKey(RpcClient client) => client.hostId ?? client.wsUrl;
String _storeKey(String host) => 'claude-app-sessions:$host';

Future<List<ClaudeAppSession>> _load(String host) async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_storeKey(host));
  if (raw == null) return [];
  try {
    final list = jsonDecode(raw);
    if (list is! List) return [];
    return list.map(ClaudeAppSession.fromJson).whereType<ClaudeAppSession>().toList();
  } catch (_) {
    return [];
  }
}

Future<void> _save(String host, List<ClaudeAppSession> sessions) async {
  final prefs = await SharedPreferences.getInstance();
  if (sessions.isEmpty) {
    await prefs.remove(_storeKey(host));
  } else {
    await prefs.setString(
      _storeKey(host),
      jsonEncode([for (final s in sessions) s.toJson()]),
    );
  }
}

class ClaudeAppSessions extends Notifier<ClaudeAppSessionsState> {
  int _generation = 0;

  @override
  ClaudeAppSessionsState build() {
    final client = ref.watch(activeClientProvider);
    ++_generation;
    if (client != null) Future.microtask(refresh);
    return ClaudeAppSessionsState(host: client == null ? null : _hostKey(client));
  }

  RpcClient? get _client => ref.read(activeClientProvider);

  /// Reconciles this phone's records with the host's live shells: a running
  /// shell reads Running, an exited one Ended, and a shell the host no longer
  /// knows (host restart, pruned) is forgotten.
  Future<void> refresh() async {
    final client = _client;
    if (client == null || client.status != RpcStatus.connected) return;
    final host = _hostKey(client);
    final generation = _generation;
    final records = await _load(host);
    final List<dynamic> rows;
    try {
      rows = await client.requestList('terminal.list');
    } catch (_) {
      return;
    }
    if (generation != _generation) return;
    final live = <String, String>{
      for (final row in rows.whereType<Map>())
        if (row['terminalId'] is String)
          row['terminalId'] as String: '${row['state']}',
    };
    final kept = <ClaudeAppSession>[];
    for (final record in records) {
      final hostState = live[record.terminalId];
      if (hostState == null) continue;
      kept.add(
        record.withState(
          hostState == 'running'
              ? ClaudeAppSessionState.running
              : ClaudeAppSessionState.ended,
        ),
      );
    }
    if (kept.length != records.length) await _save(host, kept);
    if (generation != _generation) return;
    kept.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    state = ClaudeAppSessionsState(host: host, sessions: kept, reconciled: true);
  }

  /// Creates a shell in [cwd] and types the Remote Control command into it.
  Future<ClaudeAppSession> start({
    required String cwd,
    required String name,
  }) async {
    final client = _client;
    if (client == null) throw RpcException('Not connected to your PC.');
    final clean = cleanSessionName(name);
    if (clean.isEmpty) throw RpcException('Give the session a name.');
    final host = _hostKey(client);
    final created = await client.requestMap('terminal.create', {
      'cols': 80,
      'rows': 24,
      'detached': true,
      'operationId': newTerminalOperationId(),
      'cwd': cwd,
    });
    final id = created['terminalId'];
    if (id is! String) throw RpcException('The PC did not open a shell.');
    final session = ClaudeAppSession(
      terminalId: id,
      name: clean,
      cwd: cwd,
      startedAt: DateTime.now().millisecondsSinceEpoch,
    );
    // Remember it before typing, so the shell is listed even if typing fails.
    final records = await _load(host);
    await _save(host, [session, ...records.where((r) => r.terminalId != id)]);
    client.notify('terminal.input', {
      'terminalId': id,
      'data': remoteControlCommand(clean),
    });
    if (state.host == host) {
      state = ClaudeAppSessionsState(
        host: host,
        sessions: [session, ...state.sessions.where((s) => s.terminalId != id)],
        reconciled: state.reconciled,
      );
    }
    unawaited(refresh());
    return session;
  }

  /// Ends the shell (and with it the session). A shell the host no longer
  /// knows counts as already stopped.
  Future<void> stop(String terminalId) async {
    final client = _client;
    if (client == null) throw RpcException('Not connected to your PC.');
    try {
      await client.request('terminal.kill', {'terminalId': terminalId});
    } on RpcException catch (e) {
      if (e.code != 'NOT_FOUND' && e.code != 'SESSION_EXITED') rethrow;
    }
    _mark(terminalId, ClaudeAppSessionState.ended);
    unawaited(refresh());
  }

  /// Forgets an ended session on this phone.
  Future<void> dismiss(String terminalId) async {
    final client = _client;
    if (client == null) return;
    final host = _hostKey(client);
    final records = await _load(host);
    await _save(host, records.where((r) => r.terminalId != terminalId).toList());
    if (state.host == host) {
      state = ClaudeAppSessionsState(
        host: host,
        sessions: state.sessions.where((s) => s.terminalId != terminalId).toList(),
        reconciled: state.reconciled,
      );
    }
  }

  /// The shell reported its exit (terminal-exit) while it was on screen.
  void markEnded(String terminalId) =>
      _mark(terminalId, ClaudeAppSessionState.ended);

  void _mark(String terminalId, ClaudeAppSessionState next) {
    state = ClaudeAppSessionsState(
      host: state.host,
      sessions: [
        for (final s in state.sessions)
          s.terminalId == terminalId ? s.withState(next) : s,
      ],
      reconciled: state.reconciled,
    );
  }
}

final claudeAppSessionsProvider =
    NotifierProvider<ClaudeAppSessions, ClaudeAppSessionsState>(
      ClaudeAppSessions.new,
    );

/// Opens the Claude app; false when it is not installed. Overridden in tests.
final claudeAppLauncherProvider = Provider<Future<bool> Function()>(
  (ref) => () async {
    try {
      return await PlatformBridge.call('app.launch', {
            'package': claudeAppPackage,
          }) ==
          true;
    } on MissingPluginException {
      return false;
    } on UnsupportedError {
      return false;
    }
  },
);
