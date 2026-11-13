import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/rpc/models.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/screens/agent_screen.dart';
import 'package:nexuslink/src/state/agent_history.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A PC with one chat whose busy flag and history the test sets, to check
/// that the chat takes "running" from the host, not from what it saw before.
class RunningHost extends RpcClient {
  RunningHost() : super('ws://pc/rpc') {
    hostId = 'pc';
  }
  final handlers = <String, List<void Function(Map<String, dynamic>)>>{};
  final calls = <String>[];
  bool busy = false;
  String taskState = 'idle';

  /// Events the host holds for task-1, as stored (seq order).
  List<Map<String, dynamic>> history = [
    {'seq': 1, 'ts': 1, 'kind': 'user', 'text': 'Fix the login bug'},
  ];

  /// When set, `agent.listSessions` answers only after this completes, with
  /// the state it had when asked.
  Completer<void>? listGate;

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
    'agent': 'antigravity',
    'cwd': '/project',
    'title': 'Fix login',
    'busy': busy,
    'taskState': taskState,
  };

  @override
  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 10),
  ]) async {
    calls.add(method);
    switch (method) {
      case 'agent.list':
        return [
          {'id': 'antigravity', 'name': 'Antigravity', 'available': true},
        ];
      case 'agent.listSessions':
        final snapshot = session;
        if (listGate != null) await listGate!.future;
        return [snapshot];
      case 'agent.historyPage':
        return {'events': List.of(history), 'hasMore': false};
      case 'agent.pendingApprovals':
      case 'agent.listModels':
        return [];
      default:
        return null;
    }
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

class _Link extends Notifier<RpcStatus> {
  @override
  RpcStatus build() => RpcStatus.connected;
  void set(RpcStatus value) => state = value;
}

final _linkProvider = NotifierProvider<_Link, RpcStatus>(_Link.new);

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The chat screen on [pc]; open the task from the list unless [open].
Future<ProviderContainer> pumpChat(
  WidgetTester tester,
  RunningHost pc, {
  bool open = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeClientProvider.overrideWithValue(pc),
        connectionStatusProvider.overrideWith((ref) => ref.watch(_linkProvider)),
      ],
      child: MaterialApp(
        home: AgentScreen(initialTaskId: open ? 'task-1' : null),
      ),
    ),
  );
  await settle(tester);
  return ProviderScope.containerOf(tester.element(find.byType(AgentScreen)));
}

/// A socket drop and recovery, as the connection layer reports it.
Future<void> reconnect(WidgetTester tester, ProviderContainer c) async {
  c.read(_linkProvider.notifier).set(RpcStatus.disconnected);
  await tester.pump();
  c.read(_linkProvider.notifier).set(RpcStatus.connected);
  await settle(tester);
}

Future<void> teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('opening a chat', () {
    testWidgets(
      'shows Working… and Stop at once when the host says the turn runs, '
      'even if the phone last saw the chat idle',
      (tester) async {
        final pc = RunningHost();
        await pumpChat(tester, pc, open: false);
        expect(find.text('Fix login'), findsOneWidget);
        // The turn started while the phone was not listening.
        pc
          ..busy = true
          ..taskState = 'running';
        await tester.tap(find.text('Fix login'));
        await settle(tester);
        expect(find.text('Working…'), findsWidgets);
        expect(find.byTooltip('Stop'), findsWidgets);
        await teardown(tester);
      },
    );

    testWidgets(
      'shows nothing running, and the visible end, when the turn ended '
      'while the page was closed',
      (tester) async {
        final pc = RunningHost()
          ..busy = true
          ..taskState = 'running';
        await pumpChat(tester, pc, open: false);
        // The list still says Working; then the turn ends unnoticed.
        pc
          ..busy = false
          ..taskState = 'failed'
          ..history = [
            ...pc.history,
            {
              'seq': 2,
              'ts': 2,
              'kind': 'error',
              'text': 'Antigravity ended unexpectedly: it exited without a reply.',
            },
          ];
        await tester.tap(find.text('Fix login'));
        await settle(tester);
        expect(find.text('Working…'), findsNothing);
        expect(find.byTooltip('Stop'), findsNothing);
        expect(find.textContaining('ended unexpectedly'), findsWidgets);
        await teardown(tester);
      },
    );
  });

  group('while the chat is open', () {
    testWidgets('a session update that says busy turns Working… on', (
      tester,
    ) async {
      final pc = RunningHost();
      await pumpChat(tester, pc);
      expect(find.text('Working…'), findsNothing);
      pc
        ..busy = true
        ..taskState = 'running';
      pc.emit('agent-session-update', {'session': pc.session});
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Working…'), findsWidgets);
      pc.busy = false;
      pc.emit('agent-session-update', {'session': pc.session});
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Working…'), findsNothing);
      await teardown(tester);
    });

    testWidgets(
      'a reconnect after missed updates shows the true state both ways, '
      'including the end the phone never saw',
      (tester) async {
        final pc = RunningHost();
        final c = await pumpChat(tester, pc);
        expect(find.text('Working…'), findsNothing);

        // Socket was down while the turn started.
        pc
          ..busy = true
          ..taskState = 'running';
        await reconnect(tester, c);
        expect(find.text('Working…'), findsWidgets);
        expect(find.byTooltip('Stop'), findsWidgets);

        // Down again while it ended with an error.
        pc
          ..busy = false
          ..taskState = 'failed'
          ..history = [
            ...pc.history,
            {
              'seq': 2,
              'ts': 2,
              'kind': 'error',
              'text': 'Antigravity stopped without saying why.',
            },
          ];
        await reconnect(tester, c);
        expect(find.text('Working…'), findsNothing);
        expect(find.byTooltip('Stop'), findsNothing);
        expect(find.textContaining('stopped without saying why'), findsWidgets);
        await teardown(tester);
      },
    );

    testWidgets(
      'a snapshot taken before the turn ended cannot bring Working… back',
      (tester) async {
        final pc = RunningHost()
          ..busy = true
          ..taskState = 'running';
        final c = await pumpChat(tester, pc);
        expect(find.text('Working…'), findsWidgets);

        pc.listGate = Completer<void>();
        c.read(_linkProvider.notifier).set(RpcStatus.disconnected);
        await tester.pump();
        c.read(_linkProvider.notifier).set(RpcStatus.connected);
        await tester.pump(const Duration(milliseconds: 100));
        // The host answered "busy", then the result arrived live ...
        pc.emit('agent-event', {
          'agentSessionId': 'task-1',
          'event': {'seq': 2, 'ts': 2, 'kind': 'result', 'text': 'All done'},
        });
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Working…'), findsNothing);
        // ... and only now does the older answer reach the phone.
        pc
          ..busy = false
          ..history = [
            ...pc.history,
            {'seq': 2, 'ts': 2, 'kind': 'result', 'text': 'All done'},
          ];
        pc.listGate!.complete();
        await settle(tester);
        expect(find.text('Working…'), findsNothing);
        expect(find.byTooltip('Stop'), findsNothing);
        await teardown(tester);
      },
    );
  });

  test('a snapshot never drops live events the phone already shows', () {
    final live = [
      AgentEvent(seq: 1, ts: 1, kind: 'user', text: 'go'),
      AgentEvent(seq: 2, ts: 2, kind: 'error', text: 'ended'),
    ];
    final merged = applyAgentHistorySnapshot(
      [AgentEvent(seq: 1, ts: 1, kind: 'user', text: 'go')],
      live,
      busy: false,
    );
    expect(merged.map((e) => e.kind), ['user', 'error']);
  });
}
