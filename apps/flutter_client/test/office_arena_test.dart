import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/arena/arena_view.dart';
import 'package:nexuslink/src/arena/office_models.dart';
import 'package:nexuslink/src/arena/office_scene.dart';
import 'package:nexuslink/src/chats/chat_models.dart';
import 'package:nexuslink/src/theme/nexus_theme.dart';

ChatSummary agent(
  String id, {
  String state = 'working',
  String activity = 'editing',
  String path = '/work/NexusLink',
  String host = 'pc',
}) => ChatSummary({
  'id': id,
  'hostId': host,
  'source': id == '2' ? 'claude' : 'codex',
  'title': 'Task $id',
  'folderPath': path,
  'folderName': 'NexusLink',
  'execution': state == 'working' ? 'working' : 'idle',
  'live': {'state': state, 'activity': activity, 'step': 'Current step $id'},
});

Widget app(
  List<ChatSummary> chats, {
  bool offline = false,
  bool reduce = true,
  ValueChanged<ChatSummary>? onOpen,
  ValueChanged<ChatSummary>? onLongPress,
  double textScale = 1,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: nexusTheme(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: reduce,
      textScaler: TextScaler.linear(textScale),
    ),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: ArenaView(
        chats: chats,
        offline: offline,
        onOpen: onOpen ?? (_) {},
        onLongPress: onLongPress,
      ),
    ),
  ),
);

void main() {
  test('reported activity assigns stations with attention taking priority', () {
    expect(
      officeStationFor(agent('1', activity: 'reading')),
      OfficeStation.research,
    );
    expect(
      officeStationFor(agent('1', activity: 'searching')),
      OfficeStation.research,
    );
    expect(
      officeStationFor(agent('1', activity: 'browsing')),
      OfficeStation.research,
    );
    expect(officeStationFor(agent('1')), OfficeStation.code);
    expect(
      officeStationFor(agent('1', activity: 'running-command')),
      OfficeStation.code,
    );
    expect(
      officeStationFor(agent('1', activity: 'responding')),
      OfficeStation.review,
    );
    expect(
      officeStationFor(agent('1', activity: 'thinking')),
      OfficeStation.review,
    );
    expect(officeStationFor(agent('1', state: 'waiting')), OfficeStation.help);
    expect(officeStationFor(agent('1', state: 'failed')), OfficeStation.help);
    expect(officeStationFor(agent('1', state: 'idle')), OfficeStation.lounge);
    expect(officeStationFor(agent('1', state: 'done')), OfficeStation.lounge);
  });

  test('rooms distinguish identical names by host and full project path', () {
    final rooms = officeProjects([
      agent('1'),
      agent('2'),
      agent('3', path: '/other/NexusLink'),
      agent('4', host: 'another-pc'),
    ]);
    expect(rooms.length, 3);
    expect(rooms.first.chats.length, 2);
    expect(rooms.map((r) => r.id).toSet().length, 3);
  });

  testWidgets(
    'puppet and roster open the correct agent and preserve long press',
    (tester) async {
      final opened = <String>[];
      final actions = <String>[];
      await tester.pumpWidget(
        app(
          [agent('1'), agent('2', state: 'waiting')],
          onOpen: (c) => opened.add(c.id),
          onLongPress: (c) => actions.add(c.id),
        ),
      );
      await tester.tap(
        find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              w.properties.label == 'Open agent 1, Claude, Task 2',
        ),
      );
      expect(opened, ['2']);
      await tester.ensureVisible(find.text('Task 1'));
      await tester.tap(find.text('Task 1'));
      expect(opened, ['2', '1']);
      await tester.longPress(find.text('Task 1'));
      expect(actions, ['1']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('all agents get a desk across floors on a small phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      app([for (var i = 0; i < 17; i++) agent('$i')], textScale: 1.8),
    );
    expect(find.byType(OfficeScene), findsNWidgets(3));
    await tester.ensureVisible(find.text('Task 16'));
    expect(find.text('Task 16'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'agents walk to new activity, then offline and reduced motion freeze them',
    (tester) async {
      Finder puppet() => find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            w.properties.label == 'Open agent 1, Codex, Task 1',
      );
      await tester.pumpWidget(
        app([agent('1', activity: 'reading')], reduce: false),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final start = tester.getTopLeft(puppet());
      await tester.pumpWidget(app([agent('1')], reduce: false));
      await tester.pump(const Duration(milliseconds: 900));
      expect(tester.getTopLeft(puppet()), isNot(start));
      await tester.pump(const Duration(seconds: 5));
      final end = tester.getTopLeft(puppet());
      expect(end.dx, greaterThan(start.dx));
      await tester.pumpWidget(app([agent('1')], offline: true, reduce: false));
      expect(find.textContaining('Offline · last known'), findsOneWidget);
      expect(find.textContaining('Working · last known'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(tester.getTopLeft(puppet()), end);
      await tester.pumpWidget(
        app([agent('1', activity: 'reading')], reduce: true),
      );
      expect(tester.getTopLeft(puppet()), start);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('empty filtered office has clear guidance', (tester) async {
    await tester.pumpWidget(app([]));
    expect(find.text('The office is quiet.'), findsOneWidget);
    expect(find.byType(OfficeScene), findsNothing);
  });
}
