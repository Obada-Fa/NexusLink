// System monitor: the detailed readings behind Desktop's compact rows.
//
// CPU and GPU stack their plots (load, then temperature, then power) on one
// time axis with matching plot edges, so a load spike and the temperature rise
// that follows line up vertically. Every number printed beside a chart comes
// from the same samples and window as the chart itself.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../monitor/monitor_models.dart';
import '../monitor/monitor_provider.dart';
import '../theme/nexus_theme.dart';
import '../theme/nx_widgets.dart';
import '../widgets/history_chart.dart';
import 'desktop_overview.dart' show DesktopStatusLine;
import 'pc_sections.dart';
import 'pc_ui.dart';

enum MonitorFocus { cpu, gpu, memory, io }

Future<void> openSystemMonitor(BuildContext context, MonitorFocus focus) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'system-monitor'),
        builder: (_) => SystemMonitorScreen(initial: focus),
      ),
    );

Future<void> openProcesses(
  BuildContext context, {
  ProcessSort sort = ProcessSort.cpu,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    settings: const RouteSettings(name: 'processes'),
    builder: (_) => ProcessesScreen(sort: sort),
  ),
);

const _window = MonitorHistory.window;

class SystemMonitorScreen extends StatelessWidget {
  const SystemMonitorScreen({super.key, this.initial = MonitorFocus.cpu});
  final MonitorFocus initial;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: MonitorFocus.values.length,
    initialIndex: initial.index,
    child: Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [Text('System monitor'), DesktopStatusLine()],
        ),
        bottom: const TabBar(
          key: ValueKey('monitor-tabs'),
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(text: 'CPU'),
            Tab(text: 'GPU'),
            Tab(text: 'Memory'),
            Tab(text: 'Network & disk'),
          ],
        ),
      ),
      body: const MonitorDemand(
        owner: 'pc-monitor',
        intervalMs: 2000,
        child: TabBarView(
          children: [
            _MonitorPage(MonitorFocus.cpu),
            _MonitorPage(MonitorFocus.gpu),
            _MonitorPage(MonitorFocus.memory),
            _MonitorPage(MonitorFocus.io),
          ],
        ),
      ),
    ),
  );
}

class _MonitorPage extends ConsumerWidget {
  const _MonitorPage(this.focus);
  final MonitorFocus focus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(monitorProvider);
    final snapshot = state.snapshot;
    final h = state.history ?? MonitorHistory();
    final children = snapshot == null
        ? [
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('Waiting for readings…')),
            ),
          ]
        : switch (focus) {
            MonitorFocus.cpu => _cpu(context, snapshot.vitals, h),
            MonitorFocus.gpu => _gpu(context, snapshot.vitals, h),
            MonitorFocus.memory => _memory(context, snapshot.vitals, h),
            MonitorFocus.io => _io(context, snapshot.vitals, h),
          };
    return ListView(
      key: PageStorageKey('monitor-${focus.name}'),
      padding: const EdgeInsets.fromLTRB(NX.pad, 16, NX.pad, 32),
      children: children,
    );
  }
}

// ---------------------------------------------------------------------------
// CPU

