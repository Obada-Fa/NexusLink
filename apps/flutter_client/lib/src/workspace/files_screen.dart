import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../state/connection.dart';
import '../screens/terminal_screen.dart';
import 'editor_screen.dart';
import 'platform_bridge.dart';
import 'project.dart';

class WorkspaceFilesScreen extends ConsumerStatefulWidget {
  final String? initialPath;
  const WorkspaceFilesScreen({super.key, this.initialPath});
  @override
  ConsumerState<WorkspaceFilesScreen> createState() =>
      _WorkspaceFilesScreenState();
}

class _WorkspaceFilesScreenState extends ConsumerState<WorkspaceFilesScreen> {
  String? _path, _next, _error;
  final List<Map<String, dynamic>> _entries = [];
  bool _loading = false, _hidden = false;
  String _query = '', _sort = 'name';
  int _generation = 0;
  Timer? _search;
  @override
  void initState() {
    super.initState();
    Future.microtask(_init);
  }

  @override
  void dispose() {
    _search?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final client = ref.read(activeClientProvider);
      if (client == null) return;
      final info = await client.requestMap('system.getInfo');
      await _load(
        widget.initialPath ??
            ref.read(projectProvider)?.path ??
            info['homeDir'] as String,
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _load(String path, {bool more = false}) async {
    final client = ref.read(activeClientProvider);
    if (client == null) return;
    final gen = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await client.requestMap('fs.listPage', {
        'path': path,
        'showHidden': _hidden,
        'query': _query,
        'sort': _sort,
        if (more && _next != null) 'cursor': _next,
      });
      if (!mounted || gen != _generation) return;
      setState(() {
        _path = result['path'] as String;
        _next = result['nextCursor'] as String?;
        if (!more) _entries.clear();
        _entries.addAll(
          (result['entries'] as List).map((e) => Map<String, dynamic>.from(e)),
        );
      });
      final prefs = await SharedPreferences.getInstance();
      final key = 'folders:${client.hostId}';
      final recent = prefs.getStringList(key) ?? [];
      await prefs.setStringList(
        key,
        [path, ...recent.where((p) => p != path)].take(12).toList(),
      );
    } catch (e) {
      if (mounted && gen == _generation) setState(() => _error = '$e');
    } finally {
      if (mounted && gen == _generation) setState(() => _loading = false);
    }
  }

  Future<String?> _input(String title, {String initial = ''}) async {
    var value = initial;
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          initialValue: initial,
          autofocus: true,
          onChanged: (text) => value = text,
          onFieldSubmitted: (_) => Navigator.pop(ctx, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, value),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  void _toast(Object value) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$value')));
    }
  }

  Future<void> _download(Map<String, dynamic> file) async {
    try {
      await enqueueDownload(
        ref,
        file['path'] as String,
        file['name'] as String,
      );
      _toast('Downloading to Downloads/NexusLink');
    } catch (e) {
      _toast(e);
    }
  }

