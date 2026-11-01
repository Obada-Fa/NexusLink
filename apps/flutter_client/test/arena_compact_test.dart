import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/arena/arena_world.dart';
import 'package:nexuslink/src/arena/world.dart';
import 'package:nexuslink/src/chats/chat_models.dart';
import 'package:nexuslink/src/monitor/approvals.dart';
import 'package:nexuslink/src/theme/nexus_theme.dart';
import 'arena_world_test.dart' show agent, now, NoApprovals;

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

  Widget app(List<ChatSummary> chats, {GlobalKey? boundary}) => ProviderScope(
    overrides: [approvalsProvider.overrideWith(NoApprovals.new)],
    child: MaterialApp(
      theme: nexusTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: RepaintBoundary(
        key: boundary,
        child: Scaffold(
          body: ArenaWorld(chats: chats, offline: false, onOpen: (_) {}),
        ),
      ),
    ),
  );

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  ArenaWorldState arena(WidgetTester tester) =>
      tester.state<ArenaWorldState>(find.byType(ArenaWorld));

  // Eight projects in every state, three of them busy.
  final fleet = [
    agent('a1', folder: 'NexusLink', state: 'waiting', activity: null),
    agent('a2', folder: 'NexusLink'),
    agent('a3', folder: 'NexusLink', activity: 'reading'),
    agent('a4', folder: 'NexusLink', activity: 'running-command'),
    agent('b1', folder: 'Website', activity: 'running-command'),
    agent('b2', folder: 'Website'),
    agent('c1', folder: 'Infra', state: 'failed', activity: null),
    agent('c2', folder: 'Infra'),
    agent('d1', folder: 'Blog', state: 'done', ask: 'Push?', activity: null),
    agent('d2', folder: 'Blog', activity: 'searching'),
    agent('e1', folder: 'Mobile', state: 'waiting', activity: null),
    agent('f1', folder: 'Scraper'),
    agent('f2', folder: 'Scraper', activity: 'reading'),
    agent('g1', folder: 'Docs', activity: 'reading'),
    agent('h1', folder: 'Sandbox'),
  ];

  test('several projects on a phone get small rooms; one project does not', () {
    final several = buildWorld(fleet, now: now, viewportWidth: 390);
    expect(several.rooms.every((r) => r.compact), isTrue);
    final one = buildWorld([agent('a')], now: now, viewportWidth: 390);
    expect(one.rooms.single.compact, isFalse);
    final wide = buildWorld(fleet, now: now, viewportWidth: 900);
    expect(wide.rooms.every((r) => r.compact), isFalse);
  });

  test('small rooms do not overlap and keep every spot indoors', () {
    final crowded = [
      ...fleet,
      for (var i = 0; i < 9; i++) agent('x$i', folder: 'Crowd'),
    ];
    final world = buildWorld(crowded, now: now, viewportWidth: 390);
    for (final a in world.rooms) {
      expect((Offset.zero & world.size).contains(a.rect.bottomRight), isTrue);
      for (final b in world.rooms) {
        if (a != b) expect(a.rect.overlaps(b.rect), isFalse);
      }
      for (final s in [
        ...a.desks,
        ...a.shelfSpots,
        ...a.serverSpots,
        ...a.loungeSpots,
        ...a.helpSpots,
      ]) {
        expect(a.rect.contains(s.pos), isTrue, reason: '${s.pos} in ${a.rect}');
      }
      expect(a.rightLeft + a.rightWidth, lessThanOrEqualTo(a.rect.right));
    }
  });

  testWidgets('the phone opens with agents of many projects on screen', (
    tester,
  ) async {
    phone(tester);
    await tester.pumpWidget(app(fleet));
    await tester.pump();
    final state = arena(tester);
    final view = Offset.zero & tester.getSize(find.byType(ArenaWorld));
    final seen = <String>{
      for (final room in state.world!.rooms)
        for (final a in room.agents)
          if (view.contains(
            MatrixUtils.transformPoint(
              state.camera.value,
              state.positionOf(a.id)! * kArtScale,
            ),
          ))
            room.name,
    };
    expect(seen.length, 8);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('zooming into a room and back returns to the overview', (
    tester,
  ) async {
    phone(tester);
    await tester.pumpWidget(app(fleet));
    await tester.pump();
    final state = arena(tester);
    final overview = state.camera.value.clone();
    state.focusRoom(state.world!.rooms.last);
    await tester.pump();
    expect(state.camera.value.getMaxScaleOnAxis(), greaterThan(.8));
    await tester.tap(find.byTooltip('Show the whole campus'));
    await tester.pump();
    expect(state.camera.value, overview);
  });

  testWidgets('a second project arriving re-aims the camera at the overview', (
    tester,
  ) async {
    phone(tester);
    await tester.pumpWidget(app([agent('a', folder: 'One')]));
    await tester.pump();
    final state = arena(tester);
    final single = state.camera.value.getMaxScaleOnAxis();
    await tester.pumpWidget(
      app([agent('a', folder: 'One'), agent('b', folder: 'Two')]),
    );
    await tester.pump();
    await tester.pump();
    expect(state.camera.value.getMaxScaleOnAxis(), lessThan(single));
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping an agent in a small room selects it', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(fleet));
    await tester.pump();
    final state = arena(tester);
    final point = MatrixUtils.transformPoint(
      state.camera.value,
      (state.positionOf('h1')! - const Offset(0, 9)) * kArtScale,
    );
    await tester.tapAt(tester.getTopLeft(find.byType(ArenaWorld)) + point);
    await tester.pump();
    expect(state.selected, 'h1');
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('capture', (tester) async {
    phone(tester);
    final key = GlobalKey();
    await tester.pumpWidget(app(fleet, boundary: key));
    await tester.pump();
    if (!const bool.fromEnvironment('OFFICE_CAPTURE')) return;
    final render =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await tester.runAsync(() => render.toImage(pixelRatio: 2));
    final bytes = await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.png),
    );
    await tester.runAsync(() async {
      final file = File('build/arena-review/compact-busy.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    });
    image!.dispose();
  });
}
