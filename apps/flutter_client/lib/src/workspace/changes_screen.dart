import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../state/connection.dart';
import 'editor_screen.dart';

class ChangesScreen extends ConsumerStatefulWidget {
  final String cwd;
  const ChangesScreen({super.key, required this.cwd});
  @override
  ConsumerState<ChangesScreen> createState() => _ChangesScreenState();
}

class _ChangesScreenState extends ConsumerState<ChangesScreen> {
  List<Map<String, dynamic>>? _files;
  String? _error, _root;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await ref.read(activeClientProvider)!.requestMap(
        'fs.gitChanges',
        {'cwd': widget.cwd},
      );
      if (mounted) {
        setState(() {
          _root = data['cwd'] as String;
          _files = (data['files'] as List)
              .map((f) => Map<String, dynamic>.from(f))
              .toList();
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _diff(Map<String, dynamic> file, bool staged) async {
    try {
      final data = await ref.read(activeClientProvider)!.requestMap(
        'fs.gitDiff',
        {'cwd': _root, 'path': file['path'], 'staged': staged},
      );
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (ctx) => Scaffold(
            appBar: AppBar(
              title: Text(
                '${staged ? 'Staged' : 'Unstaged'} · ${file['path']}',
              ),
              actions: [
                IconButton(
                  tooltip: 'Open file',
                  onPressed: () =>
                      openEditor(ctx, file['absolutePath'] as String),
                  icon: const Icon(Icons.edit_note),
                ),
              ],
            ),
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                '${data['binary'] == true ? 'Binary file changed.\n' : ''}${data['text']}${data['truncated'] == true ? '\n[Diff truncated]' : ''}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ListTile(
        title: const Text('Working-tree changes'),
        subtitle: const Text(
          'Includes edits from agents and other applications.',
        ),
        trailing: IconButton(
          onPressed: _load,
          tooltip: 'Refresh changes',
          icon: const Icon(Icons.refresh),
        ),
      ),
      Expanded(
        child: _error != null
            ? Center(child: Text(_error!))
            : _files == null
            ? const Center(child: CircularProgressIndicator())
            : _files!.isEmpty
            ? const Center(child: Text('Working tree is clean'))
            : ListView(
                children: [
                  for (final file in _files!)
                    ListTile(
                      title: Text(file['path'] as String),
                      subtitle: Text(file['status'] as String),
                      onTap: () => file['untracked'] == true
                          ? openEditor(context, file['absolutePath'] as String)
                          : _diff(file, file['staged'] == true),
                      trailing: PopupMenuButton<String>(
                        onSelected: (choice) {
                          if (choice == 'open') {
                            openEditor(context, file['absolutePath'] as String);
                          } else {
                            _diff(file, choice == 'staged');
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'open',
                            child: Text('Open file'),
                          ),
                          if (file['staged'] == true)
                            const PopupMenuItem(
                              value: 'staged',
                              child: Text('Staged diff'),
                            ),
                          if (file['unstaged'] == true &&
                              file['untracked'] != true)
                            const PopupMenuItem(
                              value: 'unstaged',
                              child: Text('Unstaged diff'),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    ],
  );
}
