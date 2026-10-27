// Native chat UI for AI agents that run on the PC (Claude Code, Cursor CLI,
// OpenCode, Antigravity, or the built-in demo agent). The phone never sees a
// terminal — tool calls become cards, assistant text is markdown, and history
// survives reconnects.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../rpc/models.dart';
import '../rpc/rpc_client.dart';
import '../services/notification_service.dart';
import '../state/agent_history.dart';
import '../state/connection.dart';
import '../state/last_cwd.dart';
import '../state/terminal_busy.dart';
import '../widgets/agent_activity_icon.dart';
import '../widgets/code_block_builder.dart';
import '../widgets/file_viewer_modal.dart';
import '../widgets/terminal_glow_border.dart';
import '../util/voice_input.dart';
import '../widgets/link_actions.dart';
import '../widgets/not_connected_view.dart';
import 'cwd_picker.dart';
import 'terminal_screen.dart';
import '../workspace/project.dart';
import '../workspace/changes_screen.dart';
import '../chats/chat_models.dart';
import '../chats/chat_repository.dart';
import '../theme/nexus_theme.dart';
import '../theme/nx_widgets.dart';

/// PC conversations will get their own screen. Skip the slow
/// `agent.listHostChats` scan on this tab until then.
const bool kAgentHostChatsInAgentTab = false;

class AgentScreen extends ConsumerStatefulWidget {
  final ChatSummary? libraryChat;
  final bool startNew;
  final String? initialFolder;
  final String? initialTaskId;
  const AgentScreen({
    super.key,
    this.libraryChat,
    this.startNew = false,
    this.initialFolder,
    this.initialTaskId,
  });

  @override
  ConsumerState<AgentScreen> createState() => _AgentScreenState();
}

class _PendingPhoto {
  final String name;
  final String mime;
  final Uint8List bytes;
  _PendingPhoto({required this.name, required this.mime, required this.bytes});
}

