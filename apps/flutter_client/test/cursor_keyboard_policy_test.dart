import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/screens/cursor_keyboard_policy.dart';

void main() {
  test('opens once and rearms only for a new activation or tap', () {
    final policy = CursorKeyboardPolicy();
    expect(policy.observe(active: false, focus: '10'), isFalse);
    expect(policy.observe(active: true, focus: '10'), isTrue);
    // Repeated hints must not reopen a manually dismissed keyboard.
    expect(policy.observe(active: true, focus: '10'), isFalse);
    expect(policy.observe(active: false, focus: '10'), isFalse);
    expect(policy.observe(active: true, focus: '10'), isTrue);
    expect(policy.observe(active: true, focus: '11'), isTrue);
    expect(policy.observe(active: true, focus: '11'), isFalse);
    policy.rearm();
    expect(policy.observe(active: true, focus: '11'), isTrue);
  });
}
