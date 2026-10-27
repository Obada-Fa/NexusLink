import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../rpc/rpc_client.dart';
import '../state/connection.dart';
import '../screens/terminal_screen.dart';
import '../theme/nexus_theme.dart';
import 'editor_screen.dart';
import 'platform_bridge.dart';
import 'project.dart';

const _imageExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};
const _binaryExtensions = {
  'pdf',
  'zip',
  'gz',
  'tgz',
  'bz2',
  'xz',
  '7z',
  'rar',
  'tar',
  'jar',
  'apk',
  'aab',
  'exe',
  'dll',
  'so',
  'dylib',
  'bin',
  'o',
  'a',
  'class',
  'pyc',
  'wasm',
  'mp3',
  'wav',
  'flac',
  'ogg',
  'm4a',
  'aac',
  'mp4',
  'mkv',
  'mov',
  'avi',
  'webm',
  'ico',
  'tif',
  'tiff',
  'psd',
  'heic',
  'ttf',
  'otf',
  'woff',
  'woff2',
  'doc',
  'docx',
  'xls',
  'xlsx',
  'ppt',
  'pptx',
  'odt',
  'ods',
  'sqlite',
  'db',
  'iso',
  'img',
  'dmg',
  'deb',
  'rpm',
  'msi',
  'blend',
  'pdb',
};

/// Files above this size are offered as downloads rather than opened as text.
const _maxEditorBytes = 4 * 1024 * 1024;
const _maxPreviewBytes = 25 * 1024 * 1024;

String _extension(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot + 1).toLowerCase();
}

enum FileOpenKind { text, image, binary }

/// How a tap on a PC file should open it on the phone.
FileOpenKind fileOpenKind(String name, num? size) {
  final ext = _extension(name);
  if (_imageExtensions.contains(ext)) {
    return (size ?? 0) > _maxPreviewBytes
        ? FileOpenKind.binary
        : FileOpenKind.image;
  }
  if (_binaryExtensions.contains(ext)) return FileOpenKind.binary;
  if ((size ?? 0) > _maxEditorBytes) return FileOpenKind.binary;
  return FileOpenKind.text;
}

