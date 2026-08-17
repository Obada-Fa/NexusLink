import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/rpc/models.dart';

void main() {
  group('AppSessionInfo', () {
    test('parses a running virtual session', () {
      final s = AppSessionInfo.fromJson({
        'sessionId': 'abc',
        'appId': 'nexus.chrome-mobile',
        'name': 'Browser',
        'display': ':51',
        'width': 390,
        'height': 844,
        'dpr': 2,
        'status': 'running',
      });
      expect(s.sessionId, 'abc');
      expect(s.width, 390);
      expect(s.status, 'running');
    });
  });

  group('AgentEvent', () {
    test('parses a tool-start / tool-end pair', () {
      final start = AgentEvent.fromJson({
        'seq': 2,
        'ts': 1,
        'kind': 'tool-start',
        'toolName': 'Shell',
        'toolInput': '{"command":"echo"}',
        'refId': 't1',
      });
      final end = AgentEvent.fromJson({
        'seq': 3,
        'ts': 2,
        'kind': 'tool-end',
        'refId': 't1',
        'toolOutput': 'ok',
      });
      expect(start.kind, 'tool-start');
      expect(start.toolName, 'Shell');
      expect(end.refId, start.refId);
      expect(end.toolOutput, 'ok');
    });

    test('parses composer capabilities and attached photo names', () {
      final agent = AgentInfo.fromJson({
        'id': 'cursor',
        'name': 'Cursor CLI',
        'available': true,
        'capabilities': {
          'modes': ['agent', 'plan', 'ask'],
          'thinkingLevels': ['low', 'medium', 'high'],
          'models': [
            {'id': 'auto', 'name': 'Auto'},
            {'id': 'gpt-5', 'name': 'GPT-5'},
          ],
          'images': true,
        },
      });
      expect(agent.capabilities.images, isTrue);
      expect(agent.capabilities.modes, ['agent', 'plan', 'ask']);
      expect(agent.capabilities.models.first.name, 'Auto');

      final oldHost = AgentInfo.fromJson({'id': 'mock', 'name': 'Demo'});
      expect(oldHost.capabilities.images, isFalse);
      expect(oldHost.capabilities.modes, ['agent']);

      final user = AgentEvent.fromJson({
        'seq': 1,
        'ts': 1,
        'kind': 'user',
        'text': 'look',
        'images': ['shot.jpg'],
      });
      expect(user.images, ['shot.jpg']);
    });
  });
}
