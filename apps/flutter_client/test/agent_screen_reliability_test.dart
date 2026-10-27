import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/chats/chat_models.dart';
import 'package:nexuslink/src/rpc/models.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/screens/agent_screen.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:shared_preferences/shared_preferences.dart';

AgentEvent host(int seq, String kind, {String? text, String? ref}) =>
    AgentEvent(
      seq: seq,
      ts: seq,
      kind: kind,
      text: text,
      toolName: ref == null ? null : 'Bash',
      refId: ref,
    );

/// Minimal PC host for AgentScreen: one busy task with an open tool.
class AgentHost extends RpcClient {
  AgentHost({this.busy = true}) : super('ws://pc/rpc') {
    hostId = 'pc';
  }
  final calls = <String>[];
  final handlers = <String, List<void Function(Map<String, dynamic>)>>{};
  final cancel = Completer<dynamic>();
  bool busy;

  @override
  RpcStatus get status => RpcStatus.connected;
  @override
  bool supports(String feature) =>
      feature == 'agent.historyPage' || feature == 'agent.pendingApprovals';
  @override
  void Function() subscribe(
    String topic,
    void Function(Map<String, dynamic>) callback,
  ) {
    final list = handlers.putIfAbsent(topic, () => [])..add(callback);
    return () => list.remove(callback);
  }

  void emit(String topic, Map<String, dynamic> msg) {
    for (final cb in List.of(handlers[topic] ?? [])) {
      cb(msg);
    }
  }

  Map<String, dynamic> get session => {
    'agentSessionId': 'task-1',
    'agent': 'claude',
    'cwd': '/project',
    'title': 'Fix login',
    'busy': busy,
    'taskState': busy ? 'running' : 'idle',
  };

  @override
  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 10),
  ]) async {
    calls.add(method);
    return switch (method) {
      'agent.list' => [
        {'id': 'claude', 'name': 'Claude Code', 'available': true},
      ],
      'agent.listSessions' => [session],
      'agent.historyPage' => {
        'events': [
          {'seq': 1, 'ts': 1, 'kind': 'user', 'text': 'Fix the login bug'},
          {
            'seq': 2,
            'ts': 2,
            'kind': 'tool-start',
            'toolName': 'Bash',
            'refId': 't1',
          },
        ],
        'hasMore': false,
      },
      'agent.pendingApprovals' => [],
      'agent.listModels' => [],
      'agent.cancel' => await cancel.future,
      _ => null,
    };
  }

  @override
  Future<Map<String, dynamic>> requestMap(
    String method, [
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 10),
  ]) async => expectMap(await request(method, params, timeout), method);

  @override
  Future<List<dynamic>> requestList(
    String method, [
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 10),
  ]) async => expectList(await request(method, params, timeout), method);
}

