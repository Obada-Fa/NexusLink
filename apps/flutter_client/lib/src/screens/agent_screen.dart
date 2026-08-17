// Native chat UI for AI agents that run on the PC (Claude Code, Cursor CLI,
// or the built-in demo agent). The phone never sees a terminal — tool calls
// become cards, assistant text is markdown, and history survives reconnects.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rpc/models.dart';
import '../rpc/rpc_client.dart';
import '../state/connection.dart';

class AgentScreen extends ConsumerStatefulWidget {
  const AgentScreen({super.key});

  @override
  ConsumerState<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends ConsumerState<AgentScreen> {
  List<AgentInfo> _agents = [];
  List<AgentSessionInfo> _sessions = [];
  AgentSessionInfo? _active;
  final _events = <AgentEvent>[];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _loading = true;
  bool _busy = false;
  bool _opening = false;
  String? _openingId;
  String? _error;
  String? _sendError;
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
      _unsub = client.subscribe('agent-event', _onPush);
      if (!mounted) return;
      setState(() {
        _agents = agentsRaw
            .map((e) => AgentInfo.fromJson(e as Map<String, dynamic>))
            .toList();
        _sessions = sessionsRaw
            .map((e) => AgentSessionInfo.fromJson(e as Map<String, dynamic>))
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
    setState(() {
      if (parsed.kind == 'user') _busy = true;
      if (parsed.kind == 'result' || parsed.kind == 'error') _busy = false;
      if (parsed.kind == 'text-delta') {
        _appendDelta(parsed.text ?? '');
      } else if (parsed.kind == 'user' &&
          _events.isNotEmpty &&
          _events.last.kind == 'user' &&
          _events.last.text == parsed.text) {
        // Already shown optimistically when the user tapped send.
      } else if (parsed.kind == 'result' && (parsed.text ?? '').trim().isEmpty) {
        // Host uses an empty result as "turn finished".
      } else if (parsed.kind == 'status') {
        // Keep the composer spinner; don't add a chat bubble.
      } else {
        _events.add(parsed);
      }
    });
    _scrollToEnd();
    if (parsed.kind == 'permission-request') {
      unawaited(_askPermission(parsed));
    }
  }

  void _appendDelta(String delta) {
    if (delta.isEmpty) return;
    if (_events.isNotEmpty && _events.last.kind == 'text') {
      final last = _events.removeLast();
      _events.add(AgentEvent(
        seq: last.seq,
        ts: last.ts,
        kind: 'text',
        text: '${last.text ?? ''}$delta',
        toolName: last.toolName,
        toolInput: last.toolInput,
        toolOutput: last.toolOutput,
        refId: last.refId,
      ));
    } else {
      _events.add(AgentEvent(seq: 0, ts: DateTime.now().millisecondsSinceEpoch, kind: 'text', text: delta));
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

  Future<void> _newChat(AgentInfo agent, {String? cwd}) async {
    final client = _client;
    if (client == null || _opening) return;
    // Open the chat immediately. Waiting on the project picker made tapping
    // Cursor look like a no-op (the sheet can take seconds, or never appear).
    setState(() {
      _opening = true;
      _openingId = agent.id;
      _error = null;
    });
    try {
      final created = await client.request('agent.createSession', {
        'agent': agent.id,
        'title': agent.name,
        if (cwd != null) 'cwd': cwd,
      }) as Map<String, dynamic>;
      final session = AgentSessionInfo.fromJson(created);
      if (!mounted) return;
      setState(() {
        _sessions.insert(0, session);
        _active = session;
        _events.clear();
        _busy = false;
        _sendError = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) setState(() {
        _opening = false;
        _openingId = null;
      });
    }
  }

  Future<void> _newChatInProject(AgentInfo agent) async {
    final cwd = await _pickProject();
    if (!mounted) return;
    await _newChat(agent, cwd: cwd);
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
      _sendError = null;
      _events
        ..clear()
        ..addAll(raw.map((e) => AgentEvent.fromJson(e as Map<String, dynamic>)));
    });
    _scrollToEnd();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    final session = _active;
    final client = _client;
    if (text.isEmpty || session == null || client == null || _busy) return;
    _input.clear();
    setState(() {
      _busy = true;
      _sendError = null;
      _events.add(AgentEvent(
        seq: 0,
        ts: DateTime.now().millisecondsSinceEpoch,
        kind: 'user',
        text: text,
      ));
    });
    _scrollToEnd();
    try {
      final raw = await client.request('agent.prompt', {
        'agentSessionId': session.agentSessionId,
        'text': text,
      });
      if (raw is Map && raw['ok'] == false) {
        throw RpcException('The agent did not accept that message.');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _sendError = e.toString();
        });
      }
    }
  }

  Future<void> _cancel() async {
    final session = _active;
    final client = _client;
    if (session == null || client == null) return;
    try {
      await client.request('agent.cancel', {'agentSessionId': session.agentSessionId});
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
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
    });
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
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0F),
        title: Text(_active?.title ?? 'Agents',
            style: const TextStyle(fontSize: 16)),
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
              ? Center(
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.white70)))
              : _active == null
                  ? _picker()
                  : _chat(),
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
              _agentIcon(a.id),
              color: a.available
                  ? const Color(0xFF2A6AFF)
                  : Colors.white24,
            ),
            title: Text(a.name),
            subtitle: Text(a.available
                ? (_opening
                    ? 'Starting…'
                    : 'Tap to chat · long-press for a folder')
                : 'CLI not installed on the PC'),
            enabled: a.available && !_opening,
            trailing: _openingId == a.id
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: a.available && !_opening ? () => _newChat(a) : null,
            onLongPress:
                a.available && !_opening ? () => _newChatInProject(a) : null,
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
      ],
    );
  }

  IconData _agentIcon(String id) {
    switch (id) {
      case 'claude':
        return Icons.auto_awesome;
      case 'cursor':
        return Icons.code;
      case 'opencode':
        return Icons.terminal;
      case 'antigravity':
        return Icons.rocket_launch_outlined;
      default:
        return Icons.smart_toy_outlined;
    }
  }

  Widget _chat() {
    final extra = _busy ? 1 : 0;
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            itemCount: _events.length + extra,
            itemBuilder: (_, i) {
              if (i >= _events.length) return _busyRow();
              return _bubble(_events[i]);
            },
          ),
        ),
        if (_sendError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Text(_sendError!,
                style: const TextStyle(color: Color(0xFFEE5555), fontSize: 12)),
          ),
        _composer(),
      ],
    );
  }

  Widget _busyRow() {
    return const Padding(
      padding: EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Text('Working…',
              style: TextStyle(
                  color: Colors.white38, fontSize: 12, fontStyle: FontStyle.italic)),
        ],
      ),
    );
  }

  Widget _bubble(AgentEvent e) {
    switch (e.kind) {
      case 'user':
        return _align(
          Alignment.centerRight,
          Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF2A6AFF),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(e.text ?? '',
                style: const TextStyle(color: Colors.white)),
          ),
        );
      case 'text':
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
          child: Text(e.text ?? 'error',
              style: const TextStyle(color: Color(0xFFEE5555))),
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
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                onSubmitted: (_) {
                  if (!_busy) _send();
                },
                decoration: InputDecoration(
                  hintText: 'Message the agent…',
                  isDense: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: _busy ? 'Stop' : 'Send',
              onPressed: _busy ? _cancel : _send,
              icon: Icon(_busy ? Icons.stop : Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
