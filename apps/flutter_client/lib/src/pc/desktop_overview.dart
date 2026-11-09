// Desktop home: the PC's live readings as an aligned, flat table with tiny
// unlabeled histories. Each reading opens the system monitor. Reads the
// monitor snapshot itself so the rest of Desktop does not rebuild on every
// push.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../monitor/monitor_models.dart';
import '../monitor/monitor_provider.dart';
import '../rpc/rpc_client.dart';
import '../state/connection.dart';
import '../theme/nexus_theme.dart';
import '../widgets/history_chart.dart';
import '../workspace/metrics.dart';
import 'pc_ui.dart';
import 'system_monitor.dart';

// ---------------------------------------------------------------------------
// Formatting

String fmtCelsius(double? c) => fmtTemp(c);

String fmtClock(num mhz) =>
    mhz <= 0 ? '—' : '${(mhz / 1000).toStringAsFixed(1)} GHz';

String fmtLoad(double? pct) => pct == null ? '—' : '${pct.round()}%';

/// Readings use monospace digits so updates never shift the columns.
const readingStyle = TextStyle(
  fontFamily: 'monospace',
  fontFeatures: NX.tabular,
  fontSize: 13.5,
  color: NX.text,
);

/// Warning colour only where the user can act (close something, cool the PC).
Color _warnIf(bool condition) => condition ? NX.waiting : NX.text;

// ---------------------------------------------------------------------------
// Header status line

/// "Connected · up 5h 56m", "Disconnected · updated 3 min ago", …
class DesktopStatusLine extends ConsumerStatefulWidget {
  const DesktopStatusLine({super.key});

  @override
  ConsumerState<DesktopStatusLine> createState() => _DesktopStatusLineState();
}

class _DesktopStatusLineState extends ConsumerState<DesktopStatusLine> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(connectionStatusProvider);
    final snapshot = ref.watch(monitorProvider.select((s) => s.snapshot));
    final text = switch (status) {
      RpcStatus.connected =>
        snapshot == null
            ? 'Connected'
            : 'Connected · up ${formatUptime(snapshot.vitals.uptimeSeconds)}',
      RpcStatus.connecting =>
        snapshot == null
            ? 'Connecting…'
            : 'Reconnecting · updated ${fmtAgo(snapshot.at)}',
      RpcStatus.disconnected =>
        snapshot == null
            ? 'Disconnected'
            : 'Disconnected · updated ${fmtAgo(snapshot.at)}',
    };
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13,
        color: status == RpcStatus.connected ? NX.textDim : NX.waiting,
      ),
    );
  }
}

/// The PC's name for the header: the host's own name once it reports one.
String desktopTitle(WidgetRef ref) {
  final name = ref.watch(
    monitorProvider.select((s) => s.snapshot?.vitals.hostname),
  );
  if (name != null && name.isNotEmpty) return name;
  final host = Uri.tryParse(ref.watch(connectionProvider).hostUrl ?? '')?.host;
  return host == null || host.isEmpty ? 'PC' : host;
}

// ---------------------------------------------------------------------------
// Readings table

class _Reading {
  const _Reading({
    required this.label,
    required this.cells,
    required this.semantics,
    this.primary = true,
    this.history = const [],
    this.historyMax,
    this.historySecondary = const [],
    this.onTap,
  });
  final String label;

  /// First cell is the headline value when [primary]; the rest are secondary.
  final List<(String, Color)> cells;
  final bool primary;
  final List<Sample> history;

  /// Null scales to the window's own peak (rates).
  final double? historyMax;

  /// Rates: the quieter direction, folded into the same bars by peak.
  final List<Sample> historySecondary;
  final String semantics;
  final VoidCallback? onTap;
}

