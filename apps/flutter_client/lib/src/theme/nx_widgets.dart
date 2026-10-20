import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'nexus_theme.dart';

/// Rounded surface card; [accent] adds a tinted border + soft glow for live items.
class NxCard extends StatelessWidget {
  const NxCard({
    super.key,
    required this.child,
    this.accent,
    this.onTap,
    this.onLongPress,
    this.padding = const EdgeInsets.all(NX.pad),
    this.color,
  });
  final Widget child;
  final Color? accent;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsetsGeometry padding;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final border = accent?.withValues(alpha: .45) ?? NX.line.withValues(alpha: .7);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? NX.surface2,
        borderRadius: BorderRadius.circular(NX.radius),
        border: Border.all(color: border),
        boxShadow: accent == null
            ? null
            : [BoxShadow(color: accent!.withValues(alpha: .12), blurRadius: 24, spreadRadius: -4)],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(NX.radius),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

class NxSectionHeader extends StatelessWidget {
  const NxSectionHeader(this.title, {super.key, this.count, this.trailing, this.color});
  final String title;
  final int? count;
  final Widget? trailing;
  final Color? color;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(NX.pad, 20, NX.pad, 8),
    child: Row(
      children: [
        Flexible(
          child: Text(
            title.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color ?? NX.textFaint,
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
            ),
          ),
        ),
        if (count != null) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(
              color: (color ?? NX.textFaint).withValues(alpha: .16),
              borderRadius: BorderRadius.circular(99),
            ),
            child: Text('$count', style: TextStyle(color: color ?? NX.textDim, fontSize: 11, fontWeight: FontWeight.w700)),
          ),
        ],
        const Spacer(),
        if (trailing != null) Flexible(child: trailing!),
      ],
    ),
  );
}

/// A softly pulsing dot; static when [pulse] is false or animations are disabled.
class LiveDot extends StatefulWidget {
  const LiveDot({super.key, required this.color, this.size = 8, this.pulse = true});
  final Color color;
  final double size;
  final bool pulse;
  @override
  State<LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<LiveDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
  bool _reduce = false;
  void _sync() {
    final run = widget.pulse && !_reduce;
    if (run && !_c.isAnimating) _c.repeat();
    if (!run && _c.isAnimating) _c.stop();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(LiveDot old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return SizedBox.square(
      dimension: widget.size * 2.2,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) {
          final t = widget.pulse && !reduce ? _c.value : 0.0;
          return Stack(
            alignment: Alignment.center,
            children: [
              if (t > 0)
                Container(
                  width: widget.size * (1 + t * 1.2),
                  height: widget.size * (1 + t * 1.2),
                  decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color.withValues(alpha: (1 - t) * .45)),
                ),
              Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
              ),
            ],
          );
        },
      ),
    );
  }
}

class NxPill extends StatelessWidget {
  const NxPill(this.label, {super.key, required this.color, this.live = false, this.icon, this.dense = false});
  final String label;
  final Color color;
  final bool live;
  final IconData? icon;
  final bool dense;
  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(horizontal: dense ? 7 : 9, vertical: dense ? 2 : 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .13),
      borderRadius: BorderRadius.circular(99),
      border: Border.all(color: color.withValues(alpha: .32)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (live) LiveDot(color: color, size: 6) else if (icon != null) Icon(icon, size: dense ? 11 : 13, color: color),
        if (live || icon != null) const SizedBox(width: 4),
        Flexible(
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontSize: dense ? 10.5 : 11.5, fontWeight: FontWeight.w700)),
        ),
      ],
    ),
  );
}

/// Circular provider badge with the provider's colour and initial.
class ProviderBadge extends StatelessWidget {
  const ProviderBadge(this.provider, {super.key, this.size = 28});
  final String provider;
  final double size;
  @override
  Widget build(BuildContext context) {
    final c = Providers.color(provider);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [c.withValues(alpha: .35), c.withValues(alpha: .12)]),
        border: Border.all(color: c.withValues(alpha: .6)),
      ),
      child: Text(
        Providers.initial(provider),
        style: TextStyle(color: c, fontWeight: FontWeight.w900, fontSize: size * .44),
      ),
    );
  }
}

