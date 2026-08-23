import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';

/// Detect syntax highlighting language identifier from file path or language tag.
String detectLanguage(String? pathOrLanguage) {
  if (pathOrLanguage == null || pathOrLanguage.trim().isEmpty) {
    return 'plaintext';
  }

  final raw = pathOrLanguage.trim().toLowerCase();
  // Strip path prefix if any
  final filename = raw.contains('/') ? raw.split('/').last : raw;
  final ext = filename.contains('.') ? filename.split('.').last : filename;

  switch (ext) {
    case 'ts':
      return 'typescript';
    case 'tsx':
    case 'jsx':
    case 'js':
    case 'mjs':
    case 'cjs':
      return 'javascript';
    case 'dart':
      return 'dart';
    case 'py':
    case 'python':
      return 'python';
    case 'rs':
    case 'rust':
      return 'rust';
    case 'go':
    case 'golang':
      return 'go';
    case 'json':
    case 'jsonc':
      return 'json';
    case 'yaml':
    case 'yml':
      return 'yaml';
    case 'toml':
    case 'ini':
      return 'ini';
    case 'sh':
    case 'bash':
    case 'zsh':
      return 'bash';
    case 'sql':
      return 'sql';
    case 'html':
    case 'htm':
    case 'svg':
    case 'xml':
      return 'xml';
    case 'css':
    case 'scss':
    case 'sass':
    case 'less':
      return 'css';
    case 'c':
    case 'h':
      return 'c';
    case 'cpp':
    case 'cc':
    case 'cxx':
    case 'hpp':
      return 'cpp';
    case 'java':
      return 'java';
    case 'kt':
    case 'kts':
      return 'kotlin';
    case 'swift':
      return 'swift';
    case 'rb':
    case 'ruby':
      return 'ruby';
    case 'php':
      return 'php';
    case 'md':
    case 'markdown':
      return 'markdown';
    case 'dockerfile':
      return 'dockerfile';
    case 'diff':
    case 'patch':
      return 'diff';
    case 'gradle':
      return 'groovy';
    case 'graphql':
    case 'gql':
      return 'graphql';
    case 'proto':
      return 'protobuf';
    default:
      if (filename == 'dockerfile') return 'dockerfile';
      if (filename == 'makefile') return 'makefile';
      return ext;
  }
}

/// Human-readable label for a detected language or file path.
String languageDisplayName(String? pathOrLanguage) {
  final lang = detectLanguage(pathOrLanguage);
  switch (lang) {
    case 'typescript':
      return 'TypeScript';
    case 'javascript':
      if (pathOrLanguage?.toLowerCase().endsWith('.tsx') == true) return 'TSX';
      if (pathOrLanguage?.toLowerCase().endsWith('.jsx') == true) return 'JSX';
      return 'JavaScript';
    case 'dart':
      return 'Dart';
    case 'python':
      return 'Python';
    case 'rust':
      return 'Rust';
    case 'go':
      return 'Go';
    case 'json':
      return 'JSON';
    case 'yaml':
      return 'YAML';
    case 'ini':
      return 'Config';
    case 'bash':
      return 'Shell';
    case 'sql':
      return 'SQL';
    case 'xml':
      return 'HTML/XML';
    case 'css':
      return 'CSS';
    case 'c':
      return 'C';
    case 'cpp':
      return 'C++';
    case 'java':
      return 'Java';
    case 'kotlin':
      return 'Kotlin';
    case 'swift':
      return 'Swift';
    case 'ruby':
      return 'Ruby';
    case 'php':
      return 'PHP';
    case 'markdown':
      return 'Markdown';
    case 'dockerfile':
      return 'Docker';
    case 'diff':
      return 'Diff';
    default:
      return lang.toUpperCase();
  }
}

/// Accent color for language tags.
Color languageAccentColor(String? pathOrLanguage) {
  final lang = detectLanguage(pathOrLanguage);
  switch (lang) {
    case 'typescript':
    case 'javascript':
      return const Color(0xFF60A5FA); // Blue
    case 'dart':
      return const Color(0xFF2DD4BF); // Teal
    case 'python':
      return const Color(0xFF38BDF8); // Cyan
    case 'rust':
      return const Color(0xFFF97316); // Orange
    case 'go':
      return const Color(0xFF38BDF8); // Cyan
    case 'json':
    case 'yaml':
    case 'ini':
      return const Color(0xFFFBBF24); // Amber
    case 'bash':
      return const Color(0xFF4ADE80); // Green
    case 'sql':
      return const Color(0xFFA78BFA); // Purple
    case 'xml':
    case 'css':
      return const Color(0xFFF472B6); // Pink
    case 'c':
    case 'cpp':
      return const Color(0xFF818CF8); // Indigo
    case 'java':
    case 'kotlin':
      return const Color(0xFFFB923C); // Orange
    case 'markdown':
      return const Color(0xFFC084FC); // Purple
    default:
      return const Color(0xFF94A3B8); // Slate
  }
}