/// Live CPU / GPU / memory / network / disk readings (hosts with monitor.v1).
class DesktopReadings extends ConsumerWidget {
  const DesktopReadings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(monitorProvider);
    final snapshot = state.snapshot;
    final live = ref.watch(connectionStatusProvider) == RpcStatus.connected;
    if (snapshot == null) {
      return _ReadingsTable(
        live: live,
        rows: [
          for (final label in const ['CPU', 'GPU', 'Memory'])
            _Reading(
              label: label,
              cells: const [('—', NX.textDim)],
              semantics: '$label, waiting for readings',
            ),
        ],
        footnote: state.error == null
            ? (live ? 'Reading the PC…' : 'Waiting for the PC to connect…')
            : 'Could not read the PC. Pull down to retry.',
      );
    }
    final v = snapshot.vitals;
    final h = state.history ?? MonitorHistory();
    final gpu = v.mainGpu;
    // The hottest sensor, the same one the monitor charts.
    final gpuTemp = gpu?.peakTempC;
    void open(MonitorFocus f) => openSystemMonitor(context, f);
    final rows = <_Reading>[
      _Reading(
        label: 'CPU',
        cells: [
          (fmtLoad(v.cpu), NX.text),
          (fmtCelsius(v.cpuTempC), _warnIf((v.cpuTempC ?? 0) >= 88)),
          (fmtClock(v.cpuMHz), NX.text),
        ],
        history: h.samples('cpu'),
        historyMax: 100,
        semantics:
            'CPU ${v.cpu.round()} percent, '
            '${v.cpuTempC == null ? 'temperature not reported' : '${v.cpuTempC!.round()} degrees'}, '
            '${fmtClock(v.cpuMHz)}',
        onTap: () => open(MonitorFocus.cpu),
      ),
      _Reading(
        label: 'GPU',
        cells: gpu == null
            ? const [('—', NX.textDim), ('not reported', NX.textDim)]
            : [
                (fmtLoad(gpu.busy), NX.text),
                (fmtCelsius(gpuTemp), _warnIf((gpuTemp ?? 0) >= 95)),
                (fmtWatts(gpu.powerW), NX.text),
              ],
        history: h.samples('gpu'),
        historyMax: 100,
        semantics: gpu == null
            ? 'GPU, not reported by this PC'
            : 'GPU ${gpu.busy == null ? 'load not reported' : '${gpu.busy!.round()} percent'}, '
                  '${gpuTemp == null ? 'temperature not reported' : '${gpuTemp.round()} degrees'}, '
                  '${gpu.powerW == null ? 'power not reported' : '${gpu.powerW!.round()} watts'}',
        onTap: () => open(MonitorFocus.gpu),
      ),
      _Reading(
        label: 'Memory',
        cells: [
          (fmtLoad(v.ramPercent), _warnIf(v.ramPercent >= 90)),
          (v.ramTotal > 0 ? fmtGiBOf(v.ramUsed, v.ramTotal) : '—', NX.text),
        ],
        history: h.samples('ram'),
        historyMax: 100,
        semantics:
            'Memory ${v.ramPercent.round()} percent, '
            '${v.ramTotal > 0 ? fmtGiBOf(v.ramUsed, v.ramTotal) : 'size not reported'}',
        onTap: () => open(MonitorFocus.memory),
      ),
      _Reading(
        label: 'Network',
        primary: false,
        cells: [
          ('↓ ${fmtIecRate(v.netRx)}', NX.text),
          ('↑ ${fmtIecRate(v.netTx)}', NX.text),
        ],
        history: h.samples('netRx'),
        historySecondary: h.samples('netTx'),
        semantics:
            'Network, down ${fmtIecRate(v.netRx)}, up ${fmtIecRate(v.netTx)}',
        onTap: () => open(MonitorFocus.io),
      ),
      _Reading(
        label: 'Disk',
        primary: false,
        cells: [
          ('R  ${fmtIecRate(v.diskRead)}', NX.text),
          ('W  ${fmtIecRate(v.diskWrite)}', NX.text),
        ],
        semantics:
            'Disk, read ${fmtIecRate(v.diskRead)}, write ${fmtIecRate(v.diskWrite)}'
            '${v.diskLow ? ', drive nearly full' : ''}',
        history: h.samples('diskRead'),
        historySecondary: h.samples('diskWrite'),
        onTap: () => open(MonitorFocus.io),
      ),
    ];
    return _ReadingsTable(
      live: live,
      rows: rows,
      dividerAfter: 3,
      footnote: v.diskLow
          ? 'Drive under 10 % free. Tap Disk for details.'
          : null,
      footnoteWarn: v.diskLow,
    );
  }
}

