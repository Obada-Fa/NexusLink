// What's flowing through the PC right now: network and disk rates with tiny
// sparklines, free space (warns under 10 %), NVMe temperature, and batteries
// of wireless peripherals.

import 'package:flutter/material.dart';

import '../monitor/monitor_models.dart';
import '../monitor/monitor_provider.dart';
import '../theme/nexus_theme.dart';
import '../theme/nx_widgets.dart';
import 'pc_ui.dart';

class FlowStrip extends StatelessWidget {
  const FlowStrip({super.key, required this.vitals, required this.history});
  final Vitals vitals;
  final MonitorHistory history;

  @override
  Widget build(BuildContext context) {
    final v = vitals;
    final tiles = <Widget>[
      _network(v),
      _disk(v),
      _storage(v),
      v.batteries.isNotEmpty ? _batteries(v) : _load(v),
    ];
    Widget pair(Widget a, Widget b) => IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: a),
          const SizedBox(width: 10),
          Expanded(child: b),
        ],
      ),
    );
    return Column(
      children: [
        pair(tiles[0], tiles[1]),
        const SizedBox(height: 10),
        pair(tiles[2], tiles[3]),
      ],
    );
  }

  Widget _network(Vitals v) {
    final iface = v.primaryInterface;
    final caption = [
      if (iface != null) interfaceKind('${iface['name']}'),
      if (v.vpnUp) 'VPN on',
    ].join(' · ');
    return _Tile(
      title: 'Network',
      icon: Icons.swap_vert_rounded,
      color: NX.accent,
      semantics:
          'Network: download ${formatRate(v.netRx)}, upload ${formatRate(v.netTx)}',
      lines: [
        _RateLine(Icons.south_rounded, formatRate(v.netRx), NX.accent),
        _RateLine(Icons.north_rounded, formatRate(v.netTx), NX.accent2),
      ],
      chart: _spark(history['netRx'], history['netTx'], NX.accent, NX.accent2),
      caption: caption.isEmpty ? null : caption,
    );
  }

  Widget _disk(Vitals v) {
    final nvme = v.nvmeTempC;
    return _Tile(
      title: 'Disk I/O',
      icon: Icons.sync_alt_rounded,
      color: NX.done,
      semantics:
          'Disk: reading ${formatRate(v.diskRead)}, writing ${formatRate(v.diskWrite)}'
          '${nvme == null ? '' : ', NVMe ${nvme.round()} degrees'}',
      lines: [
        _RateLine(
          Icons.file_download_outlined,
          formatRate(v.diskRead),
          NX.done,
        ),
        _RateLine(Icons.file_upload_outlined, formatRate(v.diskWrite), NX.warm),
      ],
      chart: _spark(
        history['diskRead'],
        history['diskWrite'],
        NX.done,
        NX.warm,
      ),
      caption: nvme == null ? null : 'NVMe ${fmtTemp(nvme)}',
      captionColor: nvme == null
          ? null
          : NX.tempHeat(nvme, warmAt: 55, hotAt: 70),
    );
  }

  Widget _storage(Vitals v) {
    final used = v.rootUsedPercent;
    final free = v.rootFree;
    final critical = used != null && used > 95;
    final color = critical
        ? NX.failed
        : v.diskLow
        ? NX.waiting
        : NX.working;
    return _Tile(
      title: 'Storage',
      icon: v.diskLow
          ? Icons.sd_card_alert_outlined
          : Icons.sd_storage_outlined,
      color: color,
      badge: v.diskLow ? 'LOW' : null,
      semantics: free == null
          ? 'Storage: unknown'
          : 'Storage: ${fmtGB(free)} free of ${fmtGB(v.rootTotal ?? 0)}'
                '${v.diskLow ? '. Warning, less than 10 percent free' : ''}',
      lines: [
        _BigValue(
          free == null ? '—' : '${fmtGB(free)} free',
          v.diskLow ? color : NX.text,
        ),
      ],
      chart: used == null
          ? null
          : Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: _Bar(percent: used, color: color),
            ),
      caption: used == null
          ? null
          : v.diskLow
          ? 'Under 10 % free — clean up soon'
          : '${used.round()}% of ${fmtGB(v.rootTotal ?? 0)} used',
      captionColor: v.diskLow ? color : null,
    );
  }

  Widget _batteries(Vitals v) {
    final list = v.batteries;
    return _Tile(
      title: list.length == 1 ? 'Battery' : 'Batteries',
      icon: Icons.headphones_rounded,
      color: NX.working,
      semantics: list
          .map(
            (b) =>
                '${b['name']} ${(b['percent'] as num? ?? 0).round()} percent'
                '${b['charging'] == true ? ', charging' : ''}',
          )
          .join('. '),
      lines: [for (final b in list.take(3)) _BatteryLine(b)],
    );
  }

  Widget _load(Vitals v) => _Tile(
    title: 'System load',
    icon: Icons.speed_rounded,
    color: NX.accent2,
    semantics: 'System load ${v.load.join(', ')}',
    lines: [
      _BigValue(
        v.load.isEmpty
            ? '—'
            : v.load.map((l) => l.toStringAsFixed(2)).join(' '),
        NX.text,
      ),
    ],
    caption: '${v.processCount} processes',
  );

  static Widget? _spark(List<double> a, List<double> b, Color ca, Color cb) =>
      a.length < 2
      ? null
      : Padding(
          padding: const EdgeInsets.only(top: 6),
          child: RepaintBoundary(
            child: Sparkline(
              values: a,
              secondary: b.length >= 2 ? b : null,
              color: ca,
              secondaryColor: cb,
              height: 26,
            ),
          ),
        );
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.title,
    required this.icon,
    required this.color,
    required this.lines,
    required this.semantics,
    this.chart,
    this.caption,
    this.captionColor,
    this.badge,
  });
  final String title;
  final IconData icon;
  final Color color;
  final List<Widget> lines;
  final Widget? chart;
  final String? caption;
  final Color? captionColor;
  final String? badge;
  final String semantics;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: semantics,
    excludeSemantics: true,
    child: Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: NX.surface2,
        borderRadius: BorderRadius.circular(NX.radiusSm),
        border: Border.all(
          color: badge != null
              ? color.withValues(alpha: .5)
              : NX.line.withValues(alpha: .7),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: NX.textFaint,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
              ),
              if (badge != null) NxPill(badge!, color: color, dense: true),
            ],
          ),
          const SizedBox(height: 6),
          ...lines,
          ?chart,
          const Spacer(),
          if (caption != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                caption!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: captionColor ?? NX.textFaint,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _RateLine extends StatelessWidget {
  const _RateLine(this.icon, this.text, this.color);
  final IconData icon;
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerLeft,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        Text(
          text,
          style: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            fontFeatures: NX.tabular,
          ),
        ),
      ],
    ),
  );
}

