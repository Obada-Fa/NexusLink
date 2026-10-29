// Opt-in phone approvals for Claude sessions started outside NexusLink. Turning it on
// adds NexusLink's PermissionRequest hook to ~/.claude/settings.json on the PC.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../monitor/approvals.dart';
import '../state/connection.dart';
import '../theme/nexus_theme.dart';
import '../theme/nx_widgets.dart';
import 'pc_actions.dart';
import 'pc_ui.dart';

class PhoneApprovalsSection extends ConsumerStatefulWidget {
  const PhoneApprovalsSection({super.key});
  @override
  ConsumerState<PhoneApprovalsSection> createState() =>
      _PhoneApprovalsSectionState();
}

class _PhoneApprovalsSectionState extends ConsumerState<PhoneApprovalsSection> {
  bool _busy = false;

  Future<void> _set({bool? claude, bool? holdTerminal}) async {
    if (claude == true) {
      final ok = await confirmPcAction(
        context,
        title: 'Approve Claude from this phone?',
        body:
            'NexusLink adds a hook to ~/.claude/settings.json on the PC (a backup is kept). '
            'Claude then also sends its permission prompts, questions and plans here. '
            'If you don’t answer, Claude shows its normal prompt on the PC; nothing is ever approved for you.',
        confirm: 'Turn on',
        icon: Icons.verified_user_outlined,
      );
      if (!ok || !mounted) return;
    }
    setState(() => _busy = true);
    final error = await ref
        .read(approvalsProvider.notifier)
        .configure(claude: claude, holdTerminal: holdTerminal);
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) showPcMessage(context, error);
  }

  @override
  Widget build(BuildContext context) {
    if (!hostSupportsApprovals(ref.watch(activeClientProvider))) {
      return const SizedBox.shrink();
    }
    final status = ref.watch(approvalsProvider.select((s) => s.status));
    final pending = ref.watch(approvalsProvider.select((s) => s.items.length));
    if (status == null) return const SizedBox.shrink();
    final claude = Map<String, dynamic>.from(status['claude'] as Map? ?? {});
    final installed = claude['installed'] == true;
    final listening = status['listening'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PcSectionHeader(
          'Phone approvals',
          trailing: NxPill(
            installed ? (pending > 0 ? '$pending waiting' : 'On') : 'Off',
            color: installed
                ? (pending > 0 ? NX.waiting : NX.working)
                : NX.idle,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: NX.pad),
          child: NxCard(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SwitchListTile(
                  value: installed,
                  onChanged: _busy ? null : (on) => _set(claude: on),
                  title: const Text('Approve Claude from this phone'),
                  subtitle: const Text(
                    'Allow or deny, answer questions and approve plans for Claude Desktop and claude CLI sessions. '
                    'Sessions started after you turn this on pick it up.',
                  ),
                ),
                SwitchListTile(
                  value: status['holdTerminal'] == true,
                  onChanged: _busy || !installed
                      ? null
                      : (on) => _set(holdTerminal: on),
                  title: const Text('Hold terminal prompts for me'),
                  subtitle: const Text(
                    'Claude Desktop prompts always show on both. A claude CLI prompt in a terminal waits for this phone '
                    '(up to 30 min) before showing there; turn on while you’re away.',
                  ),
                ),
                if (claude['error'] is String)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                    child: PcNote(
                      claude['error'] as String,
                      color: NX.failed,
                      icon: Icons.error_outline_rounded,
                    ),
                  )
                else if (installed && !listening)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 4, 12, 0),
                    child: PcNote(
                      'NexusLink couldn’t open its local hook port, so prompts stay on the PC. Restart NexusLink on the PC.',
                      color: NX.waiting,
                      icon: Icons.warning_amber_rounded,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
