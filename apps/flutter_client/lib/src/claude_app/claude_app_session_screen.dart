// The shell of a "Start for Claude app" session, under a compact banner:
// name and folder, whether it is running, Open Claude and Stop. The user
// answers Claude's own prompts (trust this folder, enable Remote Control)
// in the terminal; nothing here reads the terminal's output.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../screens/terminal_screen.dart';
import '../state/connection.dart';
import '../theme/nexus_theme.dart';
import '../theme/nx_widgets.dart';
import '../workspace/terminal_repository.dart';
import 'claude_app_sessions.dart';

/// Opens the Claude app, or explains that it is not installed.
Future<void> openClaudeApp(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  bool opened;
  try {
    opened = await ref.read(claudeAppLauncherProvider)();
  } catch (_) {
    opened = false;
  }
  if (opened) return;
  messenger.showSnackBar(
    const SnackBar(
      content: Text(
        'The Claude app isn\'t installed on this phone. Install it from '
        'Google Play, or open claude.ai/code in a browser.',
      ),
    ),
  );
}

/// Asks before ending the session; true when it was stopped.
Future<bool> confirmStopClaudeAppSession(
  BuildContext context,
  WidgetRef ref,
  ClaudeAppSession session,
) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Stop "${session.name}"?'),
      content: const Text(
        'This ends the shell on your PC. The session stops in the Claude app '
        'and anything it is doing stops too.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Keep running'),
        ),
        TextButton(
          key: const ValueKey('confirm-stop-claude-app'),
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(foregroundColor: NX.failed),
          child: const Text('Stop'),
        ),
      ],
    ),
  );
  if (yes != true || !context.mounted) return false;
  try {
    await ref.read(claudeAppSessionsProvider.notifier).stop(session.terminalId);
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not stop it: $e')));
    }
    return false;
  }
}

class ClaudeAppSessionScreen extends ConsumerStatefulWidget {
  const ClaudeAppSessionScreen({super.key, required this.session});
  final ClaudeAppSession session;
  @override
  ConsumerState<ClaudeAppSessionScreen> createState() =>
      _ClaudeAppSessionScreenState();
}

class _ClaudeAppSessionScreenState
    extends ConsumerState<ClaudeAppSessionScreen> {
  RemoteTerminal? _remote;
  bool _shellEnded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _watchShell();
  }

  /// Follows the shell's own exit event (not its output) for the banner.
  void _watchShell() {
    if (_remote != null || ref.read(activeClientProvider) == null) return;
    try {
      _remote = ref
          .read(terminalRepositoryProvider)
          .get(widget.session.terminalId, terminalId: widget.session.terminalId)
        ..addListener(_onShell);
    } catch (_) {}
  }

  void _onShell() {
    final ended = _remote?.ended == true;
    if (ended == _shellEnded || !mounted) return;
    setState(() => _shellEnded = ended);
    if (ended) {
      ref
          .read(claudeAppSessionsProvider.notifier)
          .markEnded(widget.session.terminalId);
    }
  }

  @override
  void dispose() {
    _remote?.removeListener(_onShell);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(activeClientProvider, (_, _) => _watchShell());
    final sessions = ref.watch(claudeAppSessionsProvider);
    final known = sessions.sessions
        .where((s) => s.terminalId == widget.session.terminalId)
        .firstOrNull;
    final running =
        !_shellEnded &&
        (sessions.reconciled ? known?.running == true : widget.session.running);
    final s = widget.session;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              s.name,
              key: const ValueKey('claude-app-session-name'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16),
            ),
            Text(
              s.cwd,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: NX.textDim),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          _Banner(
            running: running,
            onOpen: () => openClaudeApp(context, ref),
            onStop: running
                ? () => confirmStopClaudeAppSession(context, ref, s)
                : null,
          ),
          Expanded(
            child: EmbeddedTerminal(
              key: ValueKey('claude-app-terminal:${s.terminalId}'),
              terminalId: s.terminalId,
              initialCwd: s.cwd,
            ),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.running, required this.onOpen, this.onStop});
  final bool running;
  final VoidCallback onOpen;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final status = Row(
      children: [
        if (running)
          const LiveDot(color: NX.working)
        else
          const Icon(Icons.stop_circle_outlined, size: 14, color: NX.idle),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            running ? 'Running' : 'Ended',
            key: const ValueKey('claude-app-banner-status'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: running ? NX.text : NX.textDim,
            ),
          ),
        ),
      ],
    );
    final open = FilledButton.icon(
      key: const ValueKey('open-claude-app'),
      onPressed: onOpen,
      style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
      icon: const Icon(Icons.open_in_new, size: 18),
      label: const Text('Open Claude'),
    );
    final stop = OutlinedButton.icon(
      key: const ValueKey('stop-claude-app'),
      onPressed: onStop,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        foregroundColor: NX.failed,
      ),
      icon: const Icon(Icons.stop_rounded, size: 18),
      label: const Text('Stop'),
    );
    return Material(
      color: NX.surface2,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(NX.pad, 6, NX.pad, 6),
        child: LayoutBuilder(
          builder: (context, c) {
            // One row when the status and both buttons fit; otherwise the
            // buttons share a second row so nothing is cut off.
            final scaler = MediaQuery.textScalerOf(context);
            final style = Theme.of(context).textTheme.labelLarge;
            double label(String text) {
              final painter = TextPainter(
                text: TextSpan(text: text, style: style),
                textDirection: TextDirection.ltr,
                textScaler: scaler,
              )..layout();
              final width = painter.width;
              painter.dispose();
              return width;
            }

            // Button = label + 18 icon + 8 gap + 16/24 padding; status needs
            // the dot, a gap and "Running".
            final needed =
                label('Open Claude') +
                label('Stop') +
                label('Running') +
                2 * (18 + 8 + 40) +
                16 +
                32;
            if (c.maxWidth >= needed) {
              return Row(
                children: [
                  Expanded(child: status),
                  const SizedBox(width: 8),
                  open,
                  const SizedBox(width: 8),
                  stop,
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                status,
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(child: open),
                    const SizedBox(width: 8),
                    Expanded(child: stop),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