List<Widget> _cpu(BuildContext context, Vitals v, MonitorHistory h) {
  final load = h.samples('cpu');
  final temp = h.samples('cpuTemp');
  final end = latestTime([load, temp]);
  final gutter = chartGutter(context, base: 38);
  final threads = v.perCore;
  return [
    _Headline(
      title: shortCpuModel(v.cpuModel),
      subtitle: [
        if (v.cores > 0) '${v.cores} threads',
        if (v.cpuMHz > 0) fmtGHz(v.cpuMHz),
      ].join(' · '),
      value: fmtPct(v.cpu),
      semantics: 'CPU load ${v.cpu.round()} percent',
      action: _ProcessesButton(sort: ProcessSort.cpu),
    ),
    _PrimaryPlot(
      key: const ValueKey('cpu-load-chart'),
      samples: load,
      end: end,
      gutter: gutter,
      unit: '%',
      what: 'CPU load',
      timeLabels: temp.isEmpty && v.cpuTempC == null,
    ),
    if (temp.isNotEmpty || v.cpuTempC != null)
      _AlignedPlot(
        key: const ValueKey('cpu-temp-chart'),
        title: 'Temperature',
        reading: fmtTemp(v.cpuTempC),
        readingColor: (v.cpuTempC ?? 0) >= 88 ? NX.waiting : NX.text,
        samples: temp,
        end: end,
        gutter: gutter,
        unit: '°',
        statUnit: ' °C',
        fromZero: false,
        timeLabels: true,
      )
    else
      const _Unavailable('Temperature'),
    if (threads.isNotEmpty) _Threads(threads),
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

/// Per-thread load: muted bars with the busiest one highlighted.
class _Threads extends StatelessWidget {
  const _Threads(this.values);
  final List<double> values;

  @override
  Widget build(BuildContext context) {
    var busiest = 0;
    for (var i = 1; i < values.length; i++) {
      if (values[i] > values[busiest]) busiest = i;
    }
    return _Section(
      title: 'Threads',
      trailing: 'busiest #${busiest + 1} · ${fmtPct(values[busiest])}',
      child: Semantics(
        label:
            '${values.length} CPU threads, busiest is thread ${busiest + 1} '
            'at ${values[busiest].round()} percent',
        excludeSemantics: true,
        child: CustomPaint(
          size: const Size(double.infinity, 48),
          painter: ThreadBarsPainter(values, busiest),
        ),
      ),
    );
  }
}

@visibleForTesting
class ThreadBarsPainter extends CustomPainter {
  ThreadBarsPainter(this.values, this.busiest);
  final List<double> values;
  final int busiest;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    const gap = 3.0;
    final w = (size.width - gap * (values.length - 1)) / values.length;
    final track = Paint()..color = NX.line.withValues(alpha: .45);
    final muted = Paint()..color = NX.textFaint.withValues(alpha: .65);
    final hot = Paint()..color = NX.accent;
    for (var i = 0; i < values.length; i++) {
      final x = i * (w + gap);
      final r = Rect.fromLTWH(x, 0, w, size.height);
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(2)),
        track,
      );
      final bh = math.max(2.0, (values[i] / 100).clamp(0.0, 1.0) * size.height);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, size.height - bh, w, bh),
          const Radius.circular(2),
        ),
        i == busiest ? hot : muted,
      );
    }
  }

  @override
  bool shouldRepaint(ThreadBarsPainter old) =>
      old.values != values || old.busiest != busiest;
}

