// How the owner reaches this PC: RustDesk (with its watchdog + a restart
// button), Tailscale and the NexusLink host itself.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../monitor/monitor_models.dart';
import '../monitor/monitor_provider.dart';
import '../theme/nexus_theme.dart';
import '../theme/nx_widgets.dart';
import 'pc_actions.dart';
import 'pc_ui.dart';

class RemoteAccessSection extends ConsumerStatefulWidget {
  const RemoteAccessSection({super.key});
  @override
  ConsumerState<RemoteAccessSection> createState() =>
      _RemoteAccessSectionState();
}

class _RemoteAccessSectionState extends ConsumerState<RemoteAccessSection>
    with AutomaticKeepAliveClientMixin {
  bool _restarting = false;

  @override
  bool get wantKeepAlive => _restarting;

  Future<void> _restartRustdesk() async {
    if (_restarting) return;
    final ok = await confirmPcAction(
      context,
      title: 'Restart RustDesk?',
      body:
          'Any open RustDesk session drops for a moment. RustDesk accepts connections again in about 10 seconds.',
      confirm: 'Restart',
      icon: Icons.restart_alt_rounded,
    );
    if (!ok || !mounted) return;
    setState(() => _restarting = true);
    updateKeepAlive();
    final messenger = ScaffoldMessenger.maybeOf(context);
    String message;
    try {
      message = await ref
          .read(monitorProvider.notifier)
          .remoteAction('rustdesk', 'restart');
    } catch (error) {
      message = pcActionError(error);
    }
    if (!mounted) {
      messenger?.showSnackBar(SnackBar(content: Text(message)));
      return;
    }
    setState(() => _restarting = false);
    updateKeepAlive();
    if (mentionsOneTimeSetup(message)) {
      await showRustdeskSetupSheet(context, message: message);
    } else {
      showPcMessage(context, message);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final services = ref.watch(
      monitorProvider.select((s) => s.snapshot?.remote),
    );
    if (services == null || services.isEmpty) return const SizedBox.shrink();
    final worst = services.any((s) => s.state == 'down')
        ? 'down'
        : services.any((s) => s.state == 'degraded')
        ? 'degraded'
        : 'healthy';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PcSectionHeader(
          'Remote access',
          trailing: NxPill(
            worst == 'healthy' ? 'All good' : Status.label(worst),
            color: Status.color(worst),
            dense: true,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: NX.pad),
          child: NxCard(
            accent: worst == 'down' ? NX.failed : null,
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < services.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _ServiceRow(
                    service: services[i],
                    restarting: services[i].id == 'rustdesk' && _restarting,
                    onRestart: services[i].id == 'rustdesk'
                        ? _restartRustdesk
                        : null,
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ServiceRow extends StatelessWidget {
  const _ServiceRow({
    required this.service,
    required this.restarting,
    required this.onRestart,
  });
  final RemoteService service;
  final bool restarting;
  final VoidCallback? onRestart;

  static IconData _icon(String id) => switch (id) {
    'rustdesk' => Icons.cast_connected_rounded,
    'tailscale' => Icons.vpn_lock_rounded,
    'nexuslink' => Icons.hub_rounded,
    _ => Icons.lan_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final s = service;
    final color = Status.color(s.state);
    final extraIssues = s.issues.where((i) => i != s.summary).toList();
    final needsSetup =
        s.id == 'rustdesk' &&
        s.installed &&
        (s.issues.any((i) => i.contains('install.sh')) ||
            s.details['passwordlessRestart'] == false);
    final repairAt = s.lastRepairAt;
    final byPhone = (s.lastRepairReason ?? '').startsWith('phone');
    final facts = s.id == 'rustdesk' && s.installed ? _rustdeskFacts(s) : null;
    final canRestart =
        onRestart != null && s.installed && s.actions.contains('restart');

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withValues(alpha: .14),
                  border: Border.all(color: color.withValues(alpha: .4)),
                ),
                child: Icon(_icon(s.id), size: 18, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (s.summary.isNotEmpty)
                      Text(
                        s.summary,
                        style: TextStyle(
                          color: s.state == 'healthy' ? NX.textDim : color,
                          fontSize: 12.5,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              NxPill(
                s.installed ? Status.label(s.state) : 'Not installed',
                color: s.installed ? color : NX.idle,
                dense: true,
              ),
            ],
          ),
          for (final issue in extraIssues)
            Padding(
              padding: const EdgeInsets.only(left: 48, top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      Icons.error_outline_rounded,
                      size: 14,
                      color: NX.waiting.withValues(alpha: .9),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      issue,
                      style: const TextStyle(color: NX.textDim, fontSize: 12.5),
                    ),
                  ),
                ],
              ),
            ),
          if (facts != null && facts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 48, top: 6),
              child: Text(
                facts,
                style: const TextStyle(color: NX.textFaint, fontSize: 12),
              ),
            ),
          if (repairAt != null)
            Padding(
              padding: const EdgeInsets.only(left: 48, top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Icon(
                      Icons.auto_fix_high_rounded,
                      size: 14,
                      color: NX.done,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      byPhone
                          ? 'Restarted from the phone ${fmtAgo(repairAt)}'
                          : 'Auto-repaired ${fmtAgo(repairAt)}'
                                '${_reason(s.lastRepairReason)}',
                      style: const TextStyle(color: NX.done, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          if (canRestart || needsSetup)
            Padding(
              padding: const EdgeInsets.only(left: 40, top: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  if (canRestart)
                    FilledButton.tonalIcon(
                      onPressed: restarting ? null : onRestart,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      icon: restarting
                          ? SizedBox.square(
                              dimension: 18,
                              child: reduceMotion(context)
                                  ? const Icon(
                                      Icons.hourglass_top_rounded,
                                      size: 18,
                                    )
                                  : const CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                            )
                          : const Icon(Icons.restart_alt_rounded, size: 20),
                      label: Text(
                        restarting
                            ? 'Restarting RustDesk…'
                            : 'Restart RustDesk',
                      ),
                    ),
                  if (needsSetup)
                    TextButton.icon(
                      onPressed: () => showRustdeskSetupSheet(context),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      icon: const Icon(Icons.build_circle_outlined, size: 20),
                      label: const Text('One-time fix'),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _rustdeskFacts(RemoteService s) {
    final d = s.details;
    return [
      if (d['display'] != null) 'Display ${d['display']}',
      if (d['directPort'] == true) 'direct port open',
      if (d['service'] != null && d['service'] != 'active')
        'service ${d['service']}',
    ].join(' · ');
  }

  static String _reason(String? reason) {
    if (reason == null || reason.isEmpty) return '';
    final r = reason.replaceFirst(RegExp(r'^watchdog:\s*'), '');
    return ' · $r';
  }
}