  Future<void> _action(String action, Map<String, dynamic> file) async {
    final path = file['path'] as String;
    final directory = file['isDirectory'] == true
        ? path
        : path.substring(0, path.lastIndexOf('/'));
    try {
      switch (action) {
        case 'download':
          await _download(file);
          break;
        case 'saveAs':
          final saved = await saveDownloadAs(ref, path, file['name'] as String);
          if (saved != null) _toast('Saved to the selected document location');
          break;
        case 'copy':
          await Clipboard.setData(ClipboardData(text: path));
          _toast('PC path copied');
          break;
        case 'terminal':
          if (mounted) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => TerminalScreen(initialCwd: directory),
              ),
            );
          }
          break;
        case 'agent':
          ref.read(projectProvider.notifier).select(directory);
          ref.read(workspaceTabProvider.notifier).select(0);
          break;
        case 'rename':
          final name = await _input(
            'Rename file',
            initial: file['name'] as String,
          );
          if (name == null || name.isEmpty) return;
          if (name.contains('/')) {
            throw Exception('Enter a filename, without a directory.');
          }
          await ref.read(activeClientProvider)!.request('fs.rename', {
            'from': path,
            'to': '$directory/$name',
            'operationId': 'rename-${DateTime.now().microsecondsSinceEpoch}',
          });
          await _load(_path!);
          break;
      }
    } catch (e) {
      _toast(e);
    }
  }

  Future<void> _create(bool directory) async {
    final name = await _input(directory ? 'New folder' : 'New text file');
    if (name == null || name.trim().isEmpty || _path == null) return;
    try {
      if (name.contains('/')) {
        throw Exception('Enter a name without a directory.');
      }
      final path = '${_path == '/' ? '' : _path}/$name';
      final client = ref.read(activeClientProvider)!;
      if (directory) {
        await client.request('fs.mkdir', {'path': path});
      } else {
        await client.request('fs.writeText', {
          'path': path,
          'content': '',
          'expectedRevision': null,
          'operationId': 'new-${DateTime.now().microsecondsSinceEpoch}',
        });
      }
      await _load(_path!);
      if (!directory && mounted) await openEditor(context, path);
    } catch (e) {
      _toast(e);
    }
  }

  Future<void> _upload() async {
    try {
      final client = ref.read(activeClientProvider)!;
      dynamic result = await PlatformBridge.call('upload.pick', {
        'base': ref.read(connectionProvider).httpBase,
        'directory': _path,
        'token': client.token,
      });
      if (result is Map && result['conflict'] == true) {
        if (!mounted) return;
        final overwrite = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('${result['name']} already exists'),
            content: const Text(
              'Replace the PC file with the selected phone file?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep PC file'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Replace'),
              ),
            ],
          ),
        );
        if (overwrite != true) return;
        result = await PlatformBridge.call('upload.retry');
      }
      if (result is String) {
        _toast('Uploaded $result');
        if (_path != null) await _load(_path!);
      }
    } catch (e) {
      _toast(e);
    }
  }

  Future<void> _locations() async {
    final client = ref.read(activeClientProvider);
    final prefs = await SharedPreferences.getInstance();
    final recent = prefs.getStringList('folders:${client?.hostId}') ?? [];
    final pins = prefs.getStringList('pins:${client?.hostId}') ?? [];
    if (!mounted) return;
    final path = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('Pinned and recent folders')),
          if (_path != null)
            ListTile(
              leading: const Icon(Icons.push_pin_outlined),
              title: const Text('Pin current folder'),
              onTap: () {
                prefs.setStringList(
                  'pins:${client?.hostId}',
                  {_path!, ...pins}.toList(),
                );
                Navigator.pop(ctx);
              },
            ),
          for (final p in {...pins, ...recent})
            ListTile(
              leading: Icon(pins.contains(p) ? Icons.push_pin : Icons.history),
              title: Text(p),
              onTap: () => Navigator.pop(ctx, p),
            ),
        ],
      ),
    );
    if (path != null) await _load(path);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(connectionStatusProvider, (_, next) {
      if (next.name == 'connected') {
        if (_path == null) {
          _init();
        } else {
          _load(_path!);
        }
      }
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('Files'),
        actions: [
          IconButton(
            tooltip: 'Transfers',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TransfersScreen()),
            ),
            icon: const Icon(Icons.download),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'folder':
                  _create(true);
                  break;
                case 'file':
                  _create(false);
                  break;
                case 'upload':
                  _upload();
                  break;
                case 'hidden':
                  setState(() => _hidden = !_hidden);
                  if (_path != null) _load(_path!);
                  break;
                default:
                  setState(() => _sort = value);
                  if (_path != null) _load(_path!);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'file', child: Text('New text file')),
              const PopupMenuItem(value: 'folder', child: Text('New folder')),
              const PopupMenuItem(
                value: 'upload',
                child: Text('Upload from phone'),
              ),
              PopupMenuItem(
                value: 'hidden',
                child: Text(
                  _hidden ? 'Hide hidden files' : 'Show hidden files',
                ),
              ),
              const PopupMenuItem(value: 'name', child: Text('Sort by name')),
              const PopupMenuItem(
                value: 'date',
                child: Text('Sort by modified date'),
              ),
              const PopupMenuItem(value: 'size', child: Text('Sort by size')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Parent folder',
                onPressed: _path == null || _path == '/'
                    ? null
                    : () => _load(
                        _path!.substring(0, _path!.lastIndexOf('/')).isEmpty
                            ? '/'
                            : _path!.substring(0, _path!.lastIndexOf('/')),
                      ),
                icon: const Icon(Icons.arrow_upward),
              ),
              Expanded(
                child: TextButton(
                  onPressed: () async {
                    final path = await _input('PC path', initial: _path ?? '/');
                    if (path != null) await _load(path);
                  },
                  child: Text(_path ?? 'Loading…', maxLines: 2),
                ),
              ),
              IconButton(
                tooltip: 'Locations',
                onPressed: _locations,
                icon: const Icon(Icons.bookmarks_outlined),
              ),
              IconButton(
                tooltip: 'Refresh',
                onPressed: _path == null ? null : () => _load(_path!),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Filter this folder',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (text) {
                _query = text;
                _search?.cancel();
                _search = Timer(const Duration(milliseconds: 250), () {
                  if (_path != null) _load(_path!);
                });
              },
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!, style: const TextStyle(color: Colors.amber)),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: _entries.length + (_next != null ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == _entries.length) {
                  return TextButton(
                    onPressed: _loading
                        ? null
                        : () => _load(_path!, more: true),
                    child: const Text('Load more'),
                  );
                }
                final f = _entries[index];
                final dir = f['isDirectory'] == true;
                return ListTile(
                  leading: Icon(
                    dir ? Icons.folder_outlined : Icons.description_outlined,
                  ),
                  title: Text(f['name'] as String),
                  subtitle: Text(
                    f['error'] != null
                        ? 'Unavailable: ${f['error']}'
                        : dir
                        ? 'Folder'
                        : '${f['size']} bytes · ${f['modifiedAt']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: f['error'] != null
                      ? null
                      : () => dir
                            ? _load(f['path'] as String)
                            : openEditor(context, f['path'] as String),
                  trailing: PopupMenuButton<String>(
                    onSelected: (a) => _action(a, f),
                    itemBuilder: (_) => [
                      if (!dir)
                        const PopupMenuItem(
                          value: 'download',
                          child: Text('Download'),
                        ),
                      if (!dir)
                        const PopupMenuItem(
                          value: 'saveAs',
                          child: Text('Save as…'),
                        ),
                      const PopupMenuItem(
                        value: 'copy',
                        child: Text('Copy PC path'),
                      ),
                      const PopupMenuItem(
                        value: 'terminal',
                        child: Text('Open terminal here'),
                      ),
                      const PopupMenuItem(
                        value: 'agent',
                        child: Text('Use folder for agent'),
                      ),
                      if (!dir)
                        const PopupMenuItem(
                          value: 'rename',
                          child: Text('Rename'),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> enqueueDownload(WidgetRef ref, String path, String name) async {
  await PlatformBridge.call(
    'download.start',
    await _downloadArguments(ref, path, name),
  );
}

Future<String?> saveDownloadAs(WidgetRef ref, String path, String name) async {
  return await PlatformBridge.call(
        'download.saveAs',
        await _downloadArguments(ref, path, name),
      )
      as String?;
}

Future<Map<String, dynamic>> _downloadArguments(
  WidgetRef ref,
  String path,
  String name,
) async {
  final client = ref.read(activeClientProvider);
  if (client == null) throw Exception('Connect to your PC first.');
  final auth = await client.requestMap('transfer.authorize', {'path': path});
  final base = Uri.parse(ref.read(connectionProvider).httpBase!);
  return {
    'host': client.hostId ?? client.wsUrl,
    'path': path,
    'name': name,
    'url': base
        .replace(
          path: '/files',
          queryParameters: {'path': auth['path'] as String},
        )
        .toString(),
    'token': auth['token'],
  };
}

class TransfersScreen extends ConsumerStatefulWidget {
  const TransfersScreen({super.key});
  @override
  ConsumerState<TransfersScreen> createState() => _TransfersScreenState();
}

class _TransfersScreenState extends ConsumerState<TransfersScreen>
    with WidgetsBindingObserver {
  List<Map<String, dynamic>> _rows = [];
  String? _error;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  void _start() {
    _refresh();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _start();
    } else {
      _timer?.cancel();
    }
  }

  Future<void> _refresh() async {
    try {
      final rows = await PlatformBridge.call('download.list') as List;
      if (mounted) {
        setState(
          () => _rows = rows.map((r) => Map<String, dynamic>.from(r)).toList(),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Downloads'),
      actions: [
        IconButton(
          tooltip: 'Android downloads',
          onPressed: () => PlatformBridge.call('download.show'),
          icon: const Icon(Icons.folder_open),
        ),
      ],
    ),
    body: _error != null
        ? Center(child: Text(_error!))
        : ListView(
            children: [
              for (final row in _rows)
                ListTile(
                  title: Text(row['name'] as String),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${row['status']}${row['status'] == 'failed' ? ' · Error ${row['reason']}' : ''}',
                      ),
                      if (row['status'] == 'running')
                        LinearProgressIndicator(
                          value: (row['total'] as num? ?? 0) > 0
                              ? (row['bytes'] as num) / (row['total'] as num)
                              : null,
                        ),
                    ],
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) async {
                      try {
                        if (action == 'retry') {
                          final client = ref.read(activeClientProvider);
                          if ((client?.hostId ?? client?.wsUrl) !=
                              row['host']) {
                            throw Exception(
                              'Connect to the original PC to retry.',
                            );
                          }
                          await enqueueDownload(
                            ref,
                            row['path'] as String,
                            row['name'] as String,
                          );
                        } else {
                          await PlatformBridge.call('download.$action', {
                            'id': row['id'],
                          });
                        }
                        await _refresh();
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(SnackBar(content: Text('$e')));
                        }
                      }
                    },
                    itemBuilder: (_) => row['status'] == 'completed'
                        ? [
                            const PopupMenuItem(
                              value: 'open',
                              child: Text('Open'),
                            ),
                            const PopupMenuItem(
                              value: 'share',
                              child: Text('Share'),
                            ),
                          ]
                        : [
                            const PopupMenuItem(
                              value: 'cancel',
                              child: Text('Cancel'),
                            ),
                            const PopupMenuItem(
                              value: 'retry',
                              child: Text('Retry'),
                            ),
                          ],
                  ),
                ),
            ],
          ),
  );
}
