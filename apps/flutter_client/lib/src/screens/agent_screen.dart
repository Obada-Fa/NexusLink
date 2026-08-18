// Native chat UI for AI agents that run on the PC (Claude Code, Cursor CLI,
// OpenCode, Antigravity, or the built-in demo agent). The phone never sees a
// terminal — tool calls become cards, assistant text is markdown, and history
// survives reconnects.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../rpc/models.dart';
import '../rpc/rpc_client.dart';
import '../services/notification_service.dart';
import '../state/agent_history.dart';
import '../state/connection.dart';
import '../state/last_cwd.dart';
import '../widgets/agent_activity_icon.dart';
import '../widgets/code_block_builder.dart';
import '../widgets/link_actions.dart';
import '../widgets/not_connected_view.dart';
import 'cwd_picker.dart';

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
  String _mode = 'agent';
  String _thinking = 'medium';
  String? _model;
  List<AgentModelOption> _liveModels = [];
  bool _loading = true;
  bool _busy = false;
  bool _sending = false;
  int _menuTab = 0;
  String? _error;
  final SpeechToText _speech = SpeechToText();
  bool _isListening = false;
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
      try {
        hostRaw = await client.requestList(
          'agent.listHostChats',
          const {},
          const Duration(seconds: 25),
        );
      } catch (_) {
        // Older hosts have no listHostChats.
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
      try {
        hostRaw = await client.requestList(
          'agent.listHostChats',
          const {},
          const Duration(seconds: 25),
        );
      } catch (_) {}
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
            _busy = match.busy;
          }
          if (shouldSyncTranscript) {
            if (match != null && !match.busy) {
              final settled = closeOpenTools(_events,
                  output: 'Interrupted — host restarted.');
              if (settled.length != _events.length) {
                _events
                  ..clear()
                  ..addAll(settled);
              }
            }
            final merged = mergeAgentHistory(history, _events);
            // While a turn is in flight, live pushes are authoritative — never
            // shrink the transcript on a reconnect/resync race.
            if (!_busy || merged.length >= _events.length) {
              _events
                ..clear()
                ..addAll(merged);
            }
          }
        }
      });
      if (shouldSyncTranscript) _scrollToEnd();
      unawaited(_refreshGitTree());
    } catch (_) {
      // Stay on the last known transcript; the next resume will try again.
    }
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

  Future<void> _askPermission(AgentEvent e) async {
    final client = _client;
    final session = _active;
    final requestId = e.refId;
    if (client == null || session == null || requestId == null || !mounted) {
      return;
    }
    final allow = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: const Color(0xFF151522),
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
    await client.request('agent.permission', {
      'agentSessionId': session.agentSessionId,
      'requestId': requestId,
      'allow': allow == true,
    });
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
    try {
      final created = await client.request('agent.createSession', {
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
      await _refreshModels(agent.id);
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
    final raw =
        await client.request('agent.history', {'agentSessionId': s.agentSessionId})
            as List<dynamic>;
    if (!mounted) return;
    setState(() {
      _active = s;
      _busy = s.busy;
      _events
        ..clear()
        ..addAll(raw.map((e) => AgentEvent.fromJson(e as Map<String, dynamic>)));
      if (!s.busy) {
        final settled = closeOpenTools(_events,
            output: 'Interrupted — host restarted.');
        _events
          ..clear()
          ..addAll(settled);
      }
      _photos.clear();
      _liveModels = [];
      _sessions.removeWhere((x) => x.agentSessionId == s.agentSessionId);
      _sessions.insert(0, s);
    });
    await _loadComposerPrefs(s.agent);
    await _refreshModels(s.agent);
    await _refreshGitTree();
    _scrollToEnd();
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
            AgentModelOption(id: 'cursor-grok-4.6', name: 'Grok 4.6'),
            AgentModelOption(id: 'claude-opus-5', name: 'Claude Opus 5'),
            AgentModelOption(id: 'claude-sonnet-5', name: 'Claude Sonnet 5'),
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

  Future<void> _refreshModels(String agentId) async {
    final client = _client;
    if (client == null) return;
    try {
      final raw = await client.requestList('agent.listModels', {'agent': agentId});
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
    if (client != null) {
      try {
        await client.request(
            'agent.cancel', {'agentSessionId': session.agentSessionId});
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _setBusy(false);
        final settled = closeOpenTools(_events, output: 'Stopped.');
        _events
          ..clear()
          ..addAll(settled);
      });
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
        backgroundColor: const Color(0xFF151522),
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
      backgroundColor: const Color(0xFF151522),
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
      backgroundColor: const Color(0xFF151522),
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
      backgroundColor: const Color(0xFF151522),
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
      backgroundColor: const Color(0xFF151522),
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
    if (_active != null) await _refreshModels(_active!.agent);
    if (!mounted) return;
    final models = _pickerModels;
    if (models.isEmpty) {
      _localStatus('This agent has no model list yet. Restart the PC host and try again.');
      return;
    }
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF151522),
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
                    const ListTile(
                      title: Text('Model',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                          'Same agent — thinking is the chip next to this'),
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
                          return ListTile(
                            title: Text(m.name),
                            subtitle: Text(m.id,
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
      backgroundColor: const Color(0xFF151522),
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
        backgroundColor: const Color(0xFF0A0A0F),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0A0A0F),
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
                    : _chat(),
      ),
    );
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
        const SizedBox(height: 16),
        _menuTabs(),
        const SizedBox(height: 8),
        if (_menuTab == 0) ...[
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
              ListTile(
                leading: AgentActivityIcon(
                  agentId: s.agent,
                  icon: s.icon,
                  active: s.busy ||
                      (_active?.agentSessionId == s.agentSessionId && _busy),
                ),
                title: Text(s.title),
                subtitle: Text(
                  chatListSubtitle(agent: s.agent, cwd: s.cwd),
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
        color: const Color(0xFF151522),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF22223A)),
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

  Widget _chat() {
    final display = groupAgentDisplay(_events);
    return Column(
      children: [
        Expanded(
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
        return const Color(0xFF101014);
      case 'antigravity':
        return const Color(0xFF2D1B4E);
      case 'claude':
        return const Color(0xFF3D2B1F);
      case 'opencode':
        return const Color(0xFF1C3330);
      default:
        return const Color(0xFF151522);
    }
  }

  Color _userBubbleColor(String? agentId) {
    switch (agentId) {
      case 'cursor':
        return const Color(0xFF4B5563); // gray
      case 'antigravity':
        return const Color(0xFF9333EA); // purple
      case 'claude':
        return const Color(0xFFD97757); // terracotta/orange
      case 'opencode':
        return const Color(0xFF0D9488); // teal
      default:
        return const Color(0xFF2A6AFF); // default blue
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
                            color: Colors.white38, fontSize: 11)),
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
                        style: const TextStyle(color: Colors.white)),
                  ),
              ],
            ),
          ),
        );
      case 'text':
      case 'text-delta':
      case 'result':
        if ((e.text ?? '').trim().isEmpty) return const SizedBox.shrink();
        return _align(
          Alignment.centerLeft,
          SelectionArea(
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 6),
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
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
                          p: const TextStyle(color: Colors.black, fontSize: 14),
                          a: const TextStyle(
                              color: Color(0xFF0055CC),
                              fontSize: 14,
                              decoration: TextDecoration.underline),
                          code: const TextStyle(
                              color: Colors.black87,
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
        return _toolCard(e, running: true);
      case 'tool-end':
        return _toolCard(e, running: false);
      case 'permission-request':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          child: SelectionArea(
            child: Text(e.text ?? 'Waiting for permission…',
                style: const TextStyle(color: Color(0xFFF0C040), fontSize: 12)),
          ),
        );
      case 'error':
        final errorText = (e.text ?? '').trim();
        if (errorText.isEmpty ||
            errorText.toLowerCase().startsWith('declaring permissions: cortex tool') ||
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

  Widget _toolGroup(List<AgentEvent> tools) {
    final running = toolGroupRunning(tools);
    final summary = toolGroupSummary(tools);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF12121C),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF22223A)),
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
                  running ? Icons.hourglass_top : Icons.check_circle_outline,
                  size: 18,
                  color: running
                      ? const Color(0xFFF0C040)
                      : const Color(0xFF4ADE80),
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
                  style: const TextStyle(fontSize: 11, color: Colors.white54),
                ),
          trailing: running
              ? IconButton(
                  tooltip: 'Stop',
                  icon: const Icon(Icons.stop, size: 20),
                  onPressed: _cancel,
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
    final showDetail = detail.isNotEmpty && detail != (e.toolName ?? '');
    return SelectionArea(
      child: Container(
        margin: EdgeInsets.symmetric(vertical: nested ? 3 : 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: nested ? const Color(0xFF0A0A10) : const Color(0xFF12121C),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF22223A)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(running ? Icons.play_arrow : Icons.check,
                    size: 14,
                    color: running
                        ? const Color(0xFFF0C040)
                        : const Color(0xFF4ADE80)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    e.toolName ?? 'tool',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (showDetail)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 20),
                child: Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Colors.white54),
                ),
              ),
            if (!running && output.isNotEmpty)
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

  Future<void> _toggleListen() async {
    if (!_isListening) {
      bool available = await _speech.initialize(
        onStatus: (val) {
          if (mounted) setState(() => _isListening = (val == 'listening'));
        },
        onError: (val) {
          if (mounted) setState(() => _isListening = false);
        },
      );
      if (available) {
        if (mounted) setState(() => _isListening = true);
        _speech.listen(
          onResult: (val) {
            if (mounted) {
              setState(() {
                _input.text = val.recognizedWords;
              });
            }
          },
        );
      }
    } else {
      if (mounted) setState(() => _isListening = false);
      _speech.stop();
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
                color: const Color(0xFF151522),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF2A2A40)),
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
                                      backgroundColor: const Color(0xFF0A0A0F),
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
                          Icons.mic,
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
        color: const Color(0xFF1E1E2E),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: _busy ? null : (canPick ? _pickMode : _openComposerMenu),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF2A2A40)),
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
    return Tooltip(
      message: 'Model: $_modelLabel${canPick ? ' (tap to switch)' : ''}',
      child: Material(
        color: const Color(0xFF1E1E2E),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: _busy ? null : (canPick ? _pickModel : _openComposerMenu),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF2A2A40)),
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
