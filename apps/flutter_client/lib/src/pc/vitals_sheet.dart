// Live detail sheet behind the hero gauges: history, per-thread load, clocks,
// temperatures, power vs cap, VRAM and memory breakdown.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../monitor/monitor_models.dart';
import '../monitor/monitor_provider.dart';
import '../theme/nexus_theme.dart';
import '../theme/nx_widgets.dart';
import 'pc_ui.dart';
import 'vitals_hero.dart';

Future<void> showVitalsSheet(BuildContext context, VitalsFocus focus) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => MonitorDemand(
      owner: 'pc-detail',
      intervalMs: 2000,
      child: VitalsSheet(initial: focus),
    ),
  );
}

class VitalsSheet extends ConsumerStatefulWidget {
  const VitalsSheet({super.key, required this.initial});
  final VitalsFocus initial;
  @override
  ConsumerState<VitalsSheet> createState() => _VitalsSheetState();
}

class _VitalsSheetState extends ConsumerState<VitalsSheet> {
  late VitalsFocus _focus = widget.initial;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(monitorProvider);
    final snapshot = state.snapshot;
    final history = state.history ?? MonitorHistory();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .8,
      minChildSize: .45,
      maxChildSize: .96,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(NX.pad, 0, NX.pad, 28),
        children: [
          SegmentedButton<VitalsFocus>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: VitalsFocus.cpu, label: Text('CPU')),
              ButtonSegment(value: VitalsFocus.gpu, label: Text('GPU')),
              ButtonSegment(value: VitalsFocus.ram, label: Text('Memory')),
            ],
            selected: {_focus},
            onSelectionChanged: (s) => setState(() => _focus = s.first),
          ),
          const SizedBox(height: 16),
          if (snapshot == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('Waiting for readings…')),
            )
          else
            ...switch (_focus) {
              VitalsFocus.cpu => _cpu(context, snapshot.vitals, history),
              VitalsFocus.gpu => _gpu(context, snapshot.vitals, history),
              VitalsFocus.ram => _ram(context, snapshot.vitals, history),
            },
        ],
      ),
    );
  }

  List<Widget> _cpu(BuildContext context, Vitals v, MonitorHistory h) {
    final busiest = v.perCore.isEmpty
        ? null
        : v.perCore.reduce((a, b) => a > b ? a : b);
    return [
      _Headline(
        value: fmtPct(v.cpu),
        color: NX.heat(v.cpu),
        title: shortCpuModel(v.cpuModel),
        subtitle: '${v.cores} threads · ${fmtGHz(v.cpuMHz)}',
      ),
      _ChartBlock(
        title: 'Load',
        value: fmtPct(v.cpu),
        color: NX.accent,
        values: h['cpu'],
        max: 100,
        unit: '%',
      ),
      if (h['cpuTemp'].isNotEmpty || v.cpuTempC != null)
        _ChartBlock(
          title: 'Temperature',
          value: fmtTemp(v.cpuTempC),
          color: NX.tempHeat(v.cpuTempC, warmAt: 70, hotAt: 90),
          values: h['cpuTemp'],
          unit: '°',
        ),
      if (v.perCore.isNotEmpty)
        _Block(
          title: 'Threads',
          trailing: busiest == null ? null : 'busiest ${fmtPct(busiest)}',
          child: Semantics(
            label:
                '${v.perCore.length} CPU threads, busiest at ${busiest?.round() ?? 0} percent',
            child: CoreBars(
              key: stillKey(context, v.perCore.join(',')),
              values: v.perCore,
              height: 56,
            ),
          ),
        ),
      _StatGrid([
        PcStat(label: 'CLOCK', value: fmtGHz(v.cpuMHz)),
        PcStat(
          label: 'LOAD AVERAGE',
          value: v.load.isEmpty
              ? '—'
              : v.load.map((l) => l.toStringAsFixed(2)).join(' · '),
        ),
        PcStat(label: 'PROCESSES', value: '${v.processCount}'),
        PcStat(label: 'UPTIME', value: formatUptime(v.uptimeSeconds)),
      ]),
    ];
  }

  List<Widget> _gpu(BuildContext context, Vitals v, MonitorHistory h) {
    final gpu = v.mainGpu;
    if (gpu == null) {
      return const [
        Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: Text('This PC doesn’t report GPU readings.')),
        ),
      ];
    }
    final powerPct = gpu.powerW != null && (gpu.powerCapW ?? 0) > 0
        ? gpu.powerW! / gpu.powerCapW! * 100
        : null;
    return [
      _Headline(
        value: gpu.busy == null ? '—' : fmtPct(gpu.busy!),
        color: NX.heat(gpu.busy ?? 0),
        title: shortGpuName(gpu.name),
        subtitle: gpu.coreMHz == null
            ? 'Graphics'
            : '${gpu.coreMHz!.round()} MHz core clock',
      ),
      _ChartBlock(
        title: 'Load',
        value: gpu.busy == null ? '—' : fmtPct(gpu.busy!),
        color: NX.accent2,
        values: h['gpu'],
        max: 100,
        unit: '%',
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: NX.gap),
        child: Row(
          children: [
            Expanded(
              child: _TempTile('Edge', gpu.tempC, warmAt: 70, hotAt: 90),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _TempTile('Hotspot', gpu.hotspotC, warmAt: 80, hotAt: 100),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _TempTile('Memory', gpu.memTempC, warmAt: 80, hotAt: 96),
            ),
          ],
        ),
      ),
      if (h['gpuTemp'].length >= 2)
        _ChartBlock(
          title: 'Hotspot temperature',
          value: fmtTemp(gpu.peakTempC),
          color: NX.tempHeat(gpu.peakTempC, warmAt: 80, hotAt: 100),
          values: h['gpuTemp'],
          unit: '°',
        ),
      if (gpu.powerW != null)
        _Block(
          title: 'Power',
          trailing: gpu.powerCapW == null
              ? null
              : 'cap ${fmtWatts(gpu.powerCapW)}',
          child: Column(
            children: [
              _Meter(
                key: stillKey(context, gpu.powerW),
                label: 'Draw',
                percent: powerPct ?? 0,
                value: gpu.powerCapW == null
                    ? fmtWatts(gpu.powerW)
                    : '${gpu.powerW!.round()}/${fmtWatts(gpu.powerCapW)}',
                color: NX.warm,
              ),
              if (h['gpuPower'].length >= 2) ...[
                const SizedBox(height: 10),
                Sparkline(values: h['gpuPower'], color: NX.warm, height: 44),
              ],
            ],
          ),
        ),
      if (gpu.vramPercent != null)
        _Block(
          title: 'Video memory',
          child: Column(
            children: [
              _Meter(
                key: stillKey(context, gpu.vramUsed),
                label: 'VRAM',
                percent: gpu.vramPercent!,
                value: fmtGBOf(gpu.vramUsed!, gpu.vramTotal!),
              ),
              if (h['vram'].length >= 2) ...[
                const SizedBox(height: 10),
                Sparkline(
                  values: h['vram'],
                  color: NX.done,
                  max: 100,
                  height: 36,
                ),
              ],
            ],
          ),
        ),
      _StatGrid([
        PcStat(
          label: 'FAN',
          value: gpu.fanRpm == null
              ? '—'
              : gpu.fanRpm == 0
              ? 'Stopped (quiet)'
              : '${gpu.fanRpm!.round()} RPM',
        ),
        PcStat(
          label: 'CORE CLOCK',
          value: gpu.coreMHz == null ? '—' : '${gpu.coreMHz!.round()} MHz',
        ),
        if (gpu.memBusy != null)
          PcStat(label: 'MEMORY BUS', value: fmtPct(gpu.memBusy!)),
      ]),
      for (final other in v.gpus.skip(1)) _OtherGpu(other),
    ];
  }

  List<Widget> _ram(BuildContext context, Vitals v, MonitorHistory h) {
    final top = v.top.map(TopProcess.new).toList()
      ..sort((a, b) => b.memory.compareTo(a.memory));
    final total = v.ramTotal <= 0 ? 1 : v.ramTotal;
    return [
      _Headline(
        value: fmtPct(v.ramPercent),
        color: NX.heat(v.ramPercent),
        title: '${fmtGB(v.ramUsed)} in use',
        subtitle:
            '${fmtGB(v.ramTotal - v.ramUsed)} free of ${fmtGB(v.ramTotal)}',
      ),
      _ChartBlock(
        title: 'Usage',
        value: fmtPct(v.ramPercent),
        color: NX.accent,
        values: h['ram'],
        max: 100,
        unit: '%',
      ),
      _Block(
        title: 'Breakdown',
        child: Column(
          children: [
            _Meter(
              key: stillKey(context, v.ramUsed),
              label: 'In use',
              percent: v.ramPercent,
              value: fmtGB(v.ramUsed),
            ),
            const SizedBox(height: 12),
            _Meter(
              key: stillKey(context, v.cachedBytes),
              label: 'Cache',
              percent: v.cachedBytes / total * 100,
              value: fmtGB(v.cachedBytes),
              color: NX.done,
            ),
            const SizedBox(height: 12),
            _Meter(
              key: stillKey(context, v.swapUsed),
              label: 'Swap',
              percent: v.swapTotal > 0 ? v.swapUsed / v.swapTotal * 100 : 0,
              value: v.swapTotal > 0
                  ? fmtGBOf(v.swapUsed, v.swapTotal)
                  : 'None',
              color: NX.accent2,
            ),
          ],
        ),
      ),
      if (top.isNotEmpty)
        _Block(
          title: 'Biggest processes',
          child: Column(
            children: [
              for (final p in top.take(5))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatBytes(p.memory),
                        style: const TextStyle(
                          color: NX.textDim,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          fontFeatures: NX.tabular,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
    ];
  }
}

class _Headline extends StatelessWidget {
  const _Headline({
    required this.value,
    required this.color,
    required this.title,
    required this.subtitle,
  });
  final String value;
  final Color color;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: NX.gap),
    child: Row(
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w900,
            color: color,
            fontFeatures: NX.tabular,
            letterSpacing: -1,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: NX.textDim, fontSize: 12.5),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Block extends StatelessWidget {
  const _Block({required this.title, required this.child, this.trailing});
  final String title;
  final String? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: NX.gap),
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: NX.surface2,
        borderRadius: BorderRadius.circular(NX.radiusSm),
        border: Border.all(color: NX.line.withValues(alpha: .7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Text(
                  title.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: NX.textFaint,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: Text(
                    trailing!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: NX.textDim,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFeatures: NX.tabular,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    ),
  );
}

/// History chart with current value and the window's low / average / peak.
class _ChartBlock extends StatelessWidget {
  const _ChartBlock({
    required this.title,
    required this.value,
    required this.color,
    required this.values,
    required this.unit,
    this.max,
  });
  final String title;
  final String value;
  final Color color;
  final List<double> values;
  final double? max;
  final String unit;

  @override
  Widget build(BuildContext context) {
    String f(double x) => '${x.round()}$unit';
    final hasData = values.length >= 2;
    final lo = hasData ? values.reduce((a, b) => a < b ? a : b) : 0.0;
    final hi = hasData ? values.reduce((a, b) => a > b ? a : b) : 0.0;
    final avg = hasData ? values.reduce((a, b) => a + b) / values.length : 0.0;
    return _Block(
      title: title,
      trailing: value,
      child: hasData
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  label:
                      '$title history: low ${f(lo)}, average ${f(avg)}, peak ${f(hi)}',
                  child: Sparkline(
                    values: values,
                    color: color,
                    max: max,
                    height: 64,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 14,
                  children: [
                    _mini('low', f(lo)),
                    _mini('avg', f(avg)),
                    _mini('peak', f(hi)),
                  ],
                ),
              ],
            )
          : const Text(
              'Collecting history…',
              style: TextStyle(color: NX.textFaint, fontSize: 12),
            ),
    );
  }

  Widget _mini(String label, String value) => Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: '$label ',
          style: const TextStyle(color: NX.textFaint),
        ),
        TextSpan(
          text: value,
          style: const TextStyle(
            color: NX.textDim,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
    style: const TextStyle(fontSize: 11.5, fontFeatures: NX.tabular),
  );
}

class _TempTile extends StatelessWidget {
  const _TempTile(
    this.label,
    this.celsius, {
    required this.warmAt,
    required this.hotAt,
  });
  final String label;
  final double? celsius;
  final double warmAt;
  final double hotAt;

  @override
  Widget build(BuildContext context) {
    final c = NX.tempHeat(celsius, warmAt: warmAt, hotAt: hotAt);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: c.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(NX.radiusSm),
        border: Border.all(color: c.withValues(alpha: .30)),
      ),
      child: PcStat(
        label: label.toUpperCase(),
        value: fmtTemp(celsius),
        color: c,
        icon: Icons.thermostat,
      ),
    );
  }
}