// ---------------------------------------------------------------------------
// GPU

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
  final load = h.samples('gpu');
  final temp = h.samples('gpuTemp');
  final power = h.samples('gpuPower');
  final end = latestTime([load, temp, power]);
  final gutter = chartGutter(context, base: 46);
  final hasTemp = temp.isNotEmpty || gpu.peakTempC != null;
  final hasPower = power.isNotEmpty || gpu.powerW != null;
  final cap = gpu.powerCapW;
  final otherTemps = [
    if (gpu.hotspotC != null && gpu.tempC != null) 'Edge ${fmtTemp(gpu.tempC)}',
    if (gpu.memTempC != null) 'Memory ${fmtTemp(gpu.memTempC)}',
  ].join(' · ');
  return [
    _Headline(
      title: shortGpuName(gpu.name),
      subtitle: gpu.coreMHz == null
          ? 'Graphics'
          : '${gpu.coreMHz!.round()} MHz core clock',
      value: gpu.busy == null ? '—' : fmtPct(gpu.busy!),
      semantics: gpu.busy == null
          ? 'GPU load not reported'
          : 'GPU load ${gpu.busy!.round()} percent',
    ),
    if (gpu.busy != null || load.isNotEmpty)
      _PrimaryPlot(
        key: const ValueKey('gpu-load-chart'),
        samples: load,
        end: end,
        gutter: gutter,
        unit: '%',
        what: 'GPU load',
        timeLabels: !hasTemp && !hasPower,
      )
    else
      const _Unavailable('Load'),
    if (hasTemp)
      _AlignedPlot(
        key: const ValueKey('gpu-temp-chart'),
        title: gpu.hotspotC != null ? 'Hotspot' : 'Temperature',
        reading: fmtTemp(gpu.peakTempC),
        readingColor: (gpu.peakTempC ?? 0) >= 95 ? NX.waiting : NX.text,
        note: otherTemps.isEmpty ? null : otherTemps,
        samples: temp,
        end: end,
        gutter: gutter,
        unit: '°',
        statUnit: ' °C',
        fromZero: false,
        timeLabels: !hasPower,
      )
    else
      const _Unavailable('Temperature'),
    if (hasPower)
      _AlignedPlot(
        key: const ValueKey('gpu-power-chart'),
        title: 'Power',
        reading: gpu.powerW == null
            ? '—'
            : cap == null || cap <= 0
            ? fmtWatts(gpu.powerW)
            : '${gpu.powerW!.round()} W of ${cap.round()} W',
        samples: power,
        end: end,
        gutter: gutter,
        max: cap != null && cap > 0 ? cap : null,
        unit: ' W',
        format: (v) => '${v.round()} W',
        statUnit: ' W',
        timeLabels: true,
      )
    else
      const _Unavailable('Power'),
    if (gpu.vramPercent != null)
      _Section(
        title: 'Video memory',
        child: _Meter(
          key: stillKey(context, gpu.vramUsed),
          label: 'Used · ${gpu.vramPercent!.round()}%',
          percent: gpu.vramPercent!,
          value: '${fmtGB(gpu.vramUsed!)} of ${fmtGB(gpu.vramTotal!)}',
        ),
      )
    else
      const _Unavailable('Video memory'),
    _StatGrid([
      PcStat(
        label: 'FAN',
        value: gpu.fanRpm == null
            ? 'Unavailable'
            : gpu.fanRpm == 0
            ? 'Stopped (quiet)'
            : '${gpu.fanRpm!.round()} RPM',
      ),
      PcStat(
        label: 'CORE CLOCK',
        value: gpu.coreMHz == null
            ? 'Unavailable'
            : '${gpu.coreMHz!.round()} MHz',
      ),
      if (gpu.memBusy != null)
        PcStat(label: 'MEMORY BUS', value: fmtPct(gpu.memBusy!)),
    ]),
    for (final other in v.gpus.skip(1)) _OtherGpu(other),
  ];
}

class _OtherGpu extends StatelessWidget {
  const _OtherGpu(this.gpu);
  final GpuVitals gpu;

