// Per-logical-CPU activity from the host's timestamped cpu.perCore samples.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../monitor/monitor_models.dart';
import '../monitor/monitor_provider.dart';
import '../theme/nexus_theme.dart';
import '../widgets/history_chart.dart';
import 'pc_ui.dart';

const _threadColors = [
  Color(0xff72ccff),
  Color(0xffdd9cfc),
  Color(0xff68d6bf),
  Color(0xffffb889),
  Color(0xffa7a4ff),
  Color(0xff8be0e3),
  Color(0xffe791bb),
  Color(0xffc0df80),
  Color(0xff7aa1ec),
  Color(0xffe4bcde),
  Color(0xff65b7a3),
  Color(0xffe8d891),
  Color(0xff9abde1),
  Color(0xffab86d9),
  Color(0xff99d1a6),
  Color(0xfffa9e95),
];
Color _color(int index) => _threadColors[index % _threadColors.length];

/// Use a short time axis while the phone collects its first few readings.
Duration cpuHistoryWindow(MonitorHistory history) {
  final samples = history.samples('cpu');
  final span = samples.isEmpty ? 0 : samples.last.t - samples.first.t;
  if (span < 15000) return const Duration(seconds: 15);
  if (span < 60000) return const Duration(minutes: 1);
  return MonitorHistory.window;
}

class CpuActivity extends StatefulWidget {
  const CpuActivity({
    super.key,
    required this.vitals,
    required this.history,
    required this.live,
    this.onOpen,
  });
  final Vitals vitals;
  final MonitorHistory history;
  final bool live;

  /// The compact Desktop panel opens the full CPU page from its header.
  final VoidCallback? onOpen;

  @override
  State<CpuActivity> createState() => _CpuActivityState();
}

class _CpuActivityState extends State<CpuActivity> {
  int? _selected;
  bool _showThreads = false;

