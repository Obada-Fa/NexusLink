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
import '../widgets/agent_activity_icon.dart';

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
  void Function()? _unsubscribe;
  RpcClient? _bound;
  bool _folders = false;
  bool _archived = false;
  bool _loading = true;
  bool _moreLoading = false;
  bool _saved = false;
  String? _source;
  String? _cursor;
  String? _error;
  String _sort = 'activity';
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
    await _load();
    _bind();
  }

  void _bind() {
    final client = ref.read(activeClientProvider);
    if (identical(client, _bound)) return;
    _unsubscribe?.call();
    _bound = client;
    if (client?.supports('chat.library.v1') == true) {
      _unsubscribe = client!.subscribe('chat-library-update', (_) {
        _debounce?.cancel();
        _debounce = Timer(
          const Duration(milliseconds: 250),
          () => unawaited(_load(quiet: true)),
        );
      });
      unawaited(
        client
            .requestMap('chat.subscribe', {'enabled': true})
            .catchError((Object error) => <String, dynamic>{}),
      );
    }
  }

  Map<String, dynamic> get _query => {
    'query': _search.text.trim(),
    'archived': _archived,
    'limit': 50,
    if (_source != null) 'source': _source,
    if (widget.folder != null) 'folderId': widget.folder!.id,
    if (_folders) 'sort': _sort,
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
                title: const Text('Archived chats'),
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

  Future<void> _clearSaved() async {
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

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(pendingTaskProvider, (_, task) {
      if (task == null) return;
      ref.read(pendingTaskProvider.notifier).select(null);
      final chat = _items
          .where((row) => row['agentSessionId'] == task)
          .firstOrNull;
      if (chat != null) {
        unawaited(_open(ChatSummary(chat)));
      } else {
        unawaited(
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => AgentScreen(initialTaskId: task),
            ),
          ),
        );
      }
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
    final needsReply = _folders
        ? <ChatSummary>[]
        : _items
              .map(ChatSummary.new)
              .where((row) => row.execution == 'needsReply')
              .toList();
    final scanning = _health.any((row) => row['state'] == 'scanning');
    final offline = status != RpcStatus.connected;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.folder?.name ?? 'Chats'),
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
            tooltip: 'Filter chats',
            icon: const Icon(Icons.filter_list),
            onPressed: _filters,
          ),
          PopupMenuButton<String>(
            tooltip: 'Chat library options',
            onSelected: (value) =>
                value == 'forget' ? _forgetPc() : _clearSaved(),
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'clear',
                child: Text('Clear saved chats on this phone'),
              ),
              const PopupMenuItem(
                value: 'forget',
                child: Text('Forget this PC'),
              ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _repo.refresh();
          await _load(quiet: true);
        },
        child: CustomScrollView(
          key: PageStorageKey('chat-library:${widget.folder?.id}:$_folders'),
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            offline
                                ? 'PC offline · Showing saved chats'
                                : 'My PC · Connected',
                          ),
                        ),
                        TextButton.icon(
                          onPressed: offline
                              ? null
                              : () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => AgentScreen(
                                      startNew: true,
                                      initialFolder: widget.folder?.path,
                                    ),
                                  ),
                                ),
                          icon: const Icon(Icons.add),
                          label: const Text('New chat'),
                        ),
                      ],
                    ),
                  ),
                  if (offline && _lastSync != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Last synced ${chatRelativeTime(DateTime.fromMillisecondsSinceEpoch(_lastSync!))}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                  if (!offline && !_repo.supported)
                    ListTile(
                      title: const Text(
                        'Update your PC host to see all PC chats',
                      ),
                      trailing: TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const AgentScreen(),
                          ),
                        ),
                        child: const Text('NexusLink chats'),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: TextField(
                      controller: _search,
                      decoration: const InputDecoration(
                        hintText: 'Search chats…',
                        prefixIcon: Icon(Icons.search),
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
                  if (widget.folder == null)
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('Recent')),
                        ButtonSegment(value: true, label: Text('Folders')),
                      ],
                      selected: {_folders},
                      onSelectionChanged: (value) {
                        setState(() {
                          _folders = value.first;
                          _items = [];
                          _cursor = null;
                        });
                        unawaited(_load());
                      },
                    ),
                  if (_folders)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        icon: const Icon(Icons.sort),
                        label: Text(
                          _sort == 'name' ? 'Name A–Z' : 'Latest activity',
                        ),
                        onPressed: () async {
                          setState(
                            () => _sort = _sort == 'name' ? 'activity' : 'name',
                          );
                          final host = await _repo.host();
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setString(
                            'chat-folder-sort:$host',
                            _sort,
                          );
                          await _load();
                        },
                      ),
                    ),
                  if (widget.folder?.path != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(widget.folder!.path!),
                    ),
                  if (needsReply.isNotEmpty)
                    ListTile(
                      leading: const Icon(Icons.pending_actions),
                      title: Text(
                        'Needs your attention · ${needsReply.length}',
                      ),
                      onTap: () => _open(needsReply.first),
                    ),
                  for (final health in _health.where(
                    (row) => row['state'] == 'error',
                  ))
                    ListTile(
                      dense: true,
                      title: Text(
                        health['reason'] as String? ??
                            'This app could not be read.',
                      ),
                      trailing: TextButton(
                        onPressed: () async {
                          await _repo.client?.requestMap('chat.refresh', {
                            'source': health['source'],
                          });
                          await _load(quiet: true);
                        },
                        child: const Text('Retry'),
                      ),
                    ),
                  if (_error != null)
                    ListTile(
                      title: Text(_error!),
                      trailing: TextButton(
                        onPressed: () => _load(),
                        child: const Text('Retry'),
                      ),
                    ),
                ],
              ),
            ),
            if (_loading)
              const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator()),
              )
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (ctx, index) {
                    if (_items.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          _search.text.isNotEmpty || _source != null
                              ? 'No search results'
                              : scanning
                              ? 'Still finding chats…'
                              : offline
                              ? 'No saved chats on this phone yet'
                              : 'No chats yet',
                          textAlign: TextAlign.center,
                        ),
                      );
                    }
                    if (index == _items.length) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (_folders) {
                      final folder = ChatFolder(_items[index]);
                      return ListTile(
                        minVerticalPadding: 12,
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(folder.name),
                        subtitle: Text(
                          '${folder.path ?? 'No recorded folder'}\nLatest: ${folder.latestTitle}',
                        ),
                        isThreeLine: true,
                        trailing: Text('${folder.count} chats'),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ChatLibraryScreen(folder: folder),
                          ),
                        ),
                      );
                    }
                    final chat = ChatSummary(_items[index]);
                    final group = chatDateGroup(chat.activity);
                    final first =
                        index == 0 ||
                        group !=
                            chatDateGroup(
                              ChatSummary(_items[index - 1]).activity,
                            );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (first)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
                            child: Text(
                              group,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                        ListTile(
                          minVerticalPadding: 12,
                          leading: AgentMark(agentId: chat.source, size: 24),
                          title: Text(
                            chat.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            [
                              if (chat.preview.isNotEmpty)
                                chat.preview.replaceAll('\n', ' '),
                              '${chat.sourceName} · ${chat.folderName}',
                              if (_saved)
                                'Saved copy'
                              else if (chat.status != null)
                                chat.status!,
                            ].join('\n'),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: SizedBox(
                            width: 72,
                            child: Text(
                              chatRelativeTime(chat.activity),
                              textAlign: TextAlign.end,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          onTap: () => _open(chat),
                        ),
                        const Divider(height: 1, indent: 16, endIndent: 16),
                      ],
                    );
                  },
                  childCount: _items.isEmpty
                      ? 1
                      : _items.length + (_moreLoading ? 1 : 0),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
