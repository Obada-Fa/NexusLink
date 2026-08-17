// Native chat UI for AI agents that run on the PC (Claude Code, Cursor CLI,
// OpenCode, Antigravity, or the built-in demo agent). The phone never sees a
// terminal — tool calls become cards, assistant text is markdown, and history
// survives reconnects.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rpc/models.dart';
import '../rpc/rpc_client.dart';
import '../state/connection.dart';

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

class _AgentScreenState extends ConsumerState<AgentScreen> {
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
  String? _error;
  void Function()? _unsub;

  RpcClient? get _client => ref.read(activeClientProvider);

  @override
  void initState() {
    super.initState();
    _load();
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
      _unsub = client.subscribe('agent-event', _onPush);
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
        _loading = false;
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

  void _onPush(Map<String, dynamic> msg) {
    if (msg['agentSessionId'] != _active?.agentSessionId) return;
    final ev = msg['event'];
    if (ev is! Map<String, dynamic>) return;
    final parsed = AgentEvent.fromJson(ev);
    if (parsed.kind == 'user' && _pendingThumbs != null) {
      _thumbsBySeq[parsed.seq] = _pendingThumbs!;
      _pendingThumbs = null;
    }
    setState(() {
      _events.add(parsed);
      if (parsed.kind == 'result' || parsed.kind == 'error') _busy = false;
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
    if (client == null) return null;
    List<dynamic> raw = const [];
    try {
      raw = await client.requestList('fs.listProjects');
    } catch (_) {
      return null;
    }
    if (!mounted || raw.isEmpty) return null;
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF151522),
      builder: (ctx) => ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const ListTile(title: Text('Working directory')),
          for (final e in raw)
            if (e is Map)
              ListTile(
                title: Text('${e['name'] ?? ''}'),
                subtitle: Text('${e['path'] ?? ''}',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.pop(ctx, e['path'] as String?),
              ),
        ],
      ),
    );
  }

