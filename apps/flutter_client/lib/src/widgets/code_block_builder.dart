// Custom code block builder for MarkdownBody in Flutter: renders code blocks
// with a language header and a one-click copy button to copy clean code without
// markdown fence backticks.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'code_viewer.dart';

/// Strips outer markdown fence backticks (e.g. ```text\n...\n```) when the
/// entire message is wrapped in a single code block.
String cleanCopyMessage(String raw) {
  final trimmed = raw.trim();
  final fenceMatch = RegExp(r'^```[a-zA-Z0-9_\-\.]*\r?\n([\s\S]*?)\r?\n?```$')
      .firstMatch(trimmed);
  if (fenceMatch != null) {
    return fenceMatch.group(1)!.trim();
  }
  return raw;
}

class CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    String language = '';
    if (element.children != null && element.children!.isNotEmpty) {
      final firstChild = element.children!.first;
      if (firstChild is md.Element && firstChild.tag == 'code') {
        final cls = firstChild.attributes['class'] ?? '';
        if (cls.startsWith('language-')) {
          language = cls.substring('language-'.length);
        }
      }
    }

    var code = element.textContent;
    if (code.endsWith('\n')) {
      code = code.substring(0, code.length - 1);
    }

    return _CodeBlockView(
      code: code,
      language: language,
    );
  }
}

class _CodeBlockView extends StatefulWidget {
  final String code;
  final String language;

  const _CodeBlockView({
    required this.code,
    required this.language,
  });

  @override
  State<_CodeBlockView> createState() => _CodeBlockViewState();
}

class _CodeBlockViewState extends State<_CodeBlockView> {
  bool _copied = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    if (widget.code.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied code to clipboard'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lang = detectLanguage(widget.language);
    final displayLang = widget.language.isNotEmpty
        ? widget.language
        : (lang != 'plaintext' ? lang : 'code');
    final accentColor = languageAccentColor(widget.language);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0C0C14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF22223A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
            decoration: const BoxDecoration(
              color: Color(0xFF141422),
              borderRadius: BorderRadius.vertical(top: Radius.circular(7)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        color: accentColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    Text(
                      displayLang,
                      style: TextStyle(
                        color: accentColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                  tooltip: 'Copy code',
                  onPressed: _copy,
                  icon: Icon(
                    _copied ? Icons.check : Icons.copy_rounded,
                    size: 14,
                    color: _copied ? const Color(0xFF4ADE80) : Colors.white38,
                  ),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.all(10),
            child: HighlightView(
              widget.code,
              language: lang,
              theme: nexusLinkCodeTheme,
              textStyle: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
