import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/agents/subagent_widgets.dart';
import 'package:nexuslink/src/rpc/models.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/screens/agent_screen.dart';
import 'package:nexuslink/src/services/notification_service.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'subagents_test.dart'
    show background, bgId, foreground, fgId, nested, innerId, outerId;

/// Numbered events as the host stores them.
List<Map<String, dynamic>> stored(
  List<Map<String, dynamic>> rows, {
  int from = 1,
}) => [
  for (var i = 0; i < rows.length; i++)
    {'seq': from + i, 'ts': 1000 + from + i, ...rows[i]},
];

const sonnetLevels = ['low', 'medium', 'high', 'ultracode'];

/// A PC with one Code Agent chat whose history and session state the test
/// controls.
class SubagentHost extends RpcClient {
  SubagentHost({
    required this.history,
    this.busy = false,
    this.runningAgents = 0,
    List<Map<String, dynamic>>? models,
  }) : models =
           models ??
           [
             {
               'id': 'sonnet',
               'name': 'Sonnet',
               'supportsEffort': true,
               'thinkingLevels': sonnetLevels,
             },
             {'id': 'opus', 'name': 'Opus', 'supportsEffort': false},
             {'id': 'plain', 'name': 'Plain', 'supportsEffort': true},
           ],
       super('ws://pc/rpc') {
    hostId = 'pc';
  }

  final List<Map<String, dynamic>> history;
  final List<Map<String, dynamic>> models;
  bool busy;
  int runningAgents;
  final calls = <String, List<Map<String, dynamic>>>{};
  final handlers = <String, List<void Function(Map<String, dynamic>)>>{};

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

  var _seq = 1000;

  /// Pushes one live event (seq after the stored history).
  void push(Map<String, dynamic> event) => emit('agent-event', {
    'agentSessionId': 'task-1',
    'event': {'seq': ++_seq, 'ts': _seq, ...event},
  });

  void updateSession() =>
      emit('agent-session-update', {'session': Map.of(session)});

  Map<String, dynamic> get session => {
    'agentSessionId': 'task-1',
    'agent': 'claude',
    'cwd': '/project',
    'title': 'Agents demo',
    'busy': busy,
    'taskState': busy ? 'running' : 'completed',
    'runningAgents': runningAgents,
  };

