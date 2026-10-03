import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/widgets/controller_owned_dialog.dart';

void main() {
  testWidgets('text controller survives the dialog closing animation', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                final controller = TextEditingController(text: '/tmp');
                showDialog<void>(
                  context: context,
                  builder: (dialogContext) => ControllerOwnedDialog(
                    controller: controller,
                    child: AlertDialog(
                      content: TextField(controller: controller),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text('Continue'),
                        ),
                      ],
                    ),
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Open'), findsOneWidget);
  });
}