/// Animated arc gauge (0-100) with a centre value.
class RingGauge extends StatelessWidget {
  const RingGauge({
    super.key,
    required this.value,
    required this.label,
    this.caption,
    this.size = 84,
    this.color,
    this.stroke = 8,
  });
  final double? value;
  final String label;
  final String? caption;
  final double size;
  final Color? color;
  final double stroke;
  @override
  Widget build(BuildContext context) {
    final v = (value ?? 0).clamp(0, 100).toDouble();
    final c = color ?? NX.heat(v);
    return SizedBox.square(
      dimension: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: v),
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeOutCubic,
        builder: (_, animated, _) => CustomPaint(
          painter: _RingPainter(animated / 100, c, stroke),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value == null ? '—' : '${animated.round()}%',
                  style: TextStyle(
                    fontSize: size * .22,
                    fontWeight: FontWeight.w800,
                    color: NX.text,
                    fontFeatures: NX.tabular,
                  ),
                ),
                Text(label, style: TextStyle(fontSize: size * .12, color: NX.textDim, fontWeight: FontWeight.w600)),
                if (caption != null)
                  Text(caption!, style: TextStyle(fontSize: size * .105, color: NX.textFaint, fontFeatures: NX.tabular)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.t, this.color, this.stroke);
  final double t;
  final Color color;
  final double stroke;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final arc = rect.deflate(stroke / 2 + 1);
    const start = math.pi * .75;
    const sweep = math.pi * 1.5;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = NX.line.withValues(alpha: .8);
    canvas.drawArc(arc, start, sweep, false, track);
    if (t <= 0) return;
    final fill = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: start,
        endAngle: start + sweep,
        colors: [color.withValues(alpha: .55), color],
        transform: const GradientRotation(0),
      ).createShader(arc);
    canvas.drawArc(arc, start, sweep * t, false, fill);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.t != t || old.color != color;
}

/// Smooth line chart with a gradient fill. [max] null → auto-scale.
class Sparkline extends StatelessWidget {
  const Sparkline({super.key, required this.values, required this.color, this.max, this.height = 44, this.secondary, this.secondaryColor});
  final List<double> values;
  final List<double>? secondary;
  final Color color;
  final Color? secondaryColor;
  final double? max;
  final double height;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    width: double.infinity,
    child: CustomPaint(painter: _SparkPainter(values, color, max, secondary, secondaryColor)),
  );
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values, this.color, this.max, this.secondary, this.secondaryColor);
  final List<double> values;
  final List<double>? secondary;
  final Color color;
  final Color? secondaryColor;
  final double? max;
  @override
  void paint(Canvas canvas, Size size) {
    final top = max ??
        [...values, ...?secondary].fold<double>(1, (a, b) => b > a ? b : a) * 1.15;
    void draw(List<double> list, Color c, bool fill) {
      if (list.length < 2) return;
      final dx = size.width / (list.length - 1);
      final path = Path();
      for (var i = 0; i < list.length; i++) {
        final x = i * dx;
        final y = size.height - (list[i] / top).clamp(0, 1) * (size.height - 2) - 1;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          final px = (i - 1) * dx;
          final py = size.height - (list[i - 1] / top).clamp(0, 1) * (size.height - 2) - 1;
          path.cubicTo(px + dx / 2, py, x - dx / 2, y, x, y);
        }
      }
      if (fill) {
        final area = Path.from(path)
          ..lineTo(size.width, size.height)
          ..lineTo(0, size.height)
          ..close();
        canvas.drawPath(
          area,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [c.withValues(alpha: .30), c.withValues(alpha: 0)],
            ).createShader(Offset.zero & size),
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..color = c,
      );
    }

    if (secondary != null) draw(secondary!, secondaryColor ?? NX.accent2, false);
    draw(values, color, true);
  }

  @override
  bool shouldRepaint(_SparkPainter old) => true;
}

/// One thin bar per CPU thread, heat-coloured.
class CoreBars extends StatelessWidget {
  const CoreBars({super.key, required this.values, this.height = 34});
  final List<double> values;
  final double height;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final v in values)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.2),
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: NX.line.withValues(alpha: .5),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  AnimatedFractionallySizedBox(
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeOut,
                    heightFactor: (v / 100).clamp(.04, 1),
                    child: Container(
                      decoration: BoxDecoration(
                        color: NX.heat(v),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

/// Horizontal meter with label + value.
class MeterBar extends StatelessWidget {
  const MeterBar({super.key, required this.label, required this.percent, required this.value, this.color});
  final String label;
  final double percent;
  final String value;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final c = color ?? NX.heat(percent);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: NX.textDim, fontSize: 12, fontWeight: FontWeight.w600))),
            const SizedBox(width: 8),
            Flexible(child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.end, style: const TextStyle(color: NX.text, fontSize: 12, fontWeight: FontWeight.w700, fontFeatures: NX.tabular))),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: Stack(
            children: [
              Container(height: 6, color: NX.line.withValues(alpha: .6)),
              AnimatedFractionallySizedBox(
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeOutCubic,
                widthFactor: (percent / 100).clamp(0, 1),
                child: Container(height: 6, decoration: BoxDecoration(gradient: LinearGradient(colors: [c.withValues(alpha: .6), c]))),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
