import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Invisible first character of the IME field, so Backspace still reaches the
/// PC when the field has nothing else to delete. Zero-width because a real
/// space would trigger the keyboard's double-space-to-period shortcut.
const imeSentinel = '​';

const streamKeyBarHeight = 44.0;

/// What the PC must do to follow one change of the IME's text.
typedef ImeEdit = ({int backspaces, String text});

/// Suggestions and autocorrect replace whole words, so compare against the text
/// already sent: "teh" -> "the " is two backspaces plus "he ".
ImeEdit diffImeText(String previous, String next) {
  final before = previous.characters.toList();
  final after = next.characters.toList();
  var shared = 0;
  while (shared < before.length &&
      shared < after.length &&
      before[shared] == after[shared]) {
    shared++;
  }
  var backspaces = before.length - shared;
  final text = after.skip(shared).join();
  // Only a lone sentinel deletion is a real Backspace; alongside other edits it
  // never existed on the PC.
  if (shared == 0 &&
      before.isNotEmpty &&
      before.first == imeSentinel &&
      (backspaces > 1 || text.isNotEmpty)) {
    backspaces--;
  }
  return (backspaces: backspaces, text: text);
}

/// How far to lift the stream so the caret at [caretY] clears the keyboard.
double keyboardLift({
  required double? caretY,
  required double viewHeight,
  required double covered,
  double margin = 40,
}) {
  if (caretY == null || covered <= 0) return 0;
  final overlap = caretY + margin - (viewHeight - covered);
  return overlap.clamp(0.0, math.max(0.0, covered)).toDouble();
}

const _symbolKeys = {
  ' ': 'space',
  '-': 'minus',
  '=': 'equal',
  '[': 'bracketleft',
  ']': 'bracketright',
  '\\': 'backslash',
  ';': 'semicolon',
  "'": 'apostrophe',
  ',': 'comma',
  '.': 'period',
  '/': 'slash',
  '`': 'grave',
};

/// X keysym for a typed character in a modifier combo, or null if it has none
/// the server accepts.
String? keysymForChar(String char) {
  if (RegExp(r'^[A-Za-z0-9]$').hasMatch(char)) return char.toLowerCase();
  return _symbolKeys[char];
}

/// Floating dock of the keys a phone keyboard lacks, directly above it.
class StreamKeyBar extends StatelessWidget {
  const StreamKeyBar({
    super.key,
    required this.field,
    required this.modifiers,
    required this.trayOpen,
    required this.onToggleModifier,
    required this.onKey,
    required this.onToggleTray,
    required this.onHide,
  });

  /// The invisible text field that owns the IME connection.
  final Widget field;
  final Set<String> modifiers;
  final bool trayOpen;
  final ValueChanged<String> onToggleModifier;
  final ValueChanged<String> onKey;
  final VoidCallback onToggleTray;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    Widget mod(String label, String name, {IconData? icon}) => _BarKey(
      label: label,
      icon: icon,
      active: modifiers.contains(name),
      onTap: () => onToggleModifier(name),
    );
    Widget key(String label, String name) =>
        _BarKey(label: label, onTap: () => onKey(name));
    Widget arrow(String name, IconData icon) => SizedBox(
      width: 40,
      child: _BarKey(label: name, icon: icon, onTap: () => onKey(name)),
    );
    Widget trayKey(String label, String name) =>
        SizedBox(width: label.length > 2 ? 52 : 40, child: key(label, name));
    return Stack(
      children: [
        Positioned(left: 0, top: 0, width: 1, height: 1, child: field),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (trayOpen)
              _Dock(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    arrow('Left', Icons.arrow_back),
                    arrow('Up', Icons.arrow_upward),
                    arrow('Down', Icons.arrow_downward),
                    arrow('Right', Icons.arrow_forward),
                    trayKey('Home', 'Home'),
                    trayKey('End', 'End'),
                    trayKey('PgUp', 'Prior'),
                    trayKey('PgDn', 'Next'),
                    trayKey('Del', 'Delete'),
                    for (var i = 1; i <= 12; i++) trayKey('F$i', 'F$i'),
                  ],
                ),
              ),
            _Dock(
              child: Row(
                children: [
                  Expanded(
                    child: mod('Windows key', 'super', icon: Icons.window),
                  ),
                  Expanded(child: mod('Ctrl', 'ctrl')),
                  Expanded(child: mod('Alt', 'alt')),
                  Expanded(child: mod('Shift', 'shift')),
                  Expanded(child: key('Esc', 'Escape')),
                  Expanded(child: key('Tab', 'Tab')),
                  Expanded(child: _ArrowNub(onKey: onKey)),
                  Expanded(
                    child: _BarKey(
                      label: 'More keys',
                      icon: Icons.more_horiz,
                      active: trayOpen,
                      onTap: onToggleTray,
                    ),
                  ),
                  Expanded(
                    child: _BarKey(
                      label: 'Hide keyboard',
                      icon: Icons.keyboard_hide,
                      onTap: onHide,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Dock extends StatelessWidget {
  const _Dock({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: streamKeyBarHeight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
        child: Material(
          color: const Color(0xE616161F),
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
      ),
    );
  }
}

/// One key for all four arrows: slide a finger across it and each 24 px is a
/// press in that direction.
class _ArrowNub extends StatefulWidget {
  const _ArrowNub({required this.onKey});

  final ValueChanged<String> onKey;

  @override
  State<_ArrowNub> createState() => _ArrowNubState();
}

class _ArrowNubState extends State<_ArrowNub> {
  static const _step = 24.0;
  Offset _travel = Offset.zero;
  bool _dragging = false;

  void _onUpdate(DragUpdateDetails d) {
    _travel += d.delta;
    while (_travel.distance >= _step) {
      final horizontal = _travel.dx.abs() >= _travel.dy.abs();
      final value = horizontal ? _travel.dx : _travel.dy;
      widget.onKey(
        horizontal
            ? (value < 0 ? 'Left' : 'Right')
            : (value < 0 ? 'Up' : 'Down'),
      );
      _travel -= horizontal
          ? Offset(value.sign * _step, 0)
          : Offset(0, value.sign * _step);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Arrow keys, slide to move',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => setState(() {
          _travel = Offset.zero;
          _dragging = true;
        }),
        onPanUpdate: _onUpdate,
        onPanEnd: (_) => setState(() => _dragging = false),
        onPanCancel: () => setState(() => _dragging = false),
        child: Center(
          child: Icon(
            Icons.open_with,
            size: 20,
            color: _dragging
                ? Theme.of(context).colorScheme.primary
                : Colors.white,
          ),
        ),
      ),
    );
  }
}

class _BarKey extends StatelessWidget {
  const _BarKey({
    required this.label,
    required this.onTap,
    this.icon,
    this.active = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = active ? colors.onPrimary : Colors.white;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: icon == null ? '' : label,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Material(
            color: active ? colors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            child: InkWell(
              // Taking focus from the hidden field would close the keyboard.
              canRequestFocus: false,
              borderRadius: BorderRadius.circular(9),
              onTap: onTap,
              child: Center(
                child: icon != null
                    ? Icon(icon, size: 20, color: color)
                    : FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          label,
                          maxLines: 1,
                          style: TextStyle(fontSize: 13, color: color),
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