class _AgentScreenState extends ConsumerState<AgentScreen>
    with WidgetsBindingObserver {
  List<AgentInfo> _agents = [];
  List<AgentSessionInfo> _sessions = [];
  List<AgentHostChat> _hostChats = [];
  AgentSessionInfo? _active;
  final _transcript = AgentTranscript();

  /// Display list of the last build (host events + phone notes).
  List<AgentEvent> _display = const [];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _imagePicker = ImagePicker();
  final _photos = <_PendingPhoto>[];
  final _thumbsBySeq = <int, List<Uint8List>>{};
  List<Uint8List>? _pendingThumbs;

  /// Permission requests for chats that are not on screen, keyed by
  /// `sessionId:requestId`. Shown in a banner and asked when that chat opens.
  final _pendingApprovals = <String, ({String sessionId, AgentEvent event})>{};
  bool _stopping = false;
  final _resolvedApprovals = <String>{};
  String _mode = 'agent';
  String _thinking = 'medium';
  String? _model;
  List<AgentModelOption> _liveModels = [];
  bool _loading = true;
  bool _busy = false;
  bool _sending = false;
  int _chatTab = 0;
  final Set<String> _terminalVisited = {};
  final Map<String, String> _drafts = {};
  String _taskQuery = '';
  String? _agentFilter;
  bool _showArchived = false;
  bool _hasOlder = false;
  bool _newActivity = false;
  Timer? _draftTimer;
  String? _error;
  final SpeechToText _speech = SpeechToText();
  bool _isListening = false;
  bool _userWantsListen = false;
  bool _listenStarting = false;
  bool _listenSessionWasActive = false;
  int _listenGen = 0;
  String _preListeningText = '';
  final _unsubs = <void Function()>[];
  RpcClient? _boundClient;
  int _syncGen = 0;
  GitWorkingTree? _gitTree;
  String? _libraryOlder;
  String? _historyNotice;
  bool _savedCopy = false;
  String? _deliveryOperation;
  Timer? _libraryTimer;
  bool _librarySyncing = false;
  bool _startedNew = false;
  bool _libraryForeground = true;
  bool _wasBackgrounded = false;

  /// Live library updates: refetch on `chat-library-update`, at most every
  /// 700 ms, re-running once if a push lands mid-fetch.
  Timer? _libraryPushTimer;
  bool _libraryDirty = false;
  DateTime _lastLibraryFetch = DateTime.fromMillisecondsSinceEpoch(0);
  static const _libraryThrottle = Duration(milliseconds: 700);
  ChatSummary? _librarySummary;
  final Map<String, Map<String, dynamic>> _libraryEvents = {};
  String? _libraryRevision;
  ChatSummary get _chatSummary => _librarySummary ?? widget.libraryChat!;
  bool get _isLibrary => widget.libraryChat != null;
  bool get _replyAllowed =>
      !_isLibrary ||
      (_chatSummary.canReply &&
          !_savedCopy &&
          _client?.status == RpcStatus.connected &&
          _deliveryOperation == null);

  RpcClient? get _client => ref.read(activeClientProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _input.addListener(_draftChanged);
    if (_isLibrary) {
      // Fallback poll; pushes normally refresh much sooner.
      _libraryTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (_libraryForeground &&
            _client?.status == RpcStatus.connected &&
            DateTime.now().difference(_lastLibraryFetch) >
                const Duration(seconds: 4)) {
          unawaited(_loadLibrary(quiet: true));
        }
      });
    }
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _libraryForeground = true;
      // Only a real trip to the background (not the notification shade or a
      // permission dialog) can have dropped socket events.
      if (_wasBackgrounded) {
        _wasBackgrounded = false;
        unawaited(_onForeground());
      } else if (_libraryDirty) {
        _scheduleLibraryRefresh();
      }
      return;
    }
    if (state != AppLifecycleState.paused &&
        state != AppLifecycleState.hidden) {
      return;
    }
    _wasBackgrounded = true;
    _libraryForeground = false;
    if (_isLibrary) {
      final chat = _chatSummary;
      unawaited(
        ref
            .read(chatCacheProvider)
            .saveDraft(
              chat.hostId,
              chat.id,
              _input.text,
              position: _scroll.hasClients ? _scroll.offset : null,
            ),
      );
    }
  }

  /// Socket events are dropped while the phone is backgrounded, so pull a
  /// fresh host snapshot when the user comes back — same as reopening the chat.
  Future<void> _onForeground({bool syncTranscript = true}) async {
    await ref.read(connectionProvider.notifier).ensureConnected();
    if (!mounted) return;
    final client = _client;
    if (client == null || client.status != RpcStatus.connected) return;
    if (!identical(client, _boundClient)) {
      await _load();
      syncTranscript = true;
    }
    await _refreshSnapshot(syncTranscript: syncTranscript);
  }

  Future<void> _load() async {
    final client = _client;
    if (_isLibrary && _active == null) await _loadLibrary(savedOnly: true);
    if (_isLibrary &&
        (client == null || client.status != RpcStatus.connected)) {
      await _loadLibrary();
      return;
    }
    if (client == null) {
      setState(() {
        _loading = false;
        _error = 'Not connected to the PC.';
      });
      return;
    }
    try {
      final agentsRaw = await client.request('agent.list') as List<dynamic>;
      final sessionsRaw =
          await client.request('agent.listSessions') as List<dynamic>;
      List<dynamic> hostRaw = const [];
      if (kAgentHostChatsInAgentTab) {
        try {
          hostRaw = await client.requestList(
            'agent.listHostChats',
            const {},
            const Duration(seconds: 25),
          );
        } catch (_) {
          // Older hosts have no listHostChats.
        }
      }
      for (final u in _unsubs) {
        u();
      }
      _unsubs.clear();
      _unsubs.add(client.subscribe('agent-event', _onPush));
      _unsubs.add(client.subscribe('agent-session-update', _onSessionUpdate));
      _unsubs.add(client.subscribe('agent-session-deleted', _onSessionDelete));
      if (_isLibrary && client.supports('chat.library.v1')) {
        _unsubs.add(
          client.subscribe(
            'chat-library-update',
            (_) => _scheduleLibraryRefresh(),
          ),
        );
        // Per-connection on the host; harmless if the list already asked.
        unawaited(
          client
              .requestMap('chat.subscribe', {'enabled': true})
              .catchError((Object _) => <String, dynamic>{}),
        );
      }
      _boundClient = client;
      if (!mounted) return;
      setState(() {
        _agents = agentsRaw
            .map((e) => AgentInfo.fromJson(e as Map<String, dynamic>))
            .toList();
        _sessions = sessionsRaw
            .map((e) => AgentSessionInfo.fromJson(e as Map<String, dynamic>))
            .toList();
        _hostChats = hostRaw
            .whereType<Map>()
            .map((e) => AgentHostChat.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        for (final a in _agents) {
          if (a.icon != null) registerAgentIcon(a.id, a.icon);
        }
        for (final s in _sessions) {
          if (s.icon != null) registerAgentIcon(s.agent, s.icon);
        }
        for (final c in _hostChats) {
          if (c.icon != null) registerAgentIcon(c.agent, c.icon);
        }
        _loading = false;
        _error = null;
      });
      _openPendingTask();
      unawaited(_seedBackgroundApprovals());
      if (widget.initialTaskId != null && _active == null) {
        final task = _sessions
            .where((session) => session.agentSessionId == widget.initialTaskId)
            .firstOrNull;
        if (task != null) await _openSession(task);
      }
      if (_isLibrary) await _loadLibrary();
      if (widget.startNew &&
          !_startedNew &&
          _agents.any((agent) => agent.available)) {
        _startedNew = true;
        final prefs = await SharedPreferences.getInstance();
        final last = prefs.getString('chat-last-source:${client.hostId}');
        final agent =
            _agents
                .where((agent) => agent.available && agent.id == last)
                .firstOrNull ??
            _agents.firstWhere((agent) => agent.available);
        if (mounted) await _newChat(agent, cwd: widget.initialFolder);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _refreshSnapshot({bool syncTranscript = true}) async {
    if (_isLibrary) {
      await _loadLibrary(quiet: true);
      return;
    }
    final client = _client;
    if (client == null || client.status != RpcStatus.connected) return;
    final gen = ++_syncGen;
    final activeId = _active?.agentSessionId;
    final shouldSyncTranscript = syncTranscript && activeId != null;
    try {
      final sessionsRaw =
          await client.request('agent.listSessions') as List<dynamic>;
      List<dynamic> hostRaw = const [];
      if (kAgentHostChatsInAgentTab) {
        try {
          hostRaw = await client.requestList(
            'agent.listHostChats',
            const {},
            const Duration(seconds: 25),
          );
        } catch (_) {}
      }
      List<AgentEvent> history = const [];
      if (shouldSyncTranscript) {
        if (client.supports('agent.historyPage')) {
          var cursor = _transcript.latestHostSeq;
          final missing = <AgentEvent>[];
          while (mounted && gen == _syncGen) {
            final page = await client.requestMap('agent.historyPage', {
              'agentSessionId': activeId,
              'afterSeq': cursor,
              'limit': 200,
            });
            final events = (page['events'] as List)
                .map((e) => AgentEvent.fromJson(Map<String, dynamic>.from(e)))
                .toList();
            missing.addAll(events);
            if (events.isEmpty || page['hasMore'] != true) break;
            cursor = events.last.seq;
          }
          history = missing;
        } else {
          final raw = await client.requestList('agent.history', {
            'agentSessionId': activeId,
          });
          history = raw
              .map((e) => AgentEvent.fromJson(Map<String, dynamic>.from(e)))
              .toList();
        }
      }
      if (!mounted || gen != _syncGen) return;
      setState(() {
        _sessions = sessionsRaw
            .map((e) => AgentSessionInfo.fromJson(e as Map<String, dynamic>))
            .toList();
        _hostChats = hostRaw
            .whereType<Map>()
            .map((e) => AgentHostChat.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        for (final s in _sessions) {
          if (s.icon != null) registerAgentIcon(s.agent, s.icon);
        }
        for (final c in _hostChats) {
          if (c.icon != null) registerAgentIcon(c.agent, c.icon);
        }
        if (activeId != null) {
          AgentSessionInfo? match;
          for (final s in _sessions) {
            if (s.agentSessionId == activeId) {
              match = s;
              break;
            }
          }
          if (match != null) {
            _active = match;
            // Same rule as _onSessionUpdate: a stale busy:true snapshot
            // must not resurrect Stop after the phone already ended the turn.
            if (!match.busy) _busy = false;
          }
          if (shouldSyncTranscript && _active?.agentSessionId == activeId) {
            // Merge host events only; phone notes live in their own key
            // space and are re-interleaved for display.
            final current = _transcript.host;
            final merged = mergeAgentHistory(history, current);
            _transcript.replaceHost(
              merged.isEmpty && current.isNotEmpty ||
                      (_busy && merged.length < current.length)
                  ? current
                  : merged,
            );
            if (!_busy && _transcript.hasOpenTools) {
              _transcript.settleOpenTools('Interrupted — host restarted.');
            }
          }
        }
      });
      if (shouldSyncTranscript) {
        await _syncApprovals(activeId);
        _scrollToEnd();
      }
      unawaited(_seedBackgroundApprovals());
      unawaited(_refreshGitTree());
    } catch (_) {
      // Stay on the last known transcript; the next resume will try again.
    }
  }

  void _scheduleLibraryRefresh() {
    if (!_isLibrary || !mounted) return;
    if (!_libraryForeground) {
      _libraryDirty = true;
      return;
    }
    if (_libraryPushTimer?.isActive == true) return;
    final wait =
        _libraryThrottle - DateTime.now().difference(_lastLibraryFetch);
    _libraryPushTimer = Timer(wait.isNegative ? Duration.zero : wait, () {
      if (mounted) unawaited(_loadLibrary(quiet: true));
    });
  }

  Future<void> _loadLibrary({
    bool quiet = false,
    bool older = false,
    bool savedOnly = false,
  }) async {
    if (!_isLibrary || !mounted) return;
    if (_librarySyncing) {
      if (!savedOnly) _libraryDirty = true;
      return;
    }
    _librarySyncing = true;
    if (!savedOnly) {
      _libraryDirty = false;
      _lastLibraryFetch = DateTime.now();
    }
    final chat = widget.libraryChat!;
    final repository = ref.read(chatRepositoryProvider);
    final generation = ++_syncGen;
    final first = _active == null;
    try {
      final page = savedOnly
          ? await repository.cache.history(chat.hostId, chat.id)
          : await repository.history(
              chat,
              olderCursor: older ? _libraryOlder : null,
            );
      if (page == null) return;
      if (savedOnly) page['saved'] = true;
      if (!mounted ||
          generation != _syncGen ||
          !identical(repository, ref.read(chatRepositoryProvider))) {
        return;
      }
      if (page['restart'] == true) {
        _libraryOlder = null;
        _libraryEvents.clear();
        _librarySyncing = false;
        await _loadLibrary(quiet: quiet);
        return;
      }
      final current = page['chat'] is Map
          ? ChatSummary(Map<String, dynamic>.from(page['chat'] as Map))
          : _chatSummary;
      final raw = (page['events'] as List? ?? [])
          .map((event) => Map<String, dynamic>.from(event as Map))
          .toList();
      if (_libraryRevision != null &&
          _libraryRevision != page['revision'] &&
          page['appendOnly'] != true &&
          !savedOnly) {
        _libraryEvents.clear();
      }
      _libraryRevision = page['revision'] as String?;
      for (final event in raw) {
        if (event['historical'] == true &&
            event['kind'] == 'permission-request') {
          event['kind'] = 'status';
          event['text'] =
              'Historical permission request · ${event['toolName'] ?? 'Work details'}';
        }
        _libraryEvents[event['id'] as String? ?? '${event['seq']}'] = event;
      }
      final ordered = _libraryEvents.values.toList()
        ..sort((a, b) => (a['seq'] as num).compareTo(b['seq'] as num));
      final loaded = ordered.map(AgentEvent.fromJson).toList();
      final previous = _transcript.host;
      final hasNew =
          loaded.length != previous.length ||
          (loaded.isNotEmpty &&
              previous.isNotEmpty &&
              loaded.last.text != previous.last.text);
      final oldExtent = _scroll.hasClients
          ? _scroll.position.maxScrollExtent
          : 0.0;
      final oldOffset = _scroll.hasClients ? _scroll.offset : 0.0;
      setState(() {
        _librarySummary = current;
        _savedCopy = page['saved'] == true;
        _historyNotice =
            page['reason'] as String? ??
            (page['completeness'] == 'partial'
                ? 'Some history is unavailable or content was truncated.'
                : null);
        _active = AgentSessionInfo(
          agentSessionId: current.sessionId ?? 'library:${chat.id}',
          agent: current.source,
          cwd: current.folderPath ?? '',
          title: current.title,
          busy: !_stopping && current.execution == 'working',
          status: 'running',
          hostChatId: current.json['nativeId'] as String?,
        );
        if (!_stopping) _busy = current.execution == 'working';
        _transcript.replaceHost(loaded);
        _libraryOlder = page['olderCursor'] as String?;
        _hasOlder = !_savedCopy && _libraryOlder != null;
        _loading = false;
        _error = null;
      });
      if (first) {
        final draft = await ref
            .read(chatCacheProvider)
            .draft(chat.hostId, chat.id);
        if (!mounted || generation != _syncGen) return;
        _input.text = draft?['text'] as String? ?? '';
        _deliveryOperation = draft?['operation'] as String?;
        if (chat.folderPath != null) {
          ref.read(projectProvider.notifier).select(chat.folderPath!);
        }
        final position = (draft?['position'] as num?)?.toDouble();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.jumpTo(
              (position ?? _scroll.position.maxScrollExtent)
                  .clamp(0.0, _scroll.position.maxScrollExtent)
                  .toDouble(),
            );
          }
        });
      } else if (older) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.jumpTo(
              (oldOffset + _scroll.position.maxScrollExtent - oldExtent)
                  .clamp(0.0, _scroll.position.maxScrollExtent)
                  .toDouble(),
            );
          }
        });
      } else if (hasNew) {
        _scrollToEnd();
      }
      if (current.json['managed'] == true &&
          current.sessionId != null &&
          !_savedCopy) {
        await _syncApprovals(current.sessionId!);
      }
    } catch (error) {
      if (mounted && generation == _syncGen) {
        setState(() {
          _loading = false;
          _historyNotice =
              'Couldn’t refresh this conversation. Your saved messages and draft remain available.';
        });
      }
    } finally {
      _librarySyncing = false;
      if (_libraryDirty && mounted) _scheduleLibraryRefresh();
    }
  }

  Future<void> _sendLibrary() async {
    if (!_replyAllowed || _sending || _input.text.trim().isEmpty) return;
    final chat = _chatSummary;
    final isWorking =
        _busy ||
        chat.execution == 'working' ||
        (chat.json['capabilities'] as Map?)?['safety'] == 'busy';
    bool interrupt = false;
    if (isWorking) {
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Chat is working on PC'),
          content: const Text(
            'This conversation is currently running on your PC.\n\n'
            'Do you want to interrupt it and send your message, or let it finish running?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('let_run'),
              child: const Text('Let it run'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop('interrupt'),
              child: const Text('Interrupt & Send'),
            ),
          ],
        ),
      );
      if (choice != 'interrupt') return;
      interrupt = true;
      if (mounted) setState(() => _setBusy(false));
    }
    final text = _input.text;
    final operation = 'chat-${DateTime.now().microsecondsSinceEpoch}';
    await ref.read(chatCacheProvider).saveDraft(chat.hostId, chat.id, text);
    await ref
        .read(chatCacheProvider)
        .saveOperation(chat.hostId, chat.id, operation);
    setState(() {
      _sending = true;
      _deliveryOperation = operation;
    });
    try {
      final outcome = await ref
          .read(chatRepositoryProvider)
          .send(
            chat,
            text,
            operation,
            model: _model,
            thinking: _modelSupportsEffort ? _thinking : null,
            mode: _mode,
            interrupt: interrupt,
            images: [
              for (final photo in _photos)
                {
                  'name': photo.name,
                  'mime': photo.mime,
                  'data': base64Encode(photo.bytes),
                },
            ],
          );
      if (!mounted) return;
      if (outcome['state'] == 'delivered') {
        _input.clear();
        _photos.clear();
        _deliveryOperation = null;
        await ref
            .read(chatCacheProvider)
            .saveOperation(chat.hostId, chat.id, null);
        await ref.read(chatCacheProvider).saveDraft(chat.hostId, chat.id, '');
        await _loadLibrary(quiet: true);
      } else if (outcome['state'] == 'rejected') {
        _deliveryOperation = null;
        _toast(
          outcome['reason'] as String? ??
              'Reply unavailable. Your draft is saved.',
        );
        await ref
            .read(chatCacheProvider)
            .saveOperation(chat.hostId, chat.id, null);
      } else {
        _toast('Delivery uncertain. Check delivery before trying again.');
      }
    } catch (error) {
      if (mounted) {
        _toast(
          'Delivery uncertain. Your draft is saved. Check delivery after reconnecting.',
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _checkDelivery() async {
    final operation = _deliveryOperation;
    if (operation == null || _client?.status != RpcStatus.connected) return;
    try {
      final status = await _client!.request('chat.sendStatus', {
        'operationId': operation,
      });
      if (!mounted) return;
      if (status is Map && status['state'] == 'delivered') {
        setState(() {
          _deliveryOperation = null;
          _input.clear();
        });
        await ref
            .read(chatCacheProvider)
            .saveOperation(_chatSummary.hostId, _chatSummary.id, null);
        await _loadLibrary(quiet: true);
      } else if (status is Map && status['state'] == 'rejected') {
        setState(() => _deliveryOperation = null);
        await ref
            .read(chatCacheProvider)
            .saveOperation(_chatSummary.hostId, _chatSummary.id, null);
        _toast('Reply was not dispatched. Your draft is saved.');
      } else {
        _toast(
          'Delivery is still uncertain. Check the original conversation on the PC.',
        );
      }
    } catch (error) {
      if (mounted) _toast('Reconnect to the PC to check delivery.');
    }
  }

  /// A chat with parked approvals was just opened: they are no longer
  /// "background", and the first unanswered one is asked right away.
  void _flushPendingApproval() {
    final id = _active?.agentSessionId;
    if (!mounted || id == null) return;
    if (_isLibrary && (_savedCopy || _chatSummary.json['managed'] != true)) {
      return;
    }
    final parked = _pendingApprovals.entries
        .where((entry) => entry.value.sessionId == id)
        .toList();
    if (parked.isEmpty) return;
    setState(() {
      for (final entry in parked) {
        _pendingApprovals.remove(entry.key);
      }
    });
    final ask = parked
        .map((entry) => entry.value.event)
        .where((e) => e.refId != null && !_resolvedApprovals.contains(e.refId))
        .firstOrNull;
    if (ask != null) unawaited(_askPermission(ask));
  }

  /// Approvals that were already waiting before this screen existed (or
  /// arrived while the socket was down) for chats that are not open.
  Future<void> _seedBackgroundApprovals() async {
    final client = _client;
    if (client == null ||
        client.status != RpcStatus.connected ||
        !client.supports('agent.pendingApprovals')) {
      return;
    }
    final activeId = _active?.agentSessionId;
    final waiting = _sessions
        .where(
          (s) =>
              !s.archived &&
              s.taskState == 'waiting' &&
              s.agentSessionId != activeId,
        )
        .take(6)
        .toList();
    final found = <String, ({String sessionId, AgentEvent event})>{};
    for (final session in waiting) {
      try {
        final pending = await client.requestList('agent.pendingApprovals', {
          'agentSessionId': session.agentSessionId,
        });
        for (final raw in pending.whereType<Map>()) {
          final event = AgentEvent.fromJson(Map<String, dynamic>.from(raw));
          if (event.refId == null) continue;
          found['${session.agentSessionId}:${event.refId}'] = (
            sessionId: session.agentSessionId,
            event: event,
          );
        }
      } catch (_) {}
    }
    if (!mounted) return;
    final stillWaiting = waiting.map((s) => s.agentSessionId).toSet();
    setState(() {
      // Sessions no longer waiting have nothing left to answer.
      _pendingApprovals.removeWhere(
        (_, value) =>
            value.sessionId != _active?.agentSessionId &&
            !stillWaiting.contains(value.sessionId) &&
            _sessions.any((s) => s.agentSessionId == value.sessionId),
      );
      _pendingApprovals.addAll(found);
    });
  }

  List<({String sessionId, AgentEvent event})> get _backgroundApprovals => [
    for (final value in _pendingApprovals.values)
      if (value.sessionId != _active?.agentSessionId) value,
  ];

  String _sessionTitle(String sessionId) =>
      _sessions
          .where((s) => s.agentSessionId == sessionId)
          .firstOrNull
          ?.title ??
      'Another chat';

  Widget _approvalBanner() {
    final waiting = _backgroundApprovals;
    if (waiting.isEmpty) return const SizedBox.shrink();
    final first = waiting.first;
    final label = waiting.length == 1
        ? '${_sessionTitle(first.sessionId)} needs approval · '
              '${first.event.toolName ?? 'action'}'
        : '${waiting.length} approvals waiting in other chats';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: NxCard(
        accent: NX.waiting,
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        onTap: _reviewApprovals,
        child: Row(
          children: [
            const LiveDot(color: NX.waiting, size: 7),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: NX.text, fontSize: 13),
              ),
            ),
            TextButton(
              onPressed: _reviewApprovals,
              child: const Text('Review'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _reviewApprovals() async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, refresh) {
          final waiting = _backgroundApprovals;
          if (waiting.isEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (sheetContext.mounted) Navigator.of(sheetContext).pop();
            });
          }
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(sheetContext).size.height * .75,
              ),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Waiting for your approval',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  for (final item in waiting)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: NxCard(
                        accent: NX.waiting,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              _sessionTitle(item.sessionId),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                color: NX.text,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              item.event.text ??
                                  'Allow ${item.event.toolName ?? 'this action'}?',
                              style: const TextStyle(color: NX.waiting),
                            ),
                            if ((item.event.toolInput ?? '').isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  item.event.toolInput!,
                                  maxLines: 6,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    color: NX.textDim,
                                  ),
                                ),
                              ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                if (!_isLibrary)
                                  TextButton(
                                    onPressed: () {
                                      Navigator.of(sheetContext).pop();
                                      final session = _sessions
                                          .where(
                                            (s) =>
                                                s.agentSessionId ==
                                                item.sessionId,
                                          )
                                          .firstOrNull;
                                      if (session != null) {
                                        unawaited(_openSession(session));
                                      }
                                    },
                                    child: const Text('Open chat'),
                                  ),
                                const Spacer(),
                                OutlinedButton(
                                  onPressed: () async {
                                    await _answerApproval(
                                      item.sessionId,
                                      item.event.refId!,
                                      false,
                                    );
                                    refresh(() {});
                                  },
                                  child: const Text('Deny'),
                                ),
                                const SizedBox(width: 8),
                                FilledButton(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: NX.waiting,
                                    foregroundColor: Colors.black,
                                  ),
                                  onPressed: () async {
                                    await _answerApproval(
                                      item.sessionId,
                                      item.event.refId!,
                                      true,
                                    );
                                    refresh(() {});
                                  },
                                  child: const Text('Approve'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Answers one approval via `agent.permission`: true when the PC accepted
  /// it, false when the PC refused it (e.g. expired), null when unreachable.
  Future<bool?> _answerApproval(
    String sessionId,
    String requestId,
    bool allow,
  ) async {
    final client = _client;
    if (client == null || client.status != RpcStatus.connected) {
      _toast('Reconnect to the PC to answer this approval.');
      return null;
    }
    try {
      final res = await client.request('agent.permission', {
        'agentSessionId': sessionId,
        'requestId': requestId,
        'allow': allow,
      });
      if (!mounted) return false;
      if (res is Map && res['ok'] == false) {
        final expired = res['reason'] == 'request already expired';
        _toast(
          expired
              ? 'That request already expired on the PC.'
              : 'The PC could not accept that answer.',
        );
        if (expired) {
          setState(() => _pendingApprovals.remove('$sessionId:$requestId'));
        }
        return false;
      }
      setState(() => _pendingApprovals.remove('$sessionId:$requestId'));
      if (sessionId != _active?.agentSessionId) {
        _toast(allow ? 'Approved.' : 'Denied.');
      }
      return true;
    } catch (e) {
      if (mounted) _toast('Could not reach the PC: $e');
      return null;
    }
  }

  String _draftKey(String id) =>
      'task-draft:${_client?.hostId ?? _client?.wsUrl}:$id';
  void _draftChanged() {
    final id = _active?.agentSessionId;
    if (id == null) return;
    _drafts[id] = _input.text;
    final text = _input.text;
    final key = _draftKey(id);
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 500), () async {
      if (_isLibrary) {
        final chat = widget.libraryChat!;
        await ref
            .read(chatCacheProvider)
            .saveDraft(
              chat.hostId,
              chat.id,
              text,
              position: _scroll.hasClients ? _scroll.offset : null,
            );
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, text);
    });
  }

  Future<void> _restoreDraft(String id) async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted || _active?.agentSessionId != id) return;
    _input.text = _drafts[id] ?? prefs.getString(_draftKey(id)) ?? '';
  }

  Future<void> _syncApprovals(String id) async {
    final client = _client;
    if (client == null || !client.supports('agent.pendingApprovals')) return;
    final pending = await client.requestList('agent.pendingApprovals', {
      'agentSessionId': id,
    });
    if (!mounted || _active?.agentSessionId != id) return;
    final activeIds = pending.map((e) => e['refId'] as String?).toSet();
    setState(() {
      for (final event in _transcript.host.where(
        (e) => e.kind == 'permission-request' && e.refId != null,
      )) {
        if (!activeIds.contains(event.refId)) {
          _resolvedApprovals.add(event.refId!);
        }
      }
    });
  }

  Future<void> _older() async {
    if (_isLibrary) {
      await _loadLibrary(older: true);
      return;
    }
    final id = _active?.agentSessionId;
    final client = _client;
    final oldest = _transcript.oldestHostSeq;
    if (id == null || client == null || oldest == null) return;
    try {
      final page = await client.requestMap('agent.historyPage', {
        'agentSessionId': id,
        'beforeSeq': oldest,
      });
      if (!mounted || _active?.agentSessionId != id) return;
      final old = (page['events'] as List)
          .map((e) => AgentEvent.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      setState(() {
        _transcript.addOlder(old);
        _hasOlder = page['hasMore'] == true;
      });
    } catch (e) {
      if (mounted) _toast('$e');
    }
  }

  void _onSessionUpdate(Map<String, dynamic> msg) {
    final raw = msg['session'];
    if (raw is! Map<String, dynamic>) return;
    final updated = AgentSessionInfo.fromJson(raw);
    if (updated.icon != null) registerAgentIcon(updated.agent, updated.icon);
    if (!mounted) return;
    setState(() {
      final idx = _sessions.indexWhere(
        (s) => s.agentSessionId == updated.agentSessionId,
      );
      if (idx != -1) {
        _sessions[idx] = updated;
      } else {
        _sessions.insert(0, updated);
      }
      if (_active?.agentSessionId == updated.agentSessionId) {
        _active = updated;
        // Never resurrect Working from a stale busy:true packet after
        // the turn already finished on the phone.
        if (!updated.busy) {
          _busy = false;
          if (_transcript.hasOpenTools) {
            _transcript.settleOpenTools(
              _stopping
                  ? 'Stopped.'
                  : 'Interrupted — host is no longer running this turn.',
            );
          }
        }
      }
    });
  }

  void _onSessionDelete(Map<String, dynamic> msg) {
    final id = msg['agentSessionId'];
    if (id is! String) return;
    if (!mounted) return;
    setState(() {
      _sessions.removeWhere((s) => s.agentSessionId == id);
      if (_active?.agentSessionId == id) {
        _active = null;
        _transcript.clear();
        _busy = false;
      }
      _pendingApprovals.removeWhere((_, value) => value.sessionId == id);
    });
  }

  void _setBusy(bool busy) {
    _busy = busy;
    final session = _active;
    if (session == null) return;
    final updated = session.copyWith(busy: busy);
    _active = updated;
    final idx = _sessions.indexWhere(
      (s) => s.agentSessionId == session.agentSessionId,
    );
    if (idx != -1) _sessions[idx] = updated;
  }

  void _onPush(Map<String, dynamic> msg) {
    final sessionId = msg['agentSessionId'] as String?;
    final ev = msg['event'];
    if (ev is! Map<String, dynamic>) return;
    final parsed = AgentEvent.fromJson(ev);
    if (parsed.kind == 'status' &&
        parsed.refId != null &&
        (parsed.text ?? '').startsWith('Approval ')) {
      final settled =
          _pendingApprovals.remove('$sessionId:${parsed.refId}') != null;
      if (sessionId == _active?.agentSessionId && parsed.refId != null) {
        _resolvedApprovals.add(parsed.refId!);
      }
      // Answered on the PC or another device: drop it from the banner.
      if (settled && mounted) setState(() {});
    }

    if (sessionId != null &&
        (parsed.kind == 'result' || parsed.kind == 'error')) {
      final idx = _sessions.indexWhere((s) => s.agentSessionId == sessionId);
      if (idx != -1) {
        _sessions[idx] = _sessions[idx].copyWith(busy: false);
      }
    }

    final matchedSession = _sessions
        .where((s) => s.agentSessionId == sessionId)
        .firstOrNull;
    NotificationService.instance.handleAgentEvent(
      sessionId,
      parsed,
      sessionTitle: matchedSession?.title ?? _active?.title,
    );

    if (sessionId != _active?.agentSessionId) {
      // A permission request for a background chat used to be dropped here, so
      // the agent blocked forever with nobody able to answer it. Park it and
      // badge the chat instead, then ask as soon as that chat is opened.
      if (parsed.kind == 'permission-request' &&
          sessionId != null &&
          parsed.refId != null) {
        setState(
          () => _pendingApprovals['$sessionId:${parsed.refId}'] = (
            sessionId: sessionId,
            event: parsed,
          ),
        );
        return;
      }
      if (sessionId != null &&
          (parsed.kind == 'result' || parsed.kind == 'error')) {
        setState(() {});
      }
      return;
    }
    if (parsed.kind == 'user' && _pendingThumbs != null) {
      _thumbsBySeq[parsed.seq] = _pendingThumbs!;
      _pendingThumbs = null;
    }
    var added = false;
    setState(() {
      // Dedupe against host seqs only; phone notes cannot collide.
      added = _transcript.addHost(parsed);
      if (parsed.kind == 'result' || parsed.kind == 'error') _setBusy(false);
    });
    if (added) _scrollToEnd();
  }

  void _scrollToEnd({bool force = false}) {
    if (!force &&
        _scroll.hasClients &&
        _scroll.position.maxScrollExtent - _scroll.offset > 120) {
      if (mounted) setState(() => _newActivity = true);
      return;
    }
    _newActivity = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _submitPermission(String? requestId, bool allow) async {
    if (_client?.status != RpcStatus.connected ||
        (_isLibrary && (_savedCopy || _chatSummary.json['managed'] != true))) {
      return;
    }
    final session = _active;
    if (session == null || requestId == null || !mounted) return;
    setState(() => _resolvedApprovals.add(requestId));
    final accepted = await _answerApproval(
      session.agentSessionId,
      requestId,
      allow,
    );
    // Unreachable: let the user try again. Refused: the PC settled it.
    if (accepted == null && mounted) {
      setState(() => _resolvedApprovals.remove(requestId));
    }
  }

  Future<void> _askPermission(AgentEvent e) async {
    final client = _client;
    final session = _active;
    final requestId = e.refId;
    if (client == null || session == null || requestId == null || !mounted) {
      return;
    }
    final allow = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: _panelBackgroundColor(_active?.agent),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              e.text ?? 'Allow this tool?',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              e.toolName ?? 'tool',
              style: const TextStyle(color: Color(0xFFF0C040)),
            ),
            if ((e.toolInput ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  e.toolInput!,
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Colors.white70,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Deny'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Allow'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (allow != null) {
      await _submitPermission(requestId, allow);
    }
  }

  Future<String?> _pickProject() async {
    final client = _client;
    if (client == null || !mounted) return null;
    return pickWorkingDirectory(context: context, client: client);
  }

  Future<void> _newChat(AgentInfo agent, {String? cwd}) async {
    final client = _client;
    if (client == null) return;
    cwd ??= await _pickProject();
    if (cwd == null) return;
    final activeClient = _client ?? client;
    try {
      final created =
          await activeClient.request('agent.createSession', {
                'operationId': 'task-${DateTime.now().microsecondsSinceEpoch}',
                'agent': agent.id,
                'title': agent.name,
                'cwd': cwd,
              })
              as Map<String, dynamic>;
      final session = AgentSessionInfo.fromJson(created);
      setState(() {
        _sessions.removeWhere(
          (x) => x.agentSessionId == session.agentSessionId,
        );
        _sessions.insert(0, session);
        _active = session;
        _transcript.clear();
        _busy = false;
        _stopping = false;
        _photos.clear();
        _liveModels = [];
        _gitTree = null;
      });
      _input.clear();
      ref.read(projectProvider.notifier).select(cwd);
      await _loadComposerPrefs(agent.id, isNewChat: true);
      await _refreshModels(agent.id, force: true);
      await _refreshGitTree();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'chat-last-source:${activeClient.hostId}',
        agent.id,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _openSession(AgentSessionInfo s) async {
    final client = _client;
    if (client == null) return;
    final gen = ++_syncGen;
    final page = client.supports('agent.historyPage')
        ? await client.requestMap('agent.historyPage', {
            'agentSessionId': s.agentSessionId,
          })
        : null;
    final raw = page != null
        ? page['events'] as List<dynamic>
        : await client.requestList('agent.history', {
            'agentSessionId': s.agentSessionId,
          });
    if (gen != _syncGen) return;
    _hasOlder = page?['hasMore'] == true;
    if (!mounted) return;
    final loaded = normalizeTranscriptSeqs(
      raw.map((e) => AgentEvent.fromJson(e as Map<String, dynamic>)).toList(),
    );
    setState(() {
      _active = s;
      _busy = s.busy;
      _stopping = false;
      _transcript
        ..clear()
        ..replaceHost(loaded);
      if (!s.busy && _transcript.hasOpenTools) {
        _transcript.settleOpenTools('Interrupted — host restarted.');
      }
      _photos.clear();
      _liveModels = [];
      _resolvedApprovals.clear();
      _sessions.removeWhere((x) => x.agentSessionId == s.agentSessionId);
      _sessions.insert(0, s);
    });
    await _syncApprovals(s.agentSessionId);
    await _restoreDraft(s.agentSessionId);
    ref.read(projectProvider.notifier).select(s.cwd);
    await _loadComposerPrefs(s.agent);
    await _refreshModels(s.agent, force: true);
    await _refreshGitTree();
    _scrollToEnd();
    // A request that landed while this chat was in the background is answered
    // now, instead of blocking the agent with no way to reach it.
    unawaited(
      Future<void>.delayed(
        const Duration(milliseconds: 250),
        _flushPendingApproval,
      ),
    );
  }

  AgentInfo? get _activeAgent {
    final id = _active?.agent;
    if (id == null) return null;
    for (final a in _agents) {
      if (a.id == id) return a;
    }
    return null;
  }

  AgentCapabilities get _caps {
    final id = _active?.agent ?? _activeAgent?.id ?? '';
    final host = _activeAgent?.capabilities ?? AgentCapabilities.empty;
    final fb = _fallbackCaps(id);
    final models = _liveModels.isNotEmpty
        ? _liveModels
        : (host.models.length > 1 ? host.models : fb.models);
    return AgentCapabilities(
      modes: host.modes.length > 1 ? host.modes : fb.modes,
      thinkingLevels: host.thinkingLevels.isNotEmpty
          ? host.thinkingLevels
          : fb.thinkingLevels,
      models: models,
      images: host.images,
    );
  }

  bool get _hostAppliesComposer =>
      _activeAgent?.capabilities.images == true ||
      (_activeAgent?.capabilities.models.length ?? 0) > 1;

  static AgentCapabilities _fallbackCaps(String id) {
    switch (id) {
      case 'cursor':
        return const AgentCapabilities(
          modes: ['agent', 'plan', 'ask'],
          thinkingLevels: ['low', 'medium', 'high', 'extra-high', 'max'],
          models: [
            AgentModelOption(id: 'auto', name: 'Auto'),
            AgentModelOption(id: 'composer-2.5', name: 'Composer 2.5'),
            AgentModelOption(id: 'gpt-5.3-codex', name: 'GPT-5.3 Codex'),
            AgentModelOption(id: 'cursor-grok-4.6-medium', name: 'Grok 4.6'),
            AgentModelOption(id: 'claude-opus-5-medium', name: 'Claude Opus 5'),
            AgentModelOption(
              id: 'claude-sonnet-5-thinking-medium',
              name: 'Claude Sonnet 5',
            ),
          ],
          images: true,
        );
      case 'opencode':
        return const AgentCapabilities(
          modes: ['agent', 'plan'],
          thinkingLevels: ['minimal', 'low', 'medium', 'high', 'max'],
          models: [
            AgentModelOption(
              id: 'opencode/deepseek-v4-flash-free',
              name: 'DeepSeek V4 Flash',
            ),
            AgentModelOption(id: 'opencode/mimo-v2.5-free', name: 'MiMo 2.5'),
            AgentModelOption(id: 'opencode/big-pickle', name: 'Big Pickle'),
          ],
          images: true,
        );
      case 'claude':
        return const AgentCapabilities(
          modes: ['agent', 'plan'],
          thinkingLevels: ['low', 'medium', 'high'],
          models: [
            AgentModelOption(id: 'sonnet', name: 'Sonnet'),
            AgentModelOption(id: 'opus', name: 'Opus'),
            AgentModelOption(id: 'haiku', name: 'Haiku'),
          ],
          images: true,
        );
      case 'antigravity':
        return const AgentCapabilities(
          modes: ['agent', 'plan'],
          thinkingLevels: ['low', 'medium', 'high'],
          models: [
            AgentModelOption(id: 'gemini-3.7-flash', name: 'Gemini 3.7 Flash'),
            AgentModelOption(id: 'gemini-3.1-pro', name: 'Gemini 3.1 Pro'),
            AgentModelOption(
              id: 'claude-sonnet-4-6',
              name: 'Claude Sonnet 4.6',
            ),
            AgentModelOption(id: 'claude-opus-4-6', name: 'Claude Opus 4.6'),
            AgentModelOption(id: 'gpt-oss-120b', name: 'GPT-OSS 120B'),
          ],
          images: true,
        );
      default:
        return const AgentCapabilities(
          modes: ['agent', 'plan', 'ask'],
          thinkingLevels: ['low', 'medium', 'high'],
          models: [],
          images: true,
        );
    }
  }

  Future<void> _loadComposerPrefs(
    String agentId, {
    bool isNewChat = false,
  }) async {
    final p = await SharedPreferences.getInstance();
    final caps = _caps;
    var mode = isNewChat
        ? 'agent'
        : (p.getString('agent-composer-$agentId-mode') ?? 'agent');
    if (!caps.modes.contains(mode)) {
      mode = caps.modes.isNotEmpty ? caps.modes.first : 'agent';
    }
    var thinking = p.getString('agent-composer-$agentId-thinking') ?? 'medium';
    if (caps.thinkingLevels.isNotEmpty &&
        !caps.thinkingLevels.contains(thinking)) {
      thinking = caps.thinkingLevels.contains('medium')
          ? 'medium'
          : caps.thinkingLevels[caps.thinkingLevels.length ~/ 2];
    }
    var model = p.getString('agent-composer-$agentId-model');
    final families = collapseModelFamilies(caps.models);
    if (model != null) {
      model = modelFamilyId(model);
      if (families.isNotEmpty && !families.any((m) => m.id == model)) {
        model = families.first.id;
      }
    }
    model ??= families.isNotEmpty ? families.first.id : null;
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _thinking = thinking;
      _model = model;
    });
  }

  Future<void> _refreshModels(String agentId, {bool force = false}) async {
    final client = _client;
    if (client == null) return;
    try {
      final raw = await client.requestList('agent.listModels', {
        'agent': agentId,
        if (force) 'refresh': true,
      });
      final models = raw
          .whereType<Map>()
          .map((e) => AgentModelOption.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      if (!mounted || models.isEmpty) return;
      setState(() => _liveModels = models);
    } catch (_) {
      // Old host has no agent.listModels — fallback catalog still shows.
    }
  }

  Future<void> _saveComposerPrefs() async {
    final agentId = _active?.agent;
    if (agentId == null) return;
    final p = await SharedPreferences.getInstance();
    await p.setString('agent-composer-$agentId-mode', _mode);
    await p.setString('agent-composer-$agentId-thinking', _thinking);
    if (_model != null) {
      await p.setString('agent-composer-$agentId-model', _model!);
    }
  }

  Future<void> _send() async {
    if (_isLibrary) {
      await _sendLibrary();
      return;
    }
    if (_sending) return;
    if (_busy) {
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Chat is working'),
          content: const Text(
            'This conversation is currently running a task.\n\n'
            'Do you want to interrupt it and send your message, or let it finish running?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('let_run'),
              child: const Text('Let it run'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop('interrupt'),
              child: const Text('Interrupt & Send'),
            ),
          ],
        ),
      );
      if (choice != 'interrupt') return;
      final outcome = await _cancel();
      if (outcome == null || !outcome.ended) return;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    final text = _input.text.trim();
    final session = _active;
    final client = _client;
    if ((text.isEmpty && _photos.isEmpty) ||
        session == null ||
        client == null) {
      return;
    }
    _sending = true;
    try {
      if (text.startsWith('/') && _photos.isEmpty) {
        if (await _handleSlash(text)) {
          _input.clear();
          return;
        }
      }
      final photos = List<_PendingPhoto>.from(_photos);
      _input.clear();
      final currentTitle = session.title.trim();
      final isDefaultTitle =
          currentTitle.isEmpty ||
          currentTitle == 'Agent' ||
          currentTitle == 'Host chat' ||
          currentTitle == 'Antigravity' ||
          currentTitle == 'OpenCode' ||
          currentTitle == 'Cursor CLI' ||
          currentTitle == 'Claude Code' ||
          currentTitle == 'Demo Agent' ||
          _agents.any((a) => a.name == currentTitle || a.id == currentTitle);
      if (isDefaultTitle && text.isNotEmpty) {
        final summary = text.split('\n').first.trim();
        final clipped = summary.length > 50
            ? '${summary.substring(0, 47)}…'
            : summary;
        if (clipped.isNotEmpty) {
          final updated = session.copyWith(title: clipped);
          _active = updated;
          final idx = _sessions.indexWhere(
            (s) => s.agentSessionId == session.agentSessionId,
          );
          if (idx != -1) _sessions[idx] = updated;
        }
      }
      setState(() {
        _setBusy(true);
        _pendingThumbs = photos.map((p) => p.bytes).toList();
        _photos.clear();
      });
      _scrollToEnd();
      try {
        await client.request('agent.prompt', {
          'agentSessionId': session.agentSessionId,
          'text': text,
          'operationId': 'prompt-${DateTime.now().microsecondsSinceEpoch}',
          if (_model != null && _model != 'auto' && _model != 'default')
            'model': _model,
          if (_mode != 'agent') 'mode': _mode,
          if (_thinking.isNotEmpty && _modelSupportsEffort)
            'thinking': _thinking,
          if (photos.isNotEmpty)
            'images': [
              for (final p in photos)
                {'name': p.name, 'mime': p.mime, 'data': base64Encode(p.bytes)},
            ],
        }, const Duration(seconds: 60));
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _setBusy(false);
          _pendingThumbs = null;
          _transcript.note(
            'error',
            'Your message was not delivered: ${friendlyLaunchError(e)}',
          );
        });
      }
    } finally {
      _sending = false;
    }
  }

  bool get _canStop => _busy || _transcript.hasOpenTools;

  /// Stop: show "Stopping…" until the PC answers, then the real outcome.
  /// Returns null when a stop is already in flight or there is no chat.
  Future<StopOutcome?> _cancel() async {
    final session = _active;
    final client = _client;
    if (_stopping || session == null || !mounted) return null;
    setState(() => _stopping = true);
    StopOutcome outcome;
    try {
      if (_isLibrary) {
        final stopped = await ref
            .read(chatRepositoryProvider)
            .cancel(_chatSummary);
        outcome = describeStopResult({'ok': stopped}, library: true);
      } else {
        if (client == null || client.status != RpcStatus.connected) {
          throw RpcException('the PC is offline');
        }
        final result = await client.request('agent.cancel', {
          'agentSessionId': session.agentSessionId,
        }, const Duration(seconds: 15));
        outcome = describeStopResult(result);
      }
    } catch (error) {
      outcome = describeStopResult(null, error: error, library: _isLibrary);
    }
    if (!mounted) return outcome;
    setState(() {
      _stopping = false;
      if (outcome.ended && _active?.agentSessionId == session.agentSessionId) {
        _setBusy(false);
        _transcript.settleOpenTools(
          outcome.state == StopState.stopped ? 'Stopped.' : 'Not running.',
        );
      }
      if (outcome.state == StopState.failed ||
          outcome.state == StopState.unsupported) {
        _transcript.note('error', outcome.message);
      }
    });
    _toast(outcome.message);
    if (outcome.state == StopState.stopped) {
      unawaited(_refreshSnapshot());
    }
    return outcome;
  }

  void _localStatus(String text) {
    setState(() => _transcript.note('status', text));
    _scrollToEnd();
  }

  AgentModelOption? _matchModel(String query) {
    final tokens = query
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((t) => t.isNotEmpty)
        .toList();
    final q = tokens.join();
    if (q.isEmpty) return null;
    AgentModelOption? best;
    var bestScore = 0;
    final seen = <String>{};
    for (final m in [..._pickerModels, ..._caps.models]) {
      if (!seen.add(m.id)) continue;
      final id = m.id.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      final name = m.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      var score = 0;
      if (id == q || name == q) {
        score = 100;
      } else if (id.contains(q) || name.contains(q)) {
        score = 80;
      } else if (tokens.every((t) => id.contains(t) || name.contains(t))) {
        score = 70;
      }
      if (score > bestScore) {
        bestScore = score;
        best = m;
      }
    }
    return best;
  }

  Future<bool> _handleSlash(String text) async {
    final m = RegExp(r'^/([a-zA-Z]+)(?:\s+(.*))?$').firstMatch(text);
    if (m == null) return false;
    final cmd = m.group(1)!.toLowerCase();
    final arg = (m.group(2) ?? '').trim();
    if (cmd == 'model') {
      if (arg.isEmpty) {
        _localStatus(
          'Current model: ${_model ?? 'CLI default'}. Pick one below, or /model <name>.',
        );
        await _pickModel();
        return true;
      }
      await _refreshModels(_active?.agent ?? '');
      final hit = _matchModel(arg);
      if (hit == null) {
        _localStatus(
          'No model matching "$arg". Open the model picker to see the list.',
        );
        await _pickModel();
        return true;
      }
      setState(() => _model = modelFamilyId(hit.id));
      await _saveComposerPrefs();
      _localStatus('Model set to ${hit.name} (`${modelFamilyId(hit.id)}`).');
      return true;
    }
    if (cmd == 'thinking' || cmd == 'effort') {
      if (!_modelSupportsEffort) {
        _localStatus('Thinking/effort is not supported for $_modelLabel.');
        return true;
      }
      final levels = _thinkingLevels;
      if (arg.isEmpty) {
        _localStatus(
          'Thinking: ${_thinkingLabel(_thinking)}. /thinking ${_thinkingLevels.join('|')}',
        );
        await _pickThinking();
        return true;
      }
      final q = arg.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      String? hit;
      for (final level in levels) {
        final id = level.replaceAll(RegExp(r'[^a-z0-9]'), '');
        final name = _thinkingLabel(
          level,
        ).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
        if (id == q || name == q || id.startsWith(q) || name.contains(q)) {
          hit = level;
          break;
        }
      }
      if (hit == null) {
        _localStatus(
          'Thinking levels: ${levels.map(_thinkingLabel).join(', ')}',
        );
        return true;
      }
      final chosen = hit;
      setState(() => _thinking = chosen);
      await _saveComposerPrefs();
      _localStatus('Thinking: ${_thinkingLabel(chosen)}');
      return true;
    }
    if (cmd == 'plan' || cmd == 'ask' || cmd == 'agent') {
      if (_caps.modes.contains(cmd)) {
        setState(() => _mode = cmd);
        await _saveComposerPrefs();
        _localStatus('Mode: ${_modeLabel(cmd)}');
        return true;
      }
    }
    if (cmd == 'rename' || cmd == 'title') {
      if (_active == null) return false;
      if (arg.isNotEmpty) {
        final updated = _active!.copyWith(title: arg);
        setState(() {
          _active = updated;
          final idx = _sessions.indexWhere(
            (s) => s.agentSessionId == updated.agentSessionId,
          );
          if (idx != -1) _sessions[idx] = updated;
        });
        final client = _client;
        if (client != null) {
          try {
            await client.request('agent.renameSession', {
              'agentSessionId': _active!.agentSessionId,
              'title': arg,
            });
          } catch (_) {}
        }
        _localStatus('Chat renamed to "$arg".');
        return true;
      } else {
        await _renameSessionDialog(_active!);
        return true;
      }
    }
    return false;
  }

  bool get _needsSignIn {
    for (var i = _display.length - 1; i >= 0; i--) {
      final e = _display[i];
      final t = (e.text ?? '').toLowerCase();
      if (e.kind == 'result' && t.contains('signed in')) return false;
      if (e.kind == 'error' || e.kind == 'status' || e.kind == 'text') {
        if (t.contains("isn't signed in") ||
            t.contains('authentication required') ||
            t.contains('authentication failed') ||
            t.contains('not logged into') ||
            t.contains('starting cursor sign-in') ||
            t.contains('starting antigravity sign-in') ||
            t.contains('sign-in is already') ||
            t.contains('no headless login')) {
          return true;
        }
      }
    }
    return false;
  }

  Future<void> _changeSessionCwd(AgentSessionInfo s) async {
    final client = _client;
    if (client == null) return;
    final cwd = await _pickProject();
    if (cwd == null || cwd.trim().isEmpty) return;
    try {
      final raw =
          await client.request('agent.setSessionCwd', {
                'agentSessionId': s.agentSessionId,
                'cwd': cwd,
              })
              as Map<String, dynamic>;
      final updated = AgentSessionInfo.fromJson(raw);
      if (!mounted) return;
      setState(() {
        final idx = _sessions.indexWhere(
          (x) => x.agentSessionId == updated.agentSessionId,
        );
        if (idx != -1) _sessions[idx] = updated;
        if (_active?.agentSessionId == updated.agentSessionId) {
          _active = updated;
        }
      });
      await _refreshGitTree();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _deleteSession(AgentSessionInfo s) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this task?'),
        content: Text(
          '“${s.title}” and its conversation are removed from the PC. '
          'This can’t be undone. Archive it instead to keep the history.',
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
    if (confirmed != true || !mounted) return;
    final client = _client;
    if (client == null || client.status != RpcStatus.connected) {
      _toast('Reconnect to the PC to delete this task.');
      return;
    }
    try {
      final result = await client.request('agent.close', {
        'agentSessionId': s.agentSessionId,
      });
      if (result is Map && result['ok'] == false) {
        _toast('The PC no longer has that task.');
      }
    } catch (e) {
      _toast('Couldn’t delete the task: ${friendlyLaunchError(e)}');
      return;
    }
    if (!mounted) return;
    setState(() {
      _sessions.removeWhere((x) => x.agentSessionId == s.agentSessionId);
      if (_active?.agentSessionId == s.agentSessionId) {
        _active = null;
        _transcript.clear();
        _busy = false;
      }
    });
  }

  Future<void> _renameSessionDialog(AgentSessionInfo s) async {
    final controller = TextEditingController(text: s.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _panelBackgroundColor(_active?.agent),
        title: const Text('Rename chat', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Chat name',
            isDense: true,
          ),
          onSubmitted: (val) => Navigator.pop(ctx, val.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newTitle == null || newTitle.isEmpty || !mounted) return;
    final updated = s.copyWith(title: newTitle);
    setState(() {
      if (_active?.agentSessionId == s.agentSessionId) {
        _active = updated;
      }
      final idx = _sessions.indexWhere(
        (x) => x.agentSessionId == s.agentSessionId,
      );
      if (idx != -1) {
        _sessions[idx] = updated;
      }
    });
    final client = _client;
    if (client != null) {
      try {
        await client.request('agent.renameSession', {
          'agentSessionId': s.agentSessionId,
          'title': newTitle,
        });
      } catch (_) {}
    }
  }

  void _leaveChat() {
    if (widget.initialTaskId != null) {
      Navigator.of(context).pop();
      return;
    }
    if (_isLibrary) {
      final chat = widget.libraryChat!;
      unawaited(
        ref
            .read(chatCacheProvider)
            .saveDraft(
              chat.hostId,
              chat.id,
              _input.text,
              position: _scroll.hasClients ? _scroll.offset : null,
            ),
      );
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _active = null;
      _transcript.clear();
      _busy = false;
      _stopping = false;
      _photos.clear();
      _liveModels = [];
      _gitTree = null;
      _chatTab = 0;
    });
  }

  IconData _modeIcon(String mode) => switch (mode) {
    'plan' => Icons.checklist_outlined,
    'ask' => Icons.help_outline,
    _ => Icons.smart_toy_outlined,
  };

  String _modeLabel(String mode) => switch (mode) {
    'plan' => 'Plan',
    'ask' => 'Ask',
    _ => 'Agent',
  };

  String _thinkingLabel(String level) => switch (level) {
    'minimal' => 'Minimal',
    'low' => 'Low',
    'high' => 'High',
    'extra-high' => 'Extra high',
    'max' => 'Max',
    _ => 'Medium',
  };

  List<AgentModelOption> get _pickerModels =>
      collapseModelFamilies(_caps.models);

  List<String> get _thinkingLevels {
    if (_caps.thinkingLevels.isNotEmpty) return _caps.thinkingLevels;
    return const ['low', 'medium', 'high'];
  }

  bool get _modelSupportsEffort =>
      isModelEffortSupported(_active?.agent, _model, _pickerModels);

  String get _modelLabel {
    final id = _model;
    if (id == null || id == 'default') {
      if (_pickerModels.isNotEmpty) return _pickerModels.first.name;
      if (_caps.models.isNotEmpty) return _caps.models.first.name;
      return 'Model';
    }
    if (id == 'auto') {
      for (final m in [..._pickerModels, ..._caps.models]) {
        if (m.id == 'auto') return m.name;
      }
      return 'Auto';
    }
    final fam = modelFamilyId(id);
    for (final m in _pickerModels) {
      if (m.id == id || m.id == fam) return m.name;
    }
    for (final m in _caps.models) {
      if (m.id == id || modelFamilyId(m.id) == fam) return m.name;
    }
    if (fam.contains('/')) return fam.split('/').last;
    return fam;
  }

  Future<void> _refreshGitTree() async {
    final client = _client;
    final cwd = _active?.cwd.trim() ?? '';
    if (client == null || cwd.isEmpty) {
      if (mounted) setState(() => _gitTree = null);
      return;
    }
    try {
      final raw = await client.request('fs.gitStatus', {'cwd': cwd});
      if (!mounted) return;
      if (raw is Map) {
        setState(
          () => _gitTree = GitWorkingTree.fromJson(
            Map<String, dynamic>.from(raw),
          ),
        );
      } else {
        setState(() => _gitTree = null);
      }
    } catch (_) {
      if (mounted) setState(() => _gitTree = null);
    }
  }

  Future<void> _pickMode() async {
    final modes = _caps.modes;
    if (modes.length < 2 || !mounted) return;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _panelBackgroundColor(_active?.agent),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
          children: [
            const ListTile(
              title: Text(
                'Mode',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text('How this agent spends the next turn'),
            ),
            for (final mode in modes)
              ListTile(
                leading: Icon(
                  mode == 'plan'
                      ? Icons.checklist_outlined
                      : mode == 'ask'
                      ? Icons.help_outline
                      : Icons.smart_toy_outlined,
                ),
                title: Text(_modeLabel(mode)),
                trailing: mode == _mode
                    ? const Icon(Icons.check, color: Color(0xFF2A6AFF))
                    : null,
                onTap: () => Navigator.pop(ctx, mode),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() => _mode = chosen);
    await _saveComposerPrefs();
  }

  Future<void> _openComposerMenu() async {
    if (_isLibrary && !_replyAllowed) return;
    await _refreshGitTree();
    if (!mounted) return;
    final cwd = _active?.cwd.trim() ?? '';
    final git = _gitTree;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panelBackgroundColor(_active?.agent),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
          children: [
            const ListTile(
              title: Text(
                'Add to this turn',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.add_photo_alternate_outlined),
              title: const Text('Photo'),
              enabled: !_busy,
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_attachPhoto());
              },
            ),
            if (cwd.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.account_tree_outlined),
                title: Text(
                  git != null
                      ? 'Working tree · ${folderDisplayName(cwd)}'
                      : folderDisplayName(cwd),
                ),
                subtitle: Text(
                  git != null ? workingTreeSubtitle(git) : cwd,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  final s = _active;
                  if (s != null) unawaited(_changeSessionCwd(s));
                },
              ),
            if (git != null)
              for (final file in git.files.take(4))
                Padding(
                  padding: const EdgeInsets.only(left: 56),
                  child: Text(
                    file,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF8A8A9A),
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
            if (git != null && git.files.isNotEmpty) const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.memory_outlined),
              title: const Text('Model'),
              subtitle: Text(_modelLabel),
              enabled: !_busy,
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_pickModel());
              },
            ),
            ListTile(
              leading: Icon(
                Icons.psychology_outlined,
                color: _modelSupportsEffort ? null : Colors.white24,
              ),
              title: const Text('Thinking'),
              subtitle: _modelSupportsEffort
                  ? Text(_thinkingLabel(_thinking))
                  : Text(
                      'Not supported for $_modelLabel',
                      style: const TextStyle(color: Colors.white38),
                    ),
              enabled: !_busy && _modelSupportsEffort,
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_pickThinking());
              },
            ),
            if (_caps.modes.length > 1)
              ListTile(
                leading: Icon(
                  _mode == 'plan'
                      ? Icons.checklist_outlined
                      : _mode == 'ask'
                      ? Icons.help_outline
                      : Icons.smart_toy_outlined,
                ),
                title: const Text('Mode'),
                subtitle: Text(_modeLabel(_mode)),
                enabled: !_busy,
                onTap: () {
                  Navigator.pop(ctx);
                  unawaited(_pickMode());
                },
              ),
            ListTile(
              leading: AgentMark(
                agentId: _active?.agent ?? '',
                color: agentMarkColor(_active?.agent ?? '', available: true),
              ),
              title: const Text('Agent'),
              subtitle: Text(_activeAgent?.name ?? 'Switch agent'),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_pickOtherAgent());
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickOtherAgent() async {
    if (!mounted) return;
    final chosen = await showModalBottomSheet<AgentInfo>(
      context: context,
      backgroundColor: _panelBackgroundColor(_active?.agent),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
          children: [
            const ListTile(
              title: Text(
                'Agent',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text('Starts a new chat in this folder'),
            ),
            for (final a in _agents)
              ListTile(
                leading: AgentMark(
                  agentId: a.id,
                  color: agentMarkColor(a.id, available: a.available),
                ),
                title: Text(a.name),
                enabled: a.available,
                trailing: a.id == _active?.agent
                    ? const Icon(Icons.check, color: Color(0xFF2A6AFF))
                    : null,
                onTap: a.available ? () => Navigator.pop(ctx, a) : null,
              ),
          ],
        ),
      ),
    );
    if (chosen == null || chosen.id == _active?.agent) return;
    await _newChat(chosen, cwd: _active?.cwd);
  }

  Future<void> _pickThinking() async {
    if (!_modelSupportsEffort) {
      _localStatus('Thinking is not supported for $_modelLabel.');
      return;
    }
    final levels = _thinkingLevels;
    if (!mounted) return;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _panelBackgroundColor(_active?.agent),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
          children: [
            const ListTile(
              title: Text(
                'Thinking',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text('How hard this model thinks on each turn'),
            ),
            for (final level in levels)
              ListTile(
                title: Text(_thinkingLabel(level)),
                trailing: level == _thinking
                    ? const Icon(Icons.check, color: Color(0xFF2A6AFF))
                    : null,
                onTap: () => Navigator.pop(ctx, level),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() => _thinking = chosen);
    await _saveComposerPrefs();
  }

  Future<void> _pickModel() async {
    final agentId = _active?.agent;
    if (agentId != null) await _refreshModels(agentId, force: true);
    if (!mounted) return;
    final models = _pickerModels;
    if (models.isEmpty) {
      _localStatus(
        'This agent has no model list yet. Restart NexusLink on the PC and try again.',
      );
      return;
    }
    final plan = _activeAgent?.capabilities.plan;
    final isOpenCode = agentId == 'opencode';
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _panelBackgroundColor(_active?.agent),
      isScrollControlled: true,
      builder: (ctx) {
        var query = '';
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final q = query.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
            final filtered = q.isEmpty
                ? models
                : models.where((m) {
                    final id = m.id.toLowerCase().replaceAll(
                      RegExp(r'[^a-z0-9]'),
                      '',
                    );
                    final name = m.name.toLowerCase().replaceAll(
                      RegExp(r'[^a-z0-9]'),
                      '',
                    );
                    return id.contains(q) || name.contains(q);
                  }).toList();
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.65,
                child: Column(
                  children: [
                    ListTile(
                      title: Row(
                        children: [
                          const Text(
                            'Model',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          if (isOpenCode && plan == 'go') ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.green.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: Colors.green.withValues(alpha: 0.4),
                                ),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.verified,
                                    size: 11,
                                    color: Colors.green,
                                  ),
                                  SizedBox(width: 3),
                                  Text(
                                    'Go plan',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: Colors.green,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                      subtitle: const Text(
                        'Same agent — thinking is the chip next to this',
                      ),
                    ),
                    // Go plan info banner for OpenCode without Go
                    if (isOpenCode && plan != 'go')
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: Colors.orange.withValues(alpha: 0.35),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.info_outline,
                                size: 14,
                                color: Colors.orange[300],
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Free / BYOK models shown. '
                                  'Subscribe at opencode.ai for the full catalog.',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: Colors.orange[300],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: TextField(
                        autofocus: models.length > 8,
                        decoration: const InputDecoration(
                          hintText: 'Search models…',
                          isDense: true,
                          prefixIcon: Icon(Icons.search, size: 20),
                        ),
                        onChanged: (v) => setSheet(() => query = v),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final m = filtered[i];
                          // Warn if model looks like it needs Go but user doesn't have it
                          final needsGo =
                              isOpenCode &&
                              !m.id.contains('-free') &&
                              !m.id.contains('free') &&
                              plan != 'go';
                          return ListTile(
                            title: Text(m.name),
                            subtitle: needsGo
                                ? Text(
                                    '${m.id} · may require Go plan',
                                    style: const TextStyle(
                                      color: Colors.orange,
                                      fontSize: 12,
                                    ),
                                  )
                                : Text(
                                    m.id,
                                    style: const TextStyle(
                                      color: Colors.white38,
                                      fontSize: 12,
                                    ),
                                  ),
                            trailing:
                                modelFamilyId(m.id) ==
                                    modelFamilyId(_model ?? '')
                                ? const Icon(
                                    Icons.check,
                                    color: Color(0xFF2A6AFF),
                                  )
                                : null,
                            onTap: () => Navigator.pop(ctx, m.id),
                          );
                        },
                      ),
                    ),
                    // Refresh button at the bottom of the picker
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: TextButton.icon(
                        onPressed: () async {
                          Navigator.pop(ctx);
                          if (agentId != null) {
                            await _refreshModels(agentId, force: true);
                          }
                          if (mounted) unawaited(_pickModel());
                        },
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('Refresh models'),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white54,
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (chosen == null || !mounted) return;
    setState(() => _model = modelFamilyId(chosen));
    await _saveComposerPrefs();
  }

  Future<void> _attachPhoto() async {
    if (!mounted || _photos.length >= 4) return;
    if (!_hostAppliesComposer) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Update NexusLink on your PC so photos reach the agent.',
          ),
        ),
      );
    }
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: _panelBackgroundColor(_active?.agent),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Photo library'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Camera'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null) return;
    try {
      if (source == ImageSource.camera) {
        final x = await _imagePicker.pickImage(
          source: ImageSource.camera,
          maxWidth: 1600,
          maxHeight: 1600,
          imageQuality: 78,
        );
        if (x != null) await _addXFile(x);
      } else {
        final xs = await _imagePicker.pickMultiImage(
          maxWidth: 1600,
          maxHeight: 1600,
          imageQuality: 78,
        );
        for (final x in xs.take(4 - _photos.length)) {
          await _addXFile(x);
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not add photo: $e')));
    }
  }

  Future<void> _addXFile(XFile x) async {
    final bytes = await x.readAsBytes();
    if (bytes.isEmpty || bytes.lengthInBytes > 4 * 1024 * 1024) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Photo is empty or larger than 4 MB')),
      );
      return;
    }
    final lower = x.name.toLowerCase();
    final mime =
        x.mimeType ??
        (lower.endsWith('.png')
            ? 'image/png'
            : lower.endsWith('.webp')
            ? 'image/webp'
            : 'image/jpeg');
    if (!mounted) return;
    setState(() {
      _photos.add(
        _PendingPhoto(
          name: x.name.isEmpty ? 'photo.jpg' : x.name,
          mime: mime,
          bytes: bytes,
        ),
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final u in _unsubs) {
      u();
    }
    _unsubs.clear();
    _userWantsListen = false;
    _listenGen++;
    _speech.stop();
    _libraryTimer?.cancel();
    _libraryPushTimer?.cancel();
    if (_isLibrary) {
      final chat = widget.libraryChat!;
      unawaited(
        ref
            .read(chatCacheProvider)
            .saveDraft(
              chat.hostId,
              chat.id,
              _input.text,
              position: _scroll.hasClients ? _scroll.offset : null,
            ),
      );
    }
    _draftTimer?.cancel();
    _input.removeListener(_draftChanged);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _openPendingTask() {
    final id = ref.read(pendingTaskProvider);
    final task = _sessions.where((s) => s.agentSessionId == id).firstOrNull;
    if (task == null) return;
    ref.read(pendingTaskProvider.notifier).select(null);
    unawaited(_openSession(task));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(pendingTaskProvider, (_, id) => _openPendingTask());
    ref.listen<RpcStatus>(connectionStatusProvider, (prev, next) {
      if (next == RpcStatus.connected && prev != RpcStatus.connected) {
        // Foreground resume always resyncs (events were missed). In-app socket
        // blips while chatting keep the live transcript — resync only when idle.
        unawaited(_onForeground(syncTranscript: true));
      }
    });
    return PopScope(
      canPop: _isLibrary || widget.initialTaskId != null || _active == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leaveChat();
      },
      child: Scaffold(
        backgroundColor: _appBackgroundColor(_active?.agent),
        appBar: AppBar(
          backgroundColor: _appBackgroundColor(_active?.agent),
          leading: _active == null
              ? null
              : IconButton(
                  tooltip: 'Back to chats',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _leaveChat,
                ),
          title: _active == null
              ? const Text('Chats', style: TextStyle(fontSize: 16))
              : InkWell(
                  onTap: _isLibrary && _chatSummary.json['managed'] != true
                      ? null
                      : () => _renameSessionDialog(_active!),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AgentActivityIcon(
                          agentId: _active!.agent,
                          icon: _active!.icon,
                          active: _busy,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            _active?.title ?? 'Agents',
                            style: const TextStyle(fontSize: 16),
                            overflow: TextOverflow.ellipsis,
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
          actions: [
            if (_active != null &&
                (!_isLibrary || _chatSummary.json['managed'] == true))
              IconButton(
                tooltip: 'Archive task',
                icon: const Icon(Icons.archive_outlined),
                onPressed: () => _archive(_active!),
              ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? looksLikeConnectionError(_error)
                  ? NotConnectedView(
                      message: _error!,
                      onReconnected: () {
                        setState(() {
                          _loading = true;
                          _error = null;
                        });
                        _load();
                      },
                    )
                  : Center(
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    )
            : Column(
                children: [
                  _approvalBanner(),
                  Expanded(
                    child: _active == null ? _picker() : _chatWithTerminal(),
                  ),
                ],
              ),
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _archive(AgentSessionInfo session) async {
    try {
      await _client?.request('agent.archive', {
        'agentSessionId': session.agentSessionId,
        'archived': !session.archived,
      });
      if (_active?.agentSessionId == session.agentSessionId) _leaveChat();
      await _refreshSnapshot();
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _newTaskFlow() async {
    var cwd = ref.read(projectProvider)?.path;
    cwd ??= await _pickProject();
    if (cwd == null || !mounted) return;
    ref.read(projectProvider.notifier).select(cwd);
    final agent = await showModalBottomSheet<AgentInfo>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Choose agent')),
            for (final a in _agents.where((a) => a.id != 'mock'))
              ListTile(
                leading: AgentMark(
                  agentId: a.id,
                  icon: a.icon,
                  color: agentMarkColor(a.id, available: a.available),
                ),
                title: Text(a.name),
                subtitle: Text(
                  a.available
                      ? 'Available on PC'
                      : 'CLI not installed on the PC',
                ),
                enabled: a.available,
                onTap: a.available ? () => Navigator.pop(ctx, a) : null,
              ),
          ],
        ),
      ),
    );
    if (agent != null) await _newChat(agent, cwd: cwd);
  }

  int _priority(AgentSessionInfo s) => s.taskState == 'waiting'
      ? 0
      : s.taskState == 'failed'
      ? 1
      : s.busy
      ? 2
      : 3;
  Widget _picker() {
    final project = ref.watch(projectProvider);
    final query = _taskQuery.toLowerCase();
    final tasks =
        _sessions
            .where(
              (s) =>
                  s.archived == _showArchived &&
                  (_agentFilter == null || s.agent == _agentFilter) &&
                  ('${s.title} ${s.cwd}'.toLowerCase().contains(query)),
            )
            .toList()
          ..sort((a, b) {
            final priority = _priority(a).compareTo(_priority(b));
            return priority != 0
                ? priority
                : b.updatedAt.compareTo(a.updatedAt);
          });
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(project?.name ?? 'Choose a project'),
          subtitle: project == null
              ? null
              : Text(
                  project.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          onTap: () async {
            final cwd = await _pickProject();
            if (cwd != null) ref.read(projectProvider.notifier).select(cwd);
          },
          trailing: FilledButton.icon(
            onPressed: _newTaskFlow,
            icon: const Icon(Icons.add),
            label: const Text('New task'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search tasks and projects',
                  ),
                  onChanged: (text) => setState(() => _taskQuery = text),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Filter tasks',
                onSelected: (value) => setState(() {
                  if (value == 'archive') {
                    _showArchived = !_showArchived;
                  } else {
                    _agentFilter = value == 'all' ? null : value;
                  }
                }),
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'all', child: Text('All agents')),
                  for (final a in _agents.where((a) => a.id != 'mock'))
                    PopupMenuItem(value: a.id, child: Text(a.name)),
                  PopupMenuItem(
                    value: 'archive',
                    child: Text(
                      _showArchived
                          ? 'Show active tasks'
                          : 'Show archived tasks',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _refreshSnapshot(syncTranscript: false),
            child: tasks.isEmpty
                ? ListView(
                    children: [
                      const SizedBox(height: 80),
                      Center(
                        child: Text(
                          _showArchived
                              ? 'No archived tasks'
                              : 'Start a task in your PC project.',
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: tasks.length,
                    itemBuilder: (context, index) {
                      final s = tasks[index];
                      final previous = index > 0
                          ? _priority(tasks[index - 1])
                          : -1;
                      final priority = _priority(s);
                      final status = s.taskState == 'waiting'
                          ? 'Approval needed'
                          : s.busy
                          ? 'Working'
                          : s.taskState;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (priority != previous)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Text(
                                priority < 2
                                    ? 'NEEDS ATTENTION'
                                    : priority == 2
                                    ? 'WORKING'
                                    : 'RECENT',
                                style: const TextStyle(
                                  color: Color(0xFFA7B0C0),
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          Card(
                            child: ListTile(
                              leading: AgentMark(
                                agentId: s.agent,
                                icon: s.icon,
                                color: agentMarkColor(s.agent, available: true),
                              ),
                              title: Text(
                                s.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '$status · ${s.cwd.split('/').last}\n${s.preview ?? s.agent}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => _openSession(s),
                              trailing: PopupMenuButton<String>(
                                onSelected: (action) {
                                  switch (action) {
                                    case 'archive':
                                      _archive(s);
                                      break;
                                    case 'rename':
                                      _renameSessionDialog(s);
                                      break;
                                    case 'delete':
                                      _deleteSession(s);
                                      break;
                                    case 'folder':
                                      _changeSessionCwd(s);
                                      break;
                                  }
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(
                                    value: 'archive',
                                    child: Text(
                                      s.archived ? 'Unarchive' : 'Archive',
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'rename',
                                    child: Text('Rename'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'folder',
                                    child: Text('Change project'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Delete task'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Color _chatBackgroundColor(String? agentId) => const Color(0xFF0B0D12);

  Widget _chatWithTerminal() {
    if (_isLibrary) return _chat();
    return Column(
      children: [
        Container(
          color: _appBackgroundColor(_active?.agent),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF141420),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF1E1E30)),
            ),
            padding: const EdgeInsets.all(2),
            child: Row(
              children: [
                _chatTabButton(0, Icons.chat_bubble_outline, 'Chat'),
                const SizedBox(width: 2),
                _chatTabButton(1, Icons.difference_outlined, 'Changes'),
                const SizedBox(width: 2),
                _chatTabButton(2, Icons.terminal, 'Terminal'),
              ],
            ),
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _chatTab,
            children: [
              _chat(),
              if (_chatTab == 1)
                ChangesScreen(cwd: _active!.cwd)
              else
                const SizedBox.shrink(),
              if (_terminalVisited.contains(_active?.agentSessionId))
                TickerMode(
                  enabled: _chatTab == 2,
                  child: EmbeddedTerminal(
                    key: ValueKey('${_active?.agentSessionId}_${_active?.cwd}'),
                    initialCwd: _active?.cwd,
                    sessionId: _active?.agentSessionId,
                  ),
                )
              else
                const SizedBox.shrink(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _chatTabButton(int index, IconData icon, String label) {
    final selected = _chatTab == index;
    final isTerminalTab = index == 2;
    final sessionId = _active?.agentSessionId ?? '';
    final termBusy = isTerminalTab
        ? (ref.watch(terminalBusyProvider)[sessionId] ?? false)
        : false;

    final pill = Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: selected ? const Color(0xFF2A6AFF) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 15,
            color: selected ? Colors.white : const Color(0xFF888899),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              color: selected ? Colors.white : const Color(0xFF888899),
            ),
          ),
        ],
      ),
    );

    return Expanded(
      child: InkWell(
        onTap: () => setState(() {
          _chatTab = index;
          if (index == 2 && _active != null) {
            _terminalVisited.add(_active!.agentSessionId);
          }
        }),
        borderRadius: BorderRadius.circular(8),
        child: isTerminalTab
            ? TerminalGlowBorder(
                active: termBusy,
                borderRadius: BorderRadius.circular(8),
                strokeWidth: 1.8,
                glowColor: Colors.white,
                child: pill,
              )
            : pill,
      ),
    );
  }

  Widget _chat() {
    _display = _transcript.display;
    final display = groupAgentDisplay(_display);
    final live = _isLibrary ? _chatSummary.live : null;
    return Column(
      children: [
        if (ChatLiveHeader.shows(live)) ChatLiveHeader(live: live!),
        if (_hasOlder)
          TextButton(
            onPressed: _older,
            child: const Text('Load earlier messages'),
          ),
        if (_newActivity)
          TextButton(
            onPressed: () => _scrollToEnd(force: true),
            child: const Text('Jump to latest ↓'),
          ),
        Expanded(
          child: Container(
            color: _chatBackgroundColor(_active?.agent),
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              itemCount: display.length + (_busy ? 1 : 0),
              itemBuilder: (_, i) {
                if (i >= display.length) {
                  return _workingRow();
                }
                final item = display[i];
                if (item.tools != null) return _toolGroup(item.tools!);
                return _bubble(item.event!);
              },
            ),
          ),
        ),
        if (_isLibrary &&
            (_savedCopy || _historyNotice != null || !_replyAllowed))
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _savedCopy
                  ? 'Saved copy · PC offline. Drafts stay on this phone.'
                  : _historyNotice ??
                        widget.libraryChat!.replyReason ??
                        'Replying is unavailable while this chat is working on the PC.',
            ),
          ),
        if (_isLibrary && _deliveryOperation != null)
          TextButton(
            onPressed: _checkDelivery,
            child: const Text('Delivery uncertain · Check delivery'),
          ),
        if (_isLibrary && !widget.libraryChat!.canReply && !_savedCopy)
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AgentScreen(
                  startNew: true,
                  initialFolder: widget.libraryChat!.folderPath,
                ),
              ),
            ),
            child: const Text(
              'Start new chat — creates a separate conversation',
            ),
          ),
        _composer(),
      ],
    );
  }

  Widget _workingRow() {
    final agentId = _active?.agent ?? 'mock';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          AgentActivityIcon(
            agentId: agentId,
            icon: _active?.icon,
            active: true,
            size: 22,
          ),
          const SizedBox(width: 10),
          Text(
            _stopping ? 'Stopping…' : 'Working…',
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 12,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  Color _agentBubbleColor(String? agentId) {
    switch (agentId) {
      case 'cursor':
        return const Color(0xFF18181C); // Clean neutral zinc
      case 'antigravity':
        return const Color(0xFF1D0E38); // Darker purple
      case 'claude':
        return const Color(0xFF2A150D); // Darker terracotta
      case 'opencode':
        return const Color(0xFF0E2320); // Darker teal
      default:
        return const Color(0xFF1E1E2F); // Darker blue-gray
    }
  }

  Color _userBubbleColor(String? agentId) {
    switch (agentId) {
      case 'cursor':
        return const Color(0xFF2B2D37); // Sleek zinc/slate
      case 'antigravity':
        return const Color(0xFF9F54FF); // Bright purple
      case 'claude':
        return const Color(0xFFE57A55); // Bright terracotta
      case 'opencode':
        return const Color(0xFF12C9B6); // Bright teal
      default:
        return const Color(0xFF2A6AFF); // Bright blue
    }
  }

  Color _userBubbleTextColor(String? agentId) {
    switch (agentId) {
      default:
        return Colors.white; // White text for colored bubbles
    }
  }

  Color _appBackgroundColor(String? agentId) => const Color(0xFF0B0D12);
  Color _panelBackgroundColor(String? agentId) => const Color(0xFF141821);

  Color _borderColor(String? agentId) {
    switch (agentId) {
      case 'cursor':
        return const Color(0xFF27272E); // Subtle dark border
      case 'antigravity':
        return const Color(0xFF281845); // Dark purple border
      case 'claude':
        return const Color(0xFF3A2015); // Dark terracotta border
      case 'opencode':
        return const Color(0xFF15332E); // Dark teal border
      default:
        return const Color(0xFF22223A); // Default purplish gray
    }
  }

  Color _inputBorderColor(String? agentId) {
    switch (agentId) {
      case 'cursor':
        return const Color(0xFF383842); // Lighter dark border
      case 'antigravity':
        return const Color(0xFF352055); // Lighter purple border
      case 'claude':
        return const Color(0xFF4A2B1C); // Lighter terracotta border
      case 'opencode':
        return const Color(0xFF1C453E); // Lighter teal border
      default:
        return const Color(0xFF2A2A40); // Default lighter purplish gray
    }
  }

  Color _chipBackgroundColor(String? agentId) {
    switch (agentId) {
      case 'cursor':
        return const Color(0xFF222228); // Dark neutral gray
      case 'antigravity':
        return const Color(0xFF1F1235); // Dark purple
      case 'claude':
        return const Color(0xFF2A150D); // Dark terracotta
      case 'opencode':
        return const Color(0xFF102824); // Dark teal
      default:
        return const Color(0xFF1E1E2E); // Default purplish gray
    }
  }

  Widget _bubble(AgentEvent e) {
    switch (e.kind) {
      case 'user':
        final thumbs = _thumbsBySeq[e.seq];
        return _align(
          Alignment.centerRight,
          SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (thumbs != null && thumbs.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      alignment: WrapAlignment.end,
                      children: [
                        for (final b in thumbs)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.memory(
                              b,
                              width: 88,
                              height: 88,
                              fit: BoxFit.cover,
                            ),
                          ),
                      ],
                    ),
                  )
                else if (e.images.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      e.images.join(', '),
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                  ),
                if ((e.text ?? '').isNotEmpty)
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: _userBubbleColor(_active?.agent),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      e.text ?? '',
                      style: TextStyle(
                        color: _userBubbleTextColor(_active?.agent),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      case 'text':
      case 'text-delta':
      case 'result':
        if ((e.text ?? '').trim().isEmpty) {
          if (e.kind == 'result' &&
              _display.isNotEmpty &&
              e.seq == _display.last.seq) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              child: Text(
                'Done',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                ),
              ),
            );
          }
          return const SizedBox.shrink();
        }
        return _align(
          Alignment.centerLeft,
          SelectionArea(
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 6),
              decoration: BoxDecoration(
                color: _agentBubbleColor(_active?.agent),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MarkdownBody(
                    data: e.text ?? '',
                    inlineSyntaxes: [IpAutolinkSyntax()],
                    builders: {
                      'a': LinkActionBuilder(client: _client),
                      'pre': CodeBlockBuilder(),
                    },
                    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                        .copyWith(
                          p: const TextStyle(color: Colors.white, fontSize: 14),
                          a: const TextStyle(
                            color: Color(0xFF5CA3FF),
                            fontSize: 14,
                            decoration: TextDecoration.underline,
                          ),
                          code: const TextStyle(
                            color: Colors.white70,
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [_CopyButton(text: e.text ?? '')],
                  ),
                ],
              ),
            ),
          ),
        );
      case 'thinking':
      case 'status':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          child: SelectionArea(
            child: Text(
              e.text ?? 'Thinking…',
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 12,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        );
      case 'tool-start':
        if (_isQuestionTool(e.toolName)) {
          return _questionBubble(e, running: true);
        }
        return _toolCard(e, running: true);
      case 'tool-end':
        if (_isQuestionTool(e.toolName)) {
          return _questionBubble(e, running: false);
        }
        return _toolCard(e, running: false);
      case 'permission-request':
        final isPending =
            _active != null &&
            (e.refId == null || !_resolvedApprovals.contains(e.refId!));
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          child: SelectionArea(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _panelBackgroundColor(_active?.agent),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: const Color(0xFFF0C040).withValues(alpha: 0.5),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.text ?? 'Allow this tool?',
                    style: const TextStyle(
                      color: Color(0xFFF0C040),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    e.toolName ?? 'tool',
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                  if ((e.toolInput ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 8),
                      child: Text(
                        e.toolInput!,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: Colors.white54,
                        ),
                      ),
                    ),
                  if (isPending)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: const BorderSide(color: Colors.white24),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                              ),
                              onPressed: () =>
                                  _submitPermission(e.refId, false),
                              child: const Text('Deny'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFFF0C040),
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                              ),
                              onPressed: () => _submitPermission(e.refId, true),
                              child: const Text('Allow'),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Responded',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.white38,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      case 'error':
        final errorText = (e.text ?? '').trim();
        if (errorText.isEmpty ||
            errorText.toLowerCase().contains(
              'is not a valid artifact path; artifacts must be in',
            )) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.all(8),
          child: SelectionArea(
            child: MarkdownBody(
              data: errorText,
              inlineSyntaxes: [IpAutolinkSyntax()],
              builders: {'a': LinkActionBuilder(client: _client)},
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                  .copyWith(
                    p: const TextStyle(color: Color(0xFFEE5555), fontSize: 13),
                    a: const TextStyle(
                      color: Color(0xFF93C5FD),
                      fontSize: 13,
                      decoration: TextDecoration.underline,
                    ),
                    code: const TextStyle(
                      color: Color(0xFFEE5555),
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
            ),
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  void _openToolFile(ToolFileInfo info) {
    final client = _client;
    if (client == null) return;
    showFileViewerModal(
      context: context,
      client: client,
      filePath: info.filePath,
      rawContent: info.rawContent,
      title: info.title,
      subtitle: info.subtitle ?? info.filePath,
      isPlan: info.isPlan,
    );
  }

  Widget _toolGroup(List<AgentEvent> tools) {
    final running = toolGroupRunning(tools);
    final summary = toolGroupSummary(tools);
    final planEvent = tools.where((t) {
      final info = extractToolFileInfo(t);
      return info?.isPlan == true;
    }).firstOrNull;
    final planInfo = planEvent != null ? extractToolFileInfo(planEvent) : null;

    // Painted by a Material (not a DecoratedBox) so the ExpansionTile's ink
    // and background stay visible; a colored box here trips a debug assert.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: _panelBackgroundColor(_active?.agent),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: _borderColor(_active?.agent)),
        ),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: PageStorageKey<int>(tools.first.seq),
            initiallyExpanded: false,
            tilePadding: const EdgeInsets.symmetric(horizontal: 12),
            childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            leading: running && _busy && _active != null
                ? AgentActivityIcon(
                    agentId: _active!.agent,
                    icon: _active!.icon,
                    active: true,
                    size: 18,
                  )
                : Icon(
                    running
                        ? Icons.hourglass_top
                        : (planInfo != null
                              ? Icons.assignment_turned_in_outlined
                              : Icons.check_circle_outline),
                    size: 18,
                    color: running
                        ? const Color(0xFFF0C040)
                        : (planInfo != null
                              ? const Color(0xFFC084FC)
                              : const Color(0xFF4ADE80)),
                  ),
            title: Text(
              _isLibrary ? 'Work details' : toolGroupTitle(tools),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            subtitle: summary.isEmpty
                ? null
                : Text(
                    summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: planInfo != null
                          ? const Color(0xFFC084FC).withValues(alpha: 0.85)
                          : Colors.white54,
                    ),
                  ),
            trailing: running
                ? IconButton(
                    tooltip: _stopping ? 'Stopping…' : 'Stop',
                    icon: _stopping
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.stop, size: 20),
                    onPressed: _stopping ? null : _cancel,
                  )
                : (planInfo != null && _client != null)
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      InkWell(
                        onTap: () => _openToolFile(planInfo),
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(
                              0xFF9F54FF,
                            ).withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: const Color(
                                0xFF9F54FF,
                              ).withValues(alpha: 0.5),
                            ),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.assignment_outlined,
                                size: 12,
                                color: Color(0xFFC084FC),
                              ),
                              SizedBox(width: 4),
                              Text(
                                'View plan',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFFC084FC),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.expand_more,
                        size: 20,
                        color: Colors.white54,
                      ),
                    ],
                  )
                : null,
            children: [
              for (final e in tools)
                _toolCard(e, running: e.kind == 'tool-start', nested: true),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolCard(AgentEvent e, {required bool running, bool nested = false}) {
    final detail = (e.toolInput ?? '').trim();
    final output = (e.toolOutput ?? '').trim();
    final fileInfo = extractToolFileInfo(e);
    final isPlan = fileInfo?.isPlan == true;
    final isFile =
        fileInfo != null &&
        !isPlan &&
        (fileInfo.filePath != null || fileInfo.rawContent != null);
    final canOpen = !running && fileInfo != null && _client != null;

    final displayName = fileInfo != null
        ? (isPlan
              ? (fileInfo.title.isNotEmpty && fileInfo.title != 'Plan'
                    ? fileInfo.title
                    : 'Implementation Plan')
              : fileInfo.title)
        : (e.toolName == 'task' || e.toolName == 'run_command'
              ? 'Command'
              : (e.toolName ?? 'tool'));

    String? displaySubtitle;
    if (fileInfo != null && isPlan) {
      if (fileInfo.subtitle != null &&
          fileInfo.subtitle!.isNotEmpty &&
          fileInfo.subtitle != 'Agent Plan') {
        displaySubtitle = fileInfo.subtitle;
      } else if (detail.isNotEmpty &&
          detail != (e.toolName ?? '') &&
          !detail.startsWith('{')) {
        displaySubtitle = detail;
      } else if (fileInfo.rawContent != null) {
        final firstLine = fileInfo.rawContent!
            .split('\n')
            .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
        displaySubtitle = firstLine
            .replaceFirst(RegExp(r'^[#\s*-]+'), '')
            .trim();
      }
    } else {
      if (detail.startsWith('{')) {
        try {
          final decoded = jsonDecode(detail);
          if (decoded is Map) {
            final cmd =
                decoded['CommandLine'] ??
                decoded['commandLine'] ??
                decoded['command'] ??
                decoded['cmd'] ??
                decoded['path'];
            if (cmd != null && '$cmd'.trim().isNotEmpty) {
              displaySubtitle = '$cmd'.trim();
            }
          }
        } catch (_) {}
      }
      if (displaySubtitle == null &&
          detail.isNotEmpty &&
          detail != (e.toolName ?? '')) {
        displaySubtitle = detail;
      }
    }

    final showDetail =
        displaySubtitle != null && displaySubtitle.trim().isNotEmpty;

    return SelectionArea(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: canOpen ? () => _openToolFile(fileInfo) : null,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            margin: EdgeInsets.symmetric(vertical: nested ? 3 : 2),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: nested
                  ? (isPlan
                        ? const Color(0xFF1E1333)
                        : _appBackgroundColor(_active?.agent))
                  : _panelBackgroundColor(_active?.agent),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isPlan
                    ? const Color(0xFF9F54FF).withValues(alpha: 0.4)
                    : _borderColor(_active?.agent),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      running
                          ? Icons.play_arrow
                          : (isPlan
                                ? Icons.assignment_outlined
                                : (isFile
                                      ? Icons.description_outlined
                                      : Icons.check)),
                      size: 14,
                      color: running
                          ? const Color(0xFFF0C040)
                          : (isPlan
                                ? const Color(0xFFC084FC)
                                : (isFile
                                      ? const Color(0xFF93C5FD)
                                      : const Color(0xFF4ADE80))),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        displayName,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                          color: isPlan
                              ? const Color(0xFFE9D5FF)
                              : Colors.white,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (canOpen) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color:
                              (isPlan
                                      ? const Color(0xFF9F54FF)
                                      : const Color(0xFF38BDF8))
                                  .withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color:
                                (isPlan
                                        ? const Color(0xFF9F54FF)
                                        : const Color(0xFF38BDF8))
                                    .withValues(alpha: 0.4),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isPlan
                                  ? Icons.assignment_outlined
                                  : Icons.description_outlined,
                              size: 11,
                              color: isPlan
                                  ? const Color(0xFFC084FC)
                                  : const Color(0xFF93C5FD),
                            ),
                            const SizedBox(width: 3),
                            Text(
                              isPlan ? 'View plan' : 'View file',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: isPlan
                                    ? const Color(0xFFC084FC)
                                    : const Color(0xFF93C5FD),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
                if (showDetail)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, left: 20),
                    child: Text(
                      displaySubtitle,
                      maxLines: isPlan ? 3 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: isPlan
                            ? const Color(0xFFD8B4FE).withValues(alpha: 0.8)
                            : Colors.white54,
                      ),
                    ),
                  ),
                if (!running && output.isNotEmpty && !isPlan)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, left: 20),
                    child: Text(
                      output,
                      maxLines: _looksLikeDiff(output) ? 12 : 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: _looksLikeDiff(output) ? 'monospace' : null,
                        fontSize: 11,
                        color: _looksLikeDiff(output)
                            ? const Color(0xFF93C5FD)
                            : const Color(0xFF6EE7B7),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _isQuestionTool(String? name) {
    if (name == null) return false;
    final n = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return n == 'askquestion' ||
        n == 'askuser' ||
        n == 'askfollowupquestion' ||
        n == 'question' ||
        n == 'promptuser' ||
        n == 'inputprompt';
  }

  Widget _questionBubble(AgentEvent e, {required bool running}) {
    final input = e.toolInput ?? '';
    if (input.isEmpty) return _toolCard(e, running: running);

    final List<Map<String, dynamic>> parsedQuestions = [];
    try {
      final json = jsonDecode(input);
      if (json is Map) {
        if (json.containsKey('questions') && json['questions'] is List) {
          final qList = json['questions'] as List;
          for (final q in qList) {
            if (q is Map) {
              final text =
                  q['question']?.toString() ??
                  q['prompt']?.toString() ??
                  q['title']?.toString() ??
                  'Question';
              final opts = <String>[];
              final rawOpts =
                  q['options'] ??
                  q['choices'] ??
                  q['suggested_answers'] ??
                  q['items'];
              if (rawOpts is List) {
                for (final opt in rawOpts) {
                  if (opt != null) opts.add(opt.toString());
                }
              }
              parsedQuestions.add({'question': text, 'options': opts});
            }
          }
        } else {
          final text =
              json['question']?.toString() ??
              json['prompt']?.toString() ??
              json['message']?.toString() ??
              json['query']?.toString() ??
              'Question';
          final opts = <String>[];
          final rawOpts =
              json['options'] ??
              json['choices'] ??
              json['suggested_answers'] ??
              json['items'];
          if (rawOpts is List) {
            for (final opt in rawOpts) {
              if (opt != null) opts.add(opt.toString());
            }
          }
          parsedQuestions.add({'question': text, 'options': opts});
        }
      }
    } catch (_) {}

    if (parsedQuestions.isEmpty) {
      parsedQuestions.add({
        'question': 'Agent question',
        'options': <String>[],
      });
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _panelBackgroundColor(_active?.agent),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: running
                ? const Color(0xFFF0C040).withValues(alpha: 0.6)
                : _borderColor(_active?.agent),
            width: running ? 1.5 : 1,
          ),
          boxShadow: running
              ? [
                  BoxShadow(
                    color: const Color(0xFFF0C040).withValues(alpha: 0.08),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  running ? Icons.help_outline : Icons.check_circle_outline,
                  size: 16,
                  color: running
                      ? const Color(0xFFF0C040)
                      : const Color(0xFF4ADE80),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    running ? 'Needs Your Input' : 'Answered',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: running
                          ? const Color(0xFFF0C040)
                          : const Color(0xFF4ADE80),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            for (int i = 0; i < parsedQuestions.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              Text(
                parsedQuestions[i]['question'] as String,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              ),
              if ((parsedQuestions[i]['options'] as List<String>).isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: (parsedQuestions[i]['options'] as List<String>)
                        .map((opt) {
                          return ActionChip(
                            label: Text(
                              opt,
                              style: TextStyle(
                                fontSize: 13,
                                color: running && !_busy
                                    ? Colors.white
                                    : Colors.white70,
                              ),
                            ),
                            backgroundColor: _appBackgroundColor(
                              _active?.agent,
                            ),
                            side: BorderSide(
                              color: running
                                  ? const Color(0xFF2A6AFF)
                                  : _borderColor(_active?.agent),
                            ),
                            elevation: running ? 1 : 0,
                            onPressed: running && !_busy
                                ? () {
                                    _input.text = opt;
                                    _send();
                                  }
                                : null,
                          );
                        })
                        .toList(),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  bool _looksLikeDiff(String s) =>
      s.contains('diff --git') || s.contains('\n@@ ') || s.startsWith('@@ ');

  Widget _align(Alignment a, Widget child) => Align(
    alignment: a,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: child,
    ),
  );

  void _showMicPermissionSnack({required bool openSettings}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'Microphone permission is required for voice input.',
        ),
        action: openSettings
            ? SnackBarAction(label: 'Settings', onPressed: openAppSettings)
            : null,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  Future<bool> _ensureMicPermission() async {
    var status = await Permission.microphone.status;
    if (status.isGranted) return true;
    status = await Permission.microphone.request();
    if (status.isGranted) return true;
    _showMicPermissionSnack(openSettings: status.isPermanentlyDenied);
    return false;
  }

  Future<void> _toggleListen() async {
    if (_userWantsListen || _isListening) {
      await _stopListen();
      return;
    }
    await _startListen();
  }

  Future<void> _stopListen() async {
    _userWantsListen = false;
    _listenGen++;
    _listenStarting = false;
    _listenSessionWasActive = false;
    if (mounted) setState(() => _isListening = false);
    await _speech.stop();
  }

  void _scheduleListenRestart() {
    if (!_userWantsListen || _listenStarting) return;
    _listenStarting = true;
    unawaited(_listenSession(restart: true));
  }

  void _onSpeechStatus(String status) {
    if (!mounted) return;
    if (isSpeechStatusListening(status)) {
      _listenSessionWasActive = true;
    }
    if (shouldRestartListen(
      userWantsListen: _userWantsListen,
      sessionWasActive: _listenSessionWasActive,
      status: status,
    )) {
      _scheduleListenRestart();
    }
  }

  void _onSpeechError(SpeechRecognitionError val) {
    if (!mounted) return;
    final errorMsg = val.errorMsg;
    if (shouldRestartListen(
      userWantsListen: _userWantsListen,
      sessionWasActive: _listenSessionWasActive,
      errorMsg: errorMsg,
    )) {
      _scheduleListenRestart();
      return;
    }
    if (isBenignSpeechError(errorMsg)) return;
    unawaited(_stopListen());
    if (errorMsg == 'error_permission' ||
        errorMsg == 'error_insufficient_permissions') {
      Permission.microphone.isGranted.then((appGranted) {
        if (!mounted) return;
        if (appGranted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(speechServicePermissionErrorMessage),
              duration: Duration(seconds: 5),
            ),
          );
        } else {
          _showMicPermissionSnack(openSettings: true);
        }
      });
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(speechErrorMessage(errorMsg)),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _startListen() async {
    if (!await _ensureMicPermission()) return;

    try {
      // Always initialize: first tap requests the mic, later taps reuse it.
      final available = await _speech.initialize(
        onStatus: _onSpeechStatus,
        onError: _onSpeechError,
        debugLogging: kDebugMode,
        options: speechInitOptions(),
      );

      if (!available) {
        final granted = await Permission.microphone.isGranted;
        if (mounted && granted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Speech recognition is unavailable. Enable Speech Services by Google, then try again.',
              ),
            ),
          );
        }
        return;
      }

      if (!await _speech.hasPermission) {
        final appGranted = await Permission.microphone.isGranted;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                appGranted
                    ? speechServicePermissionErrorMessage
                    : speechErrorMessage('error_permission'),
              ),
              action: appGranted
                  ? null
                  : SnackBarAction(
                      label: 'Settings',
                      onPressed: openAppSettings,
                    ),
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return;
      }

      _userWantsListen = true;
      _listenSessionWasActive = false;
      _preListeningText = _input.text.isNotEmpty && !_input.text.endsWith(' ')
          ? '${_input.text} '
          : _input.text;
      if (mounted) setState(() => _isListening = true);
      _listenStarting = true;
      await _listenSession(restart: false);
    } catch (e) {
      _userWantsListen = false;
      _listenStarting = false;
      if (mounted) {
        setState(() => _isListening = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start voice input: $e')),
        );
      }
    }
  }

  Future<void> _listenSession({required bool restart}) async {
    final gen = ++_listenGen;
    _listenStarting = true;
    final localeId = speechLocaleId(Localizations.localeOf(context));
    try {
      // Google's recognizer often returns error_client if listen() races
      // the just-created SpeechRecognizer.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (!mounted || !_userWantsListen || gen != _listenGen) return;
      if (restart && _speech.isListening) {
        await _speech.stop();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (!mounted || !_userWantsListen || gen != _listenGen) return;
      }

      await _speech.listen(
        onResult: (val) {
          if (!mounted || !_userWantsListen) return;
          setState(() {
            _input.text = '$_preListeningText${val.recognizedWords}';
            _input.selection = TextSelection.fromPosition(
              TextPosition(offset: _input.text.length),
            );
            if (val.finalResult) {
              _preListeningText = commitSpeechPrefix(
                _preListeningText,
                val.recognizedWords,
              );
            }
          });
        },
        listenOptions: speechListenOptions().copyWith(localeId: localeId),
      );
      if (!mounted || gen != _listenGen) return;
      _listenSessionWasActive = true;
      setState(() => _isListening = _userWantsListen);
    } catch (e) {
      if (gen != _listenGen) return;
      _userWantsListen = false;
      if (mounted) {
        setState(() => _isListening = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              restart
                  ? 'Voice input stopped: $e'
                  : 'Failed to start voice input: $e',
            ),
          ),
        );
      }
    } finally {
      if (gen == _listenGen) _listenStarting = false;
    }
  }

  Widget _composer() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_needsSignIn)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: FilledButton.tonal(
                  onPressed: _busy
                      ? null
                      : () {
                          _input.text = 'login';
                          _send();
                        },
                  child: const Text('Sign in on the PC'),
                ),
              ),
            Container(
              decoration: BoxDecoration(
                color: _panelBackgroundColor(_active?.agent),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _inputBorderColor(_active?.agent)),
              ),
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_photos.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                      child: SizedBox(
                        height: 64,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: _photos.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 8),
                          itemBuilder: (_, i) {
                            final p = _photos[i];
                            return Stack(
                              clipBehavior: Clip.none,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.memory(
                                    p.bytes,
                                    width: 64,
                                    height: 64,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                                Positioned(
                                  top: -6,
                                  right: -6,
                                  child: IconButton(
                                    visualDensity: VisualDensity.compact,
                                    style: IconButton.styleFrom(
                                      backgroundColor: _appBackgroundColor(
                                        _active?.agent,
                                      ),
                                      minimumSize: const Size(22, 22),
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    iconSize: 14,
                                    onPressed: () =>
                                        setState(() => _photos.removeAt(i)),
                                    icon: const Icon(Icons.close),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 6,
                    enabled: _isLibrary || !_busy,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: _needsSignIn
                          ? 'login or CURSOR_API_KEY=…'
                          : _photos.isEmpty
                          ? 'Write a reply…'
                          : 'Add a note about the photo…',
                      isDense: true,
                      filled: true,
                      fillColor: Colors.transparent,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Photo, model, thinking, folder…',
                        onPressed: _openComposerMenu,
                        icon: const Icon(Icons.add),
                      ),
                      const SizedBox(width: 2),
                      if (!_isLibrary) _modeChip(),
                      const SizedBox(width: 6),
                      if (!_isLibrary) Flexible(child: _modelChip()),
                      const SizedBox(width: 4),
                      const Spacer(),
                      IconButton(
                        tooltip: _isListening
                            ? 'Stop listening'
                            : 'Voice to text',
                        onPressed: _toggleListen,
                        icon: Icon(
                          _isListening ? Icons.stop_circle : Icons.mic,
                          color: _isListening ? Colors.red : Colors.white70,
                        ),
                      ),
                      _sendOrStopButton(),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sendOrStopButton() {
    final stopMode =
        _stopping ||
        (_canStop && _input.text.trim().isEmpty && _photos.isEmpty);
    if (!stopMode) {
      return IconButton.filled(
        tooltip: 'Send',
        onPressed: _replyAllowed ? _send : null,
        icon: const Icon(Icons.arrow_upward),
      );
    }
    return IconButton.filled(
      tooltip: _stopping ? 'Stopping…' : 'Stop',
      onPressed: _stopping ? null : _cancel,
      icon: _stopping
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.stop),
    );
  }

  Widget _modeChip() {
    final modeColor = switch (_mode) {
      'plan' => const Color(0xFFF59E0B),
      'ask' => const Color(0xFF38BDF8),
      _ => const Color(0xFF818CF8),
    };
    final canPick = _caps.modes.length > 1;
    return Tooltip(
      message: canPick
          ? 'Mode: ${_modeLabel(_mode)} (tap to switch)'
          : 'Mode: ${_modeLabel(_mode)}',
      child: Material(
        color: _chipBackgroundColor(_active?.agent),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: _busy ? null : (canPick ? _pickMode : _openComposerMenu),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _inputBorderColor(_active?.agent)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_modeIcon(_mode), size: 14, color: modeColor),
                const SizedBox(width: 4),
                Text(
                  _modeLabel(_mode),
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _modelChip() {
    final canPick = _pickerModels.isNotEmpty;
    final isOpenCode = _active?.agent == 'opencode';
    final plan = _activeAgent?.capabilities.plan;
    final hasGo = isOpenCode && plan == 'go';
    final noGo = isOpenCode && plan != null && plan != 'go';
    return Tooltip(
      message: [
        'Model: $_modelLabel${canPick ? ' (tap to switch)' : ''}',
        if (hasGo) '· OpenCode Go plan active',
        if (noGo) '· Free/BYOK plan — subscribe at opencode.ai',
      ].join(' '),
      child: Material(
        color: _chipBackgroundColor(_active?.agent),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: _busy ? null : (canPick ? _pickModel : _openComposerMenu),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _inputBorderColor(_active?.agent)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.memory_outlined,
                  size: 14,
                  color: Color(0xFF8A8A9A),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    _modelLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: Colors.white70,
                    ),
                  ),
                ),
                // Go plan badge in composer bar
                if (hasGo) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.verified, size: 11, color: Colors.green),
                ],
                if (noGo) ...[
                  const SizedBox(width: 4),
                  Icon(Icons.info_outline, size: 11, color: Colors.orange[300]),
                ],
                if (canPick) ...[
                  const SizedBox(width: 2),
                  const Icon(
                    Icons.arrow_drop_down,
                    size: 14,
                    color: Colors.white38,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CopyButton extends StatefulWidget {
  final String text;
  const _CopyButton({required this.text});

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    if (widget.text.isEmpty) return;
    final textToCopy = cleanCopyMessage(widget.text);
    await Clipboard.setData(ClipboardData(text: textToCopy));
    if (!mounted) return;
    setState(() => _copied = true);
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied to clipboard'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
      tooltip: 'Copy message',
      onPressed: _copy,
      icon: Icon(
        _copied ? Icons.check : Icons.copy_rounded,
        size: 14,
        color: _copied ? const Color(0xFF4ADE80) : Colors.white38,
      ),
    );
  }
}

/// A chat transcript: host events keyed by the host's `seq`, plus phone-only
/// notes (slash-command replies, send errors, "Stopped" settlements) kept in a
/// separate key space. A phone note can never shadow or swallow a host event
/// that later arrives with the same seq, and dedupe only ever compares host
/// seqs with host seqs.
class AgentTranscript {
  final List<AgentEvent> _host = [];
  final Set<int> _hostSeqs = {};
  final List<({int anchor, int order, bool settlement, AgentEvent event})>
  _local = [];
  int _localCount = 0;

  /// Host events in arrival order (read-only view).
  List<AgentEvent> get host => List.unmodifiable(_host);
  bool get isEmpty => _host.isEmpty && _local.isEmpty;

  int get latestHostSeq {
    var max = 0;
    for (final e in _host) {
      if (e.seq > max) max = e.seq;
    }
    return max;
  }

  int? get oldestHostSeq {
    int? min;
    for (final e in _host) {
      if (e.seq > 0 && (min == null || e.seq < min)) min = e.seq;
    }
    return min;
  }

  /// Adds a live host event. Returns false when that host seq is already
  /// present (replayed push). Events without a seq are always kept.
  bool addHost(AgentEvent event) {
    if (event.seq > 0 && !_hostSeqs.add(event.seq)) return false;
    _host.add(event);
    return true;
  }

  void replaceHost(Iterable<AgentEvent> events) {
    _host
      ..clear()
      ..addAll(events);
    _hostSeqs
      ..clear()
      ..addAll(_host.map((e) => e.seq).where((seq) => seq > 0));
  }

  /// Prepends an older page, skipping events already present.
  void addOlder(Iterable<AgentEvent> events) {
    final fresh = [
      for (final e in events)
        if (e.seq <= 0 || _hostSeqs.add(e.seq)) e,
    ];
    _host.insertAll(0, fresh);
  }

  /// A phone-only status/error line, shown after the host events seen so far.
  void note(String kind, String text) => _addLocal(
    AgentEvent(
      seq: 0,
      ts: DateTime.now().millisecondsSinceEpoch,
      kind: kind,
      text: text,
    ),
  );

  void _addLocal(AgentEvent event, {bool settlement = false}) {
    final order = ++_localCount;
    _local.add((
      anchor: latestHostSeq,
      order: order,
      settlement: settlement,
      // Negative seqs are display-only keys; they never meet host seqs.
      event: AgentEvent(
        seq: -order,
        ts: event.ts,
        kind: event.kind,
        text: event.text,
        toolName: event.toolName,
        toolInput: event.toolInput,
        toolOutput: event.toolOutput,
        refId: event.refId,
      ),
    ));
  }

  /// Ends every unfinished tool on the phone so the UI leaves "Working".
  /// Settlements disappear by themselves once the host sends real tool ends.
  void settleOpenTools(String output) {
    final ts = DateTime.now().millisecondsSinceEpoch;
    for (final start in mergeToolEvents(
      display,
    ).where((e) => e.kind == 'tool-start')) {
      _addLocal(
        AgentEvent(
          seq: 0,
          ts: ts,
          kind: 'tool-end',
          toolName: start.toolName,
          toolInput: start.toolInput,
          toolOutput: output,
          refId: start.refId,
        ),
        settlement: true,
      );
    }
  }

  bool get hasOpenTools => transcriptHasOpenTools(display);

  void clear() {
    _host.clear();
    _hostSeqs.clear();
    _local.clear();
  }

  /// Host events with phone notes interleaved after the host event they
  /// followed.
  List<AgentEvent> get display {
    if (_local.isEmpty) return List.of(_host);
    // A settlement only stands in for a tool the host still shows as open.
    final open = <String, int>{};
    for (final e in mergeToolEvents(_host)) {
      if (e.kind != 'tool-start') continue;
      final key = '${e.refId}|${e.toolName}';
      open[key] = (open[key] ?? 0) + 1;
    }
    final locals =
        [
          for (final l in _local)
            if (!l.settlement) l else if (_take(open, l.event)) l,
        ]..sort((a, b) {
          final byAnchor = a.anchor.compareTo(b.anchor);
          return byAnchor != 0 ? byAnchor : a.order.compareTo(b.order);
        });
    final out = <AgentEvent>[];
    var i = 0;
    for (final h in _host) {
      while (i < locals.length && h.seq > 0 && locals[i].anchor < h.seq) {
        out.add(locals[i++].event);
      }
      out.add(h);
    }
    while (i < locals.length) {
      out.add(locals[i++].event);
    }
    return out;
  }

  static bool _take(Map<String, int> open, AgentEvent end) {
    final key = '${end.refId}|${end.toolName}';
    final count = open[key] ?? 0;
    if (count == 0) return false;
    open[key] = count - 1;
    return true;
  }
}

enum StopState { stopped, notRunning, unsupported, failed }

/// What actually happened when the user pressed Stop.
class StopOutcome {
  const StopOutcome(this.state, this.message);
  final StopState state;
  final String message;

  /// The turn is over on the PC (or was never running there).
  bool get ended => state == StopState.stopped || state == StopState.notRunning;
}

/// Turns the host's answer to `agent.cancel` / `chat.cancel` (or the error
/// thrown while asking) into an honest outcome for the UI.
StopOutcome describeStopResult(
  Object? result, {
  Object? error,
  bool library = false,
}) {
  if (error != null) {
    final reason = error is RpcException ? error.message : '$error';
    return StopOutcome(
      StopState.failed,
      'Couldn’t stop the agent: $reason. It may still be running on the PC.',
    );
  }
  if (result is Map && result['ok'] == false) {
    return library
        ? const StopOutcome(
            StopState.unsupported,
            'This conversation can’t be stopped from the phone. Stop it on the PC.',
          )
        : const StopOutcome(
            StopState.notRunning,
            'That task was no longer running on the PC.',
          );
  }
  return const StopOutcome(StopState.stopped, 'Stopped.');
}

/// Compact "what is the agent doing right now" header for a PC conversation,
/// built from the chat summary's `live` field (absent on older hosts).
class ChatLiveHeader extends StatefulWidget {
  const ChatLiveHeader({super.key, required this.live, this.now});
  final ChatLive live;

  /// Clock override for tests.
  final DateTime Function()? now;

  /// Whether [live] carries anything worth a header.
  static bool shows(ChatLive? live) =>
      live != null &&
      (const {'working', 'waiting', 'failed'}.contains(live.state) ||
          live.todos.isNotEmpty);

  @override
  State<ChatLiveHeader> createState() => _ChatLiveHeaderState();
}

class _ChatLiveHeaderState extends State<ChatLiveHeader> {
  Timer? _tick;
  bool _expanded = false;

  bool get _ticking =>
      widget.live.turnStartedAt != null &&
      (widget.live.state == 'working' || widget.live.state == 'waiting');

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(ChatLiveHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTimer();
  }

  void _syncTimer() {
    if (_ticking && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!_ticking) {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final live = widget.live;
    final color = Status.color(live.state);
    final now = (widget.now ?? DateTime.now)();
    final started = live.turnStartedAt;
    final todos = live.todos;
    final done = live.todosDone;
    final step =
        live.step ??
        live.activeTodo ??
        (live.state == 'waiting'
            ? 'Waiting for you'
            : Status.label(live.state));
    final meta = [
      if (live.model != null) live.model!,
      if (live.steps != null) '${live.steps} steps',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: NxCard(
        accent: color,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                LiveDot(color: color, pulse: live.state == 'working'),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    step,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: NX.text,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (started != null && _ticking) ...[
                  const SizedBox(width: 8),
                  Text(
                    formatElapsed(now.difference(started)),
                    style: const TextStyle(
                      color: NX.textDim,
                      fontSize: 12,
                      fontFeatures: NX.tabular,
                    ),
                  ),
                ],
              ],
            ),
            if (live.waitingFor != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: NX.waiting.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(NX.radiusSm),
                  border: Border.all(color: NX.waiting.withValues(alpha: .35)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.front_hand_outlined,
                      size: 16,
                      color: NX.waiting,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        live.waitingFor!,
                        style: const TextStyle(color: NX.text, fontSize: 12.5),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (todos.isNotEmpty) ...[
              const SizedBox(height: 8),
              InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: LinearProgressIndicator(
                            value: done / todos.length,
                            minHeight: 5,
                            color: color,
                            backgroundColor: NX.line.withValues(alpha: .6),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '$done/${todos.length}',
                        style: const TextStyle(
                          color: NX.textDim,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          fontFeatures: NX.tabular,
                        ),
                      ),
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                        color: NX.textDim,
                        semanticLabel: _expanded ? 'Hide plan' : 'Show plan',
                      ),
                    ],
                  ),
                ),
              ),
              if (_expanded)
                for (final todo in todos)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          todo.state == 'done'
                              ? Icons.check_circle
                              : todo.state == 'active'
                              ? Icons.play_circle_outline
                              : Icons.radio_button_unchecked,
                          size: 15,
                          color: todo.state == 'done'
                              ? NX.done
                              : todo.state == 'active'
                              ? NX.working
                              : NX.textFaint,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            todo.text,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: todo.state == 'done'
                                  ? NX.textFaint
                                  : NX.text,
                              decoration: todo.state == 'done'
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
            ],
            if (meta.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                meta,
                style: const TextStyle(color: NX.textFaint, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
