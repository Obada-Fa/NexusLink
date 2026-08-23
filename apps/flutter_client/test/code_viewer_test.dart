import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/widgets/code_viewer.dart';

void main() {
  group('detectLanguage', () {
    test('detects TypeScript and TSX/JSX correctly', () {
      expect(detectLanguage('page.tsx'), 'javascript');
      expect(detectLanguage('/path/to/component.jsx'), 'javascript');
      expect(detectLanguage('index.ts'), 'typescript');
      expect(detectLanguage('server.js'), 'javascript');
    });

    test('detects Dart, Python, Rust, and Go', () {
      expect(detectLanguage('main.dart'), 'dart');
      expect(detectLanguage('script.py'), 'python');
      expect(detectLanguage('lib.rs'), 'rust');
      expect(detectLanguage('main.go'), 'go');
    });

    test('detects structured configs', () {
      expect(detectLanguage('package.json'), 'json');
      expect(detectLanguage('config.yaml'), 'yaml');
      expect(detectLanguage('docker-compose.yml'), 'yaml');
      expect(detectLanguage('config.toml'), 'ini');
    });

    test('detects shell and special files', () {
      expect(detectLanguage('build.sh'), 'bash');
      expect(detectLanguage('Dockerfile'), 'dockerfile');
      expect(detectLanguage('Makefile'), 'makefile');
      expect(detectLanguage('styles.css'), 'css');
      expect(detectLanguage('index.html'), 'xml');
      expect(detectLanguage('query.sql'), 'sql');
    });

    test('handles empty or null inputs', () {
      expect(detectLanguage(null), 'plaintext');
      expect(detectLanguage(''), 'plaintext');
      expect(detectLanguage('   '), 'plaintext');
    });
  });

  group('languageDisplayName', () {
    test('formats display names cleanly', () {
      expect(languageDisplayName('page.tsx'), 'TSX');
      expect(languageDisplayName('Component.jsx'), 'JSX');
      expect(languageDisplayName('index.ts'), 'TypeScript');
      expect(languageDisplayName('main.dart'), 'Dart');
      expect(languageDisplayName('test.py'), 'Python');
      expect(languageDisplayName('data.json'), 'JSON');
      expect(languageDisplayName('config.yaml'), 'YAML');
    });
  });

  group('languageAccentColor', () {
    test('returns consistent accent colors', () {
      final tsColor = languageAccentColor('page.tsx');
      final dartColor = languageAccentColor('main.dart');
      final pyColor = languageAccentColor('script.py');
      expect(tsColor, isA<Color>());
      expect(dartColor, isA<Color>());
      expect(pyColor, isA<Color>());
    });
  });

  group('CodeViewer Widget', () {
    testWidgets('renders code with line numbers and syntax highlighter', (tester) async {
      const sampleCode = "import React from 'react';\nconst x = 1;\nconsole.log(x);";

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CodeViewer(
              code: sampleCode,
              filePath: 'test.tsx',
              showLineNumbers: true,
              isWordWrap: false,
            ),
          ),
        ),
      );

      expect(find.byType(HighlightView), findsOneWidget);
      // Line numbers gutter should contain line count representation
      expect(find.textContaining('1'), findsWidgets);
      expect(find.textContaining('2'), findsWidgets);
      expect(find.textContaining('3'), findsWidgets);
    });

    testWidgets('renders in word wrap mode', (tester) async {
      const sampleCode = "print('hello world')";

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CodeViewer(
              code: sampleCode,
              filePath: 'test.py',
              showLineNumbers: true,
              isWordWrap: true,
            ),
          ),
        ),
      );

      expect(find.byType(HighlightView), findsOneWidget);
    });
  });
}
