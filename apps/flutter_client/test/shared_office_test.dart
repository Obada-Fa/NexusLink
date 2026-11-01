import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/arena/shared_office.dart';
import 'package:nexuslink/src/chats/chat_models.dart';
import 'package:nexuslink/src/monitor/approvals.dart';
import 'package:nexuslink/src/theme/nexus_theme.dart';
import 'arena_world_test.dart' show agent, NoApprovals;

void main() {
  setUpAll(() async {
    const fontPath = String.fromEnvironment('ARENA_FONT');
    if (fontPath.isNotEmpty) {
      final font = FontLoader('Roboto')
        ..addFont(
          Future.value(
            ByteData.sublistView(await File(fontPath).readAsBytes()),
          ),
        );
      await font.load();
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  Widget app(
    List<ChatSummary> chats, {
    bool offline = false,
    bool reduced = true,
    double scale = 1,
    ValueChanged<String?>? create,
    Future<List<ChatFolder>> Function()? projects,
    GlobalKey? boundary,
    VoidCallback? more,
  }) => ProviderScope(
    overrides: [approvalsProvider.overrideWith(NoApprovals.new)],
    child: MaterialApp(
      theme: nexusTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reduced,
          textScaler: TextScaler.linear(scale),
        ),
        child: child!,
      ),
      home: RepaintBoundary(
        key: boundary,
        child: Scaffold(
          body: SharedOffice(
            chats: chats,
            offline: offline,
            onOpen: (_) {},
            onNewChat: create ?? (_) {},
            loadProjects: projects ?? () async => [],
            onLoadMore: more,
          ),
        ),
      ),
    ),
  );

  testWidgets(
    'attention first, idle collapsed, stable seats, completion leaves office',
    (tester) async {
      tester.view.physicalSize = const Size(390, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final a = agent('a'),
          b = agent('b'),
          wait = agent('wait', state: 'waiting');
      await tester.pumpWidget(app([a, b, wait, agent('idle', state: 'idle')]));
      expect(
        tester.getTopLeft(find.text('Task wait')).dy,
        lessThan(tester.getTopLeft(find.text('Task a')).dy),
      );
      expect(find.text('Task idle'), findsNothing);
      await tester.pumpWidget(app([b, a, wait, agent('idle', state: 'idle')]));
      expect(
        tester.getTopLeft(find.text('Task a')).dy,
        lessThan(tester.getTopLeft(find.text('Task b')).dy),
      );
      await tester.pumpWidget(app([agent('a', state: 'done'), b]));
      expect(find.text('Completed'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Task a'), findsNothing);
      expect(find.text('Idle & completed (1)'), findsOneWidget);
    },
  );
  testWidgets(
    'reception chooses project, cancellation and offline disable creation',
    (tester) async {
      String? chosen;
      var calls = 0;
      await tester.pumpWidget(
        app(
          [],
          create: (p) {
            chosen = p;
            calls++;
          },
          projects: () async => [
            ChatFolder({'name': 'NexusLink', 'path': '/w/NexusLink'}),
          ],
        ),
      );
      await tester.tap(find.text('New chat'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'nexus');
      await tester.pump();
      await tester.tap(find.text('NexusLink'));
      await tester.pumpAndSettle();
      expect(chosen, '/w/NexusLink');
      await tester.tap(find.text('New chat'));
      await tester.pumpAndSettle();
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      expect(calls, 1);
      await tester.pumpWidget(app([], offline: true, create: (_) => calls++));
      await tester.tap(find.text('New chat'));
      await tester.pump();
      expect(find.text('Choose a project'), findsNothing);
      expect(calls, 1);
    },
  );
  testWidgets(
    'project failure retries and empty projects allow default folder',
    (tester) async {
      var attempts = 0, creates = 0;
      await tester.pumpWidget(
        app(
          [],
          create: (p) {
            expect(p, isNull);
            creates++;
          },
          projects: () async {
            if (attempts++ == 0) throw StateError('offline');
            return [];
          },
        ),
      );
      await tester.tap(find.text('New chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(
        find.text('No matching projects. You can use the default folder.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Default folder'));
      await tester.pumpAndSettle();
      expect(creates, 1);
    },
  );
  testWidgets('all 40 agents and pagination reachable', (tester) async {
    var more = 0;
    await tester.pumpWidget(
      app(List.generate(40, (i) => agent('$i')), more: () => more++),
    );
    await tester.scrollUntilVisible(
      find.text('Task 39'),
      200,
      maxScrolls: 100,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Task 39'), findsOneWidget);
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('Load more chats'),
      200,
      maxScrolls: 100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Load more chats'));
    expect(more, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('project filter and receptionist preselection', (tester) async {
    await tester.pumpWidget(
      app(
        [agent('one', folder: 'One'), agent('two', folder: 'Two')],
        projects: () async => [
          ChatFolder({'name': 'One', 'path': '/w/One'}),
          ChatFolder({'name': 'Two', 'path': '/w/Two'}),
        ],
      ),
    );
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Two').last);
    await tester.pumpAndSettle();
    expect(find.text('Task one'), findsNothing);
    expect(find.text('Task two'), findsOneWidget);
    await tester.tap(find.text('New chat'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Two').last).dy,
      lessThan(tester.getTopLeft(find.text('One').last).dy),
    );
  });
  testWidgets('working animation changes frames', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      app([agent('typing')], reduced: false, boundary: key),
    );
    await tester.pump();
    final render =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final first = await tester.runAsync(() => render.toImage());
    final before = await tester.runAsync(() => first!.toByteData());
    await tester.pump(const Duration(milliseconds: 1200));
    final second = await tester.runAsync(() => render.toImage());
    final after = await tester.runAsync(() => second!.toByteData());
    expect(
      after!.buffer.asUint8List(),
      isNot(equals(before!.buffer.asUint8List())),
    );
    first!.dispose();
    second!.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });
  for (final scene in ['empty', 'busy', 'large-text']) {
    testWidgets('$scene narrow layout and reduced motion', (tester) async {
      tester.view.physicalSize = Size(scene == 'large-text' ? 320 : 390, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(
        app(
          scene == 'empty'
              ? []
              : [
                  agent('approval', state: 'waiting', waitKind: 'approval'),
                  agent('reading', activity: 'reading'),
                  agent('tests', activity: 'running-command'),
                ],
          boundary: key,
          scale: scene == 'large-text' ? 1.8 : 1,
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final render =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final first = await tester.runAsync(() => render.toImage());
      final bytes = await tester.runAsync(
        () => first!.toByteData(format: ui.ImageByteFormat.png),
      );
      await tester.pump(const Duration(seconds: 2));
      final second = await tester.runAsync(() => render.toImage());
      final after = await tester.runAsync(
        () => second!.toByteData(format: ui.ImageByteFormat.png),
      );
      expect(after!.buffer.asUint8List(), bytes!.buffer.asUint8List());
      if (const bool.fromEnvironment('OFFICE_CAPTURE')) {
        await tester.runAsync(() async {
          final file = File('build/arena-review/office-$scene.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes.buffer.asUint8List());
        });
      }
      first!.dispose();
      second!.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
