// Markdown for a message that is still growing. Finished blocks keep their
// parsed widgets, so each streamed delta only re-parses the block at the end.

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

final _fence = RegExp(r'^ {0,3}(`{3,}|~{3,})');
final _listItem = RegExp(r'^(?:[-+*]|\d{1,9}[.)])(?:\s|$)');
final _linkDefinition = RegExp(r'^ {0,3}\[[^\]]+\]:', multiLine: true);

/// Splits [text] at blank lines where parsing each piece alone renders the same
/// as parsing the whole. Appending text never changes earlier blocks, except
/// that a link definition (which applies to the whole message) merges them all.
List<String> splitMarkdownBlocks(String text) {
  if (_linkDefinition.hasMatch(text)) return [text];
  final blocks = <String>[];
  var start = 0;
  var offset = 0;
  var afterBlank = false;
  String? fence;
  while (offset < text.length) {
    final newline = text.indexOf('\n', offset);
    final end = newline == -1 ? text.length : newline;
    final line = text.substring(offset, end);
    if (fence != null) {
      final trimmed = line.trim();
      if (trimmed.length >= fence.length &&
          trimmed.split('').every((c) => c == fence![0])) {
        fence = null;
      }
    } else if (line.trim().isEmpty) {
      afterBlank = true;
    } else {
      // Indented lines and further list items still belong to the open list.
      if (afterBlank &&
          offset > start &&
          line[0] != ' ' &&
          line[0] != '\t' &&
          !_listItem.hasMatch(line)) {
        blocks.add(text.substring(start, offset).trimRight());
        start = offset;
      }
      afterBlank = false;
      fence = _fence.firstMatch(line)?.group(1);
    }
    offset = end + 1;
  }
  blocks.add(text.substring(start));
  return blocks;
}

class StreamedMarkdown extends StatefulWidget {
  const StreamedMarkdown({
    super.key,
    required this.data,
    required this.styleSheet,
    this.builders = const {},
    this.inlineSyntaxes,
  });

  final String data;
  final MarkdownStyleSheet styleSheet;
  final Map<String, MarkdownElementBuilder> builders;
  final List<md.InlineSyntax>? inlineSyntaxes;

  @override
  State<StreamedMarkdown> createState() => _StreamedMarkdownState();
}

class _StreamedMarkdownState extends State<StreamedMarkdown> {
  late List<String> _blocks = splitMarkdownBlocks(widget.data);

  @override
  void didUpdateWidget(StreamedMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) {
      _blocks = splitMarkdownBlocks(widget.data);
    }
  }

  @override
  Widget build(BuildContext context) {
    final spacing = widget.styleSheet.blockSpacing ?? 8;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _blocks.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : spacing),
            child: MarkdownBody(
              data: _blocks[i],
              inlineSyntaxes: widget.inlineSyntaxes,
              builders: widget.builders,
              styleSheet: widget.styleSheet,
            ),
          ),
      ],
    );
  }
}
