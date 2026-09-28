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

/// PC conversations will get their own screen. Skip the slow
/// `agent.listHostChats` scan on this tab until then.
const bool kAgentHostChatsInAgentTab = false;

class AgentScreen extends ConsumerStatefulWidget {
  const AgentScreen({super.key});

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
  final _events = <AgentEvent>[];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _imagePicker = ImagePicker();
  final _photos = <_PendingPhoto>[];
  final _thumbsBySeq = <int, List<Uint8List>>{};
  List<Uint8List>? _pendingThumbs;

  /// Permission requests that arrived while another chat was on screen, keyed by
  /// agentSessionId. Surfaced as a badge and asked when that chat is opened.
  final _pendingApprovals = <String, AgentEvent>{};
  final _resolvedApprovals = <String>{};
  String _mode = 'agent';
  String _thinking = 'medium';
  String? _model;
  List<AgentModelOption> _liveModels = [];
  bool _loading = true;
  bool _busy = false;
  bool _sending = false;
  int _menuTab = 0;
  int _chatTab = 0;
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

  RpcClient? get _client => ref.read(activeClientProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_onForeground());
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
        final raw = await client.request(
          'agent.history',
          {'agentSessionId': activeId},
        ) as List<dynamic>;
        history = raw
            .map((e) => AgentEvent.fromJson(e as Map<String, dynamic>))
            .toList();
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
          if (shouldSyncTranscript &&
              _active?.agentSessionId == activeId) {
            final merged = applyAgentHistorySnapshot(
              history,
              _events,
              busy: _busy,
            );
            _events
              ..clear()
              ..addAll(merged);
          }
        }
      });
      if (shouldSyncTranscript) _scrollToEnd();
      _flushPendingApproval();
      unawaited(_refreshGitTree());
    } catch (_) {
      // Stay on the last known transcript; the next resume will try again.
    }
  }

  /// Ask a permission request that arrived while this chat was in the background.
  void _flushPendingApproval() {
    final sessionId = _active?.agentSessionId;
    if (sessionId == null) return;
    final pending = _pendingApprovals.remove(sessionId);
    if (pending == null) return;
    unawaited(_askPermission(pending));
  }

  void _onSessionUpdate(Map<String, dynamic> msg) {
    final raw = msg['session'];
    if (raw is! Map<String, dynamic>) return;
    final updated = AgentSessionInfo.fromJson(raw);
    if (updated.icon != null) registerAgentIcon(updated.agent, updated.icon);
    if (!mounted) return;
    setState(() {
      final idx = _sessions
          .indexWhere((s) => s.agentSessionId == updated.agentSessionId);
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
          final settled = closeOpenTools(_events,
              output: 'Interrupted — host is no longer running this turn.');
          if (settled.length != _events.length) {
            _events
              ..clear()
              ..addAll(settled);
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
        _events.clear();
        _busy = false;
      }
    });
  }

  void _setBusy(bool busy) {
    _busy = busy;
    final session = _active;
    if (session == null) return;
    final updated = session.copyWith(busy: busy);
    _active = updated;
    final idx =
        _sessions.indexWhere((s) => s.agentSessionId == session.agentSessionId);
    if (idx != -1) _sessions[idx] = updated;
  }

  void _onPush(Map<String, dynamic> msg) {
    final sessionId = msg['agentSessionId'] as String?;
    final ev = msg['event'];
    if (ev is! Map<String, dynamic>) return;
    final parsed = AgentEvent.fromJson(ev);

    if (sessionId != null &&
        (parsed.kind == 'result' || parsed.kind == 'error')) {
      final idx =
          _sessions.indexWhere((s) => s.agentSessionId == sessionId);
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
        setState(() => _pendingApprovals[sessionId] = parsed);
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
    setState(() {
      _events.add(parsed);
      if (parsed.kind == 'result' || parsed.kind == 'error') _setBusy(false);
    });
    _scrollToEnd();
    if (parsed.kind == 'permission-request') {
      unawaited(_askPermission(parsed));
    }
  }

  void _scrollToEnd() {
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
    final client = _client;
    final session = _active;
    if (client == null || session == null || requestId == null || !mounted) {
      return;
    }
    setState(() => _resolvedApprovals.add(requestId));
    try {
      final res = await client.request('agent.permission', {
        'agentSessionId': session.agentSessionId,
        'requestId': requestId,
        'allow': allow,
      });
      if (!mounted) return;
      if (res is Map && res['ok'] == false) {
        _toast(res['reason'] == 'request already expired'
            ? 'That request already expired on the PC.'
            : 'The PC could not accept that answer.');
      } else if (mounted) {
        setState(() => _pendingApprovals.remove(session.agentSessionId));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _resolvedApprovals.remove(requestId));
        _toast('Could not reach the PC: $e');
      }
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
            Text(e.text ?? 'Allow this tool?',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(e.toolName ?? 'tool',
                style: const TextStyle(color: Color(0xFFF0C040))),
            if ((e.toolInput ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(e.toolInput!,
                    maxLines: 8,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: Colors.white70)),
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
      final created = await activeClient.request('agent.createSession', {
        'agent': agent.id,
        'title': agent.name,
        'cwd': cwd,
      }) as Map<String, dynamic>;
      final session = AgentSessionInfo.fromJson(created);
      setState(() {
        _sessions.removeWhere((x) => x.agentSessionId == session.agentSessionId);
        _sessions.insert(0, session);
        _active = session;
        _events.clear();
        _busy = false;
        _photos.clear();
        _liveModels = [];
        _gitTree = null;
      });
      await _loadComposerPrefs(agent.id, isNewChat: true);
      await _refreshModels(agent.id, force: true);
      await _refreshGitTree();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  Future<void> _openSession(AgentSessionInfo s) async {
    final client = _client;
    if (client == null) return;
    ++_syncGen;
    final raw =
        await client.request('agent.history', {'agentSessionId': s.agentSessionId})
            as List<dynamic>;
    if (!mounted) return;
    final loaded = normalizeTranscriptSeqs(raw
        .map((e) => AgentEvent.fromJson(e as Map<String, dynamic>))
        .toList());
    setState(() {
      _active = s;
      _busy = s.busy;
      _events
        ..clear()
        ..addAll(loaded);
      if (!s.busy && transcriptHasOpenTools(_events)) {
        final settled = closeOpenTools(_events,
            output: 'Interrupted — host restarted.');
        _events
          ..clear()
          ..addAll(settled);
      }
      _photos.clear();
      _liveModels = [];
      _resolvedApprovals.clear();
      _sessions.removeWhere((x) => x.agentSessionId == s.agentSessionId);
      _sessions.insert(0, s);
    });
    await _loadComposerPrefs(s.agent);
    await _refreshModels(s.agent, force: true);
    await _refreshGitTree();
    _scrollToEnd();
    // A request that landed while this chat was in the background is answered
    // now, instead of blocking the agent with no way to reach it.
    unawaited(Future<void>.delayed(const Duration(milliseconds: 250), _flushPendingApproval));
  }

  Future<void> _openHostChat(AgentHostChat chat) async {
    final client = _client;
    if (client == null) return;
    var cwd = chat.cwd.trim();
    if (cwd.isEmpty) {
      cwd = (await _pickProject())?.trim() ?? '';
      if (cwd.isEmpty) return;
    }
    try {
      final created = await client.request(
        'agent.openHostChat',
        {
          'agent': chat.agent,
          'hostChatId': chat.hostChatId,
          'cwd': cwd,
          'title': chat.title,
        },
        const Duration(seconds: 25),
      ) as Map<String, dynamic>;
      final session = AgentSessionInfo.fromJson(created);
      if (!mounted) return;
      setState(() {
        _sessions.removeWhere((s) => s.agentSessionId == session.agentSessionId);
        _sessions.insert(0, session);
      });
      await _openSession(session);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
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
      images: true,
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
            AgentModelOption(id: 'claude-sonnet-5-thinking-medium', name: 'Claude Sonnet 5'),
          ],
          images: true,
        );
      case 'opencode':
        return const AgentCapabilities(
          modes: ['agent', 'plan'],
          thinkingLevels: ['minimal', 'low', 'medium', 'high', 'max'],
          models: [
            AgentModelOption(id: 'opencode/deepseek-v4-flash-free', name: 'DeepSeek V4 Flash'),
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
            AgentModelOption(id: 'claude-sonnet-4-6', name: 'Claude Sonnet 4.6'),
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

  Future<void> _loadComposerPrefs(String agentId, {bool isNewChat = false}) async {
    final p = await SharedPreferences.getInstance();
    final caps = _caps;
    var mode = isNewChat ? 'agent' : (p.getString('agent-composer-$agentId-mode') ?? 'agent');
    if (!caps.modes.contains(mode)) {
      mode = caps.modes.isNotEmpty ? caps.modes.first : 'agent';
    }
    var thinking = p.getString('agent-composer-$agentId-thinking') ?? 'medium';
    if (caps.thinkingLevels.isNotEmpty && !caps.thinkingLevels.contains(thinking)) {
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
      final raw = await client.requestList(
        'agent.listModels',
        {'agent': agentId, if (force) 'refresh': true},
      );
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
    if (_busy || _sending) return;
    final text = _input.text.trim();
    final session = _active;
    final client = _client;
    if ((text.isEmpty && _photos.isEmpty) || session == null || client == null) {
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
      final isDefaultTitle = currentTitle.isEmpty ||
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
        final clipped =
            summary.length > 50 ? '${summary.substring(0, 47)}…' : summary;
        if (clipped.isNotEmpty) {
          final updated = session.copyWith(title: clipped);
          _active = updated;
          final idx = _sessions
              .indexWhere((s) => s.agentSessionId == session.agentSessionId);
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
        await client.request(
          'agent.prompt',
          {
            'agentSessionId': session.agentSessionId,
            'text': text,
            if (_model != null && _model != 'auto' && _model != 'default')
              'model': _model,
            if (_mode != 'agent') 'mode': _mode,
            if (_thinking.isNotEmpty && _modelSupportsEffort) 'thinking': _thinking,
            if (photos.isNotEmpty)
              'images': [
                for (final p in photos)
                  {
                    'name': p.name,
                    'mime': p.mime,
                    'data': base64Encode(p.bytes),
                  },
              ],
          },
          const Duration(seconds: 60),
        );
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _setBusy(false);
          _pendingThumbs = null;
          _events.add(AgentEvent(
            seq: _events.length + 1,
            ts: DateTime.now().millisecondsSinceEpoch,
            kind: 'error',
            text: e.toString(),
          ));
        });
      }
    } finally {
      _sending = false;
    }
  }

  bool get _canStop => _busy || transcriptHasOpenTools(_events);

  Future<void> _cancel() async {
    final session = _active;
    final client = _client;
    if (session == null) return;
    if (mounted) {
      setState(() {
        _setBusy(false);
        final settled = closeOpenTools(_events, output: 'Stopped.');
        _events
          ..clear()
          ..addAll(settled);
      });
    }
    if (client != null) {
      try {
        await client.request(
            'agent.cancel', {'agentSessionId': session.agentSessionId});
      } catch (_) {}
    }
  }

  void _localStatus(String text) {
    setState(() {
      _events.add(AgentEvent(
        seq: _events.length + 1,
        ts: DateTime.now().millisecondsSinceEpoch,
        kind: 'status',
        text: text,
      ));
    });
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
        _localStatus('No model matching "$arg". Open the model picker to see the list.');
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
        final name =
            _thinkingLabel(level).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
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
          final idx = _sessions
              .indexWhere((s) => s.agentSessionId == updated.agentSessionId);
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
    for (var i = _events.length - 1; i >= 0; i--) {
      final e = _events[i];
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
      final raw = await client.request('agent.setSessionCwd', {
        'agentSessionId': s.agentSessionId,
        'cwd': cwd,
      }) as Map<String, dynamic>;
      final updated = AgentSessionInfo.fromJson(raw);
      if (!mounted) return;
      setState(() {
        final idx =
            _sessions.indexWhere((x) => x.agentSessionId == updated.agentSessionId);
        if (idx != -1) _sessions[idx] = updated;
        if (_active?.agentSessionId == updated.agentSessionId) {
          _active = updated;
        }
      });
      await _refreshGitTree();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  Future<void> _deleteSession(AgentSessionInfo s) async {
    final client = _client;
    if (client != null) {
      try {
        await client
            .request('agent.close', {'agentSessionId': s.agentSessionId});
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _sessions.removeWhere((x) => x.agentSessionId == s.agentSessionId);
      if (_active?.agentSessionId == s.agentSessionId) {
        _active = null;
        _events.clear();
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
      final idx =
          _sessions.indexWhere((x) => x.agentSessionId == s.agentSessionId);
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

  Future<void> _closeActive() async {
    final session = _active;
    final client = _client;
    if (session == null || client == null) return;
    await client.request(
        'agent.close', {'agentSessionId': session.agentSessionId});
    setState(() {
      _sessions.removeWhere((s) => s.agentSessionId == session.agentSessionId);
      _active = null;
      _events.clear();
      _busy = false;
      _chatTab = 0;
    });
  }

  void _leaveChat() {
    setState(() {
      _active = null;
      _events.clear();
      _busy = false;
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
        setState(() =>
            _gitTree = GitWorkingTree.fromJson(Map<String, dynamic>.from(raw)));
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
              title: Text('Mode',
                  style: TextStyle(fontWeight: FontWeight.w600)),
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
              title: Text('Add to this turn',
                  style: TextStyle(fontWeight: FontWeight.w600)),
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
                  : Text('Not supported for $_modelLabel',
                      style: const TextStyle(color: Colors.white38)),
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
              title: Text('Agent',
                  style: TextStyle(fontWeight: FontWeight.w600)),
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
              title: Text('Thinking',
                  style: TextStyle(fontWeight: FontWeight.w600)),
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
      _localStatus('This agent has no model list yet. Restart the PC host and try again.');
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
                    final id = m.id.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
                    final name = m.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
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
                          const Text('Model',
                              style: TextStyle(fontWeight: FontWeight.w600)),
                          if (isOpenCode && plan == 'go') ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.green.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                    color: Colors.green.withValues(alpha: 0.4)),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.verified,
                                      size: 11, color: Colors.green),
                                  SizedBox(width: 3),
                                  Text('Go plan',
                                      style: TextStyle(
                                          fontSize: 10.5,
                                          color: Colors.green,
                                          fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                      subtitle: const Text(
                          'Same agent — thinking is the chip next to this'),
                    ),
                    // Go plan info banner for OpenCode without Go
                    if (isOpenCode && plan != 'go')
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: Colors.orange.withValues(alpha: 0.35)),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.info_outline,
                                  size: 14,
                                  color: Colors.orange[300]),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Free / BYOK models shown. '
                                  'Subscribe at opencode.ai for the full catalog.',
                                  style: TextStyle(
                                      fontSize: 11.5,
                                      color: Colors.orange[300]),
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
                          final needsGo = isOpenCode &&
                              !m.id.contains('-free') &&
                              !m.id.contains('free') &&
                              plan != 'go';
                          return ListTile(
                            title: Text(m.name),
                            subtitle: needsGo
                                ? Text('${m.id} · may require Go plan',
                                    style: const TextStyle(
                                        color: Colors.orange, fontSize: 12))
                                : Text(m.id,
                                    style: const TextStyle(
                                        color: Colors.white38, fontSize: 12)),
                            trailing: modelFamilyId(m.id) ==
                                    modelFamilyId(_model ?? '')
                                ? const Icon(Icons.check, color: Color(0xFF2A6AFF))
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
            'Restart the PC host (bun run lan) so photos actually reach the agent.',
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not add photo: $e')),
      );
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
    final mime = x.mimeType ??
        (lower.endsWith('.png')
            ? 'image/png'
            : lower.endsWith('.webp')
                ? 'image/webp'
                : 'image/jpeg');
    if (!mounted) return;
    setState(() {
      _photos.add(_PendingPhoto(
        name: x.name.isEmpty ? 'photo.jpg' : x.name,
        mime: mime,
        bytes: bytes,
      ));
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
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<RpcStatus>(connectionStatusProvider, (prev, next) {
      if (next == RpcStatus.connected && prev != RpcStatus.connected) {
        // Foreground resume always resyncs (events were missed). In-app socket
        // blips while chatting keep the live transcript — resync only when idle.
        unawaited(_onForeground(syncTranscript: !_busy));
      }
    });
    return PopScope(
      canPop: _active == null,
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
                  tooltip: 'Agent list',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _leaveChat,
                ),
          title: _active == null
              ? const Text('Agents', style: TextStyle(fontSize: 16))
              : InkWell(
                  onTap: () => _renameSessionDialog(_active!),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
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
                        const Icon(Icons.edit_outlined,
                            size: 14, color: Colors.white38),
                      ],
                    ),
                  ),
                ),
          actions: [
            if (_active != null)
              IconButton(
                tooltip: 'End chat',
                icon: const Icon(Icons.delete_outline),
                onPressed: _closeActive,
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
                        child: Text(_error!,
                            style: const TextStyle(color: Colors.white70)))
                : _active == null
                    ? _picker()
                    : _chatWithTerminal(),
      ),
    );
  }

  /// Per-agent permission policy. 'auto' is the escape hatch for when a request
  /// would otherwise sit unanswered on a phone that is not watching that chat.
  Widget _approvalToggle(AgentInfo a) {
    final auto = a.capabilities.approvalMode == 'auto';
    return Row(
      children: [
        const Text('Approvals',
            style: TextStyle(fontSize: 12, color: Color(0xFF8A8A9A))),
        const SizedBox(width: 10),
        _ApprovalChip(
          label: 'Ask me',
          selected: !auto,
          onTap: () => _setApprovalMode(a, 'ask'),
        ),
        const SizedBox(width: 6),
        _ApprovalChip(
          label: 'Automatic',
          selected: auto,
          onTap: () => _setApprovalMode(a, 'auto'),
        ),
      ],
    );
  }

  Future<void> _setApprovalMode(AgentInfo a, String mode) async {
    final client = _client;
    if (client == null) return;
    try {
      final res = await client.request('agent.setApprovalMode', {
        'agent': a.id,
        'mode': mode,
      });
      if (!mounted) return;
      if (res is Map && res['ok'] != true) {
        _toast('The PC rejected that approval setting.');
        return;
      }
      setState(() {
        _agents = _agents
            .map((x) => x.id == a.id
                ? x.copyWith(
                    capabilities: x.capabilities.copyWith(approvalMode: mode))
                : x)
            .toList();
      });
    } catch (_) {
      if (mounted) _toast('This PC does not support approval settings yet.');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _picker() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        const Text('NEW CHAT',
            style: TextStyle(
                fontSize: 11, letterSpacing: 0.8, color: Color(0xFF666677))),
        const SizedBox(height: 8),
        for (final a in _agents)
          Builder(
            builder: (context) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    leading: AgentMark(
                      agentId: a.id,
                      icon: a.icon,
                      color: agentMarkColor(a.id, available: a.available),
                    ),
                    title: Text(a.name),
                    subtitle: Text(a.available
                        ? 'Runs on the PC — chat here'
                        : 'CLI not installed on the PC'),
                    enabled: a.available,
                    trailing: a.available
                        ? FilledButton(
                            onPressed: () => _newChat(a),
                            child: const Text('Select'),
                          )
                        : null,
                    onTap: a.available ? () => _newChat(a) : null,
                  ),
                  if (a.available && a.capabilities.approvalMode != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: _approvalToggle(a),
                    ),
                ],
              );
            },
          ),
        const SizedBox(height: 16),
        if (kAgentHostChatsInAgentTab) ...[
          _menuTabs(),
          const SizedBox(height: 8),
        ],
        if (!kAgentHostChatsInAgentTab || _menuTab == 0) ...[
          if (_sessions.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24, horizontal: 16),
              child: Center(
                child: Text(
                  'No recent chats yet.\nStart a new chat above.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF666677), fontSize: 13),
                ),
              ),
            )
          else
            for (final s in _sessions)
              Builder(builder: (context) {
                final busy = ref.watch(terminalBusyProvider)[s.agentSessionId] ?? false;
                final needsApproval =
                    _pendingApprovals.containsKey(s.agentSessionId);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: TerminalGlowBorder(
                    active: busy,
                    borderRadius: BorderRadius.circular(12),
                    strokeWidth: 2.0,
                    glowColor: Colors.white,
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF141420),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: needsApproval
                              ? const Color(0xFFF0C040)
                              : const Color(0xFF1E1E30),
                        ),
                      ),
                      child: ListTile(
                        leading: needsApproval
                            ? const Icon(Icons.shield_outlined,
                                color: Color(0xFFF0C040), size: 24)
                            : AgentActivityIcon(
                                agentId: s.agent,
                                icon: s.icon,
                                active: s.busy ||
                                    (_active?.agentSessionId ==
                                            s.agentSessionId &&
                                        _busy),
                              ),
                        title: Text(s.title),
                        subtitle: Text(
                          needsApproval
                              ? 'Waiting for your approval'
                              : chatListSubtitle(agent: s.agent, cwd: s.cwd),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: PopupMenuButton<String>(
                          icon: const Icon(Icons.more_vert,
                              size: 18, color: Colors.white38),
                          onSelected: (val) {
                            if (val == 'rename') {
                              _renameSessionDialog(s);
                            } else if (val == 'folder') {
                              _changeSessionCwd(s);
                            } else if (val == 'delete') {
                              _deleteSession(s);
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: 'rename',
                              child: Row(
                                children: [
                                  Icon(Icons.edit_outlined, size: 16),
                                  SizedBox(width: 8),
                                  Text('Rename'),
                                ],
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'folder',
                              child: Row(
                                children: [
                                  Icon(Icons.folder_open, size: 16),
                                  SizedBox(width: 8),
                                  Text('Change folder'),
                                ],
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'delete',
                              child: Row(
                                children: [
                                  Icon(Icons.delete_outline,
                                      size: 16, color: Color(0xFFEE5555)),
                                  SizedBox(width: 8),
                                  Text('Delete',
                                      style: TextStyle(color: Color(0xFFEE5555))),
                                ],
                              ),
                            ),
                          ],
                        ),
                        onTap: () => _openSession(s),
                        onLongPress: () => _renameSessionDialog(s),
                      ),
                    ),
                  ),
                );
              }),
        ] else ...[
          if (_hostChats.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24, horizontal: 16),
              child: Center(
                child: Text(
                  'No PC conversations found.\nChats started on your PC with Antigravity, OpenCode, Claude, or Cursor will appear here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF666677), fontSize: 13),
                ),
              ),
            )
          else
            for (final c in _hostChats)
              ListTile(
                leading: AgentActivityIcon(
                  agentId: c.agent,
                  icon: c.icon,
                ),
                title: Text(c.title),
                subtitle: Text(
                  chatListSubtitle(
                    agent: c.agent,
                    source: c.source,
                    cwd: c.cwd,
                    resumable: c.resumable,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => _openHostChat(c),
              ),
        ],
      ],
    );
  }

  Widget _menuTabs() {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: _panelBackgroundColor(_active?.agent),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _borderColor(_active?.agent)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _tabButton(
              label: _sessions.isNotEmpty ? 'Recent (${_sessions.length})' : 'Recent',
              icon: Icons.history,
              selected: _menuTab == 0,
              onTap: () => setState(() => _menuTab = 0),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _tabButton(
              label: _hostChats.isNotEmpty ? 'PC (${_hostChats.length})' : 'PC',
              icon: Icons.computer_outlined,
              selected: _menuTab == 1,
              onTap: () => setState(() => _menuTab = 1),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabButton({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
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
      ),
    );
  }

  Color _chatBackgroundColor(String? agentId) {
    switch (agentId) {
      case 'cursor': return const Color(0xFF0E0E12); // Sleek charcoal dark
      case 'antigravity': return const Color(0xFF0D0717); // Slightly lighter deep purple
      case 'claude': return const Color(0xFF140B08); // Slightly lighter deep brown
      case 'opencode': return const Color(0xFF060F0D); // Slightly lighter deep teal
      default: return Colors.transparent; // Fallback to Scaffold background
    }
  }

  Widget _chatWithTerminal() {
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
                _chatTabButton(1, Icons.terminal, 'Terminal'),
              ],
            ),
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _chatTab,
            children: [
              _chat(),
              EmbeddedTerminal(
                key: ValueKey('${_active?.agentSessionId}_${_active?.cwd}'),
                initialCwd: _active?.cwd,
                sessionId: _active?.agentSessionId,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _chatTabButton(int index, IconData icon, String label) {
    final selected = _chatTab == index;
    final isTerminalTab = index == 1;
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
        onTap: () => setState(() => _chatTab = index),
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
    final display = groupAgentDisplay(_events);
    return Column(
      children: [
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
          const Text(
            'Working…',
            style: TextStyle(
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

  Color _appBackgroundColor(String? agentId) {
    switch (agentId) {
      case 'cursor': return const Color(0xFF000000); // Pure black
      case 'antigravity': return const Color(0xFF0A0512);
      case 'claude': return const Color(0xFF0F0806);
      case 'opencode': return const Color(0xFF040A09);
      default: return const Color(0xFF0A0A0F);
    }
  }

  Color _panelBackgroundColor(String? agentId) {
    switch (agentId) {
      case 'cursor': return const Color(0xFF1A1A1A); // Dark gray
      case 'antigravity': return const Color(0xFF120B20);
      case 'claude': return const Color(0xFF1A100B);
      case 'opencode': return const Color(0xFF0A1412);
      default: return const Color(0xFF151522);
    }
  }

  Color _borderColor(String? agentId) {
    switch (agentId) {
      case 'cursor': return const Color(0xFF27272E); // Subtle dark border
      case 'antigravity': return const Color(0xFF281845); // Dark purple border
      case 'claude': return const Color(0xFF3A2015); // Dark terracotta border
      case 'opencode': return const Color(0xFF15332E); // Dark teal border
      default: return const Color(0xFF22223A); // Default purplish gray
    }
  }

  Color _inputBorderColor(String? agentId) {
    switch (agentId) {
      case 'cursor': return const Color(0xFF383842); // Lighter dark border
      case 'antigravity': return const Color(0xFF352055); // Lighter purple border
      case 'claude': return const Color(0xFF4A2B1C); // Lighter terracotta border
      case 'opencode': return const Color(0xFF1C453E); // Lighter teal border
      default: return const Color(0xFF2A2A40); // Default lighter purplish gray
    }
  }

  Color _chipBackgroundColor(String? agentId) {
    switch (agentId) {
      case 'cursor': return const Color(0xFF222228); // Dark neutral gray
      case 'antigravity': return const Color(0xFF1F1235); // Dark purple
      case 'claude': return const Color(0xFF2A150D); // Dark terracotta
      case 'opencode': return const Color(0xFF102824); // Dark teal
      default: return const Color(0xFF1E1E2E); // Default purplish gray
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
                            child: Image.memory(b,
                                width: 88, height: 88, fit: BoxFit.cover),
                          ),
                      ],
                    ),
                  )
                else if (e.images.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(e.images.join(', '),
                        style: const TextStyle(
                            color: Colors.white38, 
                            fontSize: 11)),
                  ),
                if ((e.text ?? '').isNotEmpty)
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: _userBubbleColor(_active?.agent),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(e.text ?? '',
                        style: TextStyle(color: _userBubbleTextColor(_active?.agent))),
                  ),
              ],
            ),
          ),
        );
      case 'text':
      case 'text-delta':
      case 'result':
        if ((e.text ?? '').trim().isEmpty) {
          if (e.kind == 'result' && _events.isNotEmpty && e == _events.last) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              child: Text('Done', style: TextStyle(color: Colors.white38, fontSize: 12, fontStyle: FontStyle.italic)),
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
                              decoration: TextDecoration.underline),
                          code: const TextStyle(
                              color: Colors.white70,
                              fontFamily: 'monospace',
                              fontSize: 12),
                        ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _CopyButton(text: e.text ?? ''),
                    ],
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
            child: Text(e.text ?? 'Thinking…',
                style: const TextStyle(
                    color: Colors.white38, fontSize: 12, fontStyle: FontStyle.italic)),
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
        final isPending = _active != null && (e.refId == null || !_resolvedApprovals.contains(e.refId!));
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          child: SelectionArea(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _panelBackgroundColor(_active?.agent),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFF0C040).withOpacity(0.5)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.text ?? 'Allow this tool?',
                      style: const TextStyle(color: Color(0xFFF0C040), fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(e.toolName ?? 'tool', style: const TextStyle(fontSize: 12, color: Colors.white70)),
                  if ((e.toolInput ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 8),
                      child: Text(e.toolInput!,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.white54)),
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
                                padding: const EdgeInsets.symmetric(vertical: 8),
                              ),
                              onPressed: () => _submitPermission(e.refId, false),
                              child: const Text('Deny'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFFF0C040),
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(vertical: 8),
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
                      child: Text('Responded', style: TextStyle(fontSize: 11, color: Colors.white38, fontStyle: FontStyle.italic)),
                    ),
                ],
              ),
            ),
          ),
        );
      case 'error':
        final errorText = (e.text ?? '').trim();
        if (errorText.isEmpty ||
            errorText.toLowerCase().contains('is not a valid artifact path; artifacts must be in')) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.all(8),
          child: SelectionArea(
            child: MarkdownBody(
              data: errorText,
              inlineSyntaxes: [IpAutolinkSyntax()],
              builders: {'a': LinkActionBuilder(client: _client)},
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                p: const TextStyle(color: Color(0xFFEE5555), fontSize: 13),
                a: const TextStyle(
                    color: Color(0xFF93C5FD),
                    fontSize: 13,
                    decoration: TextDecoration.underline),
                code: const TextStyle(
                    color: Color(0xFFEE5555),
                    fontFamily: 'monospace',
                    fontSize: 12),
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

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: _panelBackgroundColor(_active?.agent),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _borderColor(_active?.agent)),
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
                      : (planInfo != null ? Icons.assignment_turned_in_outlined : Icons.check_circle_outline),
                  size: 18,
                  color: running
                      ? const Color(0xFFF0C040)
                      : (planInfo != null ? const Color(0xFFC084FC) : const Color(0xFF4ADE80)),
                ),
          title: Text(
            toolGroupTitle(tools),
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
                    color: planInfo != null ? const Color(0xFFC084FC).withOpacity(0.85) : Colors.white54,
                  ),
                ),
          trailing: running
              ? IconButton(
                  tooltip: 'Stop',
                  icon: const Icon(Icons.stop, size: 20),
                  onPressed: _cancel,
                )
              : (planInfo != null && _client != null)
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        InkWell(
                          onTap: () => _openToolFile(planInfo),
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF9F54FF).withOpacity(0.18),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: const Color(0xFF9F54FF).withOpacity(0.5),
                              ),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.assignment_outlined, size: 12, color: Color(0xFFC084FC)),
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
                        const Icon(Icons.expand_more, size: 20, color: Colors.white54),
                      ],
                    )
                  : null,
          children: [
            for (final e in tools)
              _toolCard(e, running: e.kind == 'tool-start', nested: true),
          ],
        ),
      ),
    );
  }

  Widget _toolCard(AgentEvent e, {required bool running, bool nested = false}) {
    final detail = (e.toolInput ?? '').trim();
    final output = (e.toolOutput ?? '').trim();
    final fileInfo = extractToolFileInfo(e);
    final isPlan = fileInfo?.isPlan == true;
    final isFile = fileInfo != null && !isPlan && (fileInfo.filePath != null || fileInfo.rawContent != null);
    final canOpen = !running && fileInfo != null && _client != null;

    final displayName = fileInfo != null
        ? (isPlan
            ? (fileInfo.title.isNotEmpty && fileInfo.title != 'Plan' ? fileInfo.title : 'Implementation Plan')
            : fileInfo.title)
        : (e.toolName == 'task' || e.toolName == 'run_command'
            ? 'Command'
            : (e.toolName ?? 'tool'));

    String? displaySubtitle;
    if (fileInfo != null && isPlan) {
      if (fileInfo.subtitle != null && fileInfo.subtitle!.isNotEmpty && fileInfo.subtitle != 'Agent Plan') {
        displaySubtitle = fileInfo.subtitle;
      } else if (detail.isNotEmpty && detail != (e.toolName ?? '') && !detail.startsWith('{')) {
        displaySubtitle = detail;
      } else if (fileInfo.rawContent != null) {
        final firstLine = fileInfo.rawContent!.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
        displaySubtitle = firstLine.replaceFirst(RegExp(r'^[#\s*-]+'), '').trim();
      }
    } else {
      if (detail.startsWith('{')) {
        try {
          final decoded = jsonDecode(detail);
          if (decoded is Map) {
            final cmd = decoded['CommandLine'] ??
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
      if (displaySubtitle == null && detail.isNotEmpty && detail != (e.toolName ?? '')) {
        displaySubtitle = detail;
      }
    }

    final showDetail = displaySubtitle != null && displaySubtitle.trim().isNotEmpty;

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
                  ? (isPlan ? const Color(0xFF1E1333) : _appBackgroundColor(_active?.agent))
                  : _panelBackgroundColor(_active?.agent),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isPlan
                    ? const Color(0xFF9F54FF).withOpacity(0.4)
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
                              : (isFile ? Icons.description_outlined : Icons.check)),
                      size: 14,
                      color: running
                          ? const Color(0xFFF0C040)
                          : (isPlan
                              ? const Color(0xFFC084FC)
                              : (isFile ? const Color(0xFF93C5FD) : const Color(0xFF4ADE80))),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        displayName,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                          color: isPlan ? const Color(0xFFE9D5FF) : Colors.white,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (canOpen) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: (isPlan ? const Color(0xFF9F54FF) : const Color(0xFF38BDF8)).withOpacity(0.18),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: (isPlan ? const Color(0xFF9F54FF) : const Color(0xFF38BDF8)).withOpacity(0.4),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isPlan ? Icons.assignment_outlined : Icons.description_outlined,
                              size: 11,
                              color: isPlan ? const Color(0xFFC084FC) : const Color(0xFF93C5FD),
                            ),
                            const SizedBox(width: 3),
                            Text(
                              isPlan ? 'View plan' : 'View file',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: isPlan ? const Color(0xFFC084FC) : const Color(0xFF93C5FD),
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
                        color: isPlan ? const Color(0xFFD8B4FE).withOpacity(0.8) : Colors.white54,
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
                              : const Color(0xFF6EE7B7)),
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
              final text = q['question']?.toString() ??
                  q['prompt']?.toString() ??
                  q['title']?.toString() ??
                  'Question';
              final opts = <String>[];
              final rawOpts = q['options'] ?? q['choices'] ?? q['suggested_answers'] ?? q['items'];
              if (rawOpts is List) {
                for (final opt in rawOpts) {
                  if (opt != null) opts.add(opt.toString());
                }
              }
              parsedQuestions.add({'question': text, 'options': opts});
            }
          }
        } else {
          final text = json['question']?.toString() ??
              json['prompt']?.toString() ??
              json['message']?.toString() ??
              json['query']?.toString() ??
              'Question';
          final opts = <String>[];
          final rawOpts = json['options'] ?? json['choices'] ?? json['suggested_answers'] ?? json['items'];
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
      parsedQuestions.add({'question': 'Agent question', 'options': <String>[]});
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _panelBackgroundColor(_active?.agent),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: running ? const Color(0xFFF0C040).withOpacity(0.6) : _borderColor(_active?.agent),
            width: running ? 1.5 : 1,
          ),
          boxShadow: running
              ? [
                  BoxShadow(
                    color: const Color(0xFFF0C040).withOpacity(0.08),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  )
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
                  color: running ? const Color(0xFFF0C040) : const Color(0xFF4ADE80),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    running ? 'Needs Your Input' : 'Answered',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: running ? const Color(0xFFF0C040) : const Color(0xFF4ADE80),
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
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Colors.white),
              ),
              if ((parsedQuestions[i]['options'] as List<String>).isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: (parsedQuestions[i]['options'] as List<String>).map((opt) {
                      return ActionChip(
                        label: Text(
                          opt,
                          style: TextStyle(
                            fontSize: 13,
                            color: running && !_busy ? Colors.white : Colors.white70,
                          ),
                        ),
                        backgroundColor: _appBackgroundColor(_active?.agent),
                        side: BorderSide(
                          color: running ? const Color(0xFF2A6AFF) : _borderColor(_active?.agent),
                        ),
                        elevation: running ? 1 : 0,
                        onPressed: running && !_busy
                            ? () {
                                _input.text = opt;
                                _send();
                              }
                            : null,
                      );
                    }).toList(),
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
            ? SnackBarAction(
                label: 'Settings',
                onPressed: openAppSettings,
              )
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
        if (mounted && await Permission.microphone.isGranted) {
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
        if (mounted) {
          final appGranted = await Permission.microphone.isGranted;
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
              _preListeningText =
                  commitSpeechPrefix(_preListeningText, val.recognizedWords);
            }
          });
        },
        localeId: speechLocaleId(Localizations.localeOf(context)),
        listenOptions: speechListenOptions(),
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
                                  child: Image.memory(p.bytes,
                                      width: 64, height: 64, fit: BoxFit.cover),
                                ),
                                Positioned(
                                  top: -6,
                                  right: -6,
                                  child: IconButton(
                                    visualDensity: VisualDensity.compact,
                                    style: IconButton.styleFrom(
                                      backgroundColor: _appBackgroundColor(_active?.agent),
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
                    enabled: !_busy,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: _needsSignIn
                          ? 'login or CURSOR_API_KEY=…'
                          : _photos.isEmpty
                              ? 'Message the agent…'
                              : 'Add a note about the photo…',
                      isDense: true,
                      filled: true,
                      fillColor: Colors.transparent,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 8),
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
                      _modeChip(),
                      const SizedBox(width: 6),
                      Flexible(
                        child: _modelChip(),
                      ),
                      const SizedBox(width: 4),
                      const Spacer(),
                      IconButton(
                        tooltip: _isListening ? 'Stop listening' : 'Voice to text',
                        onPressed: _toggleListen,
                        icon: Icon(
                          _isListening ? Icons.stop_circle : Icons.mic,
                          color: _isListening ? Colors.red : Colors.white70,
                        ),
                      ),
                      IconButton.filled(
                        tooltip: _canStop ? 'Stop' : 'Send',
                        onPressed: _canStop ? _cancel : _send,
                        icon: Icon(_canStop ? Icons.stop : Icons.arrow_upward),
                      ),
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
                const Icon(Icons.memory_outlined,
                    size: 14, color: Color(0xFF8A8A9A)),
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
                  const Icon(Icons.arrow_drop_down,
                      size: 14, color: Colors.white38),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact two-state selector for the per-agent approval policy.
class _ApprovalChip extends StatelessWidget {
  const _ApprovalChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF2F6BFF).withValues(alpha: 0.22) : null,
          border: Border.all(
            color: selected ? const Color(0xFF2F6BFF) : const Color(0xFF33334A),
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: selected ? const Color(0xFF9FC0FF) : const Color(0xFF8A8A9A),
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
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
