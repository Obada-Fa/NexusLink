import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/chats/chat_models.dart';

ChatSummary chat(
  String id, {
  String execution = 'idle',
  Map<String, dynamic>? live,
  String? parentId,
  String? cleared,
  int at = 100,
}) => ChatSummary({
  'id': id,
  'hostId': 'pc',
  'source': 'claude',
  'title': id,
  'execution': execution,
  'activityAt': at,
  'live': ?live,
  'parentId': ?parentId,
  'attentionCleared': ?cleared,
});

void main() {
  test('an after-turn ask is your turn, not needs-you', () {
    final c = chat(
      'asks',
      live: {'state': 'done', 'ask': 'Should I commit it?'},
    );
    expect(c.needsAttention, isFalse);
    expect(c.yourTurn, isTrue);
    expect(c.liveState, 'turn');
    expect(c.monitorSection, 'Your turn');
    expect(c.monitorStatus, 'Your turn');
    expect(c.stepLabel, 'Should I commit it?');
  });

  test("a worker's ask is its orchestrator's, so it is just done", () {
    final c = chat(
      'worker',
      parentId: 'pc:claude:boss',
      live: {'state': 'done', 'ask': 'Should I commit it?'},
    );
    expect(c.isWorker, isTrue);
    expect(c.yourTurn, isFalse);
    expect(c.needsAttention, isFalse);
    expect(c.liveState, 'done');
    expect(c.monitorStatus, 'Reported to its orchestrator');
  });

  test('a blocked worker still needs you: only you can approve its tools', () {
    final c = chat(
      'worker',
      execution: 'needsReply',
      parentId: 'pc:claude:boss',
      live: {
        'state': 'waiting',
        'waitKind': 'approval',
        'waitingFor': 'Approve: rm -rf build',
      },
    );
    expect(c.needsAttention, isTrue);
    expect(c.liveState, 'waiting');
    expect(c.monitorStatus, 'Needs approval');
  });

  test('wait kinds and guesses read differently', () {
    String status(Map<String, dynamic> live) => chat(
      'x',
      execution: 'needsReply',
      live: {'state': 'waiting', ...live},
    ).monitorStatus;
    expect(status({'waitKind': 'question'}), 'Asking you');
    expect(status({'waitKind': 'plan'}), 'Plan to approve');
    expect(status({'waitKind': 'approval'}), 'Needs approval');
    expect(
      status({'waitKind': 'approval', 'via': 'transcript-heuristic'}),
      'Probably needs approval',
    );
    expect(status({}), 'Waiting for you');
  });

  test('a dismissed ask is plain done', () {
    final c = chat('asks', cleared: 'acknowledged', live: {'state': 'done'});
    expect(c.yourTurn, isFalse);
    expect(c.liveState, 'done');
  });

  test('sort order: needs you, your turn, running, recent', () {
    final rows = [
      chat('recent', at: 400),
      chat(
        'running',
        execution: 'working',
        live: {'state': 'working'},
        at: 300,
      ),
      chat('turn', live: {'state': 'done', 'ask': 'Push?'}, at: 200),
      chat(
        'blocked',
        execution: 'needsReply',
        live: {'state': 'waiting'},
        at: 100,
      ),
    ]..sort(compareMonitorChats);
    expect(rows.map((c) => c.id), ['blocked', 'turn', 'running', 'recent']);
  });

  test('sub-agents parse with their state and step', () {
    final c = chat(
      'boss',
      execution: 'working',
      live: {
        'state': 'working',
        'subagents': [
          {
            'name': 'Deploy check',
            'kind': 'general-purpose',
            'state': 'waiting',
            'step': 'Approve: deploy',
            'updatedAt': 5,
          },
          {'name': 'Read changelog', 'state': 'done'},
          {'state': 'done'},
        ],
      },
    );
    final subs = c.live!.subagents;
    expect(subs.map((s) => s.name), ['Deploy check', 'Read changelog']);
    expect(subs.first.kind, 'general-purpose');
    expect(subs.first.state, 'waiting');
    expect(subs.first.step, 'Approve: deploy');
    expect(subs.last.kind, isNull);
  });
}
