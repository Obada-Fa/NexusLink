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

/// Agent logo used in lists and chat. Pulses gently while [active] is true.
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
    final icon = Icon(
      iconForAgent(widget.agentId),
      size: widget.size,
      color: widget.color,
    );
    if (!widget.active) return icon;

    return AnimatedBuilder(
      animation: _controller,
      builder: (_, child) {
        final t = _controller.value * 2 * math.pi;
        final scale = 1.0 + 0.14 * math.sin(t);
        final angle = 0.12 * math.sin(t);
        return Transform.rotate(
          angle: angle,
          child: Transform.scale(scale: scale, child: child),
        );
      },
      child: icon,
    );
  }
}
