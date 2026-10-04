import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

/// xterm 4's keytab handler reads appKeypadMode for AppCuKeys. Supply the
/// tracked cursor mode while it encodes cursor keys, then restore keypad mode.
class CursorModeInputHandler implements TerminalInputHandler {
  const CursorModeInputHandler();

  @override
  String? call(TerminalKeyboardEvent event) {
    final terminal = event.state;
    if (terminal is! Terminal ||
        !const {
          TerminalKey.arrowLeft,
          TerminalKey.arrowUp,
          TerminalKey.arrowDown,
          TerminalKey.arrowRight,
        }.contains(event.key) ||
        terminal.appKeypadMode == terminal.cursorKeysMode) {
      return defaultInputHandler(event);
    }
    final keypadMode = terminal.appKeypadMode;
    terminal.setAppKeypadMode(terminal.cursorKeysMode);
    try {
      return defaultInputHandler(event);
    } finally {
      terminal.setAppKeypadMode(keypadMode);
    }
  }
}

/// Owns only app-provided input. xterm continues to encode keys and IME input.
class TerminalInputController extends ChangeNotifier {
  TerminalInputController(this.terminal);

  final Terminal terminal;
  final FocusNode focusNode = FocusNode();
  bool available = false;
  bool ctrl = false;
  bool alt = false;
  Timer? _delay;
  Timer? _repeat;
  TerminalKey? _held;
  Offset? _swipeStart;
  Axis? _axis;
  int _swipeSteps = 0;

  void setAvailable(bool value) {
    if (available == value) return;
    available = value;
    if (!value) {
      cancelRepeat();
      cancelSwipe();
      ctrl = false;
      alt = false;
    }
    notifyListeners();
  }

  void toggleCtrl() {
    if (available) {
      ctrl = !ctrl;
      notifyListeners();
    }
  }

  void toggleAlt() {
    if (available) {
      alt = !alt;
      notifyListeners();
    }
  }

  bool sendKey(TerminalKey key, {bool forcedCtrl = false}) {
    if (!available) return false;
    final sent = terminal.keyInput(key, ctrl: ctrl || forcedCtrl, alt: alt);
    ctrl = false;
    alt = false;
    notifyListeners();
    return sent;
  }

  void sendText(String value) {
    if (!available || value.isEmpty) return;
    if (value.runes.length == 1 && (ctrl || alt)) {
      final rune = value.toLowerCase().runes.single;
      if (!terminal.charInput(rune, ctrl: ctrl, alt: alt)) {
        terminal.textInput(value);
      }
    } else {
      terminal.textInput(value);
    }
    ctrl = false;
    alt = false;
    notifyListeners();
  }

  void startArrow(TerminalKey key) {
    cancelRepeat();
    if (!available) return;
    _held = key;
    sendKey(key);
    _delay = Timer(const Duration(milliseconds: 350), () {
      if (!available || _held != key) return;
      _repeat = Timer.periodic(const Duration(milliseconds: 70), (_) {
        if (available && _held == key) sendKey(key);
      });
    });
  }

  void cancelRepeat() {
    _held = null;
    _delay?.cancel();
    _repeat?.cancel();
    _delay = null;
    _repeat = null;
  }

  void startSwipe(Offset position) {
    cancelSwipe();
    if (available) _swipeStart = position;
  }

  void updateSwipe(Offset position) {
    final start = _swipeStart;
    if (!available || start == null) return;
    final delta = position - start;
    if (_axis == null) {
      if (delta.distance < 12) return;
      _axis = delta.dx.abs() >= delta.dy.abs()
          ? Axis.horizontal
          : Axis.vertical;
    }
    final distance = _axis == Axis.horizontal ? delta.dx : delta.dy;
    final steps = (distance.abs() / 24).floor();
    if (steps <= _swipeSteps) return;
    final key = _axis == Axis.horizontal
        ? (distance < 0 ? TerminalKey.arrowLeft : TerminalKey.arrowRight)
        : (distance < 0 ? TerminalKey.arrowUp : TerminalKey.arrowDown);
    for (var i = _swipeSteps; i < steps; i++) {
      sendKey(key);
    }
    _swipeSteps = steps;
  }

  void cancelSwipe() {
    _swipeStart = null;
    _axis = null;
    _swipeSteps = 0;
  }

  @override
  void dispose() {
    cancelRepeat();
    cancelSwipe();
    focusNode.dispose();
    super.dispose();
  }
}