  @override
  Widget build(BuildContext context) => _Section(
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
            color: (gpu.peakTempC ?? 0) >= 95 ? NX.waiting : NX.text,
          ),
          if (gpu.powerW != null)
            PcStat(label: 'POWER', value: fmtWatts(gpu.powerW)),
          if (gpu.coreMHz != null)
            PcStat(label: 'CLOCK', value: '${gpu.coreMHz!.round()} MHz'),
        ]),
        if (gpu.vramPercent != null)
          _Meter(
            label: 'VRAM used · ${gpu.vramPercent!.round()}%',
            percent: gpu.vramPercent!,
            value: '${fmtGB(gpu.vramUsed!)} of ${fmtGB(gpu.vramTotal!)}',
          ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Memory

List<Widget> _memory(BuildContext context, Vitals v, MonitorHistory h) {
  final top = v.top.map(TopProcess.new).toList()
    ..sort((a, b) => b.memory.compareTo(a.memory));
  final total = v.ramTotal <= 0 ? 1.0 : v.ramTotal;
  final usage = h.samples('ram');
  return [
    _Headline(
      title: v.ramTotal > 0
          ? '${fmtGiBOf(v.ramUsed, v.ramTotal)} in use'
          : 'Memory',
      subtitle: v.ramTotal > 0
          ? '${fmtIec(v.ramTotal - v.ramUsed)} free'
          : 'Size not reported',
      value: fmtPct(v.ramPercent),
      valueColor: v.ramPercent >= 90 ? NX.waiting : NX.text,
      semantics: 'Memory ${v.ramPercent.round()} percent in use',
      action: _ProcessesButton(sort: ProcessSort.memory),
    ),
    _PrimaryPlot(
      key: const ValueKey('ram-chart'),
      samples: usage,
      end: latestTime([usage]),
      gutter: chartGutter(context, base: 38),
      unit: '%',
      what: 'Memory use',
      timeLabels: true,
    ),
    _Section(
      title: 'Breakdown',
      child: Column(
        children: [
          _Meter(
            key: stillKey(context, v.ramUsed),
            label: 'In use',
            percent: v.ramPercent,
            value: fmtIec(v.ramUsed),
          ),
          const SizedBox(height: 12),
          _Meter(
            key: stillKey(context, v.cachedBytes),
            label: 'Cache',
            percent: v.cachedBytes / total * 100,
            value: fmtIec(v.cachedBytes),
            color: NX.textDim,
          ),
          const SizedBox(height: 12),
          _Meter(
            key: stillKey(context, v.swapUsed),
            label: 'Swap',
            percent: v.swapTotal > 0 ? v.swapUsed / v.swapTotal * 100 : 0,
            value: v.swapTotal > 0
                ? '${fmtIec(v.swapUsed)} of ${fmtIec(v.swapTotal)}'
                : 'None',
            color: NX.textDim,
          ),
        ],
      ),
    ),
    if (top.isNotEmpty)
      _Section(
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
                      fmtIec(p.memory),
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

// ---------------------------------------------------------------------------
// Network and disk

/// A binary unit that keeps a rate chart's axis on round numbers.
({double size, String label}) _rateUnit(double peak) => peak >= 1048576
    ? (size: 1048576, label: 'MiB/s')
    : peak >= 1024
    ? (size: 1024, label: 'KiB/s')
    : (size: 1, label: 'B/s');

List<Sample> _scaled(List<Sample> s, double by) =>
    by == 1 ? s : [for (final x in s) Sample(x.t, x.v / by)];

List<Widget> _io(BuildContext context, Vitals v, MonitorHistory h) {
  final rx = h.samples('netRx'), tx = h.samples('netTx');
  final rd = h.samples('diskRead'), wr = h.samples('diskWrite');
  final iface = v.primaryInterface;
  final netCaption = [
    if (iface != null) interfaceKind('${iface['name']}'),
    if (v.vpnUp) 'VPN on',
  ].join(' · ');
  final nvme = v.nvmeTempC;
  return [
    _FlowPlot(
      key: const ValueKey('net-chart'),
      first: true,
      title: 'Network',
      caption: netCaption.isEmpty ? null : netCaption,
      a: ('Download', fmtIecRate(v.netRx), rx),
      b: ('Upload', fmtIecRate(v.netTx), tx),
    ),
    _FlowPlot(
      key: const ValueKey('disk-chart'),
      title: 'Disk',
      caption: nvme == null ? null : 'NVMe ${fmtTemp(nvme)}',
      captionWarn: (nvme ?? 0) >= 70,
      a: ('Read', fmtIecRate(v.diskRead), rd),
      b: ('Write', fmtIecRate(v.diskWrite), wr),
    ),
    _Storage(v),
    if (v.batteries.isNotEmpty) _Batteries(v.batteries),
  ];
}

class _FlowPlot extends StatelessWidget {
  const _FlowPlot({
    super.key,
    required this.title,
    required this.a,
    required this.b,
    this.caption,
    this.captionWarn = false,
    this.first = false,
  });
  final bool first;
  final String title;
  final (String, String, List<Sample>) a;
  final (String, String, List<Sample>) b;
  final String? caption;
  final bool captionWarn;

  @override
  Widget build(BuildContext context) {
    final end = latestTime([a.$3, b.$3]);
    final sa = statsOf(a.$3, _window), sb = statsOf(b.$3, _window);
    final unit = _rateUnit(
      [sa?.peak ?? 0, sb?.peak ?? 0].reduce((x, y) => x > y ? x : y),
    );
    String axis(double v) => v == 0
        ? '0'
        : '${v == v.roundToDouble() ? v.round() : v.toStringAsFixed(1)} ${unit.label}';
    return _Section(
      first: first,
      title: title,
      trailing: caption,
      trailingColor: captionWarn ? NX.waiting : null,
      child: Semantics(
        label:
            '$title: ${a.$1} ${a.$2}, ${b.$1} ${b.$2}'
            '${sa == null ? '' : ', peak ${a.$1.toLowerCase()} ${fmtIecRate(sa.peak)}'}'
            '${sb == null ? '' : ', peak ${b.$1.toLowerCase()} ${fmtIecRate(sb.peak)}'}',
        excludeSemantics: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ChartLegend(
              entries: [
                (a.$1, a.$2, NX.accent, false),
                (b.$1, b.$2, NX.textDim, true),
              ],
            ),
            const SizedBox(height: 10),
            if (end == null)
              const _Collecting()
            else
              TimeChart(
                samples: _scaled(a.$3, unit.size),
                secondary: _scaled(b.$3, unit.size),
                end: end,
                format: axis,
                height: 120,
                timeLabels: true,
              ),
            if (sa != null && sb != null)
              _Stats(
                text:
                    'peak ${a.$1.toLowerCase()} ${fmtIecRate(sa.peak)} · '
                    '${b.$1.toLowerCase()} ${fmtIecRate(sb.peak)}',
              ),
          ],
        ),
      ),
    );
  }
}

class _Storage extends StatelessWidget {
  const _Storage(this.v);
  final Vitals v;

  @override
  Widget build(BuildContext context) {
    final used = v.rootUsedPercent;
    final free = v.rootFree;
    final color = v.diskLow ? NX.waiting : NX.accent;
    return _Section(
      title: 'Storage',
      trailing: v.diskLow ? 'Under 10 % free' : null,
      trailingColor: NX.waiting,
      child: used == null || free == null
          ? const Text(
              'Unavailable',
              style: TextStyle(color: NX.textFaint, fontSize: 13),
            )
          : Semantics(
              label:
                  'Storage ${used.round()} percent used, ${fmtGB(free)} free '
                  'of ${fmtGB(v.rootTotal ?? 0)}',
              excludeSemantics: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Meter(
                    key: const ValueKey('storage-used'),
                    label: 'Used',
                    percent: used,
                    value: '${used.round()}%',
                    color: color,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${fmtGB(free)} free of ${fmtGB(v.rootTotal ?? 0)}',
                    style: TextStyle(
                      color: v.diskLow ? NX.waiting : NX.textDim,
                      fontSize: 12.5,
                      fontFeatures: NX.tabular,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _Batteries extends StatelessWidget {
  const _Batteries(this.list);
  final List<Map<String, dynamic>> list;

  @override
  Widget build(BuildContext context) => _Section(
    title: list.length == 1 ? 'Battery' : 'Batteries',
    child: Column(
      children: [
        for (final b in list)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${b['name'] ?? 'Device'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                if (b['charging'] == true)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: Text(
                      'charging',
                      style: TextStyle(color: NX.textDim, fontSize: 12),
                    ),
                  ),
                Text(
                  '${(b['percent'] as num? ?? 0).round()}%',
                  style: TextStyle(
                    color: (b['percent'] as num? ?? 0) < 20
                        ? NX.waiting
                        : NX.text,
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
  );
}

// ---------------------------------------------------------------------------
// Building blocks

/// Hardware name and the current value, shown once above the primary plot.
class _Headline extends StatelessWidget {
  const _Headline({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.semantics,
    this.valueColor = NX.text,
    this.action,
  });
  final String title;
  final String subtitle;
  final String value;
  final Color valueColor;
  final String semantics;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: NX.textDim, fontSize: 12.5),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Semantics(
              label: semantics,
              excludeSemantics: true,
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: valueColor,
                  fontFeatures: NX.tabular,
                  letterSpacing: -.5,
                ),
              ),
            ),
          ],
        ),
        if (action != null)
          Padding(padding: const EdgeInsets.only(top: 6), child: action),
      ],
    ),
  );
}

class _ProcessesButton extends StatelessWidget {
  const _ProcessesButton({required this.sort});
  final ProcessSort sort;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    key: ValueKey('processes-${sort.name}'),
    onPressed: () => openProcesses(context, sort: sort),
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(48, 40),
      side: const BorderSide(color: NX.line),
    ),
    icon: const Icon(Icons.list_alt_rounded, size: 18),
    label: const Text('Processes'),
  );
}

/// The ~120 dp main chart with a light fill; its value is in the headline, so
/// it only adds the window's peak and average.
class _PrimaryPlot extends StatelessWidget {
  const _PrimaryPlot({
    super.key,
    required this.samples,
    required this.end,
    required this.gutter,
    required this.unit,
    required this.what,
    this.timeLabels = false,
  });
  final List<Sample> samples;
  final int? end;
  final double gutter;
  final String unit;
  final String what;
  final bool timeLabels;

  @override
  Widget build(BuildContext context) {
    final s = statsOf(samples, _window, end: end);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: s == null
          ? const _Collecting()
          : Semantics(
              label:
                  '$what history over ${_span(s)}: now ${s.latest.v.round()}$unit, '
                  'peak ${s.peak.round()}$unit, average ${s.average.round()}$unit',
              excludeSemantics: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TimeChart(
                    samples: samples,
                    end: end,
                    max: 100,
                    unit: unit,
                    fill: true,
                    gutter: gutter,
                    height: 120,
                    timeLabels: timeLabels,
                  ),
                  _Stats(
                    text:
                        'peak ${s.peak.round()}$unit · avg ${s.average.round()}$unit'
                        '${_shortWindow(s)}',
                  ),
                ],
              ),
            ),
    );
  }
}

