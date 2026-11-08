import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/widgets/streamed_markdown.dart';

void main() {
  group('splitMarkdownBlocks', () {
    test('splits paragraphs and headings', () {
      expect(splitMarkdownBlocks('# Title\n\nOne\nstill one\n\nTwo'), [
        '# Title',
        'One\nstill one',
        'Two',
      ]);
    });

    test('keeps a fenced code block with blank lines whole', () {
      const code = '```dart\na\n\nb\n```';
      expect(splitMarkdownBlocks('Intro\n\n$code\n\nOutro'), [
        'Intro',
        code,
        'Outro',
      ]);
      expect(splitMarkdownBlocks('Intro\n\n```\nopen\n\nstill open'), [
        'Intro',
        '```\nopen\n\nstill open',
      ]);
    });

    test('a shorter or different fence does not close a code block', () {
      const code = '````\n```\n\n~~~\n\ntext\n````';
      expect(splitMarkdownBlocks('$code\n\nAfter'), [code, 'After']);
    });

    test('keeps loose lists and their continuations whole', () {
      const list = '- one\n\n- two\n\n  more of two\n\n1. three\n\n2) four';
      expect(splitMarkdownBlocks('$list\n\nAfter'), [list, 'After']);
    });

    test('a link definition keeps the whole message together', () {
      const text = 'See [docs][d]\n\nMore\n\n[d]: http://x.y';
      expect(splitMarkdownBlocks(text), [text]);
    });

    test('appending lines never changes finished blocks', () {
      const text =
          '# T\n\nPara\n\n- a\n\n- b\n\n```\nx\n\ny\n```\n\nEnd\n\n> quote\n\nLast';
      final finalBlocks = splitMarkdownBlocks(text);
      final lines = text.split('\n');
      for (var n = 1; n <= lines.length; n++) {
        final blocks = splitMarkdownBlocks(lines.take(n).join('\n'));
        final finished = blocks.sublist(0, blocks.length - 1);
        expect(finished, finalBlocks.sublist(0, finished.length));
      }
    });

    test('joined blocks keep all the content', () {
      const text = 'A\n\nB\n\n```\nC\n```\n\nD\n';
      expect(splitMarkdownBlocks(text).join('\n\n').trim(), text.trim());
    });
  });

  testWidgets('a growing message only replaces its last block', (t) async {
    Widget app(String data) => MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => StreamedMarkdown(
            data: data,
            // Built fresh on each rebuild, the same way the chat screen does.
            styleSheet: MarkdownStyleSheet.fromTheme(
              Theme.of(context),
            ).copyWith(p: const TextStyle(fontSize: 14)),
          ),
        ),
      ),
    );
    await t.pumpWidget(app('First\n\nSecond'));
    expect(find.byType(MarkdownBody), findsNWidgets(2));
    final firstText = t.widgetList(find.byType(RichText)).first;
    await t.pumpWidget(app('First\n\nSecond grows\n\nThird'));
    expect(find.byType(MarkdownBody), findsNWidgets(3));
    expect(find.textContaining('Second grows'), findsOneWidget);
    // MarkdownBody keeps its parsed widgets unless the data or the style sheet
    // compare as changed, so the same instance means no re-parse.
    expect(
      identical(t.widgetList(find.byType(RichText)).first, firstText),
      isTrue,
    );
  });
}
