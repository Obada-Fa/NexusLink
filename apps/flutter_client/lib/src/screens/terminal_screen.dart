// Native phone terminal: a real PTY on the PC (pty-host.py) rendered with
// the xterm Dart widget — colors, job control, resize, and the phone IME.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../rpc/rpc_client.dart';
import '../state/connection.dart';

class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key});

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  late final Terminal _term;
  String? _terminalId;
  void Function()? _unsub;
  bool _ready = false;
  String? _error;

  RpcClient? get _client => ref.read(activeClientProvider);

  @override
  void initState() {
    super.initState();
    _term = Terminal(
      maxLines: 2000,
      onOutput: (data) {
        final id = _terminalId;
        if (id == null) return;
        _client?.notify('terminal.input', {'terminalId': id, 'data': data});
      },
      onResize: (w, h, _, _) {
        final id = _terminalId;
        if (id == null) return;
        _client?.notify(
            'terminal.resize', {'terminalId': id, 'cols': w, 'rows': h});
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final client = _client;
    if (client == null) {
      setState(() => _error = 'Not connected to the PC.');
      return;
    }
    try {
      final res = await client.request('terminal.create', {
        'cols': _term.viewWidth > 0 ? _term.viewWidth : 80,
        'rows': _term.viewHeight > 0 ? _term.viewHeight : 24,
      }) as Map<String, dynamic>;
      _terminalId = res['terminalId'] as String?;
      _unsub = client.subscribe('terminal-output', (msg) {
        if (msg['terminalId'] != _terminalId) return;
        final data = msg['data'];
        if (data is String) _term.write(data);
      });
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _unsub?.call();
    final id = _terminalId;
    if (id != null) _client?.notify('terminal.kill', {'terminalId': id});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0F),
        title: const Text('Terminal', style: TextStyle(fontSize: 16)),
      ),
      body: _error != null
          ? Center(
              child: Text(_error!,
                  style: const TextStyle(color: Colors.white70)))
          : !_ready
              ? const Center(child: CircularProgressIndicator())
              : TerminalView(
                  _term,
                  theme: TerminalThemes.defaultTheme,
                  textStyle: const TerminalStyle(fontSize: 13),
                  autofocus: true,
                  backgroundOpacity: 1,
                  padding: const EdgeInsets.all(8),
                ),
    );
  }
}
