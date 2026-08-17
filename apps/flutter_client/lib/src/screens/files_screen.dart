// File browser + transfer. Browsing uses the fs.list RPC; transfers use the
// host's HTTP endpoints (apps/desktop/src/server/handlers/files-http.ts) so
// large payloads stay off the RPC WebSocket. Download picks a save location
// via the platform SAF dialog; upload picks a file and POSTs it to the CWD.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../rpc/models.dart';
import '../state/connection.dart';
import '../widgets/not_connected_view.dart';

class FilesScreen extends ConsumerStatefulWidget {
  const FilesScreen({super.key});

  @override
  ConsumerState<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends ConsumerState<FilesScreen> {
  String? _cwd;
  List<FileEntry> _entries = [];
  bool _loading = true;
  String? _error;
  double? _transfer; // 0..1 while a transfer is in flight, null otherwise
  String _transferLabel = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final client = ref.read(activeClientProvider);
    if (client == null) {
      setState(() {
        _loading = false;
        _error = 'Not connected.';
      });
      return;
    }
    try {
      final info =
          await client.request('system.getInfo') as Map<String, dynamic>;
      await _navigate((info['homeDir'] as String?) ?? '/');
    } catch (e) {
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _navigate(String path) async {
    final client = ref.read(activeClientProvider);
    if (client == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await client.request('fs.list', {'path': path}) as List<dynamic>;
      if (!mounted) return;
      setState(() {
        _cwd = path;
        _entries =
            raw.map((e) => FileEntry.fromJson(e as Map<String, dynamic>)).toList();
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  void _up() {
    final cwd = _cwd;
    if (cwd == null || cwd == '/') return;
    final parent = cwd.substring(0, cwd.lastIndexOf('/'));
    _navigate(parent.isEmpty ? '/' : parent);
  }

  String get _httpBase => ref.read(connectionProvider).httpBase ?? '';

  Future<void> _download(FileEntry f) async {
    setState(() {
      _transfer = 0;
      _transferLabel = 'Downloading ${f.name}…';
    });
    try {
      // Stream to a temp file with progress (kept off the RPC socket), then
      // hand it to the OS share sheet so the user saves it wherever they want.
      final uri =
          Uri.parse('$_httpBase/files?path=${Uri.encodeQueryComponent(f.path)}');
      final resp = await http.Client().send(http.Request('GET', uri));
      final total = resp.contentLength ?? f.size;
      final dir = await getTemporaryDirectory();
      final out = File('${dir.path}/${f.name}');
      final sink = out.openWrite();
      var received = 0;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && mounted) {
          setState(() => _transfer = received / total);
        }
      }
      await sink.close();
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(files: [XFile(out.path)], text: f.name),
      );
    } catch (e) {
      _toast('Download failed: $e');
    } finally {
      if (mounted) setState(() => _transfer = null);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Files')),
      body: Column(
        children: [
          _pathBar(),
          if (_transfer != null) _transferBar(),
          Expanded(child: _list()),
        ],
      ),
    );
  }

  Widget _pathBar() {
    return Container(
      width: double.infinity,
      color: const Color(0xFF12121C),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_upward, size: 18),
            onPressed: _cwd == null || _cwd == '/' ? null : _up,
            visualDensity: VisualDensity.compact,
          ),
          Expanded(
            child: Text(_cwd ?? '',
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Widget _transferBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_transferLabel, style: const TextStyle(fontSize: 11)),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: _transfer == 0 ? null : _transfer),
        ],
      ),
    );
  }

  Widget _list() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      if (looksLikeConnectionError(_error)) {
        return NotConnectedView(
          message: _error!,
          onReconnected: () {
            setState(() {
              _loading = true;
              _error = null;
            });
            _init();
          },
        );
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent)),
        ),
      );
    }
    if (_entries.isEmpty) {
      return const Center(child: Text('Empty folder'));
    }
    return ListView.separated(
      itemCount: _entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final e = _entries[i];
        return ListTile(
          leading: Icon(e.isDirectory ? Icons.folder : Icons.insert_drive_file,
              color: e.isDirectory ? const Color(0xFF6B8CFF) : Colors.white54),
          title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: e.isDirectory ? null : Text(_humanSize(e.size)),
          trailing: e.isDirectory
              ? const Icon(Icons.chevron_right, size: 18)
              : IconButton(
                  icon: const Icon(Icons.download, size: 20),
                  onPressed: _transfer == null ? () => _download(e) : null,
                ),
          onTap: e.isDirectory ? () => _navigate(e.path) : null,
        );
      },
    );
  }

  static String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}
