import 'package:flutter/material.dart';
import '../chats/chat_models.dart';
import '../theme/nexus_theme.dart';
import 'arena_world.dart' show ArenaWorld;

/// The Arena tab: the project campus plus the controls around it.
class SharedOffice extends StatefulWidget {
  const SharedOffice({
    super.key,
    required this.chats,
    required this.offline,
    required this.onOpen,
    required this.onNewChat,
    required this.loadProjects,
    this.onActions,
    this.onLoadMore,
    this.loadingMore = false,
    this.hostKey,
  });
  final List<ChatSummary> chats;
  final bool offline, loadingMore;
  final Object? hostKey;
  final ValueChanged<ChatSummary> onOpen;
  final ValueChanged<ChatSummary>? onActions;
  final ValueChanged<String?> onNewChat;
  final Future<List<ChatFolder>> Function() loadProjects;
  final VoidCallback? onLoadMore;
  @override
  State<SharedOffice> createState() => _SharedOfficeState();
}

class _SharedOfficeState extends State<SharedOffice> {
  Future<void> _pickProject() async {
    final host = widget.hostKey;
    final choice = await showModalBottomSheet<ChatFolder>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => OfficeProjectPicker(load: widget.loadProjects),
    );
    if (mounted &&
        choice != null &&
        !widget.offline &&
        host == widget.hostKey) {
      widget.onNewChat(choice.path);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Drag to explore, pinch to zoom',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: NX.textDim, fontSize: 12),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: widget.offline ? null : _pickProject,
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('New chat'),
            ),
          ],
        ),
      ),
      Expanded(
        child: ArenaWorld(
          chats: widget.chats,
          offline: widget.offline,
          onNewChat: widget.offline
              ? null
              : (room) => widget.onNewChat(room.path),
          onOpen: widget.onOpen,
          onActions: widget.onActions,
        ),
      ),
      if (widget.onLoadMore != null)
        TextButton(
          onPressed: widget.loadingMore ? null : widget.onLoadMore,
          child: Text(widget.loadingMore ? 'Loading…' : 'Load more chats'),
        ),
    ],
  );
}

class OfficeProjectPicker extends StatefulWidget {
  const OfficeProjectPicker({super.key, required this.load});
  final Future<List<ChatFolder>> Function() load;
  @override
  State<OfficeProjectPicker> createState() => _OfficeProjectPickerState();
}

class _OfficeProjectPickerState extends State<OfficeProjectPicker> {
  late Future<List<ChatFolder>> _projects = widget.load();
  String _query = '';
  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .65,
        child: Column(
          children: [
            const Text(
              'Choose a project',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            TextField(
              decoration: const InputDecoration(labelText: 'Search projects'),
              onChanged: (q) => setState(() => _query = q.toLowerCase()),
            ),
            ListTile(
              title: const Text('Default folder'),
              onTap: () => Navigator.pop(context, ChatFolder({})),
            ),
            Expanded(
              child: FutureBuilder<List<ChatFolder>>(
                future: _projects,
                builder: (context, result) {
                  if (result.hasError) {
                    return Column(
                      children: [
                        const Text(
                          'Could not load projects. Check the PC connection.',
                        ),
                        TextButton(
                          onPressed: () => setState(() {
                            _projects = widget.load();
                          }),
                          child: const Text('Retry'),
                        ),
                      ],
                    );
                  }
                  if (!result.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final rows =
                      result.data!
                          .where(
                            (p) => '${p.name} ${p.path}'.toLowerCase().contains(
                              _query,
                            ),
                          )
                          .toList()
                        ..sort((a, b) => a.name.compareTo(b.name));
                  if (rows.isEmpty) {
                    return const Center(
                      child: Text(
                        'No matching projects. You can use the default folder.',
                      ),
                    );
                  }
                  return ListView(
                    children: [
                      for (final p in rows)
                        ListTile(
                          title: Text(p.name),
                          subtitle: Text(p.path ?? ''),
                          onTap: () => Navigator.pop(context, p),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
