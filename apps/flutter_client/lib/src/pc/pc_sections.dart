// PC tab sections that read the live monitor state themselves, so the tab's
// app launcher doesn't rebuild on every vitals push.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../monitor/monitor_models.dart';
import '../monitor/monitor_provider.dart';
import '../rpc/rpc_client.dart';
import '../state/connection.dart';
import '../theme/nexus_theme.dart';
import '../theme/nx_widgets.dart';
import 'flow_strip.dart';
import 'pc_actions.dart';
import 'pc_ui.dart';
import 'vitals_hero.dart';
import 'vitals_sheet.dart';

const _sidePad = EdgeInsets.symmetric(horizontal: NX.pad);

class PcHeroSection extends ConsumerWidget {
  const PcHeroSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(monitorProvider);
    final status = ref.watch(connectionStatusProvider);
    final snapshot = state.snapshot;
    return Padding(
      padding: _sidePad,
      child: snapshot == null
          ? _HeroLoading(error: state.error, status: status)
          : VitalsHero(
              snapshot: snapshot,
              history: state.history ?? MonitorHistory(),
              status: status,
              onOpen: (focus) => showVitalsSheet(context, focus),
            ),
    );
  }
}

class _HeroLoading extends StatelessWidget {
  const _HeroLoading({required this.error, required this.status});
  final String? error;
  final RpcStatus status;

  @override
  Widget build(BuildContext context) {
    final offline = status != RpcStatus.connected;
    return NxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              LiveDot(color: offline ? NX.idle : NX.waiting, pulse: !offline),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  offline
                      ? 'Waiting for the PC to connect…'
                      : 'Reading PC vitals…',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(
              friendlyLaunchError(error!),
              style: const TextStyle(color: NX.waiting, fontSize: 12.5),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              for (final label in const ['CPU', 'GPU', 'RAM'])
                Expanded(
                  child: Center(
                    child: MediaQuery.withClampedTextScaling(
                      maxScaleFactor: 1.15,
                      child: RingGauge(value: null, label: label, size: 72),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class PcFlowSection extends ConsumerWidget {
  const PcFlowSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(monitorProvider);
    final snapshot = state.snapshot;
    if (snapshot == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NxSectionHeader('Flow'),
        Padding(
          padding: _sidePad,
          child: FlowStrip(
            vitals: snapshot.vitals,
            history: state.history ?? MonitorHistory(),
          ),
        ),
      ],
    );
  }
}

/// Busiest processes right now (from the vitals push). Ending a process is
/// offered only when the host implements `process.kill`.
class TopProcessesSection extends ConsumerWidget {
  const TopProcessesSection({super.key});

  Future<void> _kill(BuildContext context, WidgetRef ref, TopProcess p) async {
    final ok = await confirmPcAction(
      context,
      title: 'End ${p.name}?',
      body: 'Stops process ${p.pid} on the PC. Anything unsaved in it is lost.',
      confirm: 'End process',
      icon: Icons.dangerous_outlined,
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    final client = ref.read(activeClientProvider);
    var message = '${p.name} ended.';
    try {
      if (client == null) throw StateError('Not connected to the PC.');
      final result = await client.request('process.kill', {'pid': p.pid});
      if (result is Map && result['message'] is String) {
        message = result['message'] as String;
      } else if (result is Map && result['ok'] == false) {
        message = 'Couldn’t end ${p.name}.';
      }
    } catch (error) {
      message = pcActionError(error);
    }
    await ref.read(monitorProvider.notifier).refresh();
    if (context.mounted) showPcMessage(context, message);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vitals = ref.watch(monitorProvider.select((s) => s.snapshot?.vitals));
    final client = ref.watch(activeClientProvider);
    if (vitals == null || vitals.top.isEmpty) return const SizedBox.shrink();
    final canKill = client?.supports('process.kill') == true;
    final list = vitals.top.map(TopProcess.new).take(8).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PcSectionHeader(
          'Top processes',
          trailing: Text(
            '${vitals.processCount} running',
            style: const TextStyle(
              color: NX.textFaint,
              fontSize: 11.5,
              fontFeatures: NX.tabular,
            ),
          ),
        ),
        Padding(
          padding: _sidePad,
          child: NxCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [
                for (final p in list)
                  _ProcessRow(
                    process: p,
                    onKill: canKill ? () => _kill(context, ref, p) : null,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ProcessRow extends StatelessWidget {
  const _ProcessRow({required this.process, required this.onKill});
  final TopProcess process;
  final VoidCallback? onKill;

  @override
  Widget build(BuildContext context) {
    final p = process;
    final heat = NX.heat(p.cpu);
    return Semantics(
      container: true,
      label:
          '${p.name}, CPU ${p.cpu.round()} percent, memory ${formatBytes(p.memory)}',
      excludeSemantics: onKill == null,
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, 6, onKill == null ? 14 : 2, 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: SizedBox(
                      height: 3,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ColoredBox(color: NX.line.withValues(alpha: .5)),
                          FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            // Scale so a few percent of a 16-thread PC shows.
                            widthFactor: (p.cpu / 25).clamp(0.0, 1.0),
                            child: ColoredBox(color: heat),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 52,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(
                  fmtPct(p.cpu),
                  style: TextStyle(
                    color: p.cpu < 1 ? NX.textFaint : heat,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    fontFeatures: NX.tabular,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 62,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(
                  formatBytes(p.memory),
                  style: const TextStyle(
                    color: NX.textDim,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    fontFeatures: NX.tabular,
                  ),
                ),
              ),
            ),
            if (onKill != null)
              IconButton(
                tooltip: 'End ${p.name}',
                onPressed: onKill,
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
          ],
        ),
      ),
    );
  }
}

/// Entry to the live full-desktop mirror (view + touch, or view only).
class DesktopEntryCard extends StatelessWidget {
  const DesktopEntryCard({super.key, required this.onOpen});
  final void Function(bool viewOnly) onOpen;

  @override
  Widget build(BuildContext context) => NxCard(
    onTap: () => onOpen(false),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(NX.radiusSm),
                gradient: LinearGradient(
                  colors: [
                    NX.accent.withValues(alpha: .28),
                    NX.accent2.withValues(alpha: .18),
                  ],
                ),
                border: Border.all(color: NX.accent.withValues(alpha: .4)),
              ),
              child: const Icon(
                Icons.desktop_windows_outlined,
                color: NX.accent,
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Your desktop',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                  Text(
                    'The PC screen, live. Tap to click, swipe to scroll, rotate for a bigger view.',
                    style: TextStyle(color: NX.textDim, fontSize: 12.5),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: () => onOpen(false),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.touch_app_outlined, size: 20),
              label: const Text('View desktop'),
            ),
            OutlinedButton.icon(
              onPressed: () => onOpen(true),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.visibility_outlined, size: 20),
              label: const Text('View only'),
            ),
          ],
        ),
      ],
    ),
  );
}
