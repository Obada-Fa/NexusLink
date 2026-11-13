import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/modules/agents/agents_module.dart';
import 'package:nexuslink/src/shell/capabilities.dart';
import 'package:nexuslink/src/shell/live_bar.dart';
import 'package:nexuslink/src/shell/module.dart';
import 'package:nexuslink/src/theme/nexus_theme.dart';

import 'fakes.dart';

LiveActivity act(String module, String label, {VoidCallback? onStop}) =>
    LiveActivity(
      moduleId: module,
      label: label,
      icon: Icons.circle,
      onStop: onStop,
    );

void main() {
  tearDown(() {
    AgentsModule.liveStatusReader = null;
    AgentsModule.liveStopper = null;
  });

  test('combines per-module lists in module order', () {
    final combined = combineLiveActivities(
      {
        'audio': [act('audio', 'Mic'), act('audio', 'Speakers')],
        'agents': [act('agents', 'Monitor')],
      },
      ['agents', 'remote', 'audio'],
    );
    expect(combined.map((a) => a.label), ['Monitor', 'Mic', 'Speakers']);
  });

  test('monitor live activity follows live.status', () {
    expect(AgentsModule.monitorActivities(null), isEmpty);
    expect(
      AgentsModule.monitorActivities({'monitoringRequested': false}),
      isEmpty,
    );
    final on = AgentsModule.monitorActivities({
      'monitoringRequested': true,
      'connectionState': 'connected',
    });
    expect(on.single.moduleId, 'agents');
    expect(on.single.label, 'Agent monitor');
    expect(
      AgentsModule.monitorActivities({
        'monitoringRequested': true,
        'connectionState': 'reconnecting',
      }).single.label,
      contains('reconnecting'),
    );
  });

  testWidgets('live bar aggregates modules and stops from the bar', (
    tester,
  ) async {
    var status = <String, dynamic>{'monitoringRequested': true};
    var stops = 0;
    AgentsModule.liveStatusReader = () async => status;
    AgentsModule.liveStopper = () async {
      stops++;
      status = {'monitoringRequested': false};
    };
    final remoteStream = StreamController<List<LiveActivity>>();
    final remote = FakeModule(id: 'remote', activities: remoteStream.stream);
    final ctx = ModuleContext(
      target: hubTarget(),
      capabilities: capabilitiesOf(hubTarget()),
      reachable: const {},
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: nexusTheme(),
        home: Scaffold(
          body: LiveBar(modules: [const AgentsModule(), remote], ctx: ctx),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('LIVE NOW · 1'), findsNothing);
    expect(find.text('Agent monitor'), findsOneWidget);

    remoteStream.add([act('remote', 'Trackpad connected')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('LIVE NOW · 2'), findsOneWidget);
    // Module order, not arrival order.
    final labels = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .where((d) => d == 'Agent monitor' || d == 'Trackpad connected')
        .toList();
    expect(labels, ['Agent monitor', 'Trackpad connected']);

    await tester.tap(find.byTooltip('Stop Agent monitor'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(stops, 1);
    expect(find.text('Agent monitor'), findsNothing);
    expect(find.text('LIVE NOW · 1'), findsNothing);

    remoteStream.add(const []);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('live-bar')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    unawaited(remoteStream.close());
  });
}