  Future<void> _newChat(AgentInfo agent) async {
    final client = _client;
    if (client == null) return;
    final cwd = await _pickProject();
    try {
      final created = await client.request('agent.createSession', {
        'agent': agent.id,
        'title': agent.name,
        'cwd': ?cwd,
      }) as Map<String, dynamic>;
      final session = AgentSessionInfo.fromJson(created);
      setState(() {
        _sessions.insert(0, session);
        _active = session;
        _events.clear();
        _busy = false;
        _photos.clear();
        _liveModels = [];
      });
      await _loadComposerPrefs(agent.id);
      await _refreshModels(agent.id);
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
      _photos.clear();
      _liveModels = [];
    });
    await _loadComposerPrefs(s.agent);
    await _refreshModels(s.agent);
    _scrollToEnd();
  }

  Future<void> _openHostChat(AgentHostChat chat) async {
    final client = _client;
    if (client == null) return;
    try {
      final created = await client.request(
        'agent.openHostChat',
        {
          'agent': chat.agent,
          'hostChatId': chat.hostChatId,
          'cwd': chat.cwd,
          'title': chat.title,
        },
        const Duration(seconds: 25),
      ) as Map<String, dynamic>;
      final session = AgentSessionInfo.fromJson(created);
      if (!mounted) return;
      setState(() {
        if (!_sessions.any((s) => s.agentSessionId == session.agentSessionId)) {
          _sessions.insert(0, session);
        }
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

  Future<void> _loadComposerPrefs(String agentId) async {
    final p = await SharedPreferences.getInstance();
    final caps = _caps;
    var mode = p.getString('agent-composer-$agentId-mode') ?? 'agent';
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
      setState(() {
        _busy = true;
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
            if (_thinking.isNotEmpty) 'thinking': _thinking,
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
          _busy = false;
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

  Future<void> _cancel() async {
    final session = _active;
    final client = _client;
    if (session == null || client == null) return;
    try {
      await client.request(
          'agent.cancel', {'agentSessionId': session.agentSessionId});
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
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
            t.contains('starting cursor sign-in') ||
            t.contains('sign-in is already') ||
            t.contains('no headless login')) {
          return true;
        }
      }
    }
    return false;
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
    });
  }

  IconData _iconFor(String id) {
    return switch (id) {
      'claude' => Icons.auto_awesome,
      'cursor' => Icons.code,
      'opencode' => Icons.terminal,
      'antigravity' => Icons.rocket_launch_outlined,
      _ => Icons.smart_toy_outlined,
    };
  }

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

  String get _modelLabel {
    final id = _model;
    if (id == null || id == 'auto' || id == 'default') return 'Model';
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

  void _cycleMode() {
    final modes = _caps.modes;
    if (modes.length < 2) return;
    final i = modes.indexOf(_mode);
    setState(() => _mode = modes[(i + 1) % modes.length]);
    unawaited(_saveComposerPrefs());
  }

  Future<void> _pickThinking() async {
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

  Future<void> _selectAgent() async {
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
              title: Text('Select agent',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final a in _agents)
              ListTile(
                leading: Icon(
                  _iconFor(a.id),
                  color: a.available
                      ? const Color(0xFF2A6AFF)
                      : Colors.white24,
                ),
                title: Text(a.name),
                subtitle: Text(a.available
                    ? 'Runs on the PC — chat here'
                    : 'CLI not installed on the PC'),
                enabled: a.available,
                trailing: a.available
                    ? FilledButton(
                        onPressed: () => Navigator.pop(ctx, a),
                        child: const Text('Select'),
                      )
                    : null,
                onTap: a.available ? () => Navigator.pop(ctx, a) : null,
              ),
          ],
        ),
      ),
    );
    if (chosen != null) await _newChat(chosen);
  }

  @override
  void dispose() {
    _unsub?.call();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
          title: Text(_active?.title ?? 'Agents',
              style: const TextStyle(fontSize: 16)),
          actions: [
            IconButton(
              tooltip: 'Select agent',
              icon: const Icon(Icons.smart_toy_outlined),
              onPressed: _selectAgent,
            ),
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
                ? Center(
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
            leading: Icon(
              _iconFor(a.id),
              color: a.available
                  ? const Color(0xFF2A6AFF)
                  : Colors.white24,
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
        if (_sessions.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text('RECENT',
              style: TextStyle(
                  fontSize: 11, letterSpacing: 0.8, color: Color(0xFF666677))),
          const SizedBox(height: 8),
          for (final s in _sessions)
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: Text(s.title),
              subtitle: Text(s.cwd, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => _openSession(s),
            ),
        ],
        if (_hostChats.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text('ON THIS PC',
              style: TextStyle(
                  fontSize: 11, letterSpacing: 0.8, color: Color(0xFF666677))),
          const SizedBox(height: 8),
          for (final c in _hostChats)
            ListTile(
              leading: Icon(_iconFor(c.agent)),
              title: Text(c.title),
              subtitle: Text(
                [
                  c.source,
                  if (c.cwd.isNotEmpty) c.cwd,
                  if (!c.resumable) 'view only',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _openHostChat(c),
            ),
        ],
      ],
    );
  }

  Widget _chat() {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            itemCount: _events.length + (_busy ? 1 : 0),
            itemBuilder: (_, i) {
              if (i >= _events.length) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                  child: Text('Working…',
                      style: TextStyle(
                          color: Colors.white38,
                          fontSize: 12,
                          fontStyle: FontStyle.italic)),
                );
              }
              return _bubble(_events[i]);
            },
          ),
        ),
        _composer(),
      ],
    );
  }

  Widget _bubble(AgentEvent e) {
    switch (e.kind) {
      case 'user':
        final thumbs = _thumbsBySeq[e.seq];
        return _align(
          Alignment.centerRight,
          Column(
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
                    color: const Color(0xFF2A6AFF),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(e.text ?? '',
                      style: const TextStyle(color: Colors.white)),
                ),
            ],
          ),
        );
      case 'text':
      case 'text-delta':
      case 'result':
        if ((e.text ?? '').trim().isEmpty) return const SizedBox.shrink();
        return _align(
          Alignment.centerLeft,
          Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF151522),
              borderRadius: BorderRadius.circular(14),
            ),
            child: MarkdownBody(
              data: e.text ?? '',
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                  .copyWith(
                    p: const TextStyle(color: Colors.white, fontSize: 14),
                    code: const TextStyle(
                        color: Color(0xFF6EE7B7),
                        fontFamily: 'monospace',
                        fontSize: 12),
                  ),
            ),
          ),
        );
      case 'thinking':
      case 'status':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          child: Text(e.text ?? 'Thinking…',
              style: const TextStyle(
                  color: Colors.white38, fontSize: 12, fontStyle: FontStyle.italic)),
        );
      case 'tool-start':
        return _toolCard(e, running: true);
      case 'tool-end':
        return _toolCard(e, running: false);
      case 'permission-request':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          child: Text(e.text ?? 'Waiting for permission…',
              style: const TextStyle(color: Color(0xFFF0C040), fontSize: 12)),
        );
      case 'error':
        return Padding(
          padding: const EdgeInsets.all(8),
          child: MarkdownBody(
            data: e.text ?? 'error',
            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
              p: const TextStyle(color: Color(0xFFEE5555), fontSize: 13),
              a: const TextStyle(color: Color(0xFF93C5FD), fontSize: 13),
              code: const TextStyle(
                  color: Color(0xFFEE5555),
                  fontFamily: 'monospace',
                  fontSize: 12),
            ),
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _toolCard(AgentEvent e, {required bool running}) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF12121C),
        borderRadius: BorderRadius.circular(10),
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
              Text(e.toolName ?? 'tool',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 12)),
            ],
          ),
          if ((e.toolInput ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(e.toolInput!,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: Colors.white54)),
            ),
          if (!running && (e.toolOutput ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(e.toolOutput!,
                  maxLines: _looksLikeDiff(e.toolOutput!) ? 20 : 8,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: _looksLikeDiff(e.toolOutput!)
                          ? const Color(0xFF93C5FD)
                          : const Color(0xFF6EE7B7))),
            ),
        ],
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
                        tooltip: 'Add photo',
                        onPressed: _busy ? null : _attachPhoto,
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              _composerChip(
                                _modelLabel,
                                onTap: _busy ? null : _pickModel,
                                icon: Icons.memory_outlined,
                                active: _model != null &&
                                    _model != 'auto' &&
                                    _model != 'default',
                              ),
                              _composerChip(
                                _thinkingLabel(_thinking),
                                onTap: _busy ? null : _pickThinking,
                                icon: Icons.psychology_outlined,
                                active: _thinking != 'medium',
                              ),
                              if (_caps.modes.length > 1)
                                _composerChip(
                                  _modeLabel(_mode),
                                  onTap: _busy ? null : _cycleMode,
                                  icon: _mode == 'plan'
                                      ? Icons.checklist_outlined
                                      : _mode == 'ask'
                                          ? Icons.help_outline
                                          : Icons.smart_toy_outlined,
                                  active: _mode != 'agent',
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton.filled(
                        tooltip: _busy ? 'Stop' : 'Send',
                        onPressed: _busy ? _cancel : _send,
                        icon: Icon(_busy ? Icons.stop : Icons.arrow_upward),
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

  Widget _composerChip(
    String label, {
    required VoidCallback? onTap,
    IconData? icon,
    bool active = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ActionChip(
        onPressed: onTap,
        avatar: icon == null
            ? null
            : Icon(icon, size: 16, color: const Color(0xFFB8B8CC)),
        label: Text(label),
        labelStyle: TextStyle(
          fontSize: 12,
          color: active ? const Color(0xFF2A6AFF) : Colors.white70,
        ),
        visualDensity: VisualDensity.compact,
        backgroundColor: active
            ? const Color(0xFF2A6AFF).withValues(alpha: 0.12)
            : const Color(0xFF1C1C2A),
        side: BorderSide(
          color: active ? const Color(0xFF2A6AFF) : const Color(0xFF2A2A40),
        ),
      ),
    );
  }
}
