import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/widgets/code_block_builder.dart';

void main() {
  group('cleanCopyMessage', () {
    test('unwraps single code block with language specifier', () {
      const input = '```text\n/mnt/shared/projects/mobile/opendesktop\n```';
      expect(cleanCopyMessage(input), '/mnt/shared/projects/mobile/opendesktop');
    });

    test('unwraps single code block without language', () {
      const input = '```\n/mnt/shared/projects/mobile/opendesktop\n```';
      expect(cleanCopyMessage(input), '/mnt/shared/projects/mobile/opendesktop');
    });

    test('unwraps multiline code block', () {
      const input = '```dart\nvoid main() {\n  print("hello");\n}\n```';
      expect(cleanCopyMessage(input), 'void main() {\n  print("hello");\n}');
    });

    test('preserves mixed content with surrounding text', () {
      const input =
          'Here is the path:\n```text\n/mnt/shared/projects/mobile/opendesktop\n```';
      expect(cleanCopyMessage(input), input);
    });

    test('preserves plain text without fences', () {
      const input = 'Hello, how can I help you today?';
      expect(cleanCopyMessage(input), input);
    });
  });
}
