/// Open once per text-cursor activation, not once per polling tick.
/// Leaving the cursor active after dismissing the IME must not reopen it.
class CursorKeyboardPolicy {
  bool _active = false;
  String? _focus;

  void rearm() => _active = false;

  bool observe({required bool active, String? focus}) {
    final open = active && (!_active || focus != _focus);
    _active = active;
    _focus = focus;
    return open;
  }
}
