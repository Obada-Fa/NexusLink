import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/screens/terminal_screen.dart';

void main() {
  test('sticky Ctrl+C becomes ETX', () {
    expect(applyStickyModifiers('c', ctrl: true, alt: false), '\x03');
    expect(applyStickyModifiers('C', ctrl: true, alt: false), '\x03');
  });

  test('sticky Alt prefixes ESC', () {
    expect(applyStickyModifiers('b', ctrl: false, alt: true), '\x1bb');
  });

  test('plain text is unchanged', () {
    expect(applyStickyModifiers('ls\n', ctrl: false, alt: false), 'ls\n');
  });
}
