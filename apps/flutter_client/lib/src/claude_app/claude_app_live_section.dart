// Agents → Live: sessions this phone started on the PC for the Claude app.
// Shown only after reconciling with the host's live shells, so a shell that
// is gone never reads "Running".

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/nexus_theme.dart';
import '../theme/nx_widgets.dart';
import 'claude_app_session_screen.dart';
import 'claude_app_sessions.dart';

/// A sliver; renders nothing when there are no such sessions.
class ClaudeAppLiveSection extends ConsumerStatefulWidget {
  const ClaudeAppLiveSection({super.key});
  @override
  ConsumerState<ClaudeAppLiveSection> createState() =>
      _ClaudeAppLiveSectionState();
}

class _ClaudeAppLiveSectionState extends ConsumerState<ClaudeAppLiveSection>
    with WidgetsBindingObserver {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(_refresh);
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _refresh() {
    if (mounted) unawaited(ref.read(claudeAppSessionsProvider.notifier).refresh());
  }

  Future<void> _open(ClaudeAppSession session) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ClaudeAppSessionScreen(session: session),
      ),
    );
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(claudeAppSessionsProvider);
    if (!state.reconciled || state.sessions.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final running = state.sessions.where((s) => s.running).length;
    return SliverList.list(
      children: [
        NxSectionHeader(
          'On PC for Claude app',
          count: running,
          color: NX.working,
        ),
        for (final s in state.sessions)
          Padding(
            padding: const EdgeInsets.fromLTRB(NX.pad, 0, NX.pad, NX.gap),
            child: ClaudeAppSessionCard(
              key: ValueKey('claude-app-row:${s.terminalId}'),
              session: s,
              onOpen: () => _open(s),
              onStop: () => confirmStopClaudeAppSession(context, ref, s),
              onDismiss: () => ref
                  .read(claudeAppSessionsProvider.notifier)
                  .dismiss(s.terminalId),
            ),
          ),
      ],
    );
  }
}

class ClaudeAppSessionCard extends StatelessWidget {
  const ClaudeAppSessionCard({
    super.key,
    required this.session,
    required this.onOpen,
    required this.onStop,
    required this.onDismiss,
  });
  final ClaudeAppSession session;
  final VoidCallback onOpen, onStop, onDismiss;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final label = s.running ? 'Running for Claude app' : 'Ended';
    return Semantics(
      label: '$label · ${s.name} · ${s.cwd}',
      child: NxCard(
        accent: s.running ? NX.working : null,
        flat: true,
        onTap: onOpen,
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (s.running)
                        const LiveDot(color: NX.working)
                      else
                        const Icon(
                          Icons.stop_circle_outlined,
                          size: 14,
                          color: NX.idle,
                        ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: s.running ? NX.working : NX.textDim,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    s.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    s.cwd,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: NX.textDim),
                  ),
                ],
              ),
            ),
            if (s.running)
              IconButton(
                key: ValueKey('claude-app-stop:${s.terminalId}'),
                tooltip: 'Stop',
                onPressed: onStop,
                icon: const Icon(Icons.stop_rounded, color: NX.failed),
              )
            else
              IconButton(
                key: ValueKey('claude-app-dismiss:${s.terminalId}'),
                tooltip: 'Remove from list',
                onPressed: onDismiss,
                icon: const Icon(Icons.close, color: NX.textDim),
              ),
          ],
        ),
      ),
    );
  }
}
