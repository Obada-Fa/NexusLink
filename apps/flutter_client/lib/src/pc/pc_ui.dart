// Shared bits for the PC tab: formatting, reduced-motion helpers, small typed
// views over monitor JSON the shared models don't expose, and tiny widgets.

import 'package:flutter/material.dart';

import '../monitor/monitor_models.dart';
import '../theme/nexus_theme.dart';
import '../theme/nx_widgets.dart';

// ---------------------------------------------------------------------------
// Motion

bool reduceMotion(BuildContext context) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false;

Duration motion(BuildContext context, Duration duration) =>
    reduceMotion(context) ? Duration.zero : duration;

/// The design-system gauges/bars tween internally. Under reduced motion, key
/// them by value so every update mounts fresh (and therefore unanimated).
Key? stillKey(BuildContext context, Object? value) =>
    reduceMotion(context) ? ValueKey(value) : null;

// ---------------------------------------------------------------------------
// Formatting

String fmtTemp(double? c) => c == null ? '—' : '${c.round()}°C';

String fmtPct(double v) =>
    v > 0 && v < 10 ? '${v.toStringAsFixed(1)}%' : '${v.round()}%';

String fmtGHz(num mhz) =>
    mhz <= 0 ? '—' : '${(mhz / 1000).toStringAsFixed(2)} GHz';

String fmtGB(double bytes) {
  final gb = bytes / 1073741824;
  return gb >= 100 ? '${gb.round()} GB' : '${gb.toStringAsFixed(1)} GB';
}

/// "2.0/15.9 GB" — compact enough for a meter row on a narrow phone.
String fmtGBOf(double used, double total) {
  final full = fmtGB(total);
  final unit = full.substring(full.indexOf(' '));
  return '${fmtGB(used).replaceFirst(unit, '')}/$full';
}

String fmtWatts(double? w) => w == null ? '—' : '${w.round()} W';

String fmtAgo(DateTime at, [DateTime? now]) {
  final d = (now ?? DateTime.now()).difference(at);
  if (d.inSeconds < 45) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes.clamp(1, 59)} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

String fmtSince(DateTime start, [DateTime? now]) {
  final seconds = (now ?? DateTime.now()).difference(start).inSeconds;
  return seconds <= 0 ? 'just started' : formatUptime(seconds);
}

/// "AMD Ryzen 7 7800X3D 8-Core Processor" → "Ryzen 7 7800X3D".
String shortCpuModel(String model) => model
    .replaceAll(RegExp(r'^(AMD|Intel\(R\)|Intel)\s+', caseSensitive: false), '')
    .replaceAll(RegExp(r'\s+\d+-Core Processor$', caseSensitive: false), '')
    .replaceAll(RegExp(r'\s+(CPU|Processor)$'), '')
    .trim();

/// "AMD Radeon RX 9070 series" → "Radeon RX 9070".
String shortGpuName(String name) => name
    .replaceAll(RegExp(r'^(AMD|NVIDIA|Intel)\s+', caseSensitive: false), '')
    .replaceAll(RegExp(r'\s+series$', caseSensitive: false), '')
    .trim();

/// Interface name → what a person calls it.
String interfaceKind(String name) {
  if (name.startsWith('wl')) return 'Wi-Fi';
  if (name.startsWith('en') || name.startsWith('eth')) return 'Ethernet';
  if (name.startsWith('tailscale') || name.startsWith('wg')) return 'VPN';
  return name;
}

/// "/home/obada/projects/x" → "~/projects/x".
String shortPath(String path) =>
    path.replaceFirst(RegExp(r'^/home/[^/]+'), '~');

// ---------------------------------------------------------------------------
// Typed views the shared models don't expose (kept here so the shared model
// file stays untouched while other engineers edit it).

