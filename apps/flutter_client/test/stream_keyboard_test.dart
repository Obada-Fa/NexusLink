import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/screens/stream_keyboard.dart';

void main() {
  const s = imeSentinel;

  group('diffImeText', () {
    test('typing sends only the new characters', () {
      expect(diffImeText('${s}he', '${s}hel'), (backspaces: 0, text: 'l'));
    });

    test('tapped suggestion completes the word', () {
      expect(diffImeText('${s}hel', '${s}hello '), (
        backspaces: 0,
        text: 'lo ',
      ));
    });

    test('autocorrect rewrites only what differs', () {
      expect(diffImeText('${s}teh', '${s}the '), (backspaces: 2, text: 'he '));
    });

    test('Backspace on an empty field still reaches the PC', () {
      expect(diffImeText(s, ''), (backspaces: 1, text: ''));
    });

    test('losing the sentinel with other text does not over-delete', () {
      expect(diffImeText('${s}hi', ''), (backspaces: 2, text: ''));
      expect(diffImeText('${s}h', 'H'), (backspaces: 1, text: 'H'));
    });

    test('an emoji is one backspace', () {
      expect(diffImeText('$s👍🏽', s), (backspaces: 1, text: ''));
    });
  });

  group('keyboardLift', () {
    test('caret above the keyboard leaves the stream still', () {
      expect(keyboardLift(caretY: 100, viewHeight: 800, covered: 300), 0);
    });

    test('caret behind the keyboard lifts just clear of it', () {
      expect(keyboardLift(caretY: 600, viewHeight: 800, covered: 300), 140);
    });

    test('never lifts further than the keyboard is tall', () {
      expect(keyboardLift(caretY: 790, viewHeight: 800, covered: 300), 300);
    });

    test('closed keyboard or unknown caret never lifts', () {
      expect(keyboardLift(caretY: 790, viewHeight: 800, covered: 0), 0);
      expect(keyboardLift(caretY: null, viewHeight: 800, covered: 300), 0);
    });
  });

  test('keysymForChar names what the server accepts', () {
    expect(keysymForChar('C'), 'c');
    expect(keysymForChar('/'), 'slash');
    expect(keysymForChar(' '), 'space');
    expect(keysymForChar('é'), isNull);
  });

  group('StreamKeyBar', () {
    Future<List<String>> pumpBar(WidgetTester tester, double width) async {
      final keys = <String>[];
      tester.view.physicalSize = Size(width, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: StreamKeyBar(
                field: const SizedBox(),
                modifiers: const {},
                trayOpen: true,
                onToggleModifier: keys.add,
                onKey: keys.add,
                onToggleTray: () {},
                onHide: () {},
              ),
            ),
          ),
        ),
      );
      return keys;
    }

    testWidgets('dock fits a narrow phone and sends the Windows key', (
      tester,
    ) async {
      final keys = await pumpBar(tester, 320);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byIcon(Icons.window));
      expect(keys, ['super']);
    });

    testWidgets('sliding the arrow nub presses arrows by direction', (
      tester,
    ) async {
      final keys = await pumpBar(tester, 360);
      await tester.drag(
        find.byIcon(Icons.open_with),
        const Offset(70, 0),
        touchSlopX: 0,
      );
      expect(keys, isNotEmpty);
      expect(keys.toSet(), {'Right'});
    });
  });
}
