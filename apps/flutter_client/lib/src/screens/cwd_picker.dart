// Working-directory picker for a new agent chat. Suggestions are git roots
// from fs.listProjects; Browse walks the PC via fs.list so any folder works.
// A later host-side allow-list can restrict this without changing the UI.

import 'dart:async';

import 'package:flutter/material.dart';

import '../rpc/models.dart';
import '../rpc/rpc_client.dart';
import '../state/last_cwd.dart';
import '../util/host_path.dart';

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

class _CwdPickerSheet extends StatefulWidget {
  final RpcClient client;
  const _CwdPickerSheet({required this.client});

  @override
  State<_CwdPickerSheet> createState() => _CwdPickerSheetState();
}

class _CwdPickerSheetState extends State<_CwdPickerSheet> {
  bool _browse = false;
  String _home = '/';
  String _cwd = '/';
  List<String> _recentPaths = const [];
  List<_ProjectHint> _projects = const [];
  List<FileEntry> _dirs = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSuggestions();
  }

  Future<void> _loadSuggestions() async {
    String home = '/';
    try {
      final info =
          await widget.client.request('system.getInfo') as Map<String, dynamic>;
      home = (info['homeDir'] as String?)?.trim().isNotEmpty == true
          ? info['homeDir'] as String
          : '/';
    } catch (_) {}

    final recent = await loadRecentAgentCwds();
    final seen = <String>{home, ...recent};
    var projects = <_ProjectHint>[];
    try {
      final raw = await widget.client.requestList('fs.listProjects');
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
    projects.add(_ProjectHint('Home', home));

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
    setState(() {
      _browse = true;
      _cwd = start ?? _home;
    });
    await _listDir(_cwd);
  }

  Future<void> _listDir(String path) async {
    setState(() {
      _loading = true;
      _error = null;
      _cwd = path;
    });
    try {
      final raw = await widget.client.request(
        'fs.list',
        {'path': path},
      ) as List<dynamic>;
      final dirs = raw
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
        _error = e.toString();
      });
    }
  }

  Future<void> _enterPath() async {
    final controller = TextEditingController(text: _cwd == '/' ? _home : _cwd);
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C2A),
        title: const Text('Folder path'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'D:/projects/foo or ~/code',
            helperText: 'Any folder on the PC. ~ is home. / is This PC.',
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
    );
    controller.dispose();
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
                        fontSize: 16, fontWeight: FontWeight.w600),
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
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Parent folder',
                    onPressed: isThisPcPath(_cwd)
                        ? null
                        : () => _listDir(parentHostPath(_cwd)),
                    icon: const Icon(Icons.arrow_upward, size: 20),
                  ),
                  Expanded(
                    child: Text(
                      _cwd,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, fontFamily: 'monospace', color: Color(0xFF8899AA)),
                    ),
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
        ListTile(
          leading: const Icon(Icons.folder_open, color: Color(0xFF6B8CFF)),
          title: const Text('Browse folders'),
          subtitle: const Text('Any directory on the PC'),
          onTap: _openBrowse,
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
                  fontSize: 11, letterSpacing: 0.8, color: Color(0xFF666677)),
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
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'SUGGESTIONS',
            style: TextStyle(
                fontSize: 11, letterSpacing: 0.8, color: Color(0xFF666677)),
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
    );
  }

  Widget _browseList() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent)),
        ),
      );
    }
    if (_dirs.isEmpty) {
      return const Center(child: Text('No subfolders — use this folder, or go up.'));
    }
    return ListView.builder(
      itemCount: _dirs.length,
      itemBuilder: (_, i) {
        final d = _dirs[i];
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
