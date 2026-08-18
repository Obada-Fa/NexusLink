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

    test('parses a host chat from the PC', () {
      final chat = AgentHostChat.fromJson({
        'agent': 'opencode',
        'hostChatId': 'ses_abc',
        'title': 'Fix login',
        'cwd': '/tmp/proj',
        'updatedAt': 1,
        'resumable': true,
        'source': 'OpenCode',
      });
      expect(chat.agent, 'opencode');
      expect(chat.hostChatId, 'ses_abc');
      expect(chat.resumable, isTrue);
      expect(chat.source, 'OpenCode');
    });
  });

  group('agent display grouping', () {
    AgentEvent ev(int seq, String kind,
            {String? name, String? ref, String? input, String? output}) =>
        AgentEvent(
          seq: seq,
          ts: seq,
          kind: kind,
          toolName: name,
          toolInput: input,
          toolOutput: output,
          refId: ref,
        );

    test('merges start/end and groups consecutive tools', () {
      final items = groupAgentDisplay([
        ev(1, 'user'),
        ev(2, 'tool-start', name: 'edit', ref: 'a', input: 'main.dart'),
        ev(3, 'tool-end', name: 'edit', ref: 'a', output: 'ok'),
        ev(4, 'tool-start', name: 'shell', ref: 'b'),
        ev(5, 'tool-end', name: 'shell', ref: 'b', output: 'failed'),
        ev(6, 'text'),
      ]);
      expect(items.length, 3);
      expect(items[0].event?.kind, 'user');
      expect(items[1].tools?.length, 2);
      expect(items[1].tools?.map((e) => e.kind).toList(),
          ['tool-end', 'tool-end']);
      expect(toolGroupTitle(items[1].tools!), '2 steps');
      expect(toolGroupSummary(items[1].tools!), 'edit · shell');
      expect(items[2].event?.kind, 'text');
    });

    test('keeps an in-flight tool in the same group', () {
      final items = groupAgentDisplay([
        ev(1, 'tool-end', name: 'edit', ref: 'a'),
        ev(2, 'tool-start', name: 'shell', ref: 'b'),
      ]);
      expect(items.length, 1);
      expect(toolGroupRunning(items[0].tools!), isTrue);
      expect(toolGroupTitle(items[0].tools!), 'Working… 2 steps');
    });

    test('merges consecutive text deltas into a single unified assistant message', () {
      final items = groupAgentDisplay([
        AgentEvent(seq: 1, ts: 1, kind: 'user', text: 'hello'),
        AgentEvent(seq: 2, ts: 2, kind: 'text-delta', text: 'Part 1: Hello '),
        AgentEvent(seq: 3, ts: 3, kind: 'text-delta', text: 'Part 2: world! '),
        AgentEvent(seq: 4, ts: 4, kind: 'text', text: 'Part 3: Done.'),
      ]);
      expect(items.length, 2);
      expect(items[0].event?.kind, 'user');
      expect(items[1].event?.kind, 'text');
      expect(items[1].event?.text, 'Part 1: Hello Part 2: world! Part 3: Done.');
    });
  });

  group('model families', () {
    test('strips thinking suffixes and collapses catalogs', () {
      expect(modelFamilyId('claude-opus-5-thinking-high'), 'claude-opus-5');
      expect(modelFamilyId('gemini-3.7-flash-high'), 'gemini-3.7-flash');
      expect(modelFamilyId('cursor-grok-4.6-xhigh-fast'), 'cursor-grok-4.6');
      expect(modelFamilyId('opencode/mimo-v2.5-free'), 'opencode/mimo-v2.5-free');

      final collapsed = collapseModelFamilies(const [
        AgentModelOption(id: 'gemini-3.7-flash-high', name: 'Gemini 3.7 Flash (High)'),
        AgentModelOption(id: 'gemini-3.7-flash-medium', name: 'Gemini 3.7 Flash (Medium)'),
        AgentModelOption(id: 'claude-opus-5-thinking-high', name: 'Claude Opus 5'),
      ]);
      expect(collapsed.map((m) => m.id).toList(), [
        'gemini-3.7-flash',
        'claude-opus-5',
      ]);
      expect(collapsed.first.name, 'Gemini 3.7 Flash');
    });
  });
}
