import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/rpc/models.dart';
import 'package:nexuslink/src/widgets/file_viewer_modal.dart';

void main() {
  group('isModelEffortSupported', () {
    test('antigravity: gemini models support effort, non-gemini models do not', () {
      expect(isModelEffortSupported('antigravity', 'gemini-3.7-flash'), isTrue);
      expect(isModelEffortSupported('antigravity', 'gemini-3.1-pro'), isTrue);
      expect(isModelEffortSupported('antigravity', 'claude-sonnet-4-6'), isFalse);
      expect(isModelEffortSupported('antigravity', 'claude-opus-4-6'), isFalse);
      expect(isModelEffortSupported('antigravity', 'gpt-oss-120b'), isFalse);
      expect(isModelEffortSupported('antigravity', 'default'), isTrue);
      expect(isModelEffortSupported('antigravity', null), isTrue);
    });

    test('claude: sonnet supports effort, opus and haiku do not', () {
      expect(isModelEffortSupported('claude', 'sonnet'), isTrue);
      expect(isModelEffortSupported('claude', 'claude-3-7-sonnet'), isTrue);
      expect(isModelEffortSupported('claude', 'default'), isTrue);
      expect(isModelEffortSupported('claude', 'opus'), isFalse);
      expect(isModelEffortSupported('claude', 'haiku'), isFalse);
    });

    test('cursor: auto and non-reasoning models do not support effort, other models do', () {
      expect(isModelEffortSupported('cursor', 'auto'), isFalse);
      expect(isModelEffortSupported('cursor', 'claude-3-5-haiku'), isFalse);
      expect(isModelEffortSupported('cursor', 'composer-2.5'), isTrue);
      expect(isModelEffortSupported('cursor', 'gpt-5.3-codex'), isTrue);
    });

    test('opencode: reasoning models support variants/effort', () {
      expect(isModelEffortSupported('opencode', 'opencode/deepseek-v4-flash-free'), isTrue);
      expect(isModelEffortSupported('opencode', 'opencode/big-pickle'), isTrue);
      expect(isModelEffortSupported('opencode', 'standard-non-reasoning'), isFalse);
    });

    test('mock: demo models support effort', () {
      expect(isModelEffortSupported('mock', 'demo'), isTrue);
      expect(isModelEffortSupported('mock', 'composer-2'), isTrue);
    });

    test('honors explicit supportsEffort in catalog', () {
      final catalog = [
        const AgentModelOption(id: 'custom-1', name: 'Custom One', supportsEffort: false),
        const AgentModelOption(id: 'custom-2', name: 'Custom Two', supportsEffort: true),
      ];
      expect(isModelEffortSupported('other', 'custom-1', catalog), isFalse);
      expect(isModelEffortSupported('other', 'custom-2', catalog), isTrue);
    });

    test('collapseModelFamilies preserves supportsEffort', () {
      final models = [
        const AgentModelOption(id: 'gemini-3.7-flash-high', name: 'Flash (High)', supportsEffort: true),
        const AgentModelOption(id: 'claude-sonnet-4-6', name: 'Claude Sonnet', supportsEffort: false),
      ];
      final collapsed = collapseModelFamilies(models);
      expect(collapsed.length, 2);
      expect(collapsed[0].id, 'gemini-3.7-flash');
      expect(collapsed[0].supportsEffort, isTrue);
      expect(collapsed[1].id, 'claude-sonnet-4-6');
      expect(collapsed[1].supportsEffort, isFalse);
    });
  });

  group('FileViewer helpers', () {
    test('cleanFilePath strips file:// and hash suffixes', () {
      expect(cleanFilePath('file:///home/user/plan.md'), '/home/user/plan.md');
      expect(cleanFilePath('file:///home/user/plan.md#L10-L20'), '/home/user/plan.md');
      expect(cleanFilePath('/tmp/test.dart'), '/tmp/test.dart');
    });

    test('isPathLike detects paths and code/markdown files', () {
      expect(isPathLike('file:///home/user/plan.md'), isTrue);
      expect(isPathLike('/home/user/plan.md'), isTrue);
      expect(isPathLike('~/projects/code.ts'), isTrue);
      expect(isPathLike('https://google.com'), isFalse);
      expect(isPathLike('just some plain text'), isFalse);
    });
  });
}