double _num(Object? v) => v is num ? v.toDouble() : 0;
double? _numOrNull(Object? v) => v is num ? v.toDouble() : null;
Map<String, dynamic> _map(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : const {};

extension PcVitals on Vitals {
  double get cachedBytes => _num(_map(json['memory'])['cachedBytes']);

  double? get rootUsedPercent {
    final free = rootFree, total = rootTotal;
    if (free == null || total == null || total <= 0) return null;
    return (1 - free / total) * 100;
  }

  /// Under 10 % free on / (this PC routinely sits around 92 % full).
  bool get diskLow {
    final used = rootUsedPercent;
    return used != null && used > 90;
  }

  /// The interface carrying the most traffic, else the first non-VPN one.
  Map<String, dynamic>? get primaryInterface {
    final list = interfaces.where((i) => i['vpn'] != true).toList();
    if (list.isEmpty) return null;
    list.sort(
      (a, b) => (_num(b['rxBps']) + _num(b['txBps'])).compareTo(
        _num(a['rxBps']) + _num(a['txBps']),
      ),
    );
    return list.first;
  }

  bool get vpnUp => interfaces.any((i) => i['vpn'] == true);
}

extension PcGpu on GpuVitals {
  double? get memBusy => _numOrNull(json['memBusyPercent']);

  /// Hottest reading, the one that throttles.
  double? get peakTempC => hotspotC ?? tempC;
}

extension PcAgentApp on AgentApp {
  bool get isStuck => state == 'stuck';
  bool can(String action) => actions.contains(action);
}

class TopProcess {
  TopProcess(Map<String, dynamic> json)
    : pid = _num(json['pid']).toInt(),
      name = json['name'] as String? ?? '?',
      cpu = _num(json['cpuPercent']),
      memory = _num(json['rssBytes']);
  final int pid;
  final String name;
  final double cpu;
  final double memory;
}

// ---------------------------------------------------------------------------
// Verdict: one glanceable line that says whether anything needs attention.

class PcVerdict {
  const PcVerdict(this.text, this.color, this.icon, {this.calm = false});
  final String text;
  final Color color;
  final IconData icon;
  final bool calm;
}

PcVerdict pcVerdict(MonitorSnapshot snapshot) {
  final v = snapshot.vitals;
  final gpu = v.mainGpu;
  final stuck = snapshot.apps.where((a) => a.isStuck).toList();
  if (stuck.isNotEmpty) {
    return PcVerdict(
      stuck.length == 1
          ? '${stuck.first.name} may be frozen — restart it below'
          : '${stuck.length} apps may be frozen',
      NX.stuck,
      Icons.ac_unit,
    );
  }
  if ((v.cpuTempC ?? 0) >= 88) {
    return PcVerdict(
      'CPU running hot · ${fmtTemp(v.cpuTempC)}',
      NX.hot,
      Icons.local_fire_department,
    );
  }
  if ((gpu?.peakTempC ?? 0) >= 95) {
    return PcVerdict(
      'GPU hotspot ${fmtTemp(gpu?.peakTempC)}',
      NX.hot,
      Icons.local_fire_department,
    );
  }
  if (v.cpu >= 85) {
    return PcVerdict('CPU flat out · ${fmtPct(v.cpu)}', NX.warm, Icons.speed);
  }
  if (v.ramPercent >= 90) {
    return PcVerdict(
      'Memory nearly full · ${fmtGB(v.ramTotal - v.ramUsed)} left',
      NX.warm,
      Icons.memory,
    );
  }
  if ((gpu?.busy ?? 0) >= 85) {
    return PcVerdict(
      'GPU working hard · ${fmtPct(gpu!.busy!)}',
      NX.warm,
      Icons.videogame_asset_outlined,
    );
  }
  if (v.diskLow) {
    return PcVerdict(
      'Disk almost full · ${fmtGB(v.rootFree ?? 0)} left',
      NX.waiting,
      Icons.sd_card_alert_outlined,
    );
  }
  final busy = snapshot.apps.where((a) => a.cpu >= 20).toList()
    ..sort((a, b) => b.cpu.compareTo(a.cpu));
  if (busy.isNotEmpty) {
    return PcVerdict(
      '${busy.first.name} is busy · ${fmtPct(busy.first.cpu)} CPU',
      NX.working,
      Icons.bolt,
    );
  }
  return const PcVerdict(
    'Running cool',
    NX.working,
    Icons.check_circle_outline,
    calm: true,
  );
}

// ---------------------------------------------------------------------------
// Small widgets

/// Label over a value, used in stat grids. Scales down instead of overflowing.
class PcStat extends StatelessWidget {
  const PcStat({
    super.key,
    required this.label,
    required this.value,
    this.color,
    this.icon,
  });
  final String label;
  final String value;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: NX.textFaint,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: .4,
        ),
      ),
      const SizedBox(height: 2),
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: color ?? NX.textDim),
              const SizedBox(width: 4),
            ],
            Text(
              value,
              style: TextStyle(
                color: color ?? NX.text,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                fontFeatures: NX.tabular,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

/// A wrapping chip row that never overflows (verdicts, notes).
class PcNote extends StatelessWidget {
  const PcNote(this.text, {super.key, required this.color, this.icon});
  final String text;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(NX.radiusSm),
      border: Border.all(color: color.withValues(alpha: .30)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 15, color: color),
          ),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Tiny coloured legend dot + label.
class PcLegend extends StatelessWidget {
  const PcLegend(this.label, {super.key, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 4),
      Text(
        label,
        style: const TextStyle(
          color: NX.textFaint,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    ],
  );
}

/// [NxSectionHeader] whose row can't shrink: drop the optional [trailing]
/// extra when the width (in text-scaled terms) has no room for it.
class PcSectionHeader extends StatelessWidget {
  const PcSectionHeader(
    this.title, {
    super.key,
    this.count,
    this.trailing,
    this.color,
  });
  final String title;
  final int? count;
  final Widget? trailing;
  final Color? color;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final scale = MediaQuery.textScalerOf(context).scale(10) / 10;
      final roomy = c.maxWidth / scale >= 340;
      return NxSectionHeader(
        title,
        count: count,
        color: color,
        trailing: roomy ? trailing : null,
      );
    },
  );
}
