import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/arena/arena_world.dart';
import 'package:nexuslink/src/arena/world.dart';
import 'package:nexuslink/src/chats/chat_models.dart';
import 'package:nexuslink/src/monitor/approvals.dart';
import 'package:nexuslink/src/theme/nexus_theme.dart';

final now = DateTime(2026, 10, 29, 15);
int ago(Duration d) => now.subtract(d).millisecondsSinceEpoch;

ChatSummary agent(
  String id, {
  String folder = 'NexusLink',
  String state = 'working',
  String? activity = 'editing',
  String? waitKind,
  String? ask,
  String? parent,
  Duration age = const Duration(minutes: 2),
  List<Map<String, dynamic>>? subagents,
}) => ChatSummary({
  'id': id,
  'hostId': 'pc',
  'source': 'claude',
  'title': 'Task $id',
  'folderPath': '/w/$folder',
  'folderName': folder,
  'execution': state == 'working'
      ? 'working'
      : state == 'waiting'
      ? 'needsReply'
      : 'idle',
  'activityAt': ago(age),
  'parentId': ?parent,
  'live': {
    'state': state,
    'activity': ?activity,
    'waitKind': ?waitKind,
    'ask': ?ask,
    'updatedAt': ago(age),
    'subagents': ?subagents,
  },
});

class NoApprovals extends ApprovalsNotifier {
  NoApprovals([this.items = const []]);
  final List<ExternalApproval> items;
  @override
  ApprovalsState build() => ApprovalsState(items: items);
}