/// Readings from the older perf-update push, for hosts without monitor.v1.
class LegacyDesktopReadings extends ConsumerWidget {
  const LegacyDesktopReadings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(metricsProvider);
    final live = ref.watch(connectionStatusProvider) == RpcStatus.connected;
    double? n(String key) =>
        data?[key] is num ? (data![key] as num).toDouble() : null;
    final cpu = n('cpuPercent');
    final ram = n('ramPercent');
    final ramGb = n('ramUsedGb');
    final free = n('diskFreeBytes');
    return _ReadingsTable(
      live: live,
      rows: [
        _Reading(
          label: 'CPU',
          cells: [(fmtLoad(cpu), NX.text)],
          semantics: cpu == null
              ? 'CPU, waiting for readings'
              : 'CPU ${cpu.round()} percent',
        ),
        _Reading(
          label: 'Memory',
          cells: [
            (fmtLoad(ram), _warnIf((ram ?? 0) >= 90)),
            if (ramGb != null) ('${ramGb.toStringAsFixed(1)} GB used', NX.text),
          ],
          semantics: ram == null
              ? 'Memory, waiting for readings'
              : 'Memory ${ram.round()} percent',
        ),
        if (free != null)
          _Reading(
            label: 'Disk',
            primary: false,
            cells: [('${fmtIec(free)} free', NX.text)],
            semantics: 'Disk, ${fmtIec(free)} free',
          ),
      ],
      footnote:
          'Update NexusLink on the PC for GPU, temperatures, network and '
          'per-metric details.',
    );
  }
}

class _ReadingsTable extends StatelessWidget {
  const _ReadingsTable({
    required this.rows,
    required this.live,
    this.dividerAfter,
    this.footnote,
    this.footnoteWarn = false,
  });
  final List<_Reading> rows;
  final bool live;
  final int? dividerAfter;
  final String? footnote;
  final bool footnoteWarn;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return LayoutBuilder(
      builder: (context, c) {
        // Columns need ~300 dp at normal text; below that, secondary
        // readings wrap under their metric. History lines only when roomy.
        final wide = c.maxWidth >= 300 * scale;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              _ReadingRow(reading: rows[i], wide: wide, live: live),
              if (dividerAfter == i + 1)
                const Divider(height: 1, thickness: 1, color: NX.line),
            ],
            if (footnote != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(NX.pad, 6, NX.pad, 0),
                child: Text(
                  footnote!,
                  style: TextStyle(
                    color: footnoteWarn ? NX.waiting : NX.textFaint,
                    fontSize: 12.5,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ReadingRow extends StatelessWidget {
  const _ReadingRow({
    required this.reading,
    required this.wide,

    required this.live,
  });
  final _Reading reading;
  final bool wide;

  final bool live;

  @override
  Widget build(BuildContext context) {
    final r = reading;
    final label = Text(
      r.label,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    );
    final details = r.primary ? r.cells.skip(1) : const <(String, Color)>[];
    final numbers = r.primary ? r.cells.take(1) : r.cells;
    final description = Wrap(
      spacing: 7,
      children: [
        for (final cell in details)
          Text(
            cell.$1,
            style: TextStyle(
              fontSize: 12,
              color: live && cell.$2 != NX.text ? cell.$2 : NX.textDim,
              fontFeatures: NX.tabular,
            ),
          ),
      ],
    );
    final values = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final cell in numbers)
          Text(
            cell.$1,
            textAlign: TextAlign.end,
            style: TextStyle(
              fontSize: r.primary ? 23 : 13,
              fontFamily: r.primary ? null : 'monospace',
              fontWeight: FontWeight.w600,
              fontFeatures: NX.tabular,
              color: live ? cell.$2 : NX.textDim,
            ),
          ),
      ],
    );
    final trace = TimeChart(
      samples: r.history,
      secondary: r.historySecondary.isEmpty ? null : r.historySecondary,
      max: r.historyMax,
      height: 29,
      axis: false,
      color: live ? NX.accent : NX.textDim,
    );
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(flex: 4, child: label),
            if (wide)
              Expanded(
                flex: 5,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: trace,
                ),
              ),
            Flexible(
              flex: r.primary ? 3 : 6,
              child: Align(alignment: Alignment.centerRight, child: values),
            ),
          ],
        ),
        if (details.isNotEmpty) description,
        if (!wide && r.history.isNotEmpty) trace,
      ],
    );
    return Semantics(
      button: r.onTap != null,
      label: r.semantics,
      hint: r.onTap == null ? null : 'Opens details',
      excludeSemantics: true,
      child: InkWell(
        onTap: r.onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: NX.pad,
              vertical: 8,
            ),
            child: Align(alignment: Alignment.centerLeft, child: body),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

/// Per-timestamp sum of two rate series (download + upload), for one row of
/// bars. A single series passes through.
List<Sample> combinedRate(List<Sample> a, List<Sample> b) {
  if (b.isEmpty) return a;
  if (a.isEmpty) return b;
  final byTime = <int, double>{for (final s in b) s.t: s.v};
  return [for (final s in a) Sample(s.t, s.v + (byTime[s.t] ?? 0))];
}
