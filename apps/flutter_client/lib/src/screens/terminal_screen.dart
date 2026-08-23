import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../rpc/rpc_client.dart';
import '../state/connection.dart';
import '../state/terminal_busy.dart';
import '../widgets/not_connected_view.dart';

class ExtraKey {
  final String label;
  final String? text;
  final TerminalKey? key;
  final bool ctrl;
  final bool alt;
  final bool stickyCtrl;
  final bool stickyAlt;
  const ExtraKey(this.label,
      {this.text,
      this.key,
      this.ctrl = false,
      this.alt = false,
      this.stickyCtrl = false,
      this.stickyAlt = false});
}

const _row1 = [
  ExtraKey('ESC', key: TerminalKey.escape),
  ExtraKey('TAB', key: TerminalKey.tab),
  ExtraKey('CTRL', stickyCtrl: true),
  ExtraKey('ALT', stickyAlt: true),
  ExtraKey('/', text: '/'),
  ExtraKey('-', text: '-'),
  ExtraKey('|', text: '|'),
  ExtraKey('_', text: '_'),
];

const _row2 = [
  ExtraKey('←', key: TerminalKey.arrowLeft),
  ExtraKey('↑', key: TerminalKey.arrowUp),
  ExtraKey('↓', key: TerminalKey.arrowDown),
  ExtraKey('→', key: TerminalKey.arrowRight),
  ExtraKey('⌂', key: TerminalKey.home),
  ExtraKey('END', key: TerminalKey.end),
  ExtraKey('PG↑', key: TerminalKey.pageUp),
  ExtraKey('PG↓', key: TerminalKey.pageDown),
];

const _row3 = [
  ExtraKey('^C', key: TerminalKey.keyC, ctrl: true),
  ExtraKey('^D', key: TerminalKey.keyD, ctrl: true),
  ExtraKey('^Z', key: TerminalKey.keyZ, ctrl: true),
  ExtraKey('^L', key: TerminalKey.keyL, ctrl: true),
  ExtraKey('^A', key: TerminalKey.keyA, ctrl: true),
  ExtraKey('^W', key: TerminalKey.keyW, ctrl: true),
  ExtraKey('^U', key: TerminalKey.keyU, ctrl: true),
  ExtraKey('^R', key: TerminalKey.keyR, ctrl: true),
];

/// Apply sticky Ctrl/Alt to IME text (mirrors PWA extra-keys.ts).
String applyStickyModifiers(String data, {required bool ctrl, required bool alt}) {
  var out = data;
  if (ctrl && out.length == 1) {
    final code = out.toUpperCase().codeUnitAt(0);
    if (code >= 65 && code <= 90) {
      out = String.fromCharCode(code & 0x1f);
    }
  }
  if (alt) out = '\x1b$out';
  return out;
}

class TerminalScreen extends ConsumerStatefulWidget {
  final String? initialCwd;
  const TerminalScreen({super.key, this.initialCwd});

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  late final Terminal _term;
  String? _terminalId;
  void Function()? _unsub;
  bool _ready = false;
  String? _error;
  bool _ctrl = false;
  bool _alt = false;
  double _fontSize = 13;

  RpcClient? get _client => ref.read(activeClientProvider);

