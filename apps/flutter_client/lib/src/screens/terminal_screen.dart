import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../state/connection.dart';
import '../workspace/terminal_repository.dart';

class ExtraKey {
  final String label;
  final String? text;
  final TerminalKey? key;
  final bool ctrl;
  final bool alt;
  final bool stickyCtrl;
  final bool stickyAlt;
  const ExtraKey(
    this.label, {
    this.text,
    this.key,
    this.ctrl = false,
    this.alt = false,
    this.stickyCtrl = false,
    this.stickyAlt = false,
  });
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
String applyStickyModifiers(
  String data, {
  required bool ctrl,
  required bool alt,
}) {
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
  final String? terminalId;
  const TerminalScreen({super.key, this.initialCwd, this.terminalId});
  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  String? _selected;
  int _new = 0;
  Future<void> _choose() async {
    final client = ref.read(activeClientProvider);
    if (client == null) return;
    try {
      final rows = await client.requestList('terminal.list');
      if (!mounted) return;
      final selected = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('PC shells')),
              for (final row in rows)
                ListTile(
                  leading: const Icon(Icons.terminal),
                  title: Text('${row['cwd']}'),
                  subtitle: Text(
                    '${row['state']} · ${row['taskId'] ?? 'Shell'}',
                  ),
                  onTap: () => Navigator.pop(ctx, row['terminalId'] as String),
                ),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('New shell'),
                onTap: () => Navigator.pop(ctx, 'new'),
              ),
            ],
          ),
        ),
      );
      if (selected != null && mounted) {
        setState(() {
          _selected = selected == 'new' ? null : selected;
          if (selected == 'new') _new++;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Terminal'),
      actions: [
        IconButton(
          tooltip: 'Shell sessions',
          onPressed: _choose,
          icon: const Icon(Icons.view_list),
        ),
      ],
    ),
    body: EmbeddedTerminal(
      key: ValueKey('${_selected ?? widget.terminalId}:$_new'),
      initialCwd: widget.initialCwd,
      terminalId: _selected ?? widget.terminalId,
      sessionId: 'global:$_new',
    ),
  );
}

class EmbeddedTerminal extends ConsumerStatefulWidget {
  final String? initialCwd, sessionId, terminalId;
  const EmbeddedTerminal({
    super.key,
    this.initialCwd,
    this.sessionId,
    this.terminalId,
  });
  @override
  ConsumerState<EmbeddedTerminal> createState() => _EmbeddedTerminalState();
}

class _EmbeddedTerminalState extends ConsumerState<EmbeddedTerminal> {
  RemoteTerminal? _remote;
  bool _ctrl = false, _alt = false;
  double _fontSize = 14;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  void _bind() {
    final client = ref.read(activeClientProvider);
    if (client == null) return;
    _remote = ref
        .read(terminalRepositoryProvider)
        .get(
          widget.terminalId ??
              '${widget.sessionId ?? 'global'}:${widget.initialCwd ?? ''}',
          cwd: widget.initialCwd,
          terminalId: widget.terminalId,
        );
    _remote?.show(TickerMode.of(context), client);
  }

  @override
  void dispose() {
    final remote = _remote;
    if (remote?.client != null) remote!.show(false, remote.client!);
    super.dispose();
  }

  void _tap(ExtraKey key) {
    final remote = _remote;
    if (remote == null || !remote.ready) return;
    if (key.stickyCtrl) {
      setState(() => _ctrl = !_ctrl);
      return;
    }
    if (key.stickyAlt) {
      setState(() => _alt = !_alt);
      return;
    }
    if (key.key != null) {
      remote.terminal.keyInput(
        key.key!,
        ctrl: key.ctrl || _ctrl,
        alt: key.alt || _alt,
      );
    } else if (key.text != null)
      remote.terminal.textInput(
        applyStickyModifiers(key.text!, ctrl: _ctrl, alt: _alt),
      );
    setState(() {
      _ctrl = false;
      _alt = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(activeClientProvider, (_, next) {
      if (next != null && mounted) setState(_bind);
    });
    final remote = _remote;
    if (remote == null) {
      return const Center(child: Text('Connect to your PC to open a shell.'));
    }
    return AnimatedBuilder(
      animation: remote,
      builder: (context, _) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    remote.ready
                        ? 'Shell connected'
                        : remote.ended
                        ? 'Shell ended'
                        : 'Reconnecting shell…',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                IconButton(
                  tooltip: 'Font size',
                  onPressed: () => setState(
                    () => _fontSize = _fontSize >= 20 ? 12 : _fontSize + 1,
                  ),
                  icon: const Icon(Icons.text_fields),
                ),
                IconButton(
                  tooltip: 'Paste',
                  onPressed: remote.ready
                      ? () async {
                          final data = await Clipboard.getData(
                            Clipboard.kTextPlain,
                          );
                          if (data?.text != null) {
                            remote.terminal.paste(data!.text!);
                          }
                        }
                      : null,
                  icon: const Icon(Icons.content_paste),
                ),
                IconButton(
                  tooltip: 'End shell',
                  onPressed: remote.ready
                      ? () async {
                          final yes = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('End this shell?'),
                              content: const Text(
                                'Commands running in this shell will stop.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('Keep running'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('End shell'),
                                ),
                              ],
                            ),
                          );
                          if (yes == true) await remote.terminate();
                        }
                      : null,
                  icon: const Icon(Icons.stop_circle_outlined),
                ),
              ],
            ),
          ),
          if (remote.error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Text(remote.error!),
                  TextButton(
                    onPressed: remote.ended
                        ? remote.newShell
                        : () => remote.bind(ref.read(activeClientProvider)!),
                    child: Text(remote.ended ? 'New shell' : 'Retry'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: AbsorbPointer(
              absorbing: !remote.ready,
              child: TerminalView(
                remote.terminal,
                textStyle: TerminalStyle(fontSize: _fontSize),
                autofocus: false,
                deleteDetection: true,
                padding: const EdgeInsets.all(8),
              ),
            ),
          ),
          if (remote.ready)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final key in [..._row1, ..._row2, ..._row3])
                    SizedBox(
                      width: 48,
                      child: TextButton(
                        onPressed: () => _tap(key),
                        child: Text(
                          key.label,
                          style: TextStyle(
                            fontSize: 12,
                            color:
                                (key.stickyCtrl && _ctrl) ||
                                    (key.stickyAlt && _alt)
                                ? Colors.amber
                                : null,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
