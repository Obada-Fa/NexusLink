import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import '../rpc/rpc_client.dart';
import '../state/connection.dart';

final terminalRepositoryProvider = Provider((ref) {
  final repository = TerminalRepository();
  ref.listen(
    activeClientProvider,
    (_, client) => repository.bind(client),
    fireImmediately: true,
  );
  ref.onDispose(repository.dispose);
  return repository;
});

class TerminalRepository {
  RpcClient? _client;
  StreamSubscription<RpcStatus>? _status;
  final Map<String, RemoteTerminal> _sessions = {};
  void bind(RpcClient? client) {
    if (identical(client, _client)) return;
    _status?.cancel();
    _client = client;
    _status = client?.statusStream.listen((status) {
      if (status == RpcStatus.connected) {
        _restore();
      } else
        for (final t in _sessions.values) {
          t.disconnected();
        }
    });
    _restore();
  }

  void _restore() {
    final client = _client;
    if (client == null || client.status != RpcStatus.connected) return;
    for (final t in _sessions.values) {
      if (t.visible && t.host == (client.hostId ?? client.wsUrl)) {
        t.bind(client);
      }
    }
  }

  RemoteTerminal get(String key, {String? cwd, String? terminalId}) {
    final client = _client;
    if (client == null) throw RpcException('Not connected');
    final host = client.hostId ?? client.wsUrl;
    if (terminalId != null) {
      for (final existing in _sessions.values) {
        if (existing.host == host && existing.id == terminalId) return existing;
      }
    }
    final t = _sessions.putIfAbsent(
      '$host:$key',
      () => RemoteTerminal(host, key, cwd: cwd, id: terminalId),
    );

    return t;
  }

  void dispose() {
    _status?.cancel();
    for (final t in _sessions.values) {
      t.dispose();
    }
  }
}

class RemoteTerminal extends ChangeNotifier {
  RemoteTerminal(this.host, this.key, {this.cwd, this.id}) {
    terminal = Terminal(
      maxLines: 4000,
      onOutput: input,
      onResize: (w, h, _, _) => resize(w, h),
    );
  }
  final String host, key;
  final String? cwd;
  late final Terminal terminal;
  RpcClient? client;
  String? id, error;
  bool ready = false, ended = false, visible = true;
  bool _disposed = false;
  int seq = 0, _generation = 0;
  final List<void Function()> _unsubs = [];
  Timer? _resize;
  Future<void>? _attaching;
  String? _operation;
  void show(bool value, RpcClient connection) {
    visible = value;
    if (!value) {
      ++_generation;
      ready = false;
      _resize?.cancel();
      if (id != null) client?.notify('terminal.detach', {'terminalId': id});
      return;
    }
    if (!ready || !identical(client, connection)) unawaited(bind(connection));
  }

  Future<void> bind(RpcClient connection) async {
    client = connection;
    final pending = _attaching;
    if (pending != null) {
      await pending;
      if (_disposed || !visible || !identical(client, connection)) return;
      if (ready) return;
    }
    if (_disposed || !visible || connection.status != RpcStatus.connected) {
      return;
    }
    final run = _attach(connection);
    _attaching = run;
    try {
      await run;
    } finally {
      if (identical(_attaching, run)) _attaching = null;
    }
  }

  Future<void> _attach(RpcClient connection) async {
    final generation = ++_generation;
    for (final u in _unsubs) {
      u();
    }
    _unsubs.clear();
    client = connection;
    ready = false;
    error = null;
    notifyListeners();
    if (!connection.supports('terminal.attach')) {
      error = 'Update the PC host for persistent terminals.';
      notifyListeners();
      return;
    }
    _unsubs.add(
      connection.subscribe('terminal-output', (msg) {
        if (msg['terminalId'] != id) return;
        final next = (msg['seq'] as num?)?.toInt() ?? 0;
        if (next <= seq) return;
        seq = next;
        terminal.write(msg['data'] as String? ?? '');
      }),
    );
    _unsubs.add(
      connection.subscribe('terminal-gap', (msg) {
        if (msg['terminalId'] != id) return;
        terminal.write(
          '\x1bc\r\n[Earlier terminal output is unavailable; redraw your program if needed.]\r\n',
        );
        seq = 0;
      }),
    );
    _unsubs.add(
      connection.subscribe('terminal-exit', (msg) {
        if (msg['terminalId'] != id) return;
        ready = false;
        ended = true;
        error = 'Shell exited (${msg['exitCode']}). ${msg['error'] ?? ''}';
        notifyListeners();
      }),
    );
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed || generation != _generation) return;
      id ??= prefs.getString('terminal:$host:$key');
      if (id == null) {
        _operation ??= '$host:$key:${DateTime.now().microsecondsSinceEpoch}';
        final response = await connection.requestMap('terminal.create', {
          'cols': terminal.viewWidth > 0 ? terminal.viewWidth : 80,
          'rows': terminal.viewHeight > 0 ? terminal.viewHeight : 24,
          'detached': true,
          'operationId': _operation,
          'taskId': key,
          if (cwd != null) 'cwd': cwd,
        });
        id = response['terminalId'] as String;
        await prefs.setString('terminal:$host:$key', id!);
      }
      if (_disposed || generation != _generation) return;
      final result = await connection.requestMap('terminal.attach', {
        'terminalId': id,
        'afterSeq': seq,
      });
      if (generation != _generation) return;
      ended = result['state'] == 'exited';
      ready = !ended;
      if (ended) {
        error =
            'Shell exited (${result['exitCode']}). ${result['error'] ?? ''}';
      }
      if (ready) resize(terminal.viewWidth, terminal.viewHeight);
    } catch (e) {
      if (generation == _generation) {
        error = e.toString();
        ready = false;
        if (e is RpcException && e.code == 'NOT_FOUND') ended = true;
      }
    }
    if (generation == _generation) notifyListeners();
  }

  void input(String text) {
    if (!ready || id == null) return;
    var start = 0;
    while (start < text.length) {
      var end = (start + 4096).clamp(0, text.length);
      if (end < text.length &&
          text.codeUnitAt(end - 1) >= 0xD800 &&
          text.codeUnitAt(end - 1) <= 0xDBFF) {
        end--;
      }
      client?.notify('terminal.input', {
        'terminalId': id,
        'data': text.substring(start, end),
      });
      start = end;
    }
  }

  void resize(int cols, int rows) {
    if (cols < 1 || rows < 1) return;
    _resize?.cancel();
    _resize = Timer(const Duration(milliseconds: 100), () {
      if (ready) {
        client?.notify('terminal.resize', {
          'terminalId': id,
          'cols': cols,
          'rows': rows,
        });
      }
    });
  }

  void disconnected() {
    ++_generation;
    ready = false;
    if (!_disposed) notifyListeners();
  }

  Future<void> terminate() async {
    if (id != null) await client?.request('terminal.kill', {'terminalId': id});
  }

  Future<void> newShell() async {
    if (ready) return;
    id = null;
    seq = 0;
    ended = false;
    _operation = null;
    terminal.write('\x1bc');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('terminal:$host:$key');
    if (client != null) await bind(client!);
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _resize?.cancel();
    for (final u in _unsubs) {
      u();
    }
    if (id != null) client?.notify('terminal.detach', {'terminalId': id});
    super.dispose();
  }
}
