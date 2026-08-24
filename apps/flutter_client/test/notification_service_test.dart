import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/rpc/models.dart';
import 'package:nexuslink/src/services/notification_service.dart';
import 'package:nexuslink/src/services/ntfy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generateNtfyTopic is 32-hex and stable with a seed', () {
    final topic = generateNtfyTopic(Random(1));
    expect(isNtfyTopic(topic), isTrue);
    expect(generateNtfyTopic(Random(1)), topic);
    expect(isNtfyTopic('nexuslink_device_123'), isFalse);
  });

  test('ntfyRegistrationPayload includes provider and endpoint', () {
    const topic = 'nexuslink-0123456789abcdef0123456789abcdef';
    final payload = ntfyRegistrationPayload(
      topic: topic,
      deviceName: 'Android Device',
    );
    expect(payload['token'], topic);
    expect(payload['provider'], 'ntfy');
    expect(payload['endpoint'], 'https://ntfy.sh/$topic');
    expect(payload['name'], 'Android Device');
    expect(ntfyEndpointForTopic(topic), 'https://ntfy.sh/$topic');
  });

  test('parseNtfyPayload reads nested JSON message from SSE', () {
    const sse = '''
{"id":"abc","event":"message","topic":"t","title":"outer","message":"{\\"title\\":\\"Agent Done\\",\\"body\\":\\"shipped\\",\\"agentSessionId\\":\\"s1\\",\\"sessionTitle\\":\\"App\\",\\"kind\\":\\"result\\",\\"seq\\":\\"7\\"}"}
''';
    final parsed = parseNtfyPayload(sse);
    expect(parsed, isNotNull);
    expect(parsed!.title, 'Agent Done');
    expect(parsed.body, 'shipped');
    expect(parsed.agentSessionId, 's1');
    expect(parsed.sessionTitle, 'App');
    expect(parsed.kind, 'result');
    expect(parsed.seq, 7);
  });

  test('parseNtfyPayload ignores keepalive events', () {
    expect(parseNtfyPayload('{"event":"keepalive"}'), isNull);
    expect(parseNtfyPayload('{"event":"open"}'), isNull);
  });

  test('agentEventKey matches NotificationService dedup key', () {
    expect(agentEventKey('s', 3, 'result'), 's_3_result');
  });

  test('NotificationService handles result and deduplicates event', () {
    final service = NotificationService.instance;
    final event = AgentEvent(
      seq: 1,
      ts: 1000,
      kind: 'result',
      text: 'Task complete',
    );

    service.handleAgentEvent('test-session', event, sessionTitle: 'My Project');
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

  test('applyNtfyPayload reuses handleAgentEvent dedup', () {
    final service = NotificationService.instance;
    const payload = NtfyPayload(
      title: 'Agent Done',
      body: 'done',
      agentSessionId: 'dup-session',
      sessionTitle: 'Proj',
      kind: 'result',
      seq: 9,
    );
    service.applyNtfyPayload(payload);
    service.applyNtfyPayload(payload);
  });
}