  @override
  void initState() {
    super.initState();
    _term = Terminal(
      maxLines: 4000,
      onOutput: (data) {
        var payload = data;
        if (_ctrl || _alt) {
          payload = applyStickyModifiers(data, ctrl: _ctrl, alt: _alt);
          if (mounted) {
            setState(() {
              _ctrl = false;
              _alt = false;
            });
          } else {
            _ctrl = false;
            _alt = false;
          }
        }
        final id = _terminalId;
        if (id == null) return;
        _client?.notify('terminal.input', {'terminalId': id, 'data': payload});
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
      final params = <String, dynamic>{
        'cols': _term.viewWidth > 0 ? _term.viewWidth : 80,
        'rows': _term.viewHeight > 0 ? _term.viewHeight : 24,
      };
      if (widget.initialCwd != null && widget.initialCwd!.isNotEmpty) {
        params['cwd'] = widget.initialCwd;
      }
      final res = await client.request('terminal.create', params) as Map<String, dynamic>;
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

  void _tap(ExtraKey k) {
    HapticFeedback.selectionClick();
    if (k.stickyCtrl) {
      setState(() => _ctrl = !_ctrl);
      return;
    }
    if (k.stickyAlt) {
      setState(() => _alt = !_alt);
      return;
    }
    if (k.key != null) {
      _term.keyInput(k.key!, ctrl: k.ctrl || _ctrl, alt: k.alt || _alt);
      if (_ctrl || _alt) setState(() { _ctrl = false; _alt = false; });
      return;
    }
    if (k.text != null) {
      _term.textInput(applyStickyModifiers(k.text!, ctrl: _ctrl, alt: _alt));
      if (_ctrl || _alt) setState(() { _ctrl = false; _alt = false; });
    }
  }

  Future<void> _paste() async {
    HapticFeedback.selectionClick();
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) _term.paste(text);
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
      backgroundColor: const Color(0xFF0D0D12),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D12),
        title: const Text('Terminal', style: TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            tooltip: 'Smaller',
            onPressed: () => setState(
                () => _fontSize = (_fontSize - 1).clamp(11, 22)),
            icon: const Text('A−', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          IconButton(
            tooltip: 'Larger',
            onPressed: () => setState(
                () => _fontSize = (_fontSize + 1).clamp(11, 22)),
            icon: const Text('A+', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          IconButton(
            tooltip: 'Paste',
            onPressed: _paste,
            icon: const Icon(Icons.content_paste),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _body()),
          if (_ready) _extraKeys(),
        ],
      ),
    );
  }

  Widget _body() {
    if (_error != null) {
      if (looksLikeConnectionError(_error)) {
        return NotConnectedView(
          message: _error!,
          onReconnected: () {
            setState(() => _error = null);
            _start();
          },
        );
      }
      return Center(
          child: Text(_error!, style: const TextStyle(color: Colors.white70)));
    }
    if (!_ready) return const Center(child: CircularProgressIndicator());
    return TerminalView(
      _term,
      theme: TerminalThemes.defaultTheme,
      textStyle: TerminalStyle(fontSize: _fontSize),
      autofocus: true,
      backgroundOpacity: 1,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      deleteDetection: true,
    );
  }

  Widget _extraKeys() {
    Widget row(List<ExtraKey> keys) => SizedBox(
          height: 42,
          child: Row(
            children: [
              for (final k in keys)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Material(
                      color: (k.stickyCtrl && _ctrl) || (k.stickyAlt && _alt)
                          ? const Color(0xFF2A6AFF)
                          : const Color(0xFF1A1A28),
                      borderRadius: BorderRadius.circular(8),
                      child: InkWell(
                        onTap: () => _tap(k),
                        borderRadius: BorderRadius.circular(8),
                        child: Center(
                          child: Text(k.label,
                              style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  fontFamily: 'monospace')),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
    return Container(
      color: const Color(0xFF0A0A10),
      padding: EdgeInsets.fromLTRB(
          6, 6, 6, 8 + MediaQuery.of(context).padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [row(_row1), const SizedBox(height: 4), row(_row2), const SizedBox(height: 4), row(_row3)],
      ),
    );
  }
}

/// Embedded terminal widget suitable for tab views inside the agent chat.
class EmbeddedTerminal extends ConsumerStatefulWidget {
  final String? initialCwd;
  final String? sessionId;

  const EmbeddedTerminal({
    super.key,
    this.initialCwd,
    this.sessionId,
  });

  @override
  ConsumerState<EmbeddedTerminal> createState() => _EmbeddedTerminalState();
}

class _EmbeddedTerminalState extends ConsumerState<EmbeddedTerminal> {
  late final Terminal _term;
  String? _terminalId;
  void Function()? _unsub;
  bool _ready = false;
  String? _error;
  bool _ctrl = false;
  bool _alt = false;
  double _fontSize = 13;

  Timer? _promptDebounce;
  static final _promptRe = RegExp(r'[\$#>%❯→] ?$');

  RpcClient? get _client => ref.read(activeClientProvider);

  @override
  void initState() {
    super.initState();
    _term = Terminal(
      maxLines: 4000,
      onOutput: (data) {
        var payload = data;
        if (_ctrl || _alt) {
          payload = applyStickyModifiers(data, ctrl: _ctrl, alt: _alt);
          if (mounted) {
            setState(() {
              _ctrl = false;
              _alt = false;
            });
          } else {
            _ctrl = false;
            _alt = false;
          }
        }
        if (payload.contains('\r') || payload.contains('\n')) {
          _setBusy(true);
        }
        final id = _terminalId;
        if (id == null) return;
        _client?.notify('terminal.input', {'terminalId': id, 'data': payload});
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

  void _setBusy(bool busy) {
    final sid = widget.sessionId;
    if (sid == null || sid.isEmpty) return;
    ref.read(terminalBusyProvider.notifier).setBusy(sid, busy);
  }

  Future<void> _start() async {
    final client = _client;
    if (client == null) {
      setState(() => _error = 'Not connected to the PC.');
      return;
    }
    try {
      final params = <String, dynamic>{
        'cols': _term.viewWidth > 0 ? _term.viewWidth : 80,
        'rows': _term.viewHeight > 0 ? _term.viewHeight : 24,
      };
      if (widget.initialCwd != null && widget.initialCwd!.isNotEmpty) {
        params['cwd'] = widget.initialCwd;
      }
      final res = await client.request('terminal.create', params)
          as Map<String, dynamic>;
      _terminalId = res['terminalId'] as String?;
      _unsub = client.subscribe('terminal-output', (msg) {
        if (msg['terminalId'] != _terminalId) return;
        final data = msg['data'];
        if (data is String) {
          _term.write(data);
          _onOutputData(data);
        }
      });
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _onOutputData(String data) {
    _promptDebounce?.cancel();
    _promptDebounce = Timer(const Duration(milliseconds: 350), () {
      final clean = data.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '').trimRight();
      if (clean.isNotEmpty) {
        final lines = clean.split('\n');
        final last = lines.lastWhere((l) => l.trim().isNotEmpty, orElse: () => '');
        if (_promptRe.hasMatch(last.trim())) {
          _setBusy(false);
        }
      }
    });
  }

  void _tap(ExtraKey k) {
    HapticFeedback.selectionClick();
    if (k.stickyCtrl) {
      setState(() => _ctrl = !_ctrl);
      return;
    }
    if (k.stickyAlt) {
      setState(() => _alt = !_alt);
      return;
    }
    if (k.label == '^C' || k.label == '^D' || k.label == '^Z') {
      // User sent interrupt/kill - will reset to prompt soon
      _promptDebounce?.cancel();
      _promptDebounce = Timer(const Duration(milliseconds: 300), () => _setBusy(false));
    }
    if (k.key != null) {
      _term.keyInput(k.key!, ctrl: k.ctrl || _ctrl, alt: k.alt || _alt);
      if (_ctrl || _alt) setState(() { _ctrl = false; _alt = false; });
      return;
    }
    if (k.text != null) {
      _term.textInput(applyStickyModifiers(k.text!, ctrl: _ctrl, alt: _alt));
      if (_ctrl || _alt) setState(() { _ctrl = false; _alt = false; });
    }
  }

  Future<void> _paste() async {
    HapticFeedback.selectionClick();
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) _term.paste(text);
  }

  @override
  void dispose() {
    _promptDebounce?.cancel();
    final sid = widget.sessionId;
    if (sid != null && sid.isNotEmpty) {
      ref.read(terminalBusyProvider.notifier).remove(sid);
    }
    _unsub?.call();
    final id = _terminalId;
    if (id != null) _client?.notify('terminal.kill', {'terminalId': id});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0D0D12),
      child: Column(
        children: [
          Container(
            color: const Color(0xFF0A0A10),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Smaller',
                  iconSize: 18,
                  onPressed: () => setState(
                      () => _fontSize = (_fontSize - 1).clamp(11, 22)),
                  icon: const Text('A−',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                ),
                IconButton(
                  tooltip: 'Larger',
                  iconSize: 18,
                  onPressed: () => setState(
                      () => _fontSize = (_fontSize + 1).clamp(11, 22)),
                  icon: const Text('A+',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                ),
                IconButton(
                  tooltip: 'Paste',
                  iconSize: 18,
                  onPressed: _paste,
                  icon: const Icon(Icons.content_paste, size: 18),
                ),
                const Spacer(),
                if (widget.initialCwd != null && widget.initialCwd!.isNotEmpty)
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        widget.initialCwd!,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white38,
                          fontFamily: 'monospace',
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(child: _body()),
          if (_ready) _extraKeys(),
        ],
      ),
    );
  }

  Widget _body() {
    if (_error != null) {
      if (looksLikeConnectionError(_error)) {
        return NotConnectedView(
          message: _error!,
          onReconnected: () {
            setState(() => _error = null);
            _start();
          },
        );
      }
      return Center(
          child: Text(_error!, style: const TextStyle(color: Colors.white70)));
    }
    if (!_ready) return const Center(child: CircularProgressIndicator());
    return TerminalView(
      _term,
      theme: TerminalThemes.defaultTheme,
      textStyle: TerminalStyle(fontSize: _fontSize),
      autofocus: true,
      backgroundOpacity: 1,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      deleteDetection: true,
    );
  }

  Widget _extraKeys() {
    Widget row(List<ExtraKey> keys) => SizedBox(
          height: 42,
          child: Row(
            children: [
              for (final k in keys)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Material(
                      color: (k.stickyCtrl && _ctrl) || (k.stickyAlt && _alt)
                          ? const Color(0xFF2A6AFF)
                          : const Color(0xFF1A1A28),
                      borderRadius: BorderRadius.circular(8),
                      child: InkWell(
                        onTap: () => _tap(k),
                        borderRadius: BorderRadius.circular(8),
                        child: Center(
                          child: Text(k.label,
                              style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  fontFamily: 'monospace')),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
    return Container(
      color: const Color(0xFF0A0A10),
      padding: EdgeInsets.fromLTRB(
          6, 6, 6, 8 + MediaQuery.of(context).padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          row(_row1),
          const SizedBox(height: 4),
          row(_row2),
          const SizedBox(height: 4),
          row(_row3),
        ],
      ),
    );
  }
}