  @override
  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 10),
  ]) async {
    calls.putIfAbsent(method, () => []).add(params);
    return switch (method) {
      'agent.list' => [
        {
          'id': 'claude',
          'name': 'Code Agent',
          'available': true,
          'capabilities': {
            'modes': ['agent', 'plan'],
            'thinkingLevels': ['low', 'medium', 'high'],
            'models': models,
            'images': true,
          },
        },
      ],
      'agent.listSessions' => [session],
      'agent.historyPage' => {
        'events': [
          for (final e in history)
            if ((e['seq'] as int) > ((params['afterSeq'] as int?) ?? 0)) e,
        ],
        'hasMore': false,
      },
      'agent.pendingApprovals' => [
        for (final e in history)
          if (e['kind'] == 'permission-request') e,
      ],
      'agent.listModels' => models,
      'agent.permission' => {'ok': true},
      'agent.prompt' => {'ok': true},
      'agent.cancel' => {'ok': true},
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

Future<void> frames(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<SubagentHost> pumpChat(
  WidgetTester tester,
  SubagentHost pc, {
  ThemeData? theme,
  Widget Function(Widget child)? wrap,
}) async {
  tester.view.physicalSize = const Size(412, 915) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final app = ProviderScope(
    overrides: [
      activeClientProvider.overrideWithValue(pc),
      connectionStatusProvider.overrideWithValue(RpcStatus.connected),
    ],
    child: MaterialApp(
      theme: theme,
      debugShowCheckedModeBanner: false,
      home: const AgentScreen(initialTaskId: 'task-1'),
    ),
  );
  await tester.pumpWidget(wrap == null ? app : wrap(app));
  await frames(tester);
  return pc;
}

Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

Finder chip(String id) => find.byKey(ValueKey('subagent-chip-$id'));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('main chat hides sub-agent events and shows a live spawn card', (
    tester,
  ) async {
    // Background agent up to the first result: still running.
    final pc = await pumpChat(
      tester,
      SubagentHost(
        history: stored(background.take(11).toList()),
        runningAgents: 1,
      ),
    );
    expect(find.text('launched'), findsOneWidget);
    // The sub-agent's own Bash call is not a main-chat card.
    expect(find.textContaining('sleep 5 && echo e2e-done'), findsNothing);
    // The Agent call shows the agent's state, not "Finished".
    final card = find.byKey(const ValueKey('subagent-card-$bgId'));
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.text('Running')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.text('Running Sleep 5 seconds then echo marker'),
      ),
      findsOneWidget,
    );
    // The sub-agent's text arrives live: not a bubble in the main chat.
    pc.push({'kind': 'text', 'text': 'sub-agent says hi', 'agentId': bgId});
    await frames(tester, 3);
    expect(find.text('sub-agent says hi'), findsNothing);
    await unmount(tester);
  });

  testWidgets('composer stays enabled while background agents run', (
    tester,
  ) async {
    await pumpChat(
      tester,
      SubagentHost(
        history: stored(background.take(11).toList()),
        runningAgents: 1,
      ),
    );
    final field = tester.widget<TextField>(find.byType(TextField).last);
    expect(field.enabled, isTrue);
    expect(find.text('Working…'), findsNothing);
    // The sub-agent's open tool never turns Send into Stop.
    expect(find.byTooltip('Send'), findsOneWidget);
    expect(find.byTooltip('Stop'), findsNothing);
    expect(find.bySemanticsLabel(RegExp('1 agent running')), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('strip shows running agents first, nested after the parent', (
    tester,
  ) async {
    // Nested pair running, plus an already finished foreground agent in the
    // same turn.
    final pc = await pumpChat(
      tester,
      SubagentHost(
        history: stored([...foreground.take(6), ...nested.skip(1).take(6)]),
        runningAgents: 2,
      ),
    );
    expect(find.byKey(const ValueKey('subagent-strip')), findsOneWidget);
    final xs = [
      for (final id in [outerId, innerId, fgId]) tester.getTopLeft(chip(id)).dx,
    ];
    expect(xs[0], lessThan(xs[1]));
    expect(xs[1], lessThan(xs[2]));
    // The nested chip is marked as started by another agent.
    expect(
      find.descendant(
        of: chip(innerId),
        matching: find.byIcon(Icons.subdirectory_arrow_right),
      ),
      findsOneWidget,
    );
    // Ended agents read their state as a word.
    expect(
      find.descendant(of: chip(fgId), matching: find.text('Done')),
      findsOneWidget,
    );
    // A new prompt with nothing running hides the strip.
    pc.push({...nested[8], 'kind': 'agent-end'});
    pc.push({...nested[10], 'kind': 'agent-end'});
    pc.runningAgents = 0;
    pc.updateSession();
    pc.push({'kind': 'user', 'text': 'next question'});
    await frames(tester, 3);
    expect(find.byKey(const ValueKey('subagent-strip')), findsNothing);
    await unmount(tester);
  });

  testWidgets('agent view works from records alone and updates live', (
    tester,
  ) async {
    final pc = await pumpChat(
      tester,
      SubagentHost(
        history: stored(foreground.take(4).toList()),
        busy: true,
        runningAgents: 1,
      ),
    );
    await tester.tap(chip(fgId));
    await frames(tester, 8);
    final view = find.byKey(const ValueKey('subagent-view-$fgId'));
    expect(view, findsOneWidget);
    expect(
      find.descendant(of: view, matching: find.text('Reply with pong')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: view, matching: find.text('general-purpose')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: view, matching: find.text('Starting…')),
      findsOneWidget,
    );
    // The task can be read in full (the test font wraps it to more than two
    // lines, so it starts collapsed here).
    final prompt = find.byKey(const ValueKey('subagent-prompt'));
    await tester.tap(prompt);
    await tester.pump();
    expect(
      find.descendant(of: prompt, matching: find.byType(SelectableText)),
      findsOneWidget,
    );
    // Live: the agent ends while the view is open.
    pc.push({...foreground[4]});
    await frames(tester, 4);
    expect(
      find.descendant(of: view, matching: find.text('RESULT')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: view, matching: find.text('pong')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: view, matching: find.text('Done')),
      findsOneWidget,
    );
    await unmount(tester);
  });

  testWidgets('a long task is collapsed until tapped', (tester) async {
    await pumpChat(
      tester,
      SubagentHost(
        history: stored([
          {'kind': 'user', 'text': 'go'},
          {
            'kind': 'agent-start',
            'agentId': 'long',
            'refId': 'spawn-long',
            'agentName': 'Long task',
            'agentDepth': 1,
            'agentBackground': true,
            'agentStatus': 'running',
            'agentPrompt': List.filled(40, 'Read every file twice.').join(' '),
          },
        ]),
        runningAgents: 1,
      ),
    );
    await tester.tap(chip('long'));
    await frames(tester, 8);
    // Its steps are not streamed: the view says so instead of looking empty.
    expect(
      find.textContaining('steps are not sent to the phone'),
      findsOneWidget,
    );
    final prompt = find.byKey(const ValueKey('subagent-prompt'));
    expect(
      find.descendant(of: prompt, matching: find.byType(SelectableText)),
      findsNothing,
    );
    await tester.tap(prompt);
    await tester.pump();
    expect(
      find.descendant(of: prompt, matching: find.byType(SelectableText)),
      findsOneWidget,
    );
    await unmount(tester);
  });

  testWidgets('nested agents are reachable from the parent view', (
    tester,
  ) async {
    await pumpChat(
      tester,
      SubagentHost(history: stored(nested.take(8).toList()), busy: true),
    );
    await tester.tap(chip(outerId));
    await frames(tester, 8);
    // The parent's streamed spawn call is the child's card.
    final childCard = find.byKey(const ValueKey('subagent-card-$innerId'));
    await tester.ensureVisible(childCard.last);
    await tester.tap(childCard.last);
    await frames(tester, 4);
    final view = find.byKey(const ValueKey('subagent-view-$innerId'));
    expect(view, findsOneWidget);
    expect(
      find.descendant(
        of: view,
        matching: find.text('Started by Nested sub-agent test'),
      ),
      findsOneWidget,
    );
    // Back returns to the parent.
    await tester.tap(find.byTooltip('Back'));
    await frames(tester, 4);
    expect(
      find.byKey(const ValueKey('subagent-view-$outerId')),
      findsOneWidget,
    );
    await unmount(tester);
  });

  testWidgets('a sub-agent permission request is answered in the main chat', (
    tester,
  ) async {
    final pc = await pumpChat(
      tester,
      SubagentHost(history: stored(nested.take(8).toList()), busy: true),
    );
    expect(find.text('From agent: Run python one-liner'), findsOneWidget);
    await tester.ensureVisible(find.text('Allow').first);
    await tester.tap(find.text('Allow').first);
    await frames(tester, 3);
    expect(
      pc.calls['agent.permission']?.single['requestId'],
      '237436a0-0e7c-46c9-abec-6aedd49d8fe5',
    );
    await unmount(tester);
  });

  testWidgets('open main tools are not settled while agents run', (
    tester,
  ) async {
    final history = stored([
      {'kind': 'user', 'text': 'go'},
      {'kind': 'tool-start', 'toolName': 'Bash', 'refId': 'main-1'},
      {
        'kind': 'tool-start',
        'toolName': 'Read',
        'refId': 'sub-1',
        'agentId': bgId,
      },
      {
        'kind': 'agent-start',
        'agentId': bgId,
        'refId': 'spawn',
        'agentName': 'Helper',
        'agentDepth': 1,
        'agentBackground': true,
        'agentStatus': 'running',
      },
      {'kind': 'result', 'text': ''},
    ]);
    await pumpChat(tester, SubagentHost(history: history, runningAgents: 1));
    // The main tool's group is still running (not settled).
    expect(find.text('Working…'), findsOneWidget);
    expect(find.text('Finished 1 step'), findsNothing);
    await unmount(tester);

    // Same chat with nothing running: the leftover main tool is settled,
    // the sub-agent's tool never is.
    final ended = [
      ...history,
      {
        'seq': 6,
        'ts': 6,
        'kind': 'agent-end',
        'agentId': bgId,
        'refId': 'spawn',
        'agentName': 'Helper',
        'agentDepth': 1,
        'agentBackground': true,
        'agentStatus': 'completed',
      },
    ];
    await pumpChat(tester, SubagentHost(history: ended));
    await tester.tap(find.text('Finished 1 step'));
    await frames(tester, 4);
    expect(find.text('Interrupted — host restarted.'), findsOneWidget);
    await unmount(tester);
  });

  test('no finished alert for a result while agents still run', () {
    final service = NotificationService.instance;
    AgentEvent ev(int seq, Map<String, dynamic> row) =>
        AgentEvent.fromJson({'seq': seq, 'ts': seq, ...row});
    service.observeAgentEvent('s1', ev(1, background[4]));
    expect(service.runningAgentsFor('s1'), 1);
    expect(service.agentName('s1', bgId), 'Run delayed echo command');
    expect(service.shouldAnnounceResult('s1'), isFalse);
    service.observeAgentEvent('s1', ev(2, background[13]));
    expect(service.shouldAnnounceResult('s1'), isTrue);
    // The host's count alone is enough too.
    expect(service.shouldAnnounceResult('s2', runningAgents: 2), isFalse);
    expect(service.shouldAnnounceResult('s2', runningAgents: 0), isTrue);
  });

  group('Ultra Code', () {
    Future<void> slash(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField).last, text);
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await frames(tester, 8);
    }

    testWidgets('offered only by a model that advertises it', (tester) async {
      final pc = await pumpChat(tester, SubagentHost(history: const []));
      await slash(tester, '/thinking');
      expect(find.text('Ultra Code'), findsOneWidget);
      expect(find.text('Runs at the highest effort level'), findsOneWidget);
      await tester.tap(find.text('Ultra Code'));
      await frames(tester, 6);

      await slash(tester, 'do it');
      expect(pc.calls['agent.prompt']!.last['thinking'], 'ultracode');
      pc.push({'kind': 'result', 'text': ''});
      await frames(tester, 2);

      // A model without Ultra Code falls back and says so.
      await slash(tester, '/model plain');
      expect(
        find.text('Plain has no Ultra Code. Thinking set to High.'),
        findsOneWidget,
      );
      await slash(tester, '/thinking');
      expect(find.byKey(const ValueKey('thinking-ultracode')), findsNothing);
      expect(find.byKey(const ValueKey('thinking-high')), findsOneWidget);
      await unmount(tester);
    });
  });

  testWidgets('strip stays usable with many agents', (tester) async {
    final rows = <Map<String, dynamic>>[
      {'kind': 'user', 'text': 'fan out'},
      for (var i = 0; i < 12; i++)
        {
          'kind': 'agent-start',
          'agentId': 'agent-$i',
          'refId': 'spawn-$i',
          'agentName': 'Worker number $i with a long name',
          'agentDepth': 1,
          'agentBackground': true,
          'agentStatus': 'running',
        },
      for (var i = 0; i < 4; i++)
        {
          'kind': 'agent-end',
          'agentId': 'agent-$i',
          'refId': 'spawn-$i',
          'agentName': 'Worker number $i with a long name',
          'agentDepth': 1,
          'agentBackground': true,
          'agentStatus': 'completed',
          'text': 'ok',
        },
    ];
    await pumpChat(
      tester,
      SubagentHost(history: stored(rows), runningAgents: 8),
    );
    expect(tester.takeException(), isNull);
    // Running agents come first even though agents 0–3 started earlier.
    final first = tester.getTopLeft(chip('agent-4')).dx;
    expect(first, lessThan(tester.getTopLeft(chip('agent-0')).dx));
    // The summary opens the whole list.
    await tester.tap(find.byKey(const ValueKey('subagent-strip-all')));
    await frames(tester, 8);
    expect(find.text('8 agents running'), findsOneWidget);
    expect(find.byType(SubagentSpawnCard), findsWidgets);
    await unmount(tester);
  });
}
