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
  });
}
