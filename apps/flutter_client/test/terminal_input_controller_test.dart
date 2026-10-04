import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/screens/terminal_input_controller.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('one tap, delayed repeat, release and disconnect cancellation', (
    tester,
  ) async {
    final output = <String>[];
    final terminal = Terminal(
      onOutput: output.add,
      inputHandler: const CursorModeInputHandler(),
    );
    final input = TerminalInputController(terminal)..setAvailable(true);
    input.startArrow(TerminalKey.arrowUp);
    expect(output.length, 1);
    await tester.pump(const Duration(milliseconds: 349));
    expect(output.length, 1);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 70));
    expect(output.length, 2);
    input.cancelRepeat();
    await tester.pump(const Duration(milliseconds: 500));
    expect(output.length, 2);
    input.startArrow(TerminalKey.arrowUp);
    input.setAvailable(false);
    await tester.pump(const Duration(milliseconds: 500));
    expect(output.length, 3);
    input.dispose();
  });

  test('swipe threshold and xterm application cursor mode', () {
    final output = <String>[];
    final terminal = Terminal(
      onOutput: output.add,
      inputHandler: const CursorModeInputHandler(),
    );
    final input = TerminalInputController(terminal)..setAvailable(true);
    input.startSwipe(Offset.zero);
    input.updateSwipe(const Offset(11, 0));
    expect(output, isEmpty);
    input.updateSwipe(const Offset(23, 0));
    expect(output, isEmpty);
    input.updateSwipe(const Offset(49, 0));
    expect(output.length, 2);
    input.cancelSwipe();
    terminal.write('\x1b[?1h');
    expect(terminal.cursorKeysMode, isTrue);
    output.clear();
    input.sendKey(TerminalKey.arrowUp);
    expect(output.single, '\x1bOA');
    input.dispose();
  });

  test('one-shot modifier applies only to supported next text key', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);
    final input = TerminalInputController(terminal)..setAvailable(true);
    input.toggleCtrl();
    input.sendText('c');
    input.sendText('d');
    expect(output, ['\x03', 'd']);
    input.dispose();
  });
}
