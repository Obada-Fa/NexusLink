import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/screens/terminal_input_controller.dart';
import 'package:nexuslink/src/screens/terminal_screen.dart';
import 'package:xterm/xterm.dart';

void main() {
  for (final width in [320.0, 360.0, 412.0]) {
    testWidgets(
      'six terminal controls fit at ${width.toInt()} dp with large text',
      (tester) async {
        final output = <String>[];
        final input = TerminalInputController(Terminal(onOutput: output.add))
          ..setAvailable(true);
        addTearDown(input.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: width,
                  child: MediaQuery(
                    data: const MediaQueryData(
                      textScaler: TextScaler.linear(1.5),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: 48,
                          child: TextField(focusNode: input.focusNode),
                        ),
                        TerminalPrimaryControls(
                          input: input,
                          more: false,
                          onMore: () {},
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        for (final label in ['Left', 'Up', 'Down', 'Right']) {
          final arrow = find.byTooltip('$label arrow');
          expect(arrow, findsOneWidget);
          expect(tester.getSize(arrow).height, 48);
          expect(tester.getSize(arrow).width, greaterThanOrEqualTo(48));
        }
        expect(find.text('Ctrl'), findsOneWidget);
        expect(find.text('More'), findsOneWidget);
        // Esc and Tab join the row only where every key keeps 48 dp.
        final wide = width >= TerminalPrimaryControls.minWidthForEscTab;
        expect(find.text('Esc'), wide ? findsOneWidget : findsNothing);
        expect(find.text('Tab'), wide ? findsOneWidget : findsNothing);
        if (wide) {
          expect(
            tester.getSize(find.widgetWithText(TextButton, 'Esc')).width,
            greaterThanOrEqualTo(48),
          );
          await tester.tap(find.text('Esc'));
          await tester.pump();
          expect(output.removeLast(), '\x1b');
        }
        input.focusNode.requestFocus();
        await tester.pump();
        await tester.tap(find.byTooltip('Up arrow'));
        await tester.pump();
        expect(output.length, 1);
        expect(input.focusNode.hasFocus, isTrue);
      },
    );
  }
}
