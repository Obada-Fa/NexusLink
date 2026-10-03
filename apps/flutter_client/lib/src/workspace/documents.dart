import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:re_editor/re_editor.dart';
import '../rpc/rpc_client.dart';
import '../state/connection.dart';

final documentRepositoryProvider = Provider((ref) {
  final repository = DocumentRepository(() => ref.read(activeClientProvider));
  ref.onDispose(repository.dispose);
  return repository;
});

class DocumentRepository {
  DocumentRepository(this.client);
  final RpcClient? Function() client;
  final Map<String, RemoteDocument> documents = {};
  final Map<String, Future<RemoteDocument>> _opening = {};
  Future<RemoteDocument> open(String path) async {
    final rpc = client();
    if (rpc == null) throw RpcException('Not connected');
    if (!rpc.supports('fs.readText')) {
      throw RpcException('Update the PC host to use the native editor.');
    }
    final host = rpc.hostId ?? rpc.wsUrl;
    final key = '$host:$path';
    if (documents.containsKey(key)) return documents[key]!;
    if (_opening.containsKey(key)) return _opening[key]!;
    final run = _open(rpc, host, path);
    _opening[key] = run;
    try {
      return await run;
    } finally {
      _opening.remove(key);
    }
  }

  Future<RemoteDocument> _open(RpcClient rpc, String host, String path) async {
    final data = await rpc.requestMap('fs.readText', {'path': path});
    // A symlink is intentionally a separate read-only view until its target is opened explicitly.
    final key = '$host:${data['writable'] == true ? data['path'] : path}';
    if (documents.containsKey(key)) return documents[key]!;
    final directory = await getApplicationSupportDirectory();
    final file = File(
      '${directory.path}/drafts/${sha256.convert(utf8.encode(key))}.json',
    );
    final doc = RemoteDocument(host, data, file, client);
    await doc.restore();
    documents[key] = doc;
    return doc;
  }

  Future<void> flush() async {
    await Future.wait(documents.values.map((d) => d.persist()));
  }

  void dispose() {
    for (final d in documents.values) {
      d.dispose();
    }
  }
}

class RemoteDocument extends ChangeNotifier {
  RemoteDocument(this.host, this.data, this.draft, this.client) {
    saved = data['content'] as String? ?? '';
    controller = CodeLineEditingController.fromText(
      saved,
      CodeLineOptions(
        lineBreak: data['lineEnding'] == 'crlf'
            ? TextLineBreak.crlf
            : TextLineBreak.lf,
      ),
    );
    controller.addListener(_changed);
  }
  final String host;
  Map<String, dynamic> data;
  final File draft;
  final RpcClient? Function() client;
  late final CodeLineEditingController controller;
  late String saved;
  bool saving = false, restored = false;
  bool _disposed = false;
  String? error;
  Timer? _timer;
  Future<void> _writing = Future.value();
  String get path => data['path'] as String;
  bool get dirty => controller.text != saved;
  bool get writable => data['writable'] == true;
  void _changed() {
    _timer?.cancel();
    _timer = Timer(
      const Duration(milliseconds: 600),
      () => unawaited(persist()),
    );
    notifyListeners();
  }

  Future<void> restore() async {
    if (!await draft.exists()) return;
    try {
      final raw =
          jsonDecode(await draft.readAsString()) as Map<String, dynamic>;
      if (raw['host'] == host && raw['path'] == path) {
        saved = raw['saved'] as String;
        data['revision'] = raw['revision'];
        controller.text = raw['content'] as String;
        restored = true;
      }
    } catch (e) {
      error = 'Draft could not be restored: $e';
    }
  }

  Future<void> persist() {
    _timer?.cancel();
    final text = jsonEncode({
      'host': host,
      'path': path,
      'revision': data['revision'],
      'saved': saved,
      'content': controller.text,
    });
    final keep = dirty;
    _writing = _writing
        .catchError((_) {})
        .then((_) async {
          if (!keep) {
            if (await draft.exists()) await draft.delete();
            return;
          }
          await draft.parent.create(recursive: true);
          final tmp = File('${draft.path}.tmp');
          await tmp.writeAsString(text, flush: true);
          await tmp.rename(draft.path);
        })
        .catchError((e) {
          error = 'Could not save recovery draft: $e';
          if (!_disposed) notifyListeners();
        });
    return _writing;
  }

  RpcClient _rpc() {
    final rpc = client();
    if (rpc == null ||
        rpc.status != RpcStatus.connected ||
        (rpc.hostId ?? rpc.wsUrl) != host) {
      throw RpcException('Reconnect to the original PC before saving.');
    }
    return rpc;
  }

  Future<void> save({String? asPath, String? replacementRevision}) async {
    if (saving) return;
    saving = true;
    error = null;
    notifyListeners();
    final content = controller.text;
    try {
      final result = await _rpc().requestMap('fs.writeText', {
        'path': asPath ?? path,
        'content': content,
        'expectedRevision': asPath != null
            ? null
            : replacementRevision ?? data['revision'],
        'bom': data['bom'] == true,
        'operationId': 'save-${DateTime.now().microsecondsSinceEpoch}',
      });
      if (asPath == null) {
        data = result;
        saved = content;
        restored = false;
        await persist();
      }
    } catch (e) {
      error = e.toString();
      rethrow;
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> latest() =>
      _rpc().requestMap('fs.readText', {'path': path});
  Future<void> reload() async {
    data = await latest();
    saved = data['content'] as String;
    controller.text = saved;
    controller.clearHistory();
    restored = false;
    await persist();
    notifyListeners();
  }

  Future<void> discard() async {
    controller.text = saved;
    await persist();
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(persist());
    _disposed = true;
    controller.removeListener(_changed);
    controller.dispose();
    super.dispose();
  }
}
