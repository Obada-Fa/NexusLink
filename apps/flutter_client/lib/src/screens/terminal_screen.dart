import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import '../state/connection.dart';
import '../workspace/terminal_repository.dart';
import '../workspace/project.dart';
import 'terminal_input_controller.dart';

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

/// Fixed primary controls shared by global and task terminals.
class TerminalPrimaryControls extends StatelessWidget {
  const TerminalPrimaryControls({
    super.key,
    required this.input,
    required this.onMore,
    required this.more,
  });
  final TerminalInputController input;
  final VoidCallback onMore;
  final bool more;

  Widget _arrow(TerminalKey key, IconData icon, String label) => Expanded(
    child: Semantics(
      button: true,
      enabled: input.available,
      label: '$label arrow',
      onTap: input.available ? () => input.sendKey(key) : null,
      child: Tooltip(
        message: '$label arrow',
        child: Listener(
          onPointerDown: (_) => input.startArrow(key),
          onPointerUp: (_) => input.cancelRepeat(),
          onPointerCancel: (_) => input.cancelRepeat(),
          child: SizedBox(
            height: 48,
            child: Center(
              child: Icon(icon, color: input.available ? null : Colors.grey),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _control(String label, VoidCallback? action, {bool active = false}) =>
      Expanded(
        child: SizedBox(
          height: 48,
          child: TextButton(
            onPressed: action,
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: active ? Colors.amber : null,
              ),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    descendantsAreFocusable: false,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          _arrow(TerminalKey.arrowLeft, Icons.arrow_back, 'Left'),
          _arrow(TerminalKey.arrowUp, Icons.arrow_upward, 'Up'),
          _arrow(TerminalKey.arrowDown, Icons.arrow_downward, 'Down'),
          _arrow(TerminalKey.arrowRight, Icons.arrow_forward, 'Right'),
          _control(
            'Ctrl',
            input.available ? input.toggleCtrl : null,
            active: input.ctrl,
          ),
          _control('More', onMore, active: more),
        ],
      ),
    ),
  );
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
  String _sessionKey = 'global:0';
  String? _loadedHost;

  Future<void> _loadSelection() async {
    final host = ref.read(activeClientProvider)?.hostId;
    if (host == null || host == _loadedHost) return;
    _loadedHost = host;
    final prefs = await SharedPreferences.getInstance();
    if (mounted && _loadedHost == host) {
      setState(() => _selected = prefs.getString('terminal:selected:$host'));
    }
  }

  void _select(String? id, {bool fresh = false}) {
    final host = ref.read(activeClientProvider)?.hostId;
    setState(() {
      _selected = id;
      if (fresh) _sessionKey = 'global:${newTerminalOperationId()}';
    });
    if (host != null) {
      SharedPreferences.getInstance().then((prefs) {
        if (id == null) {
          prefs.remove('terminal:selected:$host');
        } else {
          prefs.setString('terminal:selected:$host', id);
        }
      });
    }
  }

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
        _select(selected == 'new' ? null : selected, fresh: selected == 'new');
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
  Widget build(BuildContext context) {
    ref.listen(activeClientProvider, (_, next) => _loadSelection());
    if (_loadedHost == null) _loadSelection();
    final project = ref.watch(projectProvider);
    return Scaffold(
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
        key: ValueKey('${_selected ?? widget.terminalId}:$_sessionKey'),
        initialCwd: widget.initialCwd ?? project?.path,
        terminalId: _selected ?? widget.terminalId,
        sessionId: _sessionKey,
        onTerminalId: (id) {
          final host = ref.read(activeClientProvider)?.hostId;
          if (host == null) return;
          SharedPreferences.getInstance().then(
            (prefs) => prefs.setString('terminal:selected:$host', id),
          );
        },
      ),
    );
  }
}

class EmbeddedTerminal extends ConsumerStatefulWidget {
  final String? initialCwd, sessionId, terminalId;
  final ValueChanged<String>? onTerminalId;
  const EmbeddedTerminal({
    super.key,
    this.initialCwd,
    this.sessionId,
    this.terminalId,
    this.onTerminalId,
  });
  @override
  ConsumerState<EmbeddedTerminal> createState() => _EmbeddedTerminalState();
}

class _EmbeddedTerminalState extends ConsumerState<EmbeddedTerminal>
    with WidgetsBindingObserver {
  RemoteTerminal? _remote;
  TerminalInputController? _input;
  final _terminalViewKey = GlobalKey<TerminalViewState>();
  bool _more = false, _swipe = false;
  String? _reportedTerminalId;
  double _fontSize = 14;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(
          () => _swipe = prefs.getBool('terminal:swipe-navigation') ?? false,
        );
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  void _bind() {
    final client = ref.read(activeClientProvider);
    if (client == null) return;
    final next = ref
        .read(terminalRepositoryProvider)
        .get(
          widget.terminalId ??
              '${widget.sessionId ?? 'global'}:${widget.initialCwd ?? ''}',
          cwd: widget.initialCwd,
          terminalId: widget.terminalId,
        );
    if (!identical(_remote, next)) {
      _input?.dispose();
      _remote = next;
      _input = TerminalInputController(next.terminal);
    }
    next.show(TickerMode.valuesOf(context).enabled, client);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _input?.cancelRepeat();
  }

  @override
  void dispose() {
    final remote = _remote;
    if (remote?.client != null) remote!.show(false, remote.client!);
    _input?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _showKeyboard() {
    if (!mounted ||
        _remote?.ready != true ||
        !TickerMode.valuesOf(context).enabled ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    _terminalViewKey.currentState?.requestKeyboard();
  }

  void _tap(ExtraKey key) {
    final input = _input;
    if (input == null) return;
    if (key.stickyCtrl) {
      input.toggleCtrl();
    } else if (key.stickyAlt) {
      input.toggleAlt();
    } else if (key.key != null) {
      input.sendKey(key.key!, forcedCtrl: key.ctrl);
    } else if (key.text != null) {
      input.sendText(key.text!);
    }
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
    final input = _input!;
    return AnimatedBuilder(
      animation: Listenable.merge([remote, input]),
      builder: (context, _) {
        final available = remote.ready && TickerMode.valuesOf(context).enabled;
        if (input.available != available) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !identical(input, _input)) return;
            final enabled =
                remote.ready && TickerMode.valuesOf(context).enabled;
            input.setAvailable(enabled);
            if (enabled) {
              _showKeyboard();
            } else {
              input.focusNode.unfocus();
              _terminalViewKey.currentState?.closeKeyboard();
            }
          });
        }
        if (remote.ready &&
            remote.id != null &&
            remote.id != _reportedTerminalId) {
          _reportedTerminalId = remote.id;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onTerminalId?.call(remote.id!);
          });
        }
        return Column(
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
                    tooltip: 'Show keyboard',
                    onPressed: available ? _showKeyboard : null,
                    icon: const Icon(Icons.keyboard),
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
                  key: _terminalViewKey,
                  readOnly: !available,
                  focusNode: input.focusNode,
                  textStyle: TerminalStyle(fontSize: _fontSize),
                  autofocus: false,
                  deleteDetection: true,
                  padding: const EdgeInsets.all(8),
                ),
              ),
            ),
            if (_swipe)
              Semantics(
                label: 'Swipe navigation strip',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (d) => input.startSwipe(d.localPosition),
                  onPanUpdate: (d) => input.updateSwipe(d.localPosition),
                  onPanEnd: (_) => input.cancelSwipe(),
                  onPanCancel: input.cancelSwipe,
                  child: const SizedBox(
                    height: 48,
                    child: Center(child: Text('Swipe to navigate')),
                  ),
                ),
              ),
            TerminalPrimaryControls(
              input: input,
              more: _more,
              onMore: () => setState(() => _more = !_more),
            ),
            if (_more)
              Flexible(
                fit: FlexFit.loose,
                child: Focus(
                  canRequestFocus: false,
                  descendantsAreFocusable: false,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 192),
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          SwitchListTile(
                            title: const Text('Swipe navigation'),
                            value: _swipe,
                            onChanged: (value) {
                              setState(() => _swipe = value);
                              SharedPreferences.getInstance().then(
                                (prefs) => prefs.setBool(
                                  'terminal:swipe-navigation',
                                  value,
                                ),
                              );
                            },
                          ),
                          Wrap(
                            children: [
                              for (final key in [..._row1, ..._row2, ..._row3])
                                if (key.key != TerminalKey.arrowLeft &&
                                    key.key != TerminalKey.arrowUp &&
                                    key.key != TerminalKey.arrowDown &&
                                    key.key != TerminalKey.arrowRight &&
                                    !key.stickyCtrl)
                                  SizedBox(
                                    width: 56,
                                    height: 48,
                                    child: TextButton(
                                      onPressed: input.available
                                          ? () => _tap(key)
                                          : null,
                                      child: Text(
                                        key.label,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ),
                                  ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
