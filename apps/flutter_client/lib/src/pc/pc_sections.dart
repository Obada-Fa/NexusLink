// PC tab sections that read the live monitor state themselves, so the tab's
// app launcher doesn't rebuild on every vitals push.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../monitor/monitor_provider.dart';
import '../state/connection.dart';
import '../theme/nexus_theme.dart';
import '../theme/nx_widgets.dart';
import 'pc_actions.dart';
import 'pc_ui.dart';

const _sidePad = EdgeInsets.symmetric(horizontal: NX.pad);

enum ProcessSort { cpu, memory }

/// Busiest processes right now (from the vitals push), busiest first. Tap one
/// to inspect it. Ending a process is offered only when the host implements
/// `process.kill`, always behind a confirmation.
class TopProcessesSection extends ConsumerWidget {
  const TopProcessesSection({super.key, this.sort = ProcessSort.cpu});
  final ProcessSort sort;

  Future<void> _inspect(
    BuildContext context,
    WidgetRef ref,
    TopProcess p, {
    required bool canKill,
    required bool busiest,
  }) async {
    final end = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(NX.pad, 0, NX.pad, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                p.name,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                busiest
                    ? 'Process ${p.pid} · busiest right now'
                    : 'Process ${p.pid}',
                style: const TextStyle(color: NX.textDim, fontSize: 13),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: PcStat(label: 'CPU', value: fmtPct(p.cpu)),
                  ),
                  Expanded(
                    child: PcStat(label: 'MEMORY', value: fmtIec(p.memory)),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              if (canKill)
                OutlinedButton.icon(
                  onPressed: () => Navigator.pop(sheet, true),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    foregroundColor: NX.waiting,
                  ),
                  icon: const Icon(Icons.dangerous_outlined),
                  label: const Text('End process'),
                )
              else
                const Text(
                  'Update the PC host to end processes from the phone.',
                  style: TextStyle(color: NX.textFaint, fontSize: 12.5),
                ),
            ],
          ),
        ),
      ),
    );
    if (end == true && context.mounted) await _kill(context, ref, p);
  }

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
    final list = vitals.top.map(TopProcess.new).toList()
      ..sort(
        (a, b) => sort == ProcessSort.cpu
            ? b.cpu.compareTo(a.cpu)
            : b.memory.compareTo(a.memory),
      );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PcSectionHeader(
          sort == ProcessSort.cpu ? 'Busiest processes' : 'Biggest processes',
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
                for (final (i, p) in list.indexed)
                  _ProcessRow(
                    key: ValueKey('process-${p.pid}'),
                    process: p,
                    onTap: () => _inspect(
                      context,
                      ref,
                      p,
                      canKill: canKill,
                      busiest: i == 0 && sort == ProcessSort.cpu,
                    ),
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
  const _ProcessRow({
    super.key,
    required this.process,
    required this.onTap,
    required this.onKill,
  });
  final TopProcess process;
  final VoidCallback onTap;
  final VoidCallback? onKill;

  @override
  Widget build(BuildContext context) {
    final p = process;
    // Flat bars; amber only for a process worth ending.
    final heat = p.cpu >= 85 ? NX.waiting : NX.accent;
    return Semantics(
      container: true,
      label:
          '${p.name}, CPU ${p.cpu.round()} percent, memory ${fmtIec(p.memory)}',
      button: true,
      excludeSemantics: onKill == null,
      child: InkWell(
        onTap: onTap,
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
                    fmtIec(p.memory),
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
      ),
    );
  }
}
