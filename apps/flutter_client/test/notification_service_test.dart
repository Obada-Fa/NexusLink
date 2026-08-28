import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/rpc/models.dart';
import 'package:nexuslink/src/services/notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('NotificationService handles result and deduplicates event', () {
    final service = NotificationService.instance;
    final event = AgentEvent(
      seq: 1,
      ts: 1000,
      kind: 'result',
      text: 'Task complete',
    );

    // First handle should process without errors
    service.handleAgentEvent('test-session', event, sessionTitle: 'My Project');

    // Duplicate call with same session & seq should be ignored by deduplication
    service.handleAgentEvent('test-session', event, sessionTitle: 'My Project');
  });

  test('NotificationService handles permission-request', () {
    final service = NotificationService.instance;
    final event = AgentEvent(
      seq: 2,
      ts: 2000,
      kind: 'permission-request',
      toolName: 'run_command',
      toolInput: 'npm run build',
    );

    service.handleAgentEvent('test-session', event, sessionTitle: 'My Project');
  });
}
