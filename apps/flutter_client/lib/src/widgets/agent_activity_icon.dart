import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

final _agentIconBytesCache = <String, Uint8List>{};
final _agentIconDataCache = <String, String>{};

/// Register a host-provided agent logo data URI (e.g. from agent.list or agent session).
void registerAgentIcon(String agentId, String? iconDataUri) {
  if (iconDataUri != null && iconDataUri.isNotEmpty) {
    _agentIconDataCache[agentId] = iconDataUri;
  }
}

String? getCachedAgentIcon(String agentId) => _agentIconDataCache[agentId];

Uint8List? _decodeDataUriBytes(String uri) {
  final cached = _agentIconBytesCache[uri];
  if (cached != null) return cached;

  final match = RegExp(
    r'^data:image/(png|jpeg|jpg|webp|gif|bmp);base64,(.*)$',
    caseSensitive: false,
  ).firstMatch(uri);
  if (match == null) return null;
  try {
    final bytes = base64Decode(match.group(2)!);
    if (_agentIconBytesCache.length > 200) {
      _agentIconBytesCache.clear();
    }
    _agentIconBytesCache[uri] = bytes;
    return bytes;
  } catch (_) {
    return null;
  }
}

IconData iconForAgent(String id) {
  return switch (id) {
    'claude' => Icons.auto_awesome,
    'cursor' => Icons.code,
    'opencode' => Icons.terminal,
    'antigravity' => Icons.auto_awesome,
    'mock' => Icons.smart_toy_outlined,
    _ => Icons.smart_toy_outlined,
  };
}

/// Official brand marks or raster logos available for this agent.
bool hasOfficialAgentLogo(String id) =>
    id == 'cursor' ||
    id == 'antigravity' ||
    id == 'claude' ||
    id == 'opencode' ||
    id == 'mock';

Color agentMarkColor(String id, {required bool available}) {
  if (!available) return Colors.white24;
  return Colors.white;
}

/// Agent brand mark for list rows and pickers. Renders unified official brand vector
/// marks for supported agents, or host raster icon if present for custom agents.
class AgentMark extends StatelessWidget {
  const AgentMark({
    super.key,
    required this.agentId,
    this.icon,
    this.size = 24,
    this.color = Colors.white,
  });

