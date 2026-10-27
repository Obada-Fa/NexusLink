// PC tab hero: who/what/how-long, a one-line verdict, and three heat-glow ring
// gauges (CPU, GPU, RAM). The arc is load; the halo is temperature.

import 'package:flutter/material.dart';

import '../monitor/monitor_models.dart';
import '../monitor/monitor_provider.dart';
import '../rpc/rpc_client.dart';
import '../theme/nexus_theme.dart';
import '../theme/nx_widgets.dart';
import 'pc_ui.dart';

enum VitalsFocus { cpu, gpu, ram }

class VitalsHero extends StatelessWidget {
  const VitalsHero({
    super.key,
    required this.snapshot,
    required this.history,
    required this.status,
    required this.onOpen,
  });

  final MonitorSnapshot snapshot;
  final MonitorHistory history;
  final RpcStatus status;
  final void Function(VitalsFocus focus) onOpen;

  @override
  Widget build(BuildContext context) {
    final v = snapshot.vitals;
    final gpu = v.mainGpu;
    final verdict = pcVerdict(snapshot);
    final connected = status == RpcStatus.connected;
    final stale =
        !connected ||
        DateTime.now().difference(snapshot.at) > const Duration(seconds: 15);
    final statusColor = switch (status) {
      RpcStatus.connected => stale ? NX.waiting : NX.working,
      RpcStatus.connecting => NX.waiting,
      RpcStatus.disconnected => NX.failed,
    };
    final subtitle = [
      'Up ${formatUptime(v.uptimeSeconds)}',
      shortCpuModel(v.cpuModel),
      if (gpu != null) shortGpuName(gpu.name),
    ].join(' · ');
    final note = !connected
        ? PcVerdict(
            status == RpcStatus.connecting
                ? 'Reconnecting… showing the last readings'
                : 'PC offline · showing the last readings',
            NX.idle,
            Icons.cloud_off_outlined,
          )
        : stale
        ? PcVerdict(
            'Waiting for fresh readings · last ${fmtAgo(snapshot.at)}',
            NX.idle,
            Icons.hourglass_empty,
          )
        : verdict;

    return NxCard(
      accent: note.calm || note.color == NX.idle ? null : note.color,
      padding: const EdgeInsets.fromLTRB(NX.pad, 14, NX.pad, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Semantics(
                label: connected
                    ? 'Connected'
                    : status == RpcStatus.connecting
                    ? 'Reconnecting'
                    : 'Offline',
                child: LiveDot(color: statusColor, pulse: connected && !stale),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      v.hostname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -.2,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: NX.textDim,
                        fontSize: 12,
                        fontFeatures: NX.tabular,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Semantics(
            liveRegion: true,
            child: PcNote(note.text, color: note.color, icon: note.icon),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _HeroGauge(
                  label: 'CPU',
                  value: v.cpu,
                  caption: v.cpuTempC == null ? null : fmtTemp(v.cpuTempC),
                  glow: v.cpuTempC == null
                      ? NX.heat(v.cpu)
                      : NX.tempHeat(v.cpuTempC, warmAt: 70, hotAt: 90),
                  heat: _tempFactor(v.cpuTempC, 45, 90),
                  footnote: fmtGHz(v.cpuMHz),
                  semantics:
                      'CPU ${v.cpu.round()} percent'
                      '${v.cpuTempC == null ? '' : ', ${v.cpuTempC!.round()} degrees'}'
                      ', ${fmtGHz(v.cpuMHz)}',
                  onTap: () => onOpen(VitalsFocus.cpu),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _HeroGauge(
                  label: 'GPU',
                  value: gpu?.busy,
                  caption: gpu?.peakTempC == null
                      ? null
                      : fmtTemp(gpu!.peakTempC),
                  glow: gpu?.peakTempC == null
                      ? NX.heat(gpu?.busy ?? 0)
                      : NX.tempHeat(gpu!.peakTempC, warmAt: 75, hotAt: 100),
                  heat: _tempFactor(gpu?.peakTempC, 50, 100),
                  footnote: gpu == null
                      ? 'No GPU data'
                      : [
                          if (gpu.powerW != null) fmtWatts(gpu.powerW),
                          if (gpu.vramPercent != null)
                            'VRAM ${gpu.vramPercent!.round()}%',
                        ].join(' · '),
                  semantics: gpu == null
                      ? 'GPU, no data'
                      : 'GPU ${(gpu.busy ?? 0).round()} percent'
                            '${gpu.peakTempC == null ? '' : ', hotspot ${gpu.peakTempC!.round()} degrees'}'
                            '${gpu.powerW == null ? '' : ', ${gpu.powerW!.round()} watts'}',
                  onTap: () => onOpen(VitalsFocus.gpu),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _HeroGauge(
                  label: 'RAM',
                  value: v.ramPercent,
                  caption: fmtGB(v.ramUsed),
                  glow: NX.heat(v.ramPercent),
                  heat: 0,
                  footnote: 'of ${fmtGB(v.ramTotal)}',
                  semantics:
                      'Memory ${v.ramPercent.round()} percent, '
                      '${fmtGB(v.ramUsed)} of ${fmtGB(v.ramTotal)}',
                  onTap: () => onOpen(VitalsFocus.ram),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _Pulse(history: history, onTap: () => onOpen(VitalsFocus.cpu)),
        ],
      ),
    );
  }

  static double _tempFactor(double? c, double from, double to) =>
      c == null ? 0 : ((c - from) / (to - from)).clamp(0.0, 1.0);
}

class _HeroGauge extends StatelessWidget {
  const _HeroGauge({
    required this.label,
    required this.value,
    required this.caption,
    required this.glow,
    required this.heat,
    required this.footnote,
    required this.semantics,
    required this.onTap,
  });

  final String label;
  final double? value;
  final String? caption;
  final Color glow;

  /// 0-1 temperature intensity; the halo brightens with load OR heat.
  final double heat;
  final String footnote;
  final String semantics;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final load = ((value ?? 0) / 100).clamp(0.0, 1.0);
    final intensity = load > heat ? load : heat;
    return Semantics(
      button: true,
      label: '$semantics. Opens details',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(NX.radiusSm),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: LayoutBuilder(
            builder: (context, c) {
              final size = (c.maxWidth - 4).clamp(56.0, 112.0);
              return Column(
                children: [
                  RepaintBoundary(
                    child: SizedBox.square(
                      dimension: size,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          AnimatedContainer(
                            duration: motion(
                              context,
                              const Duration(milliseconds: 700),
                            ),
                            curve: Curves.easeOutCubic,
                            width: size * .78,
                            height: size * .78,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  glow.withValues(alpha: .05 + .16 * intensity),
                                  glow.withValues(alpha: 0),
                                ],
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: glow.withValues(
                                    alpha: .06 + .30 * intensity,
                                  ),
                                  blurRadius: size * .32,
                                  spreadRadius: size * .02,
                                ),
                              ],
                            ),
                          ),
                          // The ring is a graphic: its text stays legible at
                          // any scale, the semantics label carries the values.
                          MediaQuery.withClampedTextScaling(
                            maxScaleFactor: 1.15,
                            child: RingGauge(
                              key: stillKey(context, value?.round()),
                              value: value,
                              label: label,
                              caption: caption,
                              size: size,
                              stroke: (size * .085).clamp(6.0, 10.0),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    width: double.infinity,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        footnote,
                        maxLines: 1,
                        style: const TextStyle(
                          color: NX.textDim,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          fontFeatures: NX.tabular,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Pulse extends StatelessWidget {
  const _Pulse({required this.history, required this.onTap});
  final MonitorHistory history;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cpu = history['cpu'];
    final gpu = history['gpu'];
    if (cpu.length < 2) return const SizedBox.shrink();
    return Semantics(
      button: true,
      label: 'CPU and GPU load history. Opens CPU details',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(NX.radiusSm),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Wrap(
                spacing: 12,
                children: [
                  PcLegend('CPU', color: NX.accent),
                  PcLegend('GPU', color: NX.accent2),
                ],
              ),
              const SizedBox(height: 6),
              RepaintBoundary(
                child: Sparkline(
                  values: cpu,
                  secondary: gpu.length >= 2 ? gpu : null,
                  color: NX.accent,
                  secondaryColor: NX.accent2,
                  max: 100,
                  height: 38,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