class _StatGrid extends StatelessWidget {
  const _StatGrid(this.stats);
  final List<Widget> stats;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: NX.gap),
    child: LayoutBuilder(
      builder: (context, c) {
        final w = (c.maxWidth - 12) / 2;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [for (final s in stats) SizedBox(width: w, child: s)],
        );
      },
    ),
  );
}

class _OtherGpu extends StatelessWidget {
  const _OtherGpu(this.gpu);
  final GpuVitals gpu;

  @override
  Widget build(BuildContext context) => _Block(
    title: gpu.integrated ? 'Integrated graphics' : 'Other GPU',
    trailing: shortGpuName(gpu.name),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatGrid([
          PcStat(
            label: 'LOAD',
            value: gpu.busy == null ? '—' : fmtPct(gpu.busy!),
          ),
          PcStat(
            label: 'TEMP',
            value: fmtTemp(gpu.peakTempC),
            color: NX.tempHeat(gpu.peakTempC),
          ),
          if (gpu.powerW != null)
            PcStat(label: 'POWER', value: fmtWatts(gpu.powerW)),
          if (gpu.coreMHz != null)
            PcStat(label: 'CLOCK', value: '${gpu.coreMHz!.round()} MHz'),
        ]),
        if (gpu.vramPercent != null)
          _Meter(
            label: 'VRAM',
            percent: gpu.vramPercent!,
            value: fmtGBOf(gpu.vramUsed!, gpu.vramTotal!),
          ),
      ],
    ),
  );
}

/// [MeterBar]'s label/value row can't shrink; cap its text growth at 1.3×
/// (values are kept compact) so it never overflows a narrow phone.
class _Meter extends StatelessWidget {
  const _Meter({
    super.key,
    required this.label,
    required this.percent,
    required this.value,
    this.color,
  });
  final String label;
  final double percent;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) => MediaQuery.withClampedTextScaling(
    maxScaleFactor: 1.3,
    child: MeterBar(label: label, percent: percent, value: value, color: color),
  );
}
