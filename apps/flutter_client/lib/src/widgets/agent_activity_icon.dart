import 'dart:math' as math;

import 'package:flutter/material.dart';

IconData iconForAgent(String id) {
  return switch (id) {
    'claude' => Icons.auto_awesome,
    'cursor' => Icons.code,
    'opencode' => Icons.terminal,
    'antigravity' => Icons.rocket_launch_outlined,
    _ => Icons.smart_toy_outlined,
  };
}

/// Human source label for list subtitles. Unknown ids are title-cased.
String agentSourceLabel(String agentId, [String? source]) {
  final given = source?.trim() ?? '';
  if (given.isNotEmpty) return given;
  return switch (agentId) {
    'claude' => 'Claude Code',
    'cursor' => 'Cursor',
    'opencode' => 'OpenCode',
    'antigravity' => 'Antigravity',
    'mock' => 'Demo Agent',
    _ => _titleCaseAgent(agentId),
  };
}

String _titleCaseAgent(String id) {
  final raw = id.trim();
  if (raw.isEmpty) return 'Agent';
  return raw
      .replaceAll(RegExp(r'[_\s]+'), '-')
      .split('-')
      .where((w) => w.isNotEmpty)
      .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}

/// `OpenCode · /path` (and `view only` when the host chat cannot be resumed).
String chatListSubtitle({
  String agent = '',
  String? source,
  String cwd = '',
  bool resumable = true,
}) {
  return [
    agentSourceLabel(agent, source),
    if (cwd.trim().isNotEmpty) cwd.trim(),
    if (!resumable) 'view only',
  ].join(' · ');
}

/// Agent logo used in lists and chat. Pulses, color-cycles, and traces an
/// orbit while [active] is true.
class AgentActivityIcon extends StatefulWidget {
  const AgentActivityIcon({
    super.key,
    required this.agentId,
    this.active = false,
    this.size = 24,
    this.color = const Color(0xFF2A6AFF),
  });

  final String agentId;
  final bool active;
  final double size;
  final Color color;

  @override
  State<AgentActivityIcon> createState() => _AgentActivityIconState();
}

class _AgentActivityIconState extends State<AgentActivityIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(AgentActivityIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active) {
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
    if (!widget.active) {
      return Icon(
        iconForAgent(widget.agentId),
        size: widget.size,
        color: widget.color,
      );
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (_, __) {
        final t = _controller.value * 2 * math.pi;
        final scale = 1.0 + 0.14 * math.sin(t);
        final angle = 0.12 * math.sin(t);
        final colorT = (math.sin(t) + 1) / 2;
        final color = Color.lerp(widget.color, Colors.white, colorT)!;
        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _OrbitPainter(
                    progress: _controller.value,
                    color: color,
                  ),
                ),
              ),
              Transform.rotate(
                angle: angle,
                child: Transform.scale(
                  scale: scale,
                  child: Icon(
                    iconForAgent(widget.agentId),
                    size: widget.size * 0.8,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _OrbitPainter extends CustomPainter {
  _OrbitPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2 - 1.2;
    final start = progress * 2 * math.pi - math.pi / 2;
    final sweep = math.pi * 0.7;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = color.withValues(alpha: 0.22),
    );

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.1
        ..strokeCap = StrokeCap.round
        ..color = color,
    );

    final tip = start + sweep;
    final dot = Offset(
      center.dx + radius * math.cos(tip),
      center.dy + radius * math.sin(tip),
    );
    canvas.drawCircle(dot, 2.3, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _OrbitPainter old) =>
      old.progress != progress || old.color != color;
}