/// "532 B", "12.4 KB", "3.1 MB", "2.0 GB".
String formatFileSize(num? bytes) {
  if (bytes == null || bytes < 0) return '';
  if (bytes < 1024) return '${bytes.toInt()} B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value < 10 ? value.toStringAsFixed(1) : value.round()} ${units[unit]}';
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "Today 14:05", "Yesterday 09:12", "Oct 3", "Oct 3, 2024".
String formatFileDate(Object? value, {DateTime? now}) {
  final parsed = value is num
      ? DateTime.fromMillisecondsSinceEpoch(value.toInt())
      : value is String
      ? DateTime.tryParse(value)
      : null;
  if (parsed == null) return '';
  final local = parsed.toLocal();
  final current = now ?? DateTime.now();
  final today = DateTime(current.year, current.month, current.day);
  final day = DateTime(local.year, local.month, local.day);
  final time =
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  if (day == today) return 'Today $time';
  if (day == today.subtract(const Duration(days: 1))) return 'Yesterday $time';
  final date = '${_months[local.month - 1]} ${local.day}';
  return local.year == current.year ? date : '$date, ${local.year}';
}

String _parentOf(String path) {
  final index = path.lastIndexOf('/');
  if (index <= 0) return '/';
  return path.substring(0, index);
}

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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            value is String
                ? value
                : friendlyLaunchError(value).replaceFirst('Exception: ', ''),
          ),
        ),
      );
    }
  }

  /// The PC lists the methods it implements; actions it lacks stay hidden.
  bool _hostHas(String method) =>
      (ref.read(activeClientProvider)?.capabilities['methods'] as List?)
          ?.contains(method) ==
      true;

  Future<void> _open(Map<String, dynamic> file) async {
    final path = file['path'] as String;
    final name = file['name'] as String;
    switch (fileOpenKind(name, file['size'] as num?)) {
      case FileOpenKind.text:
        await openEditor(context, path);
      case FileOpenKind.image:
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => FileImagePreview(path: path, name: name),
          ),
        );
      case FileOpenKind.binary:
        await _openChoice(file);
    }
  }

  /// Files that are not text: download instead of dumping bytes in the editor.
  Future<void> _openChoice(Map<String, dynamic> file) async {
    final name = file['name'] as String;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                [
                  formatFileSize(file['size'] as num?),
                  formatFileDate(file['modifiedAt']),
                ].where((part) => part.isNotEmpty).join(' · '),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('Download to phone'),
              subtitle: const Text('Saved in Downloads/NexusLink'),
              onTap: () => Navigator.pop(ctx, 'download'),
            ),
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: const Text('Save as…'),
              onTap: () => Navigator.pop(ctx, 'saveAs'),
            ),
            if (((file['size'] as num?) ?? 0) <= _maxEditorBytes)
              ListTile(
                leading: const Icon(Icons.notes),
                title: const Text('Open as text anyway'),
                onTap: () => Navigator.pop(ctx, 'text'),
              ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'text') {
      await openEditor(context, file['path'] as String);
    } else {
      await _action(action, file);
    }
  }

  Future<void> _delete(Map<String, dynamic> file) async {
    final dir = file['isDirectory'] == true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${file['name']}?'),
        content: Text(
          dir
              ? 'This folder and everything in it is deleted from the PC.'
              : 'This file is deleted from the PC.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: NX.failed),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(activeClientProvider)!.request('fs.delete', {
      'path': file['path'],
    });
    _toast('Deleted ${file['name']}');
    if (_path != null) await _load(_path!);
  }

  Future<void> _move(Map<String, dynamic> file) async {
    final path = file['path'] as String;
    final name = file['name'] as String;
    final target = await _input('Move or rename', initial: path);
    if (target == null) return;
    var to = target.trim();
    if (to.isEmpty || to == path) return;
    // A trailing slash means "into this folder, keep the name".
    if (to.endsWith('/')) to = '$to$name';
    if (!to.startsWith('/')) to = '${_parentOf(path)}/$to';
    await ref.read(activeClientProvider)!.request('fs.move', {
      'from': path,
      'to': to,
    });
    _toast('Moved to $to');
    if (_path != null) await _load(_path!);
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
        case 'delete':
          await _delete(file);
          break;
        case 'move':
          await _move(file);
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
                final kind = dir
                    ? null
                    : fileOpenKind(f['name'] as String, f['size'] as num?);
                final modified = formatFileDate(f['modifiedAt']);
                return ListTile(
                  leading: Icon(
                    dir
                        ? Icons.folder_outlined
                        : kind == FileOpenKind.image
                        ? Icons.image_outlined
                        : kind == FileOpenKind.binary
                        ? Icons.insert_drive_file_outlined
                        : Icons.description_outlined,
                  ),
                  title: Text(f['name'] as String),
                  subtitle: Text(
                    f['error'] != null
                        ? 'Unavailable: ${f['error']}'
                        : dir
                        ? (modified.isEmpty ? 'Folder' : 'Folder · $modified')
                        : [
                            formatFileSize(f['size'] as num?),
                            modified,
                          ].where((part) => part.isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: f['error'] != null
                      ? null
                      : () => dir ? _load(f['path'] as String) : _open(f),
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
                      if (_hostHas('fs.move'))
                        const PopupMenuItem(
                          value: 'move',
                          child: Text('Move or rename…'),
                        ),
                      if (_hostHas('fs.delete'))
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text(
                            'Delete',
                            style: TextStyle(color: NX.failed),
                          ),
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

/// A short-lived, authorized HTTP URL for one PC file (the same path the
/// Android downloader uses). Send the token as `Authorization: Bearer`.
Future<({String url, String token})> authorizedFileUrl(
  WidgetRef ref,
  String path,
) async {
  final client = ref.read(activeClientProvider);
  final httpBase = ref.read(connectionProvider).httpBase;
  if (client == null || httpBase == null) {
    throw Exception('Connect to your PC first.');
  }
  final auth = await client.requestMap('transfer.authorize', {'path': path});
  final url = Uri.parse(httpBase)
      .replace(
        path: '/files',
        queryParameters: {'path': auth['path'] as String},
      )
      .toString();
  return (url: url, token: auth['token'] as String);
}

Future<Map<String, dynamic>> _downloadArguments(
  WidgetRef ref,
  String path,
  String name,
) async {
  final client = ref.read(activeClientProvider);
  if (client == null) throw Exception('Connect to your PC first.');
  final file = await authorizedFileUrl(ref, path);
  return {
    'host': client.hostId ?? client.wsUrl,
    'path': path,
    'name': name,
    'url': file.url,
    'token': file.token,
  };
}

/// Full-screen, zoomable preview of an image on the PC.
class FileImagePreview extends ConsumerStatefulWidget {
  const FileImagePreview({super.key, required this.path, required this.name});
  final String path;
  final String name;
  @override
  ConsumerState<FileImagePreview> createState() => _FileImagePreviewState();
}

class _FileImagePreviewState extends ConsumerState<FileImagePreview> {
  late Future<({String url, String token})> _file = authorizedFileUrl(
    ref,
    widget.path,
  );

  Future<void> _save(bool saveAs) async {
    try {
      if (saveAs) {
        final saved = await saveDownloadAs(ref, widget.path, widget.name);
        if (saved == null) return;
      } else {
        await enqueueDownload(ref, widget.path, widget.name);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              saveAs
                  ? 'Saved to the selected location'
                  : 'Downloading to Downloads/NexusLink',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(friendlyLaunchError(e))));
      }
    }
  }

  Widget _failed(Object error) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.broken_image_outlined, size: 40, color: NX.textDim),
          const SizedBox(height: 12),
          const Text(
            'Couldn’t load this image from the PC.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () =>
                setState(() => _file = authorizedFileUrl(ref, widget.path)),
            child: const Text('Try again'),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Download to phone',
            onPressed: () => _save(false),
            icon: const Icon(Icons.download),
          ),
          IconButton(
            tooltip: 'Save as…',
            onPressed: () => _save(true),
            icon: const Icon(Icons.save_alt),
          ),
        ],
      ),
      body: FutureBuilder<({String url, String token})>(
        future: _file,
        builder: (context, snapshot) {
          if (snapshot.hasError) return _failed(snapshot.error!);
          final file = snapshot.data;
          if (file == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return InteractiveViewer(
            maxScale: 8,
            child: Center(
              child: Image.network(
                file.url,
                headers: {'Authorization': 'Bearer ${file.token}'},
                fit: BoxFit.contain,
                loadingBuilder: (context, child, progress) => progress == null
                    ? child
                    : const Center(child: CircularProgressIndicator()),
                errorBuilder: (context, error, _) => _failed(error),
              ),
            ),
          );
        },
      ),
    );
  }
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
  bool _foreground = true;
  bool _refreshing = false;
  bool _wasVisible = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncPolling();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncPolling();
    });
  }

  bool get _visible =>
      _foreground &&
      ref.read(workspaceTabProvider) == 1 &&
      (ModalRoute.of(context)?.isCurrent ?? false);

  void _syncPolling() {
    final visible = _visible;
    if (visible && !_wasVisible) _refresh();
    _wasVisible = visible;
    _timer?.cancel();
    if (visible &&
        _rows.any(
          (r) => r['status'] == 'running' || r['status'] == 'pending',
        )) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncPolling();
  }

  Future<void> _refresh() async {
    if (_refreshing || !_visible) return;
    _refreshing = true;
    try {
      final rows = await PlatformBridge.call('download.list') as List;
      if (mounted) {
        setState(
          () => _rows = rows.map((r) => Map<String, dynamic>.from(r)).toList(),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _refreshing = false;
      if (mounted) _syncPolling();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  String _transferLabel(Map<String, dynamic> row) {
    final total = row['total'] as num?;
    final bytes = row['bytes'] as num?;
    return switch (row['status']) {
      'completed' => 'Downloaded · ${formatFileSize(total ?? bytes)}',
      'running' =>
        total != null && total > 0
            ? 'Downloading · ${formatFileSize(bytes)} of ${formatFileSize(total)}'
            : 'Downloading…',
      'pending' => 'Waiting to start…',
      'paused' => 'Paused · waiting for the network',
      'failed' => 'Failed (error ${row['reason']}) · tap ⋮ to retry',
      'canceled' => 'Canceled',
      _ => 'No longer available',
    };
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(workspaceTabProvider, (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncPolling();
      });
    });
    return Scaffold(
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
          : _rows.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.download_outlined,
                      size: 44,
                      color: NX.textFaint,
                    ),
                    SizedBox(height: 12),
                    Text(
                      'No downloads yet',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'Files you download from your PC appear here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: NX.textDim),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              children: [
                for (final row in _rows)
                  ListTile(
                    title: Text(row['name'] as String),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_transferLabel(row)),
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
}