Future<AgentHost> pumpTask(WidgetTester tester, {bool busy = true}) async {
  final pc = AgentHost(busy: busy);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeClientProvider.overrideWithValue(pc),
        connectionStatusProvider.overrideWithValue(RpcStatus.connected),
      ],
      child: const MaterialApp(home: AgentScreen(initialTaskId: 'task-1')),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return pc;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('transcript key spaces', () {
    test('a phone note never swallows the host event with the next seq', () {
      final transcript = AgentTranscript()
        ..replaceHost([
          host(1, 'user', text: 'hi'),
          host(2, 'text', text: 'a'),
        ]);
      // The old code gave this note seq = length + 1 = 3 ...
      transcript.note('status', 'Model set to Opus');
      // ... so the host's real seq 3 was deduped away.
      expect(transcript.addHost(host(3, 'text', text: 'host reply')), isTrue);
      expect(transcript.host.map((e) => e.seq), [1, 2, 3]);
      expect(transcript.display.map((e) => e.text), [
        'hi',
        'a',
        'Model set to Opus',
        'host reply',
      ]);
      expect(
        transcript.display.where((e) => e.seq == 3).single.text,
        'host reply',
      );
    });

    test('replayed host events are still deduplicated by host seq', () {
      final transcript = AgentTranscript()..addHost(host(5, 'text', text: 'x'));
      expect(transcript.addHost(host(5, 'text', text: 'x')), isFalse);
      expect(transcript.host, hasLength(1));
      transcript.addOlder([host(4, 'user'), host(5, 'text')]);
      expect(transcript.host.map((e) => e.seq), [4, 5]);
      expect(transcript.latestHostSeq, 5);
      expect(transcript.oldestHostSeq, 4);
    });

    test('a phone-side stop settlement yields to the host’s real tool end', () {
      final transcript = AgentTranscript()
        ..replaceHost([host(1, 'tool-start', ref: 't1')]);
      expect(transcript.hasOpenTools, isTrue);
      transcript.settleOpenTools('Stopped.');
      expect(transcript.hasOpenTools, isFalse);
      // The host later reports its own end for the same tool.
      transcript.addHost(host(2, 'tool-end', ref: 't1'));
      final ends = transcript.display.where((e) => e.kind == 'tool-end');
      expect(ends.map((e) => e.seq), [2]);
      expect(transcript.hasOpenTools, isFalse);
    });
  });

  group('stop outcome', () {
    test('reports what the PC actually did', () {
      expect(describeStopResult({'ok': true}).state, StopState.stopped);
      expect(describeStopResult({'ok': true}).ended, isTrue);
      expect(describeStopResult({'ok': false}).state, StopState.notRunning);
      final unsupported = describeStopResult({'ok': false}, library: true);
      expect(unsupported.state, StopState.unsupported);
      expect(unsupported.ended, isFalse);
      final failed = describeStopResult(
        null,
        error: RpcException('request timeout: agent.cancel'),
      );
      expect(failed.state, StopState.failed);
      expect(failed.ended, isFalse);
      expect(failed.message, contains('may still be running'));
    });

    testWidgets('Stop shows Stopping… until the PC confirms', (tester) async {
      final pc = await pumpTask(tester);
      expect(find.text('Working…'), findsWidgets);
      await tester.tap(find.byTooltip('Stop').last);
      await tester.pump();
      expect(pc.calls, contains('agent.cancel'));
      expect(find.text('Stopping…'), findsOneWidget);
      expect(find.text('Stopped.'), findsNothing);

      pc.busy = false;
      pc.cancel.complete({'ok': true});
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Stopping…'), findsNothing);
      expect(find.text('Working…'), findsNothing);
      expect(find.text('Stopped.'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a failed stop says so and keeps the task running', (
      tester,
    ) async {
      final pc = await pumpTask(tester);
      await tester.tap(find.byTooltip('Stop').last);
      await tester.pump();
      pc.cancel.completeError(RpcException('connection closed'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Working…'), findsWidgets);
      expect(find.text('Stopping…'), findsNothing);
      expect(find.textContaining('Couldn’t stop the agent'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a live host event with seq after a phone note is shown', (
      tester,
    ) async {
      final pc = await pumpTask(tester, busy: false);
      // Slash commands answer with phone-only notes. With two host events on
      // screen the old code numbered this note seq 3.
      await tester.enterText(find.byType(TextField).last, '/plan');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Mode: Plan'), findsOneWidget);
      pc.emit('agent-event', {
        'agentSessionId': 'task-1',
        'event': {'seq': 3, 'ts': 3, 'kind': 'text', 'text': 'Host says hi'},
      });
      await tester.pump();
      expect(find.text('Host says hi'), findsOneWidget);
      expect(find.text('Mode: Plan'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('live header', () {
    testWidgets('renders step, elapsed time, todos and waiting callout', (
      tester,
    ) async {
      final start = DateTime(2026, 10, 20, 12);
      final live = ChatLive({
        'state': 'waiting',
        'step': 'Running: npm test',
        'turnStartedAt': start.millisecondsSinceEpoch,
        'waitingFor': 'Approve: rm -rf build',
        'model': 'opus',
        'steps': 12,
        'todos': [
          {'text': 'Reproduce bug', 'state': 'done'},
          {'text': 'Fix login', 'state': 'active'},
          {'text': 'Add test', 'state': 'pending'},
        ],
      });
      expect(ChatLiveHeader.shows(live), isTrue);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatLiveHeader(
              live: live,
              now: () => start.add(const Duration(minutes: 4, seconds: 12)),
            ),
          ),
        ),
      );
      expect(find.text('Running: npm test'), findsOneWidget);
      expect(find.text('4m 12s'), findsOneWidget);
      expect(find.text('Approve: rm -rf build'), findsOneWidget);
      expect(find.text('1/3'), findsOneWidget);
      expect(find.text('opus · 12 steps'), findsOneWidget);
      expect(find.text('Fix login'), findsNothing);
      await tester.tap(find.text('1/3'));
      await tester.pump();
      expect(find.text('Fix login'), findsOneWidget);
      expect(find.text('Add test'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    test('stays hidden for idle chats and older hosts without live', () {
      expect(ChatLiveHeader.shows(null), isFalse);
      expect(ChatLiveHeader.shows(ChatLive({'state': 'idle'})), isFalse);
      expect(ChatLiveHeader.shows(ChatLive({'state': 'done'})), isFalse);
      expect(ChatLiveHeader.shows(ChatLive({'state': 'working'})), isTrue);
      final summary = ChatSummary({
        'id': 'c',
        'hostId': 'pc',
        'live': {'state': 'working', 'step': 'Editing lib/main.dart'},
      });
      expect(summary.live?.step, 'Editing lib/main.dart');
    });
  });
}