void main() {
  group('poses', () {
    test('each state has a place', () {
      expect(poseFor(agent('a', activity: 'editing'), now: now), Pose.typing);
      expect(
        poseFor(agent('a', activity: 'reading'), now: now),
        Pose.researching,
      );
      expect(
        poseFor(agent('a', activity: 'browsing'), now: now),
        Pose.researching,
      );
      expect(
        poseFor(agent('a', activity: 'running-command'), now: now),
        Pose.running,
      );
      expect(
        poseFor(agent('a', state: 'waiting', activity: null), now: now),
        Pose.asking,
      );
      expect(
        poseFor(agent('a', state: 'failed', activity: null), now: now),
        Pose.failed,
      );
      expect(
        poseFor(
          agent('a', state: 'done', ask: 'Push?', activity: null),
          now: now,
        ),
        Pose.yourTurn,
      );
      expect(
        poseFor(agent('a', state: 'done', activity: null), now: now),
        Pose.resting,
      );
      expect(
        poseFor(
          agent(
            'a',
            state: 'done',
            activity: null,
            age: const Duration(hours: 5),
          ),
          now: now,
        ),
        Pose.sleeping,
      );
    });

    test('a prompt waiting on the phone overrides the transcript guess', () {
      expect(poseFor(agent('a'), asking: {'a'}, now: now), Pose.asking);
    });
  });

  group('layout', () {
    test('only recent or active projects get a room; urgent rooms first', () {
      final world = buildWorld([
        agent(
          'old',
          folder: 'Old',
          state: 'done',
          activity: null,
          age: const Duration(days: 9),
        ),
        agent('busy-old', folder: 'Legacy', age: const Duration(days: 9)),
        agent(
          'quiet',
          folder: 'Quiet',
          state: 'done',
          activity: null,
          age: const Duration(hours: 1),
        ),
        agent(
          'ask',
          folder: 'Urgent',
          state: 'waiting',
          activity: null,
          age: const Duration(hours: 2),
        ),
      ], now: now);
      expect(world.rooms.map((r) => r.name), ['Urgent', 'Legacy', 'Quiet']);
    });

    test('rooms never overlap and fit inside the world', () {
      final world = buildWorld([
        for (var i = 0; i < 30; i++) agent('a$i', folder: 'P${i % 7}'),
      ], now: now);
      expect(world.rooms, hasLength(7));
      for (final a in world.rooms) {
        expect((Offset.zero & world.size).contains(a.rect.bottomRight), isTrue);
        for (final b in world.rooms) {
          if (a != b) expect(a.rect.overlaps(b.rect), isFalse);
        }
      }
    });

    test('a phone gets three desks per row, a tablet four', () {
      final chats = [for (var i = 0; i < 8; i++) agent('a$i')];
      expect(
        buildWorld(
          chats,
          now: now,
          viewportWidth: 390,
        ).rooms.single.desksPerRow,
        3,
      );
      expect(
        buildWorld(
          chats,
          now: now,
          viewportWidth: 900,
        ).rooms.single.desksPerRow,
        4,
      );
    });

    test('quiet chats beyond the cap are counted, active ones always stay', () {
      final world = buildWorld([
        for (var i = 0; i < 14; i++) agent('busy$i'),
        for (var i = 0; i < 5; i++)
          agent('done$i', state: 'done', activity: null),
      ], now: now);
      final room = world.rooms.single;
      expect(room.agents.where((a) => a.id.startsWith('busy')), hasLength(14));
      expect(room.hidden, 5);
    });

    test('workers sit right after their orchestrator, who is marked boss', () {
      final world = buildWorld([
        agent('solo'),
        agent('w1', parent: 'boss'),
        agent('boss'),
        agent('w2', parent: 'boss'),
      ], now: now);
      final ids = world.rooms.single.agents.map((a) => a.id).toList();
      expect(ids.indexOf('w1'), ids.indexOf('boss') + 1);
      expect(ids.indexOf('w2'), ids.indexOf('boss') + 2);
      expect(world.agent('boss')!.isBoss, isTrue);
      expect(world.agent('w1')!.isBoss, isFalse);
    });

    test('blocked agents wait by the door; typists stay at their own desk', () {
      final world = buildWorld([
        agent('typist'),
        agent('asker', state: 'waiting', activity: null),
        agent('reader', activity: 'reading'),
      ], now: now);
      final room = world.rooms.single;
      final typist = world.agent('typist')!;
      final asker = world.agent('asker')!;
      expect(typist.spot, typist.desk);
      expect(asker.spot.pos.dy, room.aisleY);
      expect((asker.spot.pos.dx - room.door.dx).abs(), lessThan(tile * 5));
      expect(
        room.shelfSpots.map((s) => s.pos),
        contains(world.agent('reader')!.spot.pos),
      );
    });

    test('walks go down the lane to the aisle and back up', () {
      final room = buildWorld([agent('a'), agent('b')], now: now).rooms.single;
      final route = routeBetween(
        room.desks[0].pos,
        room.desks[0],
        room.loungeSpots[0],
        room.aisleY,
      );
      expect(route.first.dx, room.desks[0].laneX);
      expect(route.map((p) => p.dy), contains(room.aisleY));
      expect(route.last, room.loungeSpots[0].pos);
    });
  });

  group('widget', () {
    Future<ArenaWorldState> pump(
      WidgetTester t,
      List<ChatSummary> chats, {
      bool offline = false,
      bool reduce = false,
      ValueChanged<ChatSummary>? onOpen,
    }) async {
      t.view.physicalSize = const Size(390, 760);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        ProviderScope(
          overrides: [approvalsProvider.overrideWith(NoApprovals.new)],
          child: MaterialApp(
            theme: nexusTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
              child: child!,
            ),
            home: Scaffold(
              body: ArenaWorld(
                chats: chats,
                offline: offline,
                onOpen: onOpen ?? (_) {},
                now: now,
              ),
            ),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 100));
      return t.state<ArenaWorldState>(find.byType(ArenaWorld));
    }

    testWidgets(
      'counters reflect the campus; the needs-you chip flies to the agent',
      (t) async {
        final arena = await pump(t, [
          agent('typist'),
          agent('asker', state: 'waiting', activity: null, folder: 'Other'),
          agent('turn', state: 'done', ask: 'Push?', activity: null),
        ]);
        expect(find.text('1 need you'), findsOneWidget);
        expect(find.text('1 your turn'), findsOneWidget);
        expect(find.text('1 working'), findsOneWidget);
        await t.tap(find.text('1 need you'));
        for (var i = 0; i < 15; i++) {
          await t.pump(const Duration(milliseconds: 50));
        }
        expect(arena.selected, 'asker');
        final pos = arena.positionOf('asker')!;
        final onScreen = MatrixUtils.transformPoint(
          arena.camera.value,
          pos * kArtScale,
        );
        expect((onScreen.dx - 195).abs(), lessThan(40));
        expect(t.takeException(), isNull);
      },
    );

    testWidgets('tapping a person opens their sheet with Open chat', (t) async {
      ChatSummary? opened;
      final arena = await pump(t, [agent('typist')], onOpen: (c) => opened = c);
      final pos = arena.positionOf('typist')!;
      final screen = MatrixUtils.transformPoint(
        arena.camera.value,
        (pos - const Offset(0, 8)) * kArtScale,
      );
      await t.tapAt(screen);
      // The Arena never settles (it animates), so step the sheet in by hand.
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Task typist'), findsWidgets);
      await t.tap(find.text('Open chat'));
      await t.pump(const Duration(milliseconds: 400));
      expect(opened?.id, 'typist');
    });

    testWidgets('a state change walks the agent to its new place', (t) async {
      final chats = [agent('a'), agent('b')];
      final arena = await pump(t, chats);
      final desk = arena.positionOf('a')!;
      await t.pumpWidget(
        ProviderScope(
          overrides: [approvalsProvider.overrideWith(NoApprovals.new)],
          child: MaterialApp(
            theme: nexusTheme(),
            home: Scaffold(
              body: ArenaWorld(
                chats: [
                  agent('a', state: 'waiting', activity: null),
                  chats[1],
                ],
                offline: false,
                onOpen: (_) {},
                now: now,
              ),
            ),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 16));
      expect(arena.isWalking('a'), isTrue);
      for (var i = 0; i < 160; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(arena.isWalking('a'), isFalse);
      final room = arena.world!.rooms.single;
      expect(arena.positionOf('a')!.dy, room.aisleY);
      expect(arena.positionOf('a'), isNot(desk));
    });

    testWidgets('reduced motion snaps instead of walking', (t) async {
      final arena = await pump(t, [agent('a')], reduce: true);
      expect(arena.isWalking('a'), isFalse);
    });

    testWidgets('offline and empty states', (t) async {
      await pump(t, [agent('a')], offline: true);
      expect(find.text('Offline · last known'), findsOneWidget);
      await pump(t, []);
      expect(find.text('The campus is quiet.'), findsOneWidget);
    });

    testWidgets('a big campus renders without errors', (t) async {
      await pump(t, [
        for (var i = 0; i < 40; i++)
          agent(
            'a$i',
            folder: 'P${i % 9}',
            state: ['working', 'waiting', 'done', 'failed'][i % 4],
            activity: [
              'editing',
              'reading',
              'running-command',
              'thinking',
            ][i % 4],
            subagents: i % 5 == 0
                ? [
                    {'name': 'Helper', 'state': 'working'},
                  ]
                : null,
          ),
      ]);
      await t.pump(const Duration(seconds: 1));
      expect(t.takeException(), isNull);
    });
  });
}