  @override
  Widget build(BuildContext context) {
    final v = widget.vitals, history = widget.history;
    final currents = v.perCore;
    final compact = widget.onOpen != null;
    final selected = _selected != null && _selected! < currents.length
        ? _selected
        : null;
    final total = history.samples('cpu');
    final threads = [
      for (var i = 0; i < currents.length; i++) history.samples('cpuThread:$i'),
    ];
    final end = latestTime([total, history.samples('cpuTemp'), ...threads]);
    final samples = selected == null ? total : threads[selected];
    final traceName = selected == null ? 'Total' : 'CPU $selected';
    final ink = selected == null ? NX.text : _color(selected);
    final showGrid = !compact || _showThreads;
    final current = selected == null ? v.cpu : currents[selected];
    final model = shortCpuModel(v.cpuModel);
    final window = cpuHistoryWindow(history);
    final stats = statsOf(samples, window, end: end);
    final at = ChartInspection.timeOf(context);
    String threadValue(int i) {
      if (at == null) return fmtPct(currents[i]);
      final sample = nearestReading(threads[i], at);
      return sample == null ? '—' : fmtPct(sample.v);
    }

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label:
              'CPU ${v.cpu.round()} percent, ${v.cpuTempC?.round() ?? 'unknown'} degrees, $model',
          button: compact,
          excludeSemantics: true,
          child: InkWell(
            onTap: widget.onOpen,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: compact ? 12 : 3),
              child: Row(
                children: [
                  const Icon(Icons.memory_rounded, color: NX.accent, size: 22),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      compact ? 'CPU activity' : model,
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -.5,
                      ),
                    ),
                  ),
                  if (compact)
                    const Icon(
                      Icons.chevron_right,
                      size: 22,
                      color: NX.textDim,
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 5),
        Wrap(
          spacing: 12,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              fmtPct(v.cpu),
              style: const TextStyle(
                fontSize: 40,
                height: 1.08,
                fontWeight: FontWeight.w600,
                letterSpacing: -1.5,
                fontFeatures: NX.tabular,
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (compact)
                  Text(
                    model,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                Wrap(
                  spacing: 8,
                  children: [
                    Text(
                      widget.live ? 'Total load' : 'Last reading',
                      style: const TextStyle(color: NX.textDim, fontSize: 12),
                    ),
                    Text(
                      fmtTemp(v.cpuTempC),
                      style: const TextStyle(color: NX.textDim, fontSize: 12),
                    ),
                    if (v.cpuMHz > 0)
                      Text(
                        '${(v.cpuMHz / 1000).toStringAsFixed(1)} GHz',
                        style: const TextStyle(color: NX.textDim, fontSize: 12),
                      ),
                  ],
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 6),
        Semantics(
          key: const ValueKey('cpu-load-chart'),
          label:
              'CPU load history, $traceName, current ${current.round()} percent'
              '${stats == null ? '' : ', peak ${stats.peak.round()}%'}',
          child: GestureDetector(
            onTap: widget.onOpen,
            behavior: HitTestBehavior.opaque,
            child: TimeChart(
              samples: samples,
              window: window,
              end: end,
              max: 100,
              unit: '%',
              gutter: chartGutter(context, base: 38),
              height: compact ? 116 : 166,
              timeLabels: true,
              markPeak: !compact,
              color: ink,
              backgroundTraces: [
                for (var i = 0; i < threads.length; i++)
                  if (i != selected)
                    (
                      threads[i],
                      _color(i).withValues(alpha: selected == null ? .70 : .23),
                    ),
              ],
            ),
          ),
        ),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 15, height: 2, color: ink),
                const SizedBox(width: 6),
                Text(traceName, style: const TextStyle(fontSize: 13)),
                if (selected != null)
                  Text('  ${fmtPct(current)}', style: TextStyle(color: ink)),
              ],
            ),
            if (currents.isNotEmpty && compact)
              TextButton.icon(
                key: const ValueKey('toggle-cpu-threads'),
                onPressed: () => setState(() => _showThreads = !_showThreads),
                icon: Icon(
                  showGrid ? Icons.expand_less : Icons.grid_view_rounded,
                  size: 15,
                ),
                label: Text('${currents.length} threads'),
              )
            else if (currents.isNotEmpty)
              Text(
                '${currents.length} logical CPUs',
                style: const TextStyle(color: NX.textDim, fontSize: 13),
              ),
          ],
        ),
        if (showGrid && currents.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: LayoutBuilder(
              builder: (context, box) {
                final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
                final columns = (box.maxWidth / (82 * scale)).floor().clamp(
                  1,
                  4,
                );
                const gap = 6.0;
                final width = (box.maxWidth - gap * (columns - 1)) / columns;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (var i = 0; i < currents.length; i++)
                      SizedBox(
                        width: width,
                        child: Semantics(
                          button: true,
                          selected: selected == i,
                          label: 'CPU $i, ${currents[i].round()} percent',
                          excludeSemantics: true,
                          child: Material(
                            color: selected == i
                                ? _color(i).withValues(alpha: .18)
                                : NX.surface2,
                            borderRadius: BorderRadius.circular(6),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              key: ValueKey('cpu-thread-$i'),
                              onTap: () => setState(
                                () => _selected = selected == i ? null : i,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(7, 6, 7, 5),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Wrap(
                                      alignment: WrapAlignment.spaceBetween,
                                      spacing: 2,
                                      children: [
                                        Text(
                                          'CPU $i',
                                          style: TextStyle(
                                            color: _color(i),
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        Text(
                                          threadValue(i),
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontFeatures: NX.tabular,
                                          ),
                                        ),
                                      ],
                                    ),
                                    TimeChart(
                                      samples: threads[i],
                                      window: window,
                                      end: end,
                                      max: 100,
                                      axis: false,
                                      color: _color(i),
                                      height: math.max(27, 30 * scale),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
      ],
    );
    if (!compact) return content;
    return Container(
      margin: const EdgeInsets.fromLTRB(NX.pad, 2, NX.pad, 10),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      decoration: BoxDecoration(
        color: NX.surface,
        border: Border.all(color: NX.line),
        borderRadius: BorderRadius.circular(16),
      ),
      child: content,
    );
  }
}
