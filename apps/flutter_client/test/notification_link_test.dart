// Notification / Continue links: scoped to one PC, consumed only by the chat
// library connected to that PC, and approval checks for the exact request.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/chats/chat_cache.dart';
import 'package:nexuslink/src/chats/chat_library_screen.dart';
import 'package:nexuslink/src/chats/chat_models.dart';
import 'package:nexuslink/src/chats/chat_repository.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/shell/home_screen.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:nexuslink/src/workspace/project.dart';
import 'package:shared_preferences/shared_preferences.dart';

const pcA = 'ws://10.0.0.1:45678/rpc';
const pcB = 'ws://10.0.0.2:45678/rpc';
const answered =
    'This request was already answered, on the PC or another device.';

Map<String, dynamic> permission(String request) => {
  'seq': 3,
  'ts': 3,
  'kind': 'permission-request',
  'toolName': 'Bash',
  'turnId': 'turn-1',
  'refId': request,
};

/// A PC as the chat library and a chat screen see it.
class PcHost extends RpcClient {
  PcHost(super.wsUrl, {required String id, this.online = true}) {
    hostId = id;
  }
  bool online;
  List<Map<String, dynamic>> pending = [];
  final calls = <String>[];
  final params = <String, Map<String, dynamic>>{};

  @override
  RpcStatus get status =>
      online ? RpcStatus.connected : RpcStatus.connecting;
  @override
  bool supports(String feature) =>
      feature == 'agent.historyPage' || feature == 'agent.pendingApprovals';
  @override
  void Function() subscribe(
    String topic,
    void Function(Map<String, dynamic>) callback,
  ) => () {};

  @override
  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 10),
  ]) async {
    calls.add(method);
    this.params[method] = Map.of(params);
    return switch (method) {
      'agent.list' => [
        {'id': 'claude', 'name': 'Code Agent', 'available': true},
      ],
      'agent.listSessions' => [
        {
          'agentSessionId': 'task-1',
          'agent': 'claude',
          'cwd': '/project',
          'title': 'Fix login',
          'busy': false,
          'taskState': 'idle',
        },
      ],
      'agent.historyPage' => {'events': [], 'hasMore': false},
      'agent.pendingApprovals' => pending,
      'agent.listModels' => [],
      // No such chat: the library says so instead of pushing a chat screen.
      'chat.historyPage' => <String, dynamic>{},
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

class MemoryCache extends ChatCache {
  @override
  Future<List<Map<String, dynamic>>> summaries(String host) async => [];
  @override
  Future<int?> lastSync(String host) async => null;
}

/// The library's view of one PC: an empty chat list.
class PcRepository extends ChatRepository {
  PcRepository(PcHost pc) : super(pc, pc.wsUrl, MemoryCache());
  @override
  bool get supported => true;
  @override
  Future<String?> host() async => client?.hostId;
  @override
  Future<Map<String, dynamic>> list(
    Map<String, dynamic> query, {
    bool folders = false,
  }) async => {'items': [], 'nextCursor': null, 'sources': []};
}

/// Which PC the phone is on, and whether that connection is up.
class CurrentPc extends Notifier<PcHost> {
  CurrentPc(this.first);
  final PcHost first;
  @override
  PcHost build() => first;
  void use(PcHost pc) => state = pc;
}

class Status extends Notifier<RpcStatus> {
  Status(this.first);
  final RpcStatus first;
  @override
  RpcStatus build() => first;
  void set(RpcStatus status) => state = status;
}

final currentPcProvider = NotifierProvider<CurrentPc, PcHost>(
  () => throw UnimplementedError(),
);
final statusProvider = NotifierProvider<Status, RpcStatus>(
  () => throw UnimplementedError(),
);

Future<ProviderContainer> pumpLibrary(
  WidgetTester tester,
  PcHost pc, {
  TaskLink? link,
}) async {
  final container = ProviderContainer(
    overrides: [
      currentPcProvider.overrideWith(() => CurrentPc(pc)),
      statusProvider.overrideWith(
        () => Status(pc.online ? RpcStatus.connected : RpcStatus.connecting),
      ),
      chatRepositoryProvider.overrideWith(
        (ref) => PcRepository(ref.watch(currentPcProvider)),
      ),
      activeClientProvider.overrideWith(
        (ref) => ref.watch(currentPcProvider),
      ),
      connectionStatusProvider.overrideWith((ref) => ref.watch(statusProvider)),
    ],
  );
  addTearDown(container.dispose);
  if (link != null) container.read(pendingTaskProvider.notifier).select(link);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ChatLibraryScreen()),
    ),
  );
  await pumpFrames(tester);
  return container;
}

