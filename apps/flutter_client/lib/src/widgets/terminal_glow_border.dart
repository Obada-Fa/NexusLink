import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Wraps [child] with a sweeping arc that traces the rounded rectangle
/// border when [active] is true.
class TerminalGlowBorder extends StatefulWidget {
  final Widget child;
  final bool active;
  final BorderRadius borderRadius;
  final Color glowColor;
  final double strokeWidth;

  const TerminalGlowBorder({
    super.key,
    required this.child,
    required this.active,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.glowColor = Colors.white,
    this.strokeWidth = 2.0,
  });

  @override
  State<TerminalGlowBorder> createState() => _TerminalGlowBorderState();
}

class _TerminalGlowBorderState extends State<TerminalGlowBorder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(TerminalGlowBorder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller
        ..stop()
        ..reset();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => CustomPaint(
        foregroundPainter: widget.active
            ? _RoundedRectOrbitPainter(
                progress: _controller.value,
                color: widget.glowColor,
                borderRadius: widget.borderRadius,
                strokeWidth: widget.strokeWidth,
              )
            : null,
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// Paints a sweeping arc + bright dot that travels around a rounded-rectangle
/// border.
class _RoundedRectOrbitPainter extends CustomPainter {
  final double progress; // 0..1 -> one full circuit
  final Color color;
  final BorderRadius borderRadius;
  final double strokeWidth;

  _RoundedRectOrbitPainter({
    required this.progress,
    required this.color,
    required this.borderRadius,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final rect = Rect.fromLTWH(
      strokeWidth / 2,
      strokeWidth / 2,
      math.max(0, size.width - strokeWidth),
      math.max(0, size.height - strokeWidth),
    );
    final rRect = borderRadius.toRRect(rect);

    // Faint full ambient outline
    canvas.drawRRect(
      rRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * 0.6
        ..color = color.withValues(alpha: 0.2),
    );

    // Extract path metrics from the RRect
    final path = Path()..addRRect(rRect);
    final metricsIterator = path.computeMetrics().iterator;
    if (!metricsIterator.moveNext()) return;
    final metric = metricsIterator.current;
    final total = metric.length;
    if (total <= 0) return;

    final arcLen = total * 0.28; // ~28% of perimeter
    final start = (progress * total) % total;
    final end = start + arcLen;

    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = color;

    if (end <= total) {
      final extract = metric.extractPath(start, end);
      canvas.drawPath(extract, arcPaint);
    } else {
      canvas.drawPath(metric.extractPath(start, total), arcPaint);
      canvas.drawPath(metric.extractPath(0, end - total), arcPaint);
    }

    // Bright glowing tip dot at the leading edge
    final tipPos = metric.getTangentForOffset(end % total)?.position;
    if (tipPos != null) {
      canvas.drawCircle(
        tipPos,
        strokeWidth + 0.8,
        Paint()..color = Colors.white,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RoundedRectOrbitPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.borderRadius != borderRadius ||
      old.strokeWidth != strokeWidth;
}