/// A 76 dp chart aligned under the primary one (same edges and time axis).
class _AlignedPlot extends StatelessWidget {
  const _AlignedPlot({
    super.key,
    required this.title,
    required this.reading,
    required this.samples,
    required this.end,
    required this.gutter,
    required this.unit,
    required this.statUnit,
    this.readingColor = NX.text,
    this.note,
    this.max,
    this.fromZero = true,
    this.timeLabels = false,
    this.format,
  });
  final String Function(double)? format;
  final String title;
  final String reading;
  final Color readingColor;
  final String? note;
  final List<Sample> samples;
  final int? end;
  final double gutter;
  final String unit;
  final String statUnit;
  final double? max;
  final bool fromZero;
  final bool timeLabels;

  @override
  Widget build(BuildContext context) {
    final s = statsOf(samples, _window, end: end);
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Semantics(
        label:
            '$title $reading'
            '${s == null ? '' : ', peak ${s.peak.round()}$statUnit'}',
        excludeSemantics: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.end,
              children: [
                Text(
                  title.toUpperCase(),
                  style: const TextStyle(
                    color: NX.textFaint,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                  ),
                ),
                Text(
                  reading,
                  style: TextStyle(
                    color: readingColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    fontFeatures: NX.tabular,
                  ),
                ),
                if (s != null)
                  Text(
                    'peak ${s.peak.round()}$statUnit',
                    style: const TextStyle(
                      color: NX.textDim,
                      fontSize: 12,
                      fontFeatures: NX.tabular,
                    ),
                  ),
                if (note != null)
                  Text(
                    note!,
                    style: const TextStyle(color: NX.textDim, fontSize: 12),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            if (s == null)
              const _Collecting()
            else
              TimeChart(
                samples: samples,
                end: end,
                max: max,
                fromZero: fromZero,
                unit: unit,
                format: format,
                gutter: gutter,
                height: timeLabels ? 76 + chartLabelSize(context) + 6 : 76,
                timeLabels: timeLabels,
              ),
          ],
        ),
      ),
    );
  }
}

