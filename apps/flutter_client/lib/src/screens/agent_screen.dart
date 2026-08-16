// Native chat UI for AI agents that run on the PC (Claude Code, Cursor CLI,
// or the built-in demo agent). The phone never sees a terminal — tool calls
// become cards, assistant text is markdown, and history survives reconnects.

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
    setState(() => _events.add(AgentEvent.fromJson(ev)));
    _scrollToEnd();
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

  Future<void> _newChat(AgentInfo agent) async {
    final client = _client;
    if (client == null) return;
    final created = await client.request('agent.createSession', {
      'agent': agent.id,
      'title': agent.name,
    }) as Map<String, dynamic>;
    final session = AgentSessionInfo.fromJson(created);
    setState(() {
      _sessions.insert(0, session);
      _active = session;
      _events.clear();
    });
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
    if (text.isEmpty || session == null || client == null) return;
    _input.clear();
    await client.request('agent.prompt', {
      'agentSessionId': session.agentSessionId,
      'text': text,
    });
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
              a.id == 'claude'
                  ? Icons.auto_awesome
                  : a.id == 'cursor'
                      ? Icons.code
                      : Icons.smart_toy_outlined,
              color: a.available
                  ? const Color(0xFF2A6AFF)
                  : Colors.white24,
            ),
            title: Text(a.name),
            subtitle: Text(a.available
                ? 'Runs on the PC — chat here'
                : 'CLI not installed on the PC'),
            enabled: a.available,
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
            itemCount: _events.length,
            itemBuilder: (_, i) => _bubble(_events[i]),
          ),
        ),
        _composer(),
      ],
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
      case 'error':
        return Padding(
          padding: const EdgeInsets.all(8),
          child: Text(e.text ?? 'error',
              style: const TextStyle(color: Color(0xFFEE5555)),
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
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: Color(0xFF6EE7B7))),
            ),
        ],
      ),
    );
  }

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
                onSubmitted: (_) => _send(),
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
              onPressed: _send,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