class _BigValue extends StatelessWidget {
  const _BigValue(this.text, this.color);
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerLeft,
    child: Text(
      text,
      style: TextStyle(
        color: color,
        fontSize: 17,
        fontWeight: FontWeight.w800,
        fontFeatures: NX.tabular,
      ),
    ),
  );
}

class _Bar extends StatelessWidget {
  const _Bar({required this.percent, required this.color});
  final double percent;
  final Color color;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(99),
    child: SizedBox(
      height: 6,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: NX.line.withValues(alpha: .6)),
          FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: (percent / 100).clamp(0.0, 1.0),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [color.withValues(alpha: .6), color],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _BatteryLine extends StatelessWidget {
  const _BatteryLine(this.battery);
  final Map<String, dynamic> battery;

  @override
  Widget build(BuildContext context) {
    final pct = (battery['percent'] as num? ?? 0).toDouble();
    final charging = battery['charging'] == true;
    final color = pct < 20
        ? NX.failed
        : pct < 40
        ? NX.waiting
        : NX.working;
    final icon = charging
        ? Icons.battery_charging_full_rounded
        : pct >= 90
        ? Icons.battery_full_rounded
        : pct >= 60
        ? Icons.battery_5_bar_rounded
        : pct >= 35
        ? Icons.battery_3_bar_rounded
        : pct >= 15
        ? Icons.battery_2_bar_rounded
        : Icons.battery_alert_rounded;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 4),
              Text(
                '${pct.round()}%',
                style: TextStyle(
                  color: color,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  fontFeatures: NX.tabular,
                ),
              ),
            ],
          ),
          Text(
            '${battery['name'] ?? 'Device'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: NX.textDim, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}