/// Custom dark theme tuned for NexusLink mobile interface.
final Map<String, TextStyle> nexusLinkCodeTheme = Map<String, TextStyle>.from(atomOneDarkTheme)
  ..addAll({
    'root': const TextStyle(
      backgroundColor: Colors.transparent,
      color: Color(0xFFABB2BF),
    ),
    'comment': const TextStyle(color: Color(0xFF6A7382), fontStyle: FontStyle.italic),
    'quote': const TextStyle(color: Color(0xFF6A7382), fontStyle: FontStyle.italic),
    'keyword': const TextStyle(color: Color(0xFFC678DD), fontWeight: FontWeight.w600),
    'selector-tag': const TextStyle(color: Color(0xFFC678DD), fontWeight: FontWeight.w600),
    'type': const TextStyle(color: Color(0xFFE5C07B)),
    'string': const TextStyle(color: Color(0xFF98C379)),
    'title': const TextStyle(color: Color(0xFF61AFEF), fontWeight: FontWeight.w600),
    'title.function': const TextStyle(color: Color(0xFF61AFEF)),
    'attr': const TextStyle(color: Color(0xFFD19A66)),
    'attribute': const TextStyle(color: Color(0xFFD19A66)),
    'number': const TextStyle(color: Color(0xFFD19A66)),
    'literal': const TextStyle(color: Color(0xFF56B6C2)),
    'built_in': const TextStyle(color: Color(0xFFE5C07B)),
    'variable': const TextStyle(color: Color(0xFFE06C75)),
    'punctuation': const TextStyle(color: Color(0xFFABB2BF)),
    'tag': const TextStyle(color: Color(0xFFE06C75)),
    'name': const TextStyle(color: Color(0xFFE06C75)),
  });

/// A full-featured code viewing widget with syntax highlighting, line numbers gutter,
/// and word-wrap support.
class CodeViewer extends StatelessWidget {
  final String code;
  final String? language;
  final String? filePath;
  final bool showLineNumbers;
  final bool isWordWrap;
  final double fontSize;
  final double lineHeight;
  final ScrollController? scrollController;
  final EdgeInsets padding;

  const CodeViewer({
    super.key,
    required this.code,
    this.language,
    this.filePath,
    this.showLineNumbers = true,
    this.isWordWrap = false,
    this.fontSize = 12.5,
    this.lineHeight = 1.45,
    this.scrollController,
    this.padding = const EdgeInsets.symmetric(vertical: 8),
  });

  @override
  Widget build(BuildContext context) {
    final lang = language ?? detectLanguage(filePath);
    final lines = code.split('\n');
    final lineCount = lines.isEmpty ? 1 : lines.length;

    final codeTextStyle = TextStyle(
      fontFamily: 'monospace',
      fontSize: fontSize,
      height: lineHeight,
      color: const Color(0xFFABB2BF),
    );

    // Gutter line numbers widget
    Widget buildLineNumbers() {
      final padWidth = lineCount.toString().length;
      final numbersText = List.generate(
        lineCount,
        (i) => (i + 1).toString().padLeft(padWidth),
      ).join('\n');

      return Container(
        padding: const EdgeInsets.only(left: 10, right: 10),
        decoration: const BoxDecoration(
          border: Border(
            right: BorderSide(color: Color(0xFF232336), width: 1),
          ),
        ),
        child: Text(
          numbersText,
          textAlign: TextAlign.right,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: fontSize,
            height: lineHeight,
            color: const Color(0xFF55556E),
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }

    final highlightView = HighlightView(
      code,
      language: lang,
      theme: nexusLinkCodeTheme,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      textStyle: codeTextStyle,
    );

    Widget content;
    if (showLineNumbers) {
      if (isWordWrap) {
        content = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            buildLineNumbers(),
            Expanded(child: highlightView),
          ],
        );
      } else {
        content = SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              buildLineNumbers(),
              highlightView,
            ],
          ),
        );
      }
    } else {
      if (isWordWrap) {
        content = highlightView;
      } else {
        content = SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: highlightView,
        );
      }
    }

    return SingleChildScrollView(
      controller: scrollController,
      padding: padding,
      physics: const BouncingScrollPhysics(),
      child: content,
    );
  }
}
