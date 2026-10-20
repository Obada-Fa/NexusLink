import 'package:flutter/material.dart';

/// NexusLink "night ops" design tokens. Use these instead of hex literals.
abstract final class NX {
  // Surfaces, darkest → most raised.
  static const bg = Color(0xFF07090E);
  static const surface = Color(0xFF0D1118);
  static const surface2 = Color(0xFF131925);
  static const surface3 = Color(0xFF1A2232);
  static const line = Color(0xFF243047);
  static const text = Color(0xFFE8EEF8);
  static const textDim = Color(0xFF9AA7BD);
  static const textFaint = Color(0xFF65728A);

  // Brand.
  static const accent = Color(0xFF5EC8FF);
  static const accent2 = Color(0xFF9C7CFF);

  // Status: one vocabulary across the whole app.
  static const working = Color(0xFF4BE3A6);
  static const waiting = Color(0xFFFFC857);
  static const failed = Color(0xFFFF6B6B);
  static const done = Color(0xFF7AB8FF);
  static const idle = Color(0xFF6B7A90);
  static const stuck = Color(0xFFFF4D8D);

  // Heat scale for gauges.
  static const cool = Color(0xFF4BE3A6);
  static const warm = Color(0xFFFFC857);
  static const hot = Color(0xFFFF6B6B);

  static const radius = 20.0;
  static const radiusSm = 14.0;
  static const gap = 12.0;
  static const pad = 16.0;

  static const tabular = [FontFeature.tabularFigures()];

  /// green → amber → red for a 0-100 load.
  static Color heat(double percent) => percent < 60
      ? Color.lerp(cool, warm, (percent / 60).clamp(0, 1))!
      : Color.lerp(warm, hot, ((percent - 60) / 40).clamp(0, 1))!;

  static Color tempHeat(double? celsius, {double warmAt = 60, double hotAt = 85}) {
    if (celsius == null) return idle;
    if (celsius < warmAt) return Color.lerp(cool, warm, (celsius - 30).clamp(0, warmAt - 30) / (warmAt - 30))!;
    return Color.lerp(warm, hot, ((celsius - warmAt) / (hotAt - warmAt)).clamp(0, 1))!;
  }
}

/// Agent/provider identity colours and names.
abstract final class Providers {
  static const _colors = <String, Color>{
    'claude': Color(0xFFE08A5E),
    'codex': Color(0xFF4FD1C5),
    'antigravity': Color(0xFF6EA8FE),
    'gemini': Color(0xFF8AB4F8),
    'cursor': Color(0xFFC3CBD6),
    'opencode': Color(0xFFF6C177),
    'nexuslink': Color(0xFF9C7CFF),
    'mock': Color(0xFF9C7CFF),
    'vscode': Color(0xFF3EA6FF),
    'windsurf': Color(0xFF2ED3B7),
    'aider': Color(0xFFF28FAD),
    'qwen': Color(0xFFB18CFF),
  };
  static const _names = <String, String>{
    'claude': 'Claude',
    'codex': 'Codex',
    'antigravity': 'Antigravity',
    'gemini': 'Gemini',
    'cursor': 'Cursor',
    'opencode': 'OpenCode',
    'nexuslink': 'NexusLink',
    'mock': 'NexusLink',
    'vscode': 'VS Code',
    'windsurf': 'Windsurf',
    'aider': 'Aider',
    'qwen': 'Qwen',
  };
  static Color color(String id) => _colors[id] ?? NX.accent2;
  static String name(String id) => _names[id] ?? id;
  static String initial(String id) => name(id).characters.first.toUpperCase();
}

/// Maps every status word the host produces onto one palette + label.
abstract final class Status {
  static Color color(String state) => switch (state) {
    'working' || 'busy' || 'running' || 'healthy' => NX.working,
    'waiting' || 'needsReply' || 'attention' || 'degraded' => NX.waiting,
    'failed' || 'error' || 'down' => NX.failed,
    'stuck' => NX.stuck,
    'done' || 'completed' || 'active' => NX.done,
    _ => NX.idle,
  };
  static String label(String state) => switch (state) {
    'working' || 'busy' || 'running' => 'Working',
    'waiting' || 'needsReply' || 'attention' => 'Needs you',
    'failed' || 'error' => 'Failed',
    'stuck' => 'Frozen?',
    'done' || 'completed' => 'Done',
    'active' => 'Active',
    'healthy' => 'Healthy',
    'degraded' => 'Degraded',
    'down' => 'Down',
    _ => 'Idle',
  };
}

ThemeData nexusTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: NX.accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: NX.accent,
    secondary: NX.accent2,
    surface: NX.surface,
    surfaceContainerLowest: NX.bg,
    surfaceContainerLow: NX.surface,
    surfaceContainer: NX.surface2,
    surfaceContainerHigh: NX.surface3,
    surfaceContainerHighest: const Color(0xFF212B3E),
    outline: NX.line,
    outlineVariant: NX.line,
    onSurface: NX.text,
    onSurfaceVariant: NX.textDim,
    error: NX.failed,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: Brightness.dark);
  return base.copyWith(
    scaffoldBackgroundColor: NX.bg,
    canvasColor: NX.bg,
    appBarTheme: const AppBarTheme(
      backgroundColor: NX.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: NX.surface2,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NX.radius),
        side: BorderSide(color: NX.line.withValues(alpha: .7)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: NX.surface,
      indicatorColor: NX.accent.withValues(alpha: .16),
      surfaceTintColor: Colors.transparent,
      height: 68,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(
          fontSize: 12,
          fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
          color: s.contains(WidgetState.selected) ? NX.text : NX.textFaint,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(color: s.contains(WidgetState.selected) ? NX.accent : NX.textFaint),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: NX.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: NX.surface2,
      side: BorderSide(color: NX.line.withValues(alpha: .8)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NX.radiusSm)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: NX.surface3,
      contentTextStyle: const TextStyle(color: NX.text),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NX.radiusSm)),
    ),
    dividerTheme: DividerThemeData(color: NX.line.withValues(alpha: .6), space: 1),
    textTheme: base.textTheme.apply(bodyColor: NX.text, displayColor: NX.text),
  );
}
