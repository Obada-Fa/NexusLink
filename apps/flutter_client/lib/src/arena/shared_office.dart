import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../chats/chat_models.dart';
import '../monitor/approvals.dart';
import '../theme/nexus_theme.dart';
import 'arena_world.dart' show ArenaAgentSheet, ArenaWorld;

/// A single office with stable seats and no limit on active chats.
class SharedOffice extends ConsumerStatefulWidget {
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
  ConsumerState<SharedOffice> createState() => _SharedOfficeState();
}

class _SharedOfficeState extends ConsumerState<SharedOffice> {
  final _seats = <String, int>{};
  final _completed = <String, Timer>{};
  int _nextSeat = 0;
  String? _project;
  @override
  void didUpdateWidget(SharedOffice oldWidget) {
    super.didUpdateWidget(oldWidget);
    final working = {
      for (final c in oldWidget.chats)
        if (c.running) c.id,
    };
    for (final c in widget.chats) {
      if (working.contains(c.id) &&
          c.liveState == 'done' &&
          !_completed.containsKey(c.id)) {
        _completed[c.id] = Timer(const Duration(seconds: 2), () {
          if (mounted) setState(() => _completed.remove(c.id));
        });
      }
    }
  }

  @override
  void dispose() {
    for (final timer in _completed.values) {
      timer.cancel();
    }
    super.dispose();
  }

  void _open(ChatSummary chat) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: NX.surface,
    builder: (sheet) => ArenaAgentSheet(
      chatId: chat.id,
      lookup: () =>
          widget.chats.where((c) => c.id == chat.id).firstOrNull ?? chat,
      room: null,
      world: null,
      offline: widget.offline,
      onOpen: () {
        Navigator.pop(sheet);
        widget.onOpen(chat);
      },
      onActions: widget.onActions == null
          ? null
          : () {
              Navigator.pop(sheet);
              widget.onActions!(chat);
            },
    ),
  );
  Future<void> _reception() async {
    final host = widget.hostKey;
    final choice = await showModalBottomSheet<ChatFolder>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          OfficeProjectPicker(load: widget.loadProjects, selected: _project),
    );
    if (mounted &&
        choice != null &&
        !widget.offline &&
        host == widget.hostKey) {
      widget.onNewChat(choice.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final asking = ref.watch(approvalsProvider.select((s) => s.chatIds));
    final chats = widget.chats.where((c) => !c.archived).toList();
    for (final c in chats) {
      _seats.putIfAbsent(c.id, () => _nextSeat++);
    }
    final projects = <String, String>{
      for (final c in chats)
        if (c.folderPath != null) c.folderPath!: c.folderName,
    };
    if (!projects.containsKey(_project)) _project = null;
    final visible = chats
        .where((c) => _project == null || c.folderPath == _project)
        .toList();
    bool active(ChatSummary c) =>
        c.monitorPriority < 3 ||
        asking.contains(c.id) ||
        _completed.containsKey(c.id);
    int priority(ChatSummary c) =>
        asking.contains(c.id) ? 0 : c.monitorPriority;
    final busy = visible.where(active).toList()
      ..sort((a, b) {
        final p = priority(a).compareTo(priority(b));
        return p != 0 ? p : _seats[a.id]!.compareTo(_seats[b.id]!);
      });
    final idle = visible.where((c) => !active(c)).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: _project,
                  hint: const Text('All projects'),
                  items: [
                    const DropdownMenuItem<String>(
                      value: null,
                      child: Text('All projects'),
                    ),
                    for (final p in projects.entries)
                      DropdownMenuItem(
                        value: p.key,
                        child: Text(p.value, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (value) => setState(() => _project = value),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: widget.offline ? null : _reception,
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('New chat'),
              ),
            ],
          ),
        ),
        const Text(
          'Drag to explore · pinch or use + / − to zoom',
          style: TextStyle(color: NX.textDim, fontSize: 12),
        ),
        Expanded(
          child: ArenaWorld(
            chats: busy,
            offline: widget.offline,
            sharedOffice: true,
            onNewChat: widget.offline ? null : _reception,
            onOpen: widget.onOpen,
            onActions: widget.onActions,
          ),
        ),
        Wrap(
          alignment: WrapAlignment.center,
          children: [
            if (idle.isNotEmpty)
              TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  showDragHandle: true,
                  builder: (sheet) => ListView(
                    children: [
                      for (final c in idle)
                        ListTile(
                          title: Text(c.title),
                          subtitle: Text(
                            '${c.folderName} · ${c.monitorStatus}',
                          ),
                          onTap: () {
                            Navigator.pop(sheet);
                            _open(c);
                          },
                        ),
                    ],
                  ),
                ),
                child: Text('Idle & completed (${idle.length})'),
              ),
            if (widget.onLoadMore != null)
              TextButton(
                onPressed: widget.loadingMore ? null : widget.onLoadMore,
                child: Text(
                  widget.loadingMore ? 'Loading…' : 'Load more chats',
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class OfficeProjectPicker extends StatefulWidget {
  const OfficeProjectPicker({super.key, required this.load, this.selected});
  final Future<List<ChatFolder>> Function() load;
  final String? selected;
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
                        ..sort(
                          (a, b) => a.path == b.path
                              ? 0
                              : a.path == widget.selected
                              ? -1
                              : b.path == widget.selected
                              ? 1
                              : a.name.compareTo(b.name),
                        );
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
                          trailing: p.path == widget.selected
                              ? const Icon(Icons.check)
                              : null,
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
