import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexuslink/src/screens/mirror_screen.dart';
import 'package:nexuslink/src/screens/terminal_screen.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'workspace_terminal_test.dart' show TerminalHost;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'terminal opens IME when ready, on return, and with keyboard button',
    (tester) async {
      final host = TerminalHost();
      final visible = ValueNotifier(true);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [activeClientProvider.overrideWithValue(host)],
          child: MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: visible,
                builder: (_, enabled, child) =>
                    TickerMode(enabled: enabled, child: child!),
                child: const EmbeddedTerminal(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      tester.testTextInput.hide();
      await tester.tap(find.byTooltip('Show keyboard'));
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      visible.value = false;
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
      visible.value = true;
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.pumpWidget(const SizedBox());
      visible.dispose();
      host.dispose();
    },
  );

  for (final browser in [false, true]) {
    testWidgets(
      '${browser ? 'browser' : 'app'} stream keyboard opens and reopens after Back',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [activeClientProvider.overrideWithValue(null)],
            child: MaterialApp(
              home: MirrorScreen(
                target: MirrorTarget(title: 'Test app', isBrowser: browser),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.tap(find.byTooltip('Show or hide keyboard'));
        await tester.pump();
        expect(tester.testTextInput.isVisible, isTrue);
        expect(find.byType(TextField), findsOneWidget);
        tester.testTextInput.hide();
        await tester.tap(find.byTooltip('Show or hide keyboard'));
        await tester.pump();
        expect(tester.testTextInput.isVisible, isTrue);
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pump();
        expect(tester.testTextInput.isVisible, isTrue);
        await tester.tap(find.byTooltip('Hide keyboard'));
        await tester.pump();
        expect(tester.testTextInput.isVisible, isFalse);
        expect(find.byType(TextField), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
