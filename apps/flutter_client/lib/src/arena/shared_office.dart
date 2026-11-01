import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../chats/chat_models.dart';
import '../monitor/approvals.dart';
import '../theme/nexus_theme.dart';
import 'arena_world.dart' show ArenaAgentSheet;
import 'pixel_art.dart';

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
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text(
                    '${visible.where((c) => c.needsAttention || asking.contains(c.id)).length} need you',
                    style: const TextStyle(color: NX.waiting),
                  ),
                  Text('${visible.where((c) => c.yourTurn).length} your turn'),
                  Text('${visible.where((c) => c.running).length} working'),
                ],
              ),
              if (widget.offline)
                const Text(
                  'PC offline · activity is last known',
                  style: TextStyle(color: NX.waiting),
                ),
              DropdownButton<String>(
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
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
            children: [
              Card(
                color: const Color(0xFF354D52),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 70,
                        height: 76,
                        child: _DeskArt(reception: true),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Reception',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const Text('Start a task in any project'),
                            FilledButton.icon(
                              onPressed: widget.offline ? null : _reception,
                              icon: const Icon(Icons.add),
                              label: const Text('New chat'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (busy.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'The office is quiet. Start a new chat at reception.',
                    textAlign: TextAlign.center,
                  ),
                ),
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns =
                      constraints.maxWidth >= 760 &&
                          MediaQuery.textScalerOf(context).scale(14) < 22
                      ? 2
                      : 1;
                  final width =
                      (constraints.maxWidth - (columns - 1) * 12) / columns;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      for (final c in busy)
                        SizedBox(
                          width: width,
                          key: ValueKey(c.id),
                          child: Card(
                            child: InkWell(
                              onTap: () => _open(c),
                              onLongPress: widget.onActions == null
                                  ? null
                                  : () => widget.onActions!(c),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SizedBox(
                                      width: 70,
                                      height: 86,
                                      child: _DeskArt(
                                        chat: c,
                                        attention: asking.contains(c.id),
                                        offline: widget.offline,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            c.title,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                          Text(
                                            '${c.folderName} · ${c.sourceName}',
                                            style: const TextStyle(
                                              color: NX.textDim,
                                              fontSize: 12,
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            asking.contains(c.id)
                                                ? 'Needs approval'
                                                : c.liveState == 'done'
                                                ? 'Completed'
                                                : c.monitorStatus,
                                            style: TextStyle(
                                              color: priority(c) == 0
                                                  ? NX.waiting
                                                  : NX.working,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          if (c.stepLabel.isNotEmpty &&
                                              c.stepLabel != c.monitorStatus)
                                            Text(
                                              c.stepLabel,
                                              maxLines: 3,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          if (c.isWorker)
                                            const Text(
                                              'Worker · reports to its orchestrator',
                                              style: TextStyle(
                                                color: NX.textDim,
                                                fontSize: 12,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
              if (idle.isNotEmpty)
                ExpansionTile(
                  title: Text('Idle & completed (${idle.length})'),
                  children: [
                    for (final c in idle)
                      ListTile(
                        title: Text(c.title),
                        subtitle: Text('${c.folderName} · ${c.monitorStatus}'),
                        onTap: () => _open(c),
                      ),
                  ],
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

class _DeskArt extends StatefulWidget {
  const _DeskArt({
    this.chat,
    this.attention = false,
    this.offline = false,
    this.reception = false,
  });
  final ChatSummary? chat;
  final bool attention, offline, reception;
  @override
  State<_DeskArt> createState() => _DeskArtState();
}

class _DeskArtState extends State<_DeskArt>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );
  final _sprites = SpriteBook();
  @override
  void dispose() {
    _clock.dispose();
    _sprites.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animate =
        !widget.offline &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (animate && !_clock.isAnimating) _clock.repeat();
    if (!animate) {
      _clock.stop();
      _clock.value = 0;
    }
    return RepaintBoundary(
      child: CustomPaint(painter: _DeskPainter(widget, _sprites, _clock)),
    );
  }
}

class _DeskPainter extends CustomPainter {
  _DeskPainter(this.data, this.sprites, this.clock) : super(repaint: clock);
  final _DeskArt data;
  final SpriteBook sprites;
  final Animation<double> clock;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(2);
    final px = Px(canvas);
    final chat =
        data.chat ?? ChatSummary({'id': 'reception', 'source': 'nexuslink'});
    final working = chat.running;
    final frame = clock.value < .5;
    final reading = [
      'reading',
      'searching',
      'browsing',
    ].contains(chat.live?.activity);
    final command = chat.live?.activity == 'running-command';
    px.r(0, 0, 35, 43, const Color(0xFF466B6D));
    px.r(2, 19, 31, 12, const Color(0xFFD2AF7C));
    px.r(2, 30, 31, 2, const Color(0xFFAE875B));
    px.r(4, 32, 2, 6, const Color(0xFF35454D));
    px.r(29, 32, 2, 6, const Color(0xFF35454D));
    if (!data.reception) {
      px.r(9, 8, 18, 12, const Color(0xFF20363F));
      for (var i = 0; i < 3; i++) {
        px.r(
          11,
          10 + i * 3,
          command ? 5 + i * 2 : 12,
          1,
          const Color(0xFF96CAB7),
        );
      }
      if (command && frame) px.r(11, 17, 3, 1, Colors.white);
    }
    final sprite = working && !reading && !command
        ? (frame ? typeA : typeB)
        : front;
    sprites.draw(canvas, sprite, lookFor(chat), const Offset(18, 39));
    if (reading) {
      px.r(11, 29, 14, 6, const Color(0xFFF2E4CA));
      px.r(frame ? 17 : 19, 29, 1, 6, const Color(0xFFAE875B));
    }
    if (data.attention || chat.needsAttention || chat.yourTurn) {
      px.r(25, frame ? 22 : 23, 3, 7, const Color(0xFFF2C9A0));
      px.r(28, 3, 2, 6, NX.waiting);
      px.r(28, 10, 2, 2, NX.waiting);
    }
    if (chat.liveState == 'done') {
      px.r(24, 8, 2, 4, NX.working);
      px.r(26, 10, 2, 2, NX.working);
      px.r(28, 6, 2, 4, NX.working);
    }
  }

  @override
  bool shouldRepaint(_DeskPainter old) => true;
}
