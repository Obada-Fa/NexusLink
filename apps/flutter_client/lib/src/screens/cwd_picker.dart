// Working-directory picker for a new agent chat. Suggestions are git roots
// from fs.listProjects; Browse walks the PC via fs.list so any folder works.
// A later host-side allow-list can restrict this without changing the UI.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rpc/models.dart';
import '../rpc/rpc_client.dart';
import '../state/connection.dart';
import '../state/last_cwd.dart';
import '../util/host_path.dart';
import '../widgets/controller_owned_dialog.dart';

export '../util/host_path.dart' show parentHostPath, parentUnixPath;

Future<String?> pickWorkingDirectory({
  required BuildContext context,
  required RpcClient client,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF151522),
    builder: (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.78,
      child: _CwdPickerSheet(client: client),
    ),
  );
}

class _ProjectHint {
  final String name;
  final String path;
  const _ProjectHint(this.name, this.path);
}

class _CwdPickerSheet extends ConsumerStatefulWidget {
  final RpcClient client;
  const _CwdPickerSheet({required this.client});

  @override
  ConsumerState<_CwdPickerSheet> createState() => _CwdPickerSheetState();
}

class _CwdPickerSheetState extends ConsumerState<_CwdPickerSheet>
    with WidgetsBindingObserver {
  bool _browse = false;
  String _home = '/';
  String _cwd = '/';
  List<String> _recentPaths = const [];
  List<_ProjectHint> _projects = const [];
  List<FileEntry> _dirs = const [];
  bool _loading = true;
  String? _error;

  RpcClient? get _activeClient =>
      ref.read(activeClientProvider) ?? widget.client;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSuggestions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_onResumed());
    }
  }

  Future<void> _onResumed() async {
    await ref.read(connectionProvider.notifier).ensureConnected();
    if (!mounted) return;
    if (_browse) {
      await _listDir(_cwd);
    } else {
      await _loadSuggestions();
    }
  }

  Future<void> _loadSuggestions() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await ref.read(connectionProvider.notifier).ensureConnected();
    } catch (_) {}

    final client = _activeClient;
    if (client == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Not connected to the PC.';
      });
      return;
    }

    String home = '/';
    try {
      final info =
          await client.request('system.getInfo') as Map<String, dynamic>;
      home = (info['homeDir'] as String?)?.trim().isNotEmpty == true
          ? info['homeDir'] as String
          : '/';
    } catch (_) {}

    final recent = await loadRecentAgentCwds();
    final seen = <String>{if (home != '/') home, ...recent};
    var projects = <_ProjectHint>[];
    try {
      final raw = await client.requestList('fs.listProjects');
      for (final e in raw) {
        if (e is! Map) continue;
        final name = '${e['name'] ?? ''}';
        final path = '${e['path'] ?? ''}';
        if (path.isEmpty || seen.contains(path)) continue;
        seen.add(path);
        projects.add(_ProjectHint(name.isEmpty ? path : name, path));
      }
    } catch (_) {}
    projects.sort((a, b) => comparePathNames(a.name, b.name));
    if (home != '/') {
      projects.add(_ProjectHint('Home', home));
    }

    if (!mounted) return;
    setState(() {
      _home = home;
      _cwd = home;
      _recentPaths = recent;
      _projects = projects;
      _loading = false;
    });
  }

  Future<void> _openBrowse([String? start]) async {
    final target = start ?? (_home != '/' ? _home : '/');
    setState(() {
      _browse = true;
      _cwd = target;
    });
    await _listDir(target);
  }

  Future<void> _listDir(String path) async {
    setState(() {
      _loading = true;
      _error = null;
      _cwd = path;
    });

    try {
      await ref.read(connectionProvider.notifier).ensureConnected();
    } catch (_) {}

    final client = _activeClient;
    if (client == null) {
      if (!mounted) return;
      setState(() {
        _dirs = const [];
        _loading = false;
        _error = 'Not connected to the PC.';
      });
      return;
    }

    try {
      final raw =
          await client.request('fs.list', {'path': path}) as List<dynamic>;
      final dirs =
          raw
              .whereType<Map>()
              .map((e) => FileEntry.fromJson(Map<String, dynamic>.from(e)))
              .where((e) => e.isDirectory)
              .toList()
            ..sort((a, b) => comparePathNames(a.name, b.name));
      if (!mounted) return;
      setState(() {
        _dirs = dirs;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _dirs = const [];
        _loading = false;
        _error = friendlyLaunchError(e);
      });
    }
  }

  Future<void> _copyCurrentPath() async {
    final path = _cwd;
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied: $path'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _pasteAndGo() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty) {
      await _listDir(text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Opened: $text'),
          duration: const Duration(seconds: 2),
        ),
      );
    } else {
      await _editBrowsePath();
    }
  }

  Future<void> _editBrowsePath() async {
    final controller = TextEditingController(text: _cwd == '/' ? _home : _cwd);
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => ControllerOwnedDialog(
        controller: controller,
        child: AlertDialog(
          backgroundColor: const Color(0xFF1C1C2A),
          title: const Text('Go to folder'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'D:/projects/foo or ~/code',
              helperText: 'Any folder on the PC. ~ is home. / is This PC.',
              suffixIcon: IconButton(
                icon: const Icon(Icons.content_paste, size: 20),
                tooltip: 'Paste from clipboard',
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null && data!.text!.trim().isNotEmpty) {
                    controller.text = data.text!.trim();
                    controller.selection = TextSelection.fromPosition(
                      TextPosition(offset: controller.text.length),
                    );
                  }
                },
              ),
            ),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Go'),
            ),
          ],
        ),
      ),
    );
    if (path != null && path.isNotEmpty && mounted) {
      await _listDir(path);
    }
  }

  Future<void> _createNewFolder() async {
    if (isThisPcPath(_cwd)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot create a folder in This PC'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => ControllerOwnedDialog(
        controller: controller,
        child: AlertDialog(
          backgroundColor: const Color(0xFF1C1C2A),
          title: const Text('New folder'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Folder name',
              labelText: 'Name',
            ),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;

    final cleaned = name.replaceAll(RegExp(r'[/\\:]'), '_').trim();
    if (cleaned.isEmpty) return;

    final targetPath = _cwd.endsWith('/') ? '$_cwd$cleaned' : '$_cwd/$cleaned';

    final client = _activeClient;
    if (client == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Not connected to the PC.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    try {
      await client.request('fs.mkdir', {'path': targetPath});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Created folder "$cleaned"'),
          duration: const Duration(seconds: 2),
        ),
      );
      await _listDir(targetPath);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to create folder: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<void> _enterPath() async {
    final controller = TextEditingController(text: _cwd == '/' ? _home : _cwd);
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => ControllerOwnedDialog(
        controller: controller,
        child: AlertDialog(
          backgroundColor: const Color(0xFF1C1C2A),
          title: const Text('Folder path'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'D:/projects/foo or ~/code',
              helperText: 'Any folder on the PC. ~ is home. / is This PC.',
              suffixIcon: IconButton(
                icon: const Icon(Icons.content_paste, size: 20),
                tooltip: 'Paste from clipboard',
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null && data!.text!.trim().isNotEmpty) {
                    controller.text = data.text!.trim();
                    controller.selection = TextSelection.fromPosition(
                      TextPosition(offset: controller.text.length),
                    );
                  }
                },
              ),
            ),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Use folder'),
            ),
          ],
        ),
      ),
    );
    if (path != null && path.isNotEmpty && mounted) {
      _use(path);
    }
  }

  void _use(String path) {
    unawaited(saveLastAgentCwd(path));
    Navigator.pop(context, path);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(
              children: [
                if (_browse)
                  IconButton(
                    tooltip: 'Suggestions',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => setState(() {
                      _browse = false;
                      _error = null;
                      _loading = false;
                    }),
                  )
                else
                  const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _browse ? 'Browse folders' : 'Working directory',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (_browse)
                  FilledButton(
                    onPressed: () => _use(_cwd),
                    child: const Text('Use this folder'),
                  ),
              ],
            ),
          ),
          if (_browse)
            Container(
              color: const Color(0xFF12121C),
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Parent folder',
                    onPressed: isThisPcPath(_cwd)
                        ? null
                        : () => _listDir(parentHostPath(_cwd)),
                    icon: const Icon(Icons.arrow_upward, size: 20),
                    visualDensity: VisualDensity.compact,
                  ),
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: _editBrowsePath,
                      onLongPress: _copyCurrentPath,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 6,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                isThisPcPath(_cwd) ? 'This PC' : _cwd,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                  color: Color(0xFF8899AA),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.edit_outlined,
                              size: 14,
                              color: Colors.white38,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (!isThisPcPath(_cwd))
                    IconButton(
                      tooltip: 'New folder',
                      icon: const Icon(
                        Icons.create_new_folder_outlined,
                        size: 18,
                      ),
                      visualDensity: VisualDensity.compact,
                      onPressed: _createNewFolder,
                    ),
                  IconButton(
                    tooltip: 'Copy path',
                    icon: const Icon(Icons.copy_outlined, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: _copyCurrentPath,
                  ),
                  IconButton(
                    tooltip: 'Paste / Go to path',
                    icon: const Icon(Icons.content_paste_outlined, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: _pasteAndGo,
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
          Expanded(child: _browse ? _browseList() : _suggestionList()),
        ],
      ),
    );
  }

  Widget _suggestionList() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF2A1616),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Colors.redAccent.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.error_outline,
                    color: Colors.redAccent,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _loadSuggestions,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ListTile(
          leading: const Icon(Icons.folder_open, color: Color(0xFF6B8CFF)),
          title: const Text('Browse folders'),
          subtitle: const Text('Any directory on the PC'),
          onTap: () => _openBrowse(),
        ),
        ListTile(
          leading: const Icon(Icons.computer, color: Color(0xFF6B8CFF)),
          title: const Text('This PC'),
          subtitle: const Text('C:/, D:/ and other drives'),
          onTap: () => _openBrowse('/'),
        ),
        ListTile(
          leading: const Icon(Icons.edit_outlined, color: Color(0xFF6B8CFF)),
          title: const Text('Enter path'),
          subtitle: const Text('Type or paste a folder path'),
          onTap: _enterPath,
        ),
        if (_recentPaths.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              'RECENT',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 0.8,
                color: Color(0xFF666677),
              ),
            ),
          ),
          for (final path in _recentPaths)
            ListTile(
              leading: const Icon(Icons.history, color: Color(0xFF6B8CFF)),
              title: Text(folderDisplayName(path)),
              subtitle: Text(
                path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _use(path),
            ),
        ],
        if (_projects.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              'SUGGESTIONS',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 0.8,
                color: Color(0xFF666677),
              ),
            ),
          ),
          for (final p in _projects)
            if (!_recentPaths.contains(p.path))
              ListTile(
                leading: Icon(
                  p.path == _home ? Icons.home_outlined : Icons.folder,
                  color: const Color(0xFF6B8CFF),
                ),
                title: Text(p.name),
                subtitle: Text(
                  p.path == _home ? 'Your user folder — not a project' : p.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => _use(p.path),
              ),
        ],
      ],
    );
  }

  Widget _browseList() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent),
              ),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: () => _listDir(_cwd),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (_dirs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('No subfolders — use this folder, or go up.'),
            const SizedBox(height: 12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isThisPcPath(_cwd)) ...[
                  FilledButton.icon(
                    onPressed: _createNewFolder,
                    icon: const Icon(Icons.create_new_folder, size: 18),
                    label: const Text('New folder'),
                  ),
                  const SizedBox(width: 8),
                ],
                FilledButton.tonal(
                  onPressed: () => _listDir(_cwd),
                  child: const Text('Refresh'),
                ),
              ],
            ),
          ],
        ),
      );
    }
    final showNewFolderHeader = !isThisPcPath(_cwd);
    final itemCount = _dirs.length + (showNewFolderHeader ? 1 : 0);
    return ListView.builder(
      itemCount: itemCount,
      itemBuilder: (_, i) {
        if (showNewFolderHeader && i == 0) {
          return ListTile(
            leading: const Icon(
              Icons.create_new_folder_outlined,
              color: Color(0xFF6B8CFF),
            ),
            title: const Text(
              'New folder…',
              style: TextStyle(
                color: Color(0xFF6B8CFF),
                fontWeight: FontWeight.w500,
              ),
            ),
            onTap: _createNewFolder,
          );
        }
        final d = _dirs[showNewFolderHeader ? i - 1 : i];
        return ListTile(
          leading: Icon(
            isWindowsDriveRoot(d.path) ? Icons.storage : Icons.folder,
            color: const Color(0xFF6B8CFF),
          ),
          title: Text(d.name),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => _listDir(d.path),
        );
      },
    );
  }
}