  final String agentId;
  final String? icon;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (hasOfficialAgentLogo(agentId)) {
      return _officialBrandWidget();
    }
    final iconUri = (icon != null && icon!.isNotEmpty)
        ? icon
        : _agentIconDataCache[agentId];
    if (iconUri != null && iconUri.startsWith('data:image/')) {
      final bytes = _decodeDataUriBytes(iconUri);
      if (bytes != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(size * 0.22),
          child: Image.memory(
            bytes,
            width: size,
            height: size,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => _fallbackWidget(),
          ),
        );
      }
    }
    return _fallbackWidget();
  }

  Widget _officialBrandWidget() {
    final painter = switch (agentId) {
      'cursor' => _CursorLogoPainter(color),
      'antigravity' => _AntigravityLogoPainter(color),
      'claude' => _ClaudeLogoPainter(color),
      'opencode' => _OpenCodeLogoPainter(color),
      _ => null,
    };
    if (painter != null) {
      return SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: painter),
      );
    }
    return Icon(iconForAgent(agentId), size: size, color: color);
  }

  Widget _fallbackWidget() {
    return Icon(iconForAgent(agentId), size: size, color: color);
  }
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
    this.icon,
    this.active = false,
    this.size = 24,
    this.color = Colors.white,
  });

  final String agentId;
  final String? icon;
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
    if (widget.icon != null && widget.icon!.isNotEmpty) {
      registerAgentIcon(widget.agentId, widget.icon);
    }
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(AgentActivityIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.icon != null && widget.icon!.isNotEmpty) {
      registerAgentIcon(widget.agentId, widget.icon);
    }
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

  Color get _markColor => Colors.white;

  @override
  Widget build(BuildContext context) {
    if (!widget.active) {
      return AgentMark(
        agentId: widget.agentId,
        icon: widget.icon,
        size: widget.size,
        color: _markColor,
      );
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
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
                  child: AgentMark(
                    agentId: widget.agentId,
                    icon: widget.icon,
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

/// Official Cursor mark (silhouette from Cursor's product icon).
class _CursorLogoPainter extends CustomPainter {
  _CursorLogoPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.shortestSide / 28);
    final path = Path()
      ..moveTo(22.8416, 1.387)
      ..cubicTo(23.4132, 1.0062, 24.1735, 1.44515, 24.1295, 2.13055)
      ..lineTo(22.6326, 25.4656)
      ..cubicTo(22.5957, 26.0405, 21.8646, 26.2609, 21.5162, 25.8022)
      ..lineTo(15.0114, 17.2395)
      ..cubicTo(14.8429, 17.0177, 14.5923, 16.873, 14.316, 16.838)
      ..lineTo(3.6481, 15.486)
      ..cubicTo(3.07656, 15.4136, 2.9019, 14.6703, 3.38136, 14.3509)
      ..close();
    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(covariant _CursorLogoPainter old) => old.color != color;
}

/// Official Antigravity mark (Google Antigravity emblem).
class _AntigravityLogoPainter extends CustomPainter {
  _AntigravityLogoPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.shortestSide / 64);
    final path = Path()
      ..moveTo(14.372, 48.786)
      ..cubicTo(13.879, 48.593, 13.705, 48.367, 13.705, 47.921)
      ..cubicTo(13.705, 47.325, 14.029, 46.791, 15.051, 45.708)
      ..cubicTo(17.191, 43.439, 18.638, 40.725, 20.157, 36.134)
      ..cubicTo(20.635, 34.688, 20.969, 33.548, 22.544, 27.971)
      ..cubicTo(23.472, 24.685, 24.311, 22.291, 25.135, 20.571)
      ..cubicTo(26.587, 17.541, 28.311, 15.846, 30.499, 15.297)
      ..cubicTo(31.022, 15.166, 31.279, 15.139, 32.036, 15.139)
      ..cubicTo(34.009, 15.139, 35.316, 15.709, 36.747, 17.195)
      ..cubicTo(37.507, 17.984, 38.132, 18.91, 38.791, 20.218)
      ..cubicTo(39.739, 22.101, 40.551, 24.398, 41.657, 28.32)
      ..cubicTo(42.012, 29.578, 42.544, 31.465, 42.841, 32.513)
      ..cubicTo(44.303, 37.688, 45.612, 40.936, 47.221, 43.383)
      ..cubicTo(47.811, 44.283, 48.255, 44.838, 49.143, 45.786)
      ..cubicTo(50.003, 46.703, 50.295, 47.213, 50.295, 47.794)
      ..cubicTo(50.295, 48.098, 50.265, 48.196, 50.128, 48.36)
      ..cubicTo(49.647, 48.932, 48.596, 49.001, 47.588, 48.526)
      ..cubicTo(46.352, 47.944, 44.316, 46.15, 42.954, 44.441)
      ..cubicTo(42.154, 43.438, 41.107, 41.833, 39.939, 39.818)
      ..cubicTo(37.659, 35.888, 36.617, 34.668, 34.83, 33.843)
      ..cubicTo(33.938, 33.43, 33.448, 33.342, 32.063, 33.341)
      ..cubicTo(30.773, 33.341, 30.526, 33.379, 29.675, 33.691)
      ..cubicTo(28.542, 34.107, 27.578, 34.844, 26.645, 36.007)
      ..cubicTo(25.982, 36.835, 25.555, 37.493, 24.323, 39.596)
      ..cubicTo(23.114, 41.656, 22.043, 43.321, 21.358, 44.201)
      ..cubicTo(19.617, 46.441, 17.258, 48.408, 15.875, 48.776)
      ..cubicTo(15.461, 48.886, 14.651, 48.891, 14.372, 48.786)
      ..close();
    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(covariant _AntigravityLogoPainter old) =>
      old.color != color;
}

/// Official Claude mark (Anthropic spark mark).
class _ClaudeLogoPainter extends CustomPainter {
  _ClaudeLogoPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.shortestSide / 24);
    final path = Path()
      ..moveTo(12.0, 2.0)
      ..lineTo(14.4, 9.6)
      ..lineTo(22.0, 12.0)
      ..lineTo(14.4, 14.4)
      ..lineTo(12.0, 22.0)
      ..lineTo(9.6, 14.4)
      ..lineTo(2.0, 12.0)
      ..lineTo(9.6, 9.6)
      ..close();
    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(covariant _ClaudeLogoPainter old) => old.color != color;
}

/// OpenCode mark (terminal chevron prompt).
class _OpenCodeLogoPainter extends CustomPainter {
  _OpenCodeLogoPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.shortestSide / 24);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(5.0, 7.0)
      ..lineTo(11.0, 12.0)
      ..lineTo(5.0, 17.0);
    canvas.drawPath(path, stroke);
    canvas.drawLine(const Offset(13.0, 17.0), const Offset(20.0, 17.0), stroke);
  }

  @override
  bool shouldRepaint(covariant _OpenCodeLogoPainter old) => old.color != color;
}

