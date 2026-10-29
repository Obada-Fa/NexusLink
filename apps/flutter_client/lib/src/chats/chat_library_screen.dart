import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../rpc/rpc_client.dart';
import '../screens/agent_screen.dart';
import '../state/connection.dart';
import '../state/last_host.dart';
import '../workspace/platform_bridge.dart';
import '../workspace/project.dart';
import '../workspace/files_screen.dart';
import 'chat_models.dart';
import 'chat_repository.dart';
import '../arena/arena_view.dart';
import '../monitor/mission_control.dart';
import '../monitor/approvals.dart';
import '../monitor/monitor_provider.dart';
import '../theme/nexus_theme.dart';
import '../theme/nx_widgets.dart';

class ChatLibraryScreen extends ConsumerStatefulWidget {
  final ChatFolder? folder;
  const ChatLibraryScreen({super.key, this.folder});
  @override
  ConsumerState<ChatLibraryScreen> createState() => _ChatLibraryScreenState();
}

class _ChatLibraryScreenState extends ConsumerState<ChatLibraryScreen>
    with WidgetsBindingObserver {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _health = [];
  Timer? _debounce;
  Timer? _liveRefresh;
  bool _liveLoading = false;
  bool _liveDirty = false;
  void Function()? _unsubscribe;
  RpcClient? _bound;
  bool _folders = false;
  bool _arena = false;
  bool _showSearch = false;
  bool _archived = false;
  bool _loading = true;
  bool _moreLoading = false;
  bool _saved = false;
  String? _source;
  String? _cursor;
  String? _error;
  String _sort = 'activity';
  String _monitorFilter = 'all';
  DateTime? _receivedAt;
  int _generation = 0;
  int? _lastSync;

  ChatRepository get _repo => ref.read(chatRepositoryProvider);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(() {
      if (_scroll.hasClients &&
          _scroll.position.extentAfter < 300 &&
          _cursor != null &&
          !_moreLoading) {
        unawaited(_load(more: true));
      }
    });
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    final host = await _repo.host();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    _sort = prefs.getString('chat-folder-sort:$host') ?? 'activity';
    if (widget.folder == null) {
      final view = prefs.getString('monitor-view') ?? 'list';
      _arena = view == 'arena';
      _folders = view == 'folders';
    }
    await _load();
    if (!mounted) return;
    _bind();
    if (mounted) await _openPending(ref.read(pendingTaskProvider));
  }

  void _bind() {
    final client = ref.read(activeClientProvider);
    if (identical(client, _bound)) return;
    _unsubscribe?.call();
    _bound = client;
    if (client?.supports('chat.library.v1') == true) {
      _unsubscribe = client!.subscribe(
        'chat-library-update',
        (_) => _scheduleLiveRefresh(),
      );
      unawaited(
        client
            .requestMap('chat.subscribe', {'enabled': true})
            .catchError((Object error) => <String, dynamic>{}),
      );
    }
  }

  // Throttle bursts, rather than delaying forever while tokens keep arriving.
  void _scheduleLiveRefresh() {
    _liveDirty = true;
    if (_liveLoading || _liveRefresh?.isActive == true) return;
    _liveRefresh = Timer(const Duration(milliseconds: 250), () async {
      if (!mounted) return;
      _liveLoading = true;
      _liveDirty = false;
      try {
        await _load(quiet: true);
      } finally {
        _liveLoading = false;
        if (mounted && _liveDirty) _scheduleLiveRefresh();
      }
    });
  }

  Map<String, dynamic> get _query => {
    'query': _search.text.trim(),
    'archived': _archived,
    'limit': 50,
    if (_source != null) 'source': _source,
    if (widget.folder != null) 'folderId': widget.folder!.id,
    'sort': _folders ? _sort : 'monitor',
    // Counters need every state; the filter is applied on the phone.
    if (!_folders) 'monitorFilter': 'all',
  };
  Future<void> _load({
    bool more = false,
    bool quiet = false,
    int restarts = 0,
  }) async {
    if (more && _cursor == null) return;
    final repository = _repo;
    final generation = more ? _generation : ++_generation;
    if (more) {
      setState(() => _moreLoading = true);
    } else if (!quiet) {
      setState(() => _loading = _items.isEmpty);
    }
    try {
      // Render saved summaries before waiting for the host's first query.
      if (!more && _items.isEmpty) {
        final host = await repository.host();
        if (host != null) {
          final cached = await repository.cache.summaries(host);
          if (mounted &&
              generation == _generation &&
              !_folders &&
              widget.folder == null &&
              _search.text.isEmpty) {
            setState(() {
              _items = cached
                  .where(
                    (row) =>
                        (row['archived'] == true) == _archived &&
                        (_source == null || row['source'] == _source),
                  )
                  .toList();
              _saved = !repository.online;
              _loading = _items.isEmpty;
            });
          }
        }
      }
      final query = Map<String, dynamic>.of(_query);
      var page = await repository.list({
        ...query,
        if (more) 'cursor': _cursor,
      }, folders: _folders);
      if (!mounted ||
          generation != _generation ||
          !identical(repository, _repo)) {
        return;
      }
      if (page['restart'] == true) {
        if (restarts >= 2) throw StateError('Library changed during refresh');
        _cursor = null;
        await _load(quiet: true, restarts: restarts + 1);
        return;
      }
      final rows = (page['items'] as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      // Refetch the already visible pages so an invalidation does not shorten
      // a scrolled list back to its first page.
      if (quiet && !more) {
        final visibleCount = _items.length;
        while (rows.length < visibleCount && page['nextCursor'] != null) {
          final next = await repository.list({
            ...query,
            'cursor': page['nextCursor'],
          }, folders: _folders);
          if (!mounted || generation != _generation) return;
          if (next['restart'] == true) {
            if (restarts >= 2) {
              throw StateError('Library changed during refresh');
            }
            await _load(quiet: true, restarts: restarts + 1);
            return;
          }
          rows.addAll(
            (next['items'] as List).map(
              (row) => Map<String, dynamic>.from(row as Map),
            ),
          );
          page = next;
        }
      }
      final host = await repository.host();
      final lastSync = host == null
          ? null
          : await repository.cache.lastSync(host);
      if (!mounted || generation != _generation) return;
      setState(() {
        if (more) {
          final ids = _items.map((row) => row['id']).toSet();
          _items.addAll(rows.where((row) => !ids.contains(row['id'])));
        } else {
          _items = rows;
        }
        _health = (page['sources'] as List? ?? [])
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList();
        _cursor = page['nextCursor'] as String?;
        _saved = page['saved'] == true;
        _lastSync = lastSync;
        _loading = false;
        _moreLoading = false;
        _error = null;
        _receivedAt = DateTime.now();
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error =
              'Couldn’t load chats. Pull to refresh or reconnect to the PC.';
          _loading = false;
          _moreLoading = false;
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_bound?.supports('chat.library.v1') == true) {
      unawaited(
        _bound!
            .requestMap('chat.subscribe', {
              'enabled': state == AppLifecycleState.resumed,
            })
            .catchError((Object _) => <String, dynamic>{}),
      );
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(
        _repo
            .refresh()
            .then((_) => _load(quiet: true))
            .catchError((Object _) {}),
      );
    }
  }

  Future<void> _filters() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('Filter chats')),
              RadioGroup<String>(
                groupValue: _source ?? '',
                onChanged: (value) =>
                    update(() => _source = value == '' ? null : value),
                child: Column(
                  children: [
                    for (final source in <String?>[
                      null,
                      'codex',
                      'claude',
                      'cursor',
                      'opencode',
                      'antigravity',
                      'mock',
                    ])
                      RadioListTile<String>(
                        title: Text(
                          source == null
                              ? 'All apps'
                              : {
                                  'codex': 'Codex',
                                  'claude': 'Claude Code',
                                  'cursor': 'Cursor',
                                  'opencode': 'OpenCode',
                                  'antigravity': 'Antigravity',
                                  'mock': 'NexusLink',
                                }[source]!,
                        ),
                        value: source ?? '',
                      ),
                  ],
                ),
              ),
              SwitchListTile(
                title: const Text('Hidden chats'),
                value: _archived,
                onChanged: (value) => update(() => _archived = value),
              ),
            ],
          ),
        ),
      ),
    );
    await _load();
  }

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _setView(String view) async {
    final folders = view == 'folders';
    setState(() {
      _arena = view == 'arena';
      if (folders != _folders) {
        _folders = folders;
        _items = [];
        _cursor = null;
      }
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('monitor-view', view);
    if (mounted && _items.isEmpty) unawaited(_load());
  }

  Future<void> _clearSaved() async {
    if (!await _confirm(
      'Clear saved chats?',
      'Saved copies on this phone are removed. Conversations on the PC are not touched.',
      'Clear',
    )) {
      return;
    }
    final host = await _repo.host();
    if (host == null) return;
    await _repo.cache.clear(host);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Saved chats cleared from this phone. PC conversations are unchanged.',
          ),
        ),
      );
      await _load();
    }
  }

  Future<void> _forgetPc() async {
    if (!await _confirm(
      'Forget this PC?',
      'You will need a new pairing code from the PC to reconnect. Saved chats and drafts on this phone are removed.',
      'Forget',
    )) {
      return;
    }
    if (!mounted) return;
    final repository = _repo;
    final host = await repository.host();
    final address = repository.address;
    repository.dispose();
    ref.read(connectionProvider.notifier).disconnect();
    if (host != null) await repository.cache.clear(host, includeDrafts: true);
    if (address != null) await PlatformBridge.removeCredential(address);
    final prefs = await SharedPreferences.getInstance();
    if (address != null) await prefs.remove('chat-host:$address');
    if (prefs.getString('chat-last-host') == host) {
      await prefs.remove('chat-last-host');
    }
    await clearLastHostUrl();
    if (mounted) {
      setState(() {
        _items = [];
        _health = [];
        _lastSync = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'PC forgotten. Saved chats and drafts removed from this phone.',
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    ++_generation;
    WidgetsBinding.instance.removeObserver(this);
    _unsubscribe?.call();
    _debounce?.cancel();
    _liveRefresh?.cancel();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _open(ChatSummary chat) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => AgentScreen(libraryChat: chat)),
    );
    if (mounted) await _load(quiet: true);
  }

  Future<void> _openPending(String? task) async {
    if (task == null || !_repo.online || !mounted) return;
    ref.read(pendingTaskProvider.notifier).select(null);
    try {
      if (task.startsWith('chat:')) {
        final page = await _repo.client!.requestMap('chat.historyPage', {
          'chatId': task.substring(5),
          'limit': 5,
        });
        if (!mounted) return;
        final chat = page['chat'];
        if (chat is! Map) throw StateError('This chat is no longer available');
        await _open(ChatSummary(Map<String, dynamic>.from(chat)));
      } else {
        final chat = _items
            .where((row) => row['agentSessionId'] == task)
            .firstOrNull;
        if (chat != null) {
          await _open(ChatSummary(chat));
        } else {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => AgentScreen(initialTaskId: task),
            ),
          );
        }
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open this update: $error')),
        );
      }
    }
  }

  String _syncLine(bool offline) => offline
      ? (_lastSync == null
            ? 'PC offline'
            : 'PC offline · synced ${chatRelativeTime(DateTime.fromMillisecondsSinceEpoch(_lastSync!))}')
      : _saved
      ? 'Connected · showing saved activity'
      : _receivedAt == null
      ? 'Connecting to your agents…'
      : 'Live · ${ref.read(activeClientProvider)?.hostId == null ? 'PC' : 'synced ${TimeOfDay.fromDateTime(_receivedAt!).format(context)}'}';

  void _newChat() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          AgentScreen(startNew: true, initialFolder: widget.folder?.path),
    ),
  );

  bool get _canEditState =>
      _repo.online && _repo.client?.supports('chat.state.v1') == true;

  /// Optimistically mark done / hide on the phone, then confirm with the PC.
  Future<void> _setChatState(
    ChatSummary chat, {
    bool? acknowledged,
    bool? hidden,
    bool offerUndo = true,
  }) async {
    final client = _repo.client;
    if (client == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final before = List<Map<String, dynamic>>.of(_items);
    setState(() {
      final index = _items.indexWhere((row) => row['id'] == chat.id);
      if (index < 0) return;
      if (hidden != null && hidden != _archived) {
        _items.removeAt(index);
        return;
      }
      final row = Map<String, dynamic>.of(_items[index]);
      if (acknowledged == true) {
        row['attentionCleared'] = 'acknowledged';
        if (row['execution'] == 'needsReply') row['execution'] = 'idle';
        if (row['live'] is Map) {
          row['live'] = {
            ...Map<String, dynamic>.from(row['live'] as Map),
            'state': 'idle',
          }..remove('waitingFor');
        }
      } else if (acknowledged == false) {
        row.remove('attentionCleared');
      }
      _items[index] = row;
    });
    try {
      final result = await client.requestMap('chat.setState', {
        'chatId': chat.id,
        'acknowledged': ?acknowledged,
        'hidden': ?hidden,
      });
      final updated = result['chat'];
      if (mounted &&
          updated is Map &&
          (hidden == null || hidden == _archived)) {
        setState(() {
          final index = _items.indexWhere((row) => row['id'] == chat.id);
          if (index >= 0) _items[index] = Map<String, dynamic>.from(updated);
        });
      }
      if (!offerUndo || !mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              acknowledged == true
                  ? 'Marked done: ${chat.title}'
                  : hidden == true
                  ? 'Hidden from Monitor'
                  : acknowledged == false
                  ? 'Flagged as needing you'
                  : 'Back in Monitor',
            ),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () => unawaited(
                _setChatState(
                  ChatSummary(
                    Map<String, dynamic>.from(
                      (updated is Map ? updated : chat.json),
                    ),
                  ),
                  acknowledged: acknowledged == null ? null : !acknowledged,
                  hidden: hidden == null ? null : !hidden,
                  offerUndo: false,
                ),
              ),
            ),
          ),
        );
    } catch (error) {
      if (!mounted) return;
      setState(() => _items = before);
      messenger.showSnackBar(
        SnackBar(content: Text('Couldn’t update the PC: $error')),
      );
    }
  }

  Future<void> _chatActions(ChatSummary chat) async {
    final action = await showChatActions(context, chat, canEdit: _canEditState);
    if (action == null || !mounted) return;
    switch (action) {
      case ChatAction.open:
        await _open(chat);
      case ChatAction.markDone:
        await _setChatState(chat, acknowledged: true);
      case ChatAction.flagAgain:
        await _setChatState(chat, acknowledged: false);
      case ChatAction.hide:
        await _setChatState(chat, hidden: true);
      case ChatAction.unhide:
        await _setChatState(chat, hidden: false);
      case ChatAction.files:
        ref.read(projectProvider.notifier).select(chat.folderPath!);
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const WorkspaceFilesScreen()),
        );
    }
  }

  /// Needs-you cards swipe away to "done".
  Widget _dismissible(ChatSummary chat, Widget child) {
    if (!_canEditState) return child;
    Widget background(Alignment align) => Container(
      margin: const EdgeInsets.fromLTRB(NX.pad, 0, NX.pad, 10),
      padding: const EdgeInsets.symmetric(horizontal: 22),
      alignment: align,
      decoration: BoxDecoration(
        color: NX.working.withValues(alpha: .16),
        borderRadius: BorderRadius.circular(NX.radius),
        border: Border.all(color: NX.working.withValues(alpha: .5)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_rounded, color: NX.working),
          SizedBox(width: 8),
          Text(
            'Mark as done',
            style: TextStyle(color: NX.working, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
    return Dismissible(
      key: ValueKey('done-${chat.id}'),
      background: background(Alignment.centerLeft),
      secondaryBackground: background(Alignment.centerRight),
      onDismissed: (_) => unawaited(_setChatState(chat, acknowledged: true)),
      child: child,
    );
  }

  Future<void> _retrySource(Map<String, dynamic> health) async {
    try {
      await _repo.client?.requestMap('chat.refresh', {
        'source': health['source'],
      });
      await _load(quiet: true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Retry failed: $error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(pendingTaskProvider, (_, task) {
      unawaited(_openPending(task));
    });
    final status = ref.watch(connectionStatusProvider);
    ref.listen(chatRepositoryProvider, (_, _) {
      ++_generation;
      setState(() {
        _items = [];
        _health = [];
        _loading = true;
        _cursor = null;
      });
      _bound = null;
      _bind();
      unawaited(_initialize());
    });
    final offline = status != RpcStatus.connected;
    final top = widget.folder == null;
    final monitorHost = hostSupportsMonitor(ref.watch(activeClientProvider));
    final tabVisible = ref.watch(workspaceTabProvider) == 0;
    final all =
        (_folders ? <Map<String, dynamic>>[] : _items)
            .map(ChatSummary.new)
            .toList()
          ..sort(compareMonitorChats);
    // A prompt waiting on the phone is certain, so it outranks what the transcript says.
    final asking = ref.watch(approvalsProvider.select((s) => s.chatIds));
    bool blocked(ChatSummary c) => c.needsAttention || asking.contains(c.id);
    final attention = all.where(blocked).toList();
    final running = all.where((c) => c.running && !blocked(c)).toList();
    final turn = all.where((c) => c.yourTurn && !blocked(c)).toList();
    final rest = all
        .where((c) => !blocked(c) && !c.running && !c.yourTurn)
        .toList();
    final now = DateTime.now();
    final doneToday = rest.where((c) {
      final t = c.activity?.toLocal();
      return t != null &&
          t.year == now.year &&
          t.month == now.month &&
          t.day == now.day;
    }).length;
    final scanning = _health.any((row) => row['state'] == 'scanning');
    final showAttention =
        _monitorFilter == 'all' || _monitorFilter == 'attention';
    final showRunning = _monitorFilter == 'all' || _monitorFilter == 'running';
    final showRecent = _monitorFilter == 'all' || _monitorFilter == 'recent';
    final emptyText = _search.text.isNotEmpty || _source != null
        ? 'No matching chats'
        : scanning
        ? 'Still finding chats on your PC…'
        : offline
        ? 'No saved chats on this phone yet'
        : _monitorFilter == 'running'
        ? 'No agents working right now'
        : _monitorFilter == 'attention'
        ? 'All caught up — nothing needs you'
        : 'No conversations yet';

    final slivers = <Widget>[
      if (_showSearch || _search.text.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(NX.pad, 4, NX.pad, 4),
            child: TextField(
              controller: _search,
              autofocus: _search.text.isEmpty,
              decoration: InputDecoration(
                hintText: 'Search chats, projects, agents…',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: NX.surface2,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(NX.radiusSm),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: IconButton(
                  tooltip: 'Close search',
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _search.clear();
                    setState(() => _showSearch = false);
                    unawaited(_load());
                  },
                ),
              ),
              onChanged: (_) {
                ++_generation;
                _debounce?.cancel();
                _debounce = Timer(
                  const Duration(milliseconds: 250),
                  () => unawaited(_load()),
                );
              },
            ),
          ),
        ),
      if (top)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(NX.pad, 4, NX.pad, 4),
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(
                  value: 'list',
                  icon: Icon(Icons.view_agenda_outlined, size: 18),
                  label: Text('Live'),
                ),
                ButtonSegment(
                  value: 'arena',
                  icon: Icon(Icons.apartment_rounded, size: 18),
                  label: Text('Arena'),
                ),
                ButtonSegment(
                  value: 'folders',
                  icon: Icon(Icons.folder_outlined, size: 18),
                  label: Text('Projects'),
                ),
              ],
              selected: {
                _folders
                    ? 'folders'
                    : _arena
                    ? 'arena'
                    : 'list',
              },
              onSelectionChanged: (value) => unawaited(_setView(value.first)),
            ),
          ),
        ),
      if (!_folders && monitorHost && top && !_arena)
        const SliverToBoxAdapter(child: VitalsPulseStrip()),
      if (monitorHost && top && !offline)
        const SliverToBoxAdapter(child: RemoteAccessAlert()),
      if (!_folders)
        SliverToBoxAdapter(
          child: StatusCounters(
            working: offline ? 0 : running.length,
            waiting: offline ? 0 : attention.length,
            done: doneToday,
            filter: _monitorFilter,
            onFilter: (f) => setState(() => _monitorFilter = f),
          ),
        ),
      if (widget.folder?.path != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(NX.pad, 10, NX.pad, 0),
            child: SelectableText(
              widget.folder!.path!,
              style: const TextStyle(color: NX.textFaint, fontSize: 12),
            ),
          ),
        ),
      if (!offline && !_repo.supported)
        SliverToBoxAdapter(
          child: ListTile(
            title: const Text('Update your PC host to see all PC chats'),
            trailing: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const AgentScreen()),
              ),
              child: const Text('NexusLink chats'),
            ),
          ),
        ),
      for (final health in _health.where((row) => row['state'] == 'error'))
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(NX.pad, 8, NX.pad, 0),
            child: NxCard(
              accent: NX.waiting,
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    color: NX.waiting,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      health['reason'] as String? ??
                          'This app could not be read.',
                      style: const TextStyle(fontSize: 12.5, color: NX.textDim),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _retrySource(health),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ),
      if (_error != null)
        SliverToBoxAdapter(
          child: ListTile(
            title: Text(_error!),
            trailing: TextButton(
              onPressed: () => _load(),
              child: const Text('Retry'),
            ),
          ),
        ),
      if (_loading)
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        )
      else if (_folders)
        ..._folderSlivers(emptyText)
      else if (_arena)
        SliverToBoxAdapter(
          child: ArenaView(
            chats: _arenaChats(
              _monitorFilter == 'all'
                  ? [...attention, ...running, ...rest]
                  : all.where((c) => c.matchesMonitor(_monitorFilter)).toList(),
            ),
            offline: offline || _saved,
            onOpen: _open,
            onLongPress: _chatActions,
          ),
        )
      else ...[
        if (showAttention && attention.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: NxSectionHeader(
              'Needs you',
              count: attention.length,
              color: NX.waiting,
            ),
          ),
          SliverList.list(
            children: [
              for (final chat in attention)
                _dismissible(
                  chat,
                  LiveAgentCard(
                    key: ValueKey(chat.id),
                    chat: chat,
                    offline: offline || _saved,
                    onOpen: () => _open(chat),
                    onLongPress: () => _chatActions(chat),
                  ),
                ),
            ],
          ),
        ],
        if (showRecent && turn.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: NxSectionHeader(
              'Your turn',
              count: turn.length,
              color: NX.accent,
            ),
          ),
          SliverList.list(
            children: [
              for (final chat in turn)
                _dismissible(
                  chat,
                  LiveAgentCard(
                    key: ValueKey(chat.id),
                    chat: chat,
                    offline: offline || _saved,
                    onOpen: () => _open(chat),
                    onLongPress: () => _chatActions(chat),
                  ),
                ),
            ],
          ),
        ],
        if (showRunning && running.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: NxSectionHeader(
              'Live now',
              count: running.length,
              color: NX.working,
            ),
          ),
          SliverList.list(
            children: [
              for (final chat in running)
                LiveAgentCard(
                  key: ValueKey(chat.id),
                  chat: chat,
                  offline: offline || _saved,
                  onOpen: () => _open(chat),
                  onLongPress: () => _chatActions(chat),
                ),
            ],
          ),
        ],
        if (top && monitorHost && _monitorFilter == 'all' && !offline)
          const SliverToBoxAdapter(child: AgentAppsStrip()),
        if (showRecent && rest.isNotEmpty) ..._recentSlivers(rest),
        if ((showAttention ? attention.length : 0) +
                (showRunning ? running.length : 0) +
                (showRecent ? rest.length + turn.length : 0) ==
            0)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                emptyText,
                textAlign: TextAlign.center,
                style: const TextStyle(color: NX.textDim),
              ),
            ),
          ),
      ],
      if (_moreLoading)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      const SliverToBoxAdapter(child: SizedBox(height: 32)),
    ];

    Widget body = RefreshIndicator(
      onRefresh: () async {
        try {
          await _repo.refresh();
          await _load(quiet: true);
          if (monitorHost) await ref.read(monitorProvider.notifier).refresh();
        } catch (_) {
          if (mounted) {
            setState(
              () => _error =
                  'Couldn’t refresh agents. Check the PC connection and retry.',
            );
          }
        }
      },
      child: CustomScrollView(
        key: PageStorageKey('chat-library:${widget.folder?.id}:$_folders'),
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: slivers,
      ),
    );
    if (top) {
      body = MonitorDemand(
        owner: 'home',
        intervalMs: 2000,
        active: tabVisible && !offline && monitorHost && !_folders,
        child: body,
      );
    }
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: top ? 64 : kToolbarHeight,
        title: top
            ? MissionTitle(
                subtitle: _syncLine(offline),
                online: !offline && !_saved,
              )
            : Text(widget.folder!.name),
        actions: [
          if (widget.folder?.path != null && !offline)
            IconButton(
              tooltip: 'Open files',
              icon: const Icon(Icons.folder_open),
              onPressed: () {
                ref.read(projectProvider.notifier).select(widget.folder!.path!);
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const WorkspaceFilesScreen(),
                  ),
                );
              },
            ),
          IconButton(
            tooltip: 'Search chats',
            icon: const Icon(Icons.search),
            onPressed: () => setState(() => _showSearch = !_showSearch),
          ),
          IconButton(
            tooltip: 'Filter by app',
            icon: Icon(
              Icons.tune,
              color: _source != null || _archived ? NX.accent : null,
            ),
            onPressed: _filters,
          ),
          IconButton(
            tooltip: 'New chat',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: offline ? null : _newChat,
          ),
          PopupMenuButton<String>(
            tooltip: 'Chat library options',
            onSelected: (value) =>
                value == 'forget' ? _forgetPc() : _clearSaved(),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'clear',
                child: Text('Clear saved chats on this phone'),
              ),
              PopupMenuItem(value: 'forget', child: Text('Forget this PC')),
            ],
          ),
        ],
      ),
      body: body,
    );
  }

  /// Keep all active agents visible; include recent work and a few quiet desks.
  List<ChatSummary> _arenaChats(List<ChatSummary> chats) {
    final active = chats.where((c) => c.needsAttention || c.running).toList();
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    final recent = chats
        .where((c) => !c.needsAttention && !c.running)
        .where((c) => c.activity?.isAfter(cutoff) == true)
        .toList();
    final others = chats.where(
      (c) => !active.contains(c) && !recent.contains(c),
    );
    final office = [...active, ...recent];
    if (office.length < 4) office.addAll(others.take(4 - office.length));
    return office;
  }

  List<Widget> _recentSlivers(List<ChatSummary> rest) {
    final out = <Widget>[];
    String? group;
    final rows = <Widget>[];
    void flush() {
      if (group == null || rows.isEmpty) return;
      out.add(SliverToBoxAdapter(child: NxSectionHeader(group)));
      out.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: NX.pad),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: NX.surface,
                borderRadius: BorderRadius.circular(NX.radius),
                border: Border.all(color: NX.line.withValues(alpha: .6)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(NX.radius),
                child: Column(children: List.of(rows)),
              ),
            ),
          ),
        ),
      );
      rows.clear();
    }

    for (final chat in rest) {
      final g = chatDateGroup(chat.activity);
      if (g != group) {
        flush();
        group = g;
      }
      if (rows.isNotEmpty) {
        rows.add(
          Divider(height: 1, indent: 58, color: NX.line.withValues(alpha: .5)),
        );
      }
      rows.add(
        RecentChatRow(
          key: ValueKey(chat.id),
          chat: chat,
          onOpen: () => _open(chat),
          onLongPress: () => _chatActions(chat),
        ),
      );
    }
    flush();
    return out;
  }

  List<Widget> _folderSlivers(String emptyText) {
    final folders = _items.map(ChatFolder.new).toList();
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(NX.pad, 8, 8, 0),
          child: Row(
            children: [
              Text(
                '${folders.length}${_cursor != null ? '+' : ''} projects',
                style: const TextStyle(color: NX.textFaint, fontSize: 12),
              ),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.sort, size: 18),
                label: Text(_sort == 'name' ? 'Name A–Z' : 'Latest activity'),
                onPressed: () async {
                  setState(() => _sort = _sort == 'name' ? 'activity' : 'name');
                  final host = await _repo.host();
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString('chat-folder-sort:$host', _sort);
                  await _load();
                },
              ),
            ],
          ),
        ),
      ),
      if (folders.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              emptyText,
              textAlign: TextAlign.center,
              style: const TextStyle(color: NX.textDim),
            ),
          ),
        ),
      SliverList.list(
        children: [
          for (final folder in folders)
            Padding(
              padding: const EdgeInsets.fromLTRB(NX.pad, 0, NX.pad, 8),
              child: NxCard(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ChatLibraryScreen(folder: folder),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: NX.accent.withValues(alpha: .12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.folder_rounded,
                        color: NX.accent,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            folder.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                          Text(
                            folder.latestTitle.isEmpty
                                ? (folder.path ?? 'No recorded folder')
                                : folder.latestTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: NX.textFaint,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    NxPill('${folder.count}', color: NX.textDim, dense: true),
                  ],
                ),
              ),
            ),
        ],
      ),
    ];
  }
}