String _span(SeriesStats s) => s.span >= _window
    ? 'the last ${fmtElapsed(_window)}'
    : 'the last ${fmtElapsed(s.span)}';

String _shortWindow(SeriesStats s) =>
    s.span >= _window - const Duration(seconds: 10)
    ? ''
    : ' · last ${fmtElapsed(s.span)}';

class _Stats extends StatelessWidget {
  const _Stats({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Text(
      text,
      style: const TextStyle(
        color: NX.textDim,
        fontSize: 12,
        fontFeatures: NX.tabular,
      ),
    ),
  );
}

class _Collecting extends StatelessWidget {
  const _Collecting();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 12),
    child: Text(
      'Collecting history…',
      style: TextStyle(color: NX.textFaint, fontSize: 12.5),
    ),
  );
}

/// A sensor this PC doesn't report: a compact, explicit row.
class _Unavailable extends StatelessWidget {
  const _Unavailable(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Semantics(
      label: '$title not reported by this PC',
      excludeSemantics: true,
      child: Wrap(
        spacing: 10,
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              color: NX.textFaint,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
          const Text(
            'Unavailable on this PC',
            style: TextStyle(color: NX.textFaint, fontSize: 12.5),
          ),
        ],
      ),
    ),
  );
}

/// Open section with a hairline on top, not a boxed card.
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.child,
    this.trailing,
    this.trailingColor,
    this.first = false,
  });
  final String title;
  final String? trailing;
  final Color? trailingColor;
  final Widget child;

  /// The page's first section: no hairline above it.
  final bool first;

  @override
  Widget build(BuildContext context) => Container(
    margin: EdgeInsets.only(top: first ? 0 : 14),
    padding: EdgeInsets.only(top: first ? 0 : 14, bottom: 4),
    decoration: first
        ? null
        : const BoxDecoration(
            border: Border(top: BorderSide(color: NX.line)),
          ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 2,
          alignment: WrapAlignment.spaceBetween,
          children: [
            Text(
              title.toUpperCase(),
              style: const TextStyle(
                color: NX.textFaint,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
              ),
            ),
            if (trailing != null)
              Text(
                trailing!,
                style: TextStyle(
                  color: trailingColor ?? NX.textDim,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFeatures: NX.tabular,
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        child,
      ],
    ),
  );
}

class _StatGrid extends StatelessWidget {
  const _StatGrid(this.stats);
  final List<Widget> stats;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 18),
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

/// [MeterBar]'s label/value row can't shrink; cap its text growth at 1.3×
/// so it never overflows a narrow phone.
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
    child: MeterBar(
      label: label,
      percent: percent,
      value: value,
      color: color ?? (percent >= 90 ? NX.waiting : NX.accent),
      flat: true,
    ),
  );
}

// ---------------------------------------------------------------------------
// Processes

class ProcessesScreen extends StatelessWidget {
  const ProcessesScreen({super.key, this.sort = ProcessSort.cpu});
  final ProcessSort sort;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        sort == ProcessSort.cpu ? 'Processes by CPU' : 'Processes by memory',
      ),
    ),
    body: MonitorDemand(
      owner: 'pc-processes',
      intervalMs: 2000,
      child: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 32),
        children: [TopProcessesSection(sort: sort)],
      ),
    ),
  );
}