Future<void> pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Unmounts the tree so snack bars and screens cancel their timers.
Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('notification intent → TaskLink', () {
    test('a new approval intent carries its PC and exact request', () {
      final link = taskLinkFromIntent({
        'taskId': 'task-1',
        'host': '10.0.0.2',
        'approval': true,
        'requestId': 'r2',
      })!;
      expect(link.id, 'task-1');
      expect(link.hostUrl, pcB, reason: 'normalized like saved targets');
      expect(link.approval, isTrue);
      expect(link.requestId, 'r2');
    });

    test('an older intent without requestId still opens, session-wide', () {
      final link = taskLinkFromIntent({
        'taskId': 'task-1',
        'host': pcA,
        'approval': true,
      })!;
      expect(link.approval, isTrue);
      expect(link.requestId, isNull);
      // Empty extras from a stripped intent count as missing too.
      expect(
        taskLinkFromIntent({
          'taskId': 'task-1',
          'host': pcA,
          'approval': true,
          'requestId': '',
        })!.requestId,
        isNull,
      );
    });

    test('a non-approval link drops a stray requestId', () {
      final link = taskLinkFromIntent({
        'taskId': 'task-1',
        'host': pcA,
        'approval': false,
        'requestId': 'r1',
      })!;
      expect(link.approval, isFalse);
      expect(link.requestId, isNull);
    });

    test('an intent without a PC or task opens no task', () {
      expect(taskLinkFromIntent({'taskId': 'task-1'}), isNull);
      expect(taskLinkFromIntent({'taskId': 'task-1', 'host': ' '}), isNull);
      expect(taskLinkFromIntent({'host': pcA}), isNull);
      expect(taskLinkFromIntent({'host': pcA, 'taskId': null}), isNull);
    });
  });

  group('two PCs', () {
    test('a link is only taken by the PC it names, once', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final pending = c.read(pendingTaskProvider.notifier);
      pending.select(const TaskLink('task-1', hostUrl: pcB));

      expect(pending.takeFor(pcA), isNull);
      expect(pending.takeFor(null), isNull);
      expect(c.read(pendingTaskProvider)?.id, 'task-1', reason: 'kept for B');

      // Same PC, written differently.
      expect(pending.takeFor('10.0.0.2')?.id, 'task-1');
      expect(c.read(pendingTaskProvider), isNull);
      expect(pending.takeFor(pcB), isNull, reason: 'consumed once');
    });

    testWidgets(
      'warm: PC A’s list leaves a PC B link; it opens on B after connecting',
      (tester) async {
        final a = PcHost(pcA, id: 'pc-a');
        final b = PcHost(pcB, id: 'pc-b', online: false);
        final c = await pumpLibrary(
          tester,
          a,
          link: const TaskLink('chat:c1', hostUrl: pcB),
        );
        // Still on A (online): the link is not A's.
        expect(a.calls, isNot(contains('chat.historyPage')));
        expect(c.read(pendingTaskProvider)?.hostUrl, pcB);

        // The shell switches to B; B is still connecting.
        c.read(currentPcProvider.notifier).use(b);
        c.read(statusProvider.notifier).set(RpcStatus.connecting);
        await pumpFrames(tester);
        expect(b.calls, isNot(contains('chat.historyPage')));
        expect(c.read(pendingTaskProvider)?.id, 'chat:c1');

        // B connects: the link opens there, exactly once.
        b.online = true;
        c.read(statusProvider.notifier).set(RpcStatus.connected);
        await pumpFrames(tester);
        expect(b.calls.where((m) => m == 'chat.historyPage'), hasLength(1));
        expect(b.params['chat.historyPage']?['chatId'], 'c1');
        expect(a.calls, isNot(contains('chat.historyPage')));
        expect(c.read(pendingTaskProvider), isNull);
        await unmount(tester);
      },
    );

    testWidgets('cold: a link set before the list exists waits for its PC', (
      tester,
    ) async {
      final b = PcHost(pcB, id: 'pc-b', online: false);
      final c = await pumpLibrary(
        tester,
        b,
        link: const TaskLink('chat:c1', hostUrl: pcB),
      );
      expect(b.calls, isNot(contains('chat.historyPage')));
      expect(c.read(pendingTaskProvider)?.id, 'chat:c1');

      b.online = true;
      c.read(statusProvider.notifier).set(RpcStatus.connected);
      await pumpFrames(tester);
      expect(b.params['chat.historyPage']?['chatId'], 'c1');
      expect(c.read(pendingTaskProvider), isNull);
      await unmount(tester);
    });

    testWidgets('a folder list never takes a link', (tester) async {
      final a = PcHost(pcA, id: 'pc-a');
      final container = ProviderContainer(
        overrides: [
          currentPcProvider.overrideWith(() => CurrentPc(a)),
          statusProvider.overrideWith(() => Status(RpcStatus.connected)),
          chatRepositoryProvider.overrideWith(
            (ref) => PcRepository(ref.watch(currentPcProvider)),
          ),
          activeClientProvider.overrideWith(
            (ref) => ref.watch(currentPcProvider),
          ),
          connectionStatusProvider.overrideWith(
            (ref) => ref.watch(statusProvider),
          ),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(pendingTaskProvider.notifier)
          .select(const TaskLink('chat:c1', hostUrl: pcA));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: ChatLibraryScreen(
              folder: ChatFolder(const {
                'id': 'f',
                'name': 'NexusLink',
                'path': '/p/NexusLink',
                'count': 0,
              }),
            ),
          ),
        ),
      );
      await pumpFrames(tester);
      expect(a.calls, isNot(contains('chat.historyPage')));
      expect(container.read(pendingTaskProvider)?.id, 'chat:c1');
      await unmount(tester);
    });
  });

  group('two requests in one session', () {
    test('only the exact request counts as still waiting', () {
      const r1 = TaskLink(
        'task-1',
        hostUrl: pcA,
        approval: true,
        requestId: 'r1',
      );
      const r2 = TaskLink(
        'task-1',
        hostUrl: pcA,
        approval: true,
        requestId: 'r2',
      );
      final onlyR2 = [permission('r2')];
      expect(approvalStillPending(r1, onlyR2), isFalse);
      expect(approvalStillPending(r2, onlyR2), isTrue);
      final both = [permission('r1'), permission('r2')];
      expect(approvalStillPending(r1, both), isTrue);
      expect(approvalStillPending(r1, const []), isFalse);
      // Older notifications only know the session.
      const legacy = TaskLink('task-1', hostUrl: pcA, approval: true);
      expect(approvalStillPending(legacy, onlyR2), isTrue);
      expect(approvalStillPending(legacy, const []), isFalse);
    });

    testWidgets('tapping the answered request says so though another waits', (
      tester,
    ) async {
      final a = PcHost(pcA, id: 'pc-a')..pending = [permission('r2')];
      await pumpLibrary(
        tester,
        a,
        link: const TaskLink(
          'task-1',
          hostUrl: pcA,
          approval: true,
          requestId: 'r1',
        ),
      );
      expect(a.params['agent.pendingApprovals']?['agentSessionId'], 'task-1');
      expect(find.text(answered), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('tapping the request still waiting says nothing', (
      tester,
    ) async {
      final a = PcHost(pcA, id: 'pc-a')..pending = [permission('r2')];
      await pumpLibrary(
        tester,
        a,
        link: const TaskLink(
          'task-1',
          hostUrl: pcA,
          approval: true,
          requestId: 'r2',
        ),
      );
      expect(a.calls, contains('agent.pendingApprovals'));
      expect(find.text(answered), findsNothing);
      await unmount(tester);
    });
  });
}
