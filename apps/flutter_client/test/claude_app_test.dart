import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/claude_app/claude_app_live_section.dart';
import 'package:nexuslink/src/claude_app/claude_app_session_screen.dart';
import 'package:nexuslink/src/claude_app/claude_app_sessions.dart';
import 'package:nexuslink/src/claude_app/new_chat_choice.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:nexuslink/src/workspace/terminal_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A PC host that answers the folder picker and the terminal calls.
class ClaudeAppHost extends RpcClient {
  ClaudeAppHost() : super('ws://pc/rpc') {
    hostId = 'pc';
  }
  final calls = <String>[];
  final inputs = <Map<String, dynamic>>[];
  final shells = <String, String>{}; // terminalId → running | exited
  final handlers = <String, List<void Function(Map<String, dynamic>)>>{};
  int _next = 0;
  String? lastCreateCwd;

  @override
  RpcStatus get status => RpcStatus.connected;
  @override
  bool supports(String feature) => true;
  @override
  void Function() subscribe(
    String topic,
    void Function(Map<String, dynamic>) callback,
  ) {
    final entries = handlers.putIfAbsent(topic, () => []);
    entries.add(callback);
    return () => entries.remove(callback);
  }

  void emit(String topic, Map<String, dynamic> event) {
    for (final cb in List.of(handlers[topic] ?? [])) {
      cb(event);
    }
  }

  @override
  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 10),
  ]) async {
    calls.add(method);
    switch (method) {
      case 'system.getInfo':
        return {'homeDir': '/home/me'};
      case 'fs.listProjects':
        return [
          {'name': 'demo', 'path': '/home/me/demo'},
        ];
      case 'terminal.create':
        lastCreateCwd = params['cwd'] as String?;
        final id = 'shell-${++_next}';
        shells[id] = 'running';
        return {'terminalId': id};
      case 'terminal.list':
        return [
          for (final e in shells.entries)
            {'terminalId': e.key, 'state': e.value, 'cwd': '/x'},
        ];
      case 'terminal.kill':
        final id = params['terminalId'] as String;
        if (!shells.containsKey(id)) {
          throw RpcException('gone', 'NOT_FOUND');
        }
        shells[id] = 'exited';
        return {};
      case 'terminal.attach':
        final id = params['terminalId'] as String;
        final state = shells[id];
        if (state == null) throw RpcException('gone', 'NOT_FOUND');
        return {'state': state, 'exitCode': state == 'exited' ? 0 : null};
    }
    return {};
  }

  @override
  void notify(String method, Map<String, dynamic> params) {
    calls.add(method);
    if (method == 'terminal.input') inputs.add(params);
  }
}

class _Harness {
  _Harness(this.host, this.launches, this.nexusChats);
  final ClaudeAppHost host;
  final List<int> launches;
  final List<String?> nexusChats;
}

Future<_Harness> _pump(
  WidgetTester tester,
  Widget Function(BuildContext context, WidgetRef ref) body, {
  ClaudeAppHost? host,
  bool installed = true,
  Size size = const Size(412, 915),
  double textScale = 1,
}) async {
  final h = _Harness(host ?? ClaudeAppHost(), [], []);
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final repository = TerminalRepository()..bind(h.host);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeClientProvider.overrideWithValue(h.host),
        terminalRepositoryProvider.overrideWithValue(repository),
        claudeAppLauncherProvider.overrideWithValue(() async {
          h.launches.add(1);
          return installed;
        }),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Consumer(
          builder: (context, ref, _) => Scaffold(body: body(context, ref)),
        ),
      ),
    ),
  );
  await _settle(tester);
  return h;
}

Widget _newChatButton(
  BuildContext context,
  WidgetRef ref,
  List<String?> nexusChats, {
  String? folder,
}) => Center(
  child: FilledButton(
    onPressed: () => startNewChatFlow(
      context: context,
      ref: ref,
      folder: folder,
      openNexusChat: nexusChats.add,
    ),
    child: const Text('New chat'),
  ),
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('command', () {
    test('normal name', () {
      expect(
        remoteControlCommand('my-project'),
        "exec claude remote-control --name='my-project'\r",
      );
    });

    test('hostile names are single-quoted and stripped of control chars', () {
      expect(
        remoteControlCommand("it's; rm -rf ~ \$(id) `id`"),
        "exec claude remote-control --name='it'\\''s; rm -rf ~ \$(id) `id`'\r",
      );
      expect(
        remoteControlCommand('a\nb\r\x1b[2Jc\x00'),
        "exec claude remote-control --name='a b [2Jc'\r",
      );
      expect(
        remoteControlCommand('--help'),
        "exec claude remote-control --name='--help'\r",
      );
      expect(cleanSessionName(' \n\t '), '');
      expect(cleanSessionName('x' * 200).length, maxSessionNameLength);
    });

    test('bash parses each hostile name as exactly one argument', () async {
      final dir = await Directory.systemTemp.createTemp('nexus-quote-');
      addTearDown(() => dir.delete(recursive: true));
      final canary = '${dir.path}/pwned';
      final names = [
        'plain name',
        "single ' quote",
        'double " quote',
        'semi; touch $canary',
        '\$(touch $canary)',
        '`touch $canary`',
        "'; touch $canary; '",
        'new\nline; touch $canary',
        '-leading dash',
        '--name=evil',
        r'back\slash \\ $HOME ${HOME} !! !$ * ? [a] ~ & | > < # %',
        'üñíçødé 🚀',
      ];
      for (final name in names) {
        final command = remoteControlCommand(name);
        expect(command.endsWith('\r'), isTrue);
        final script = command
            .substring(0, command.length - 1)
            .replaceFirst(
              'exec claude remote-control ',
              r"printf '%s\0' ",
            );
        final result = await Process.run('bash', ['-c', script]);
        expect(result.exitCode, 0, reason: name);
        final args = (result.stdout as String).split('\x00')..removeLast();
        expect(args, ['--name=${cleanSessionName(name)}'], reason: name);
      }
      expect(File(canary).existsSync(), isFalse);
    });

    test('Windows paths are recognised', () {
      expect(isWindowsHostPath('C:/Users/me'), isTrue);
      expect(isWindowsHostPath('/home/me'), isFalse);
    });
  });

  group('choice after the folder picker', () {
    testWidgets('picking a folder then Chat here keeps the Nexus chat', (
      tester,
    ) async {
      late _Harness h;
      final chats = <String?>[];
      h = await _pump(tester, (c, r) => _newChatButton(c, r, chats));
      await tester.tap(find.text('New chat'));
      await _settle(tester);
      // The existing folder picker comes first.
      await tester.tap(find.text('demo'));
      await _settle(tester);
      expect(find.text('Chat here in Nexus'), findsOneWidget);
      expect(find.text('Start for Claude app'), findsOneWidget);
      expect(
        find.textContaining('it ends if the PC host restarts'),
        findsOneWidget,
      );
      expect(find.text('/home/me/demo'), findsOneWidget);
      await tester.tap(find.text('Chat here in Nexus'));
      await _settle(tester);
      expect(chats, ['/home/me/demo']);
      expect(h.host.calls, isNot(contains('terminal.create')));
    });

    testWidgets('cancelling the picker does nothing', (tester) async {
      final chats = <String?>[];
      final h = await _pump(tester, (c, r) => _newChatButton(c, r, chats));
      await tester.tap(find.text('New chat'));
      await _settle(tester);
      await tester.tapAt(const Offset(200, 40)); // scrim
      await _settle(tester);
      expect(find.text('Chat here in Nexus'), findsNothing);
      expect(chats, isEmpty);
      expect(h.host.calls, isNot(contains('terminal.create')));
    });

    testWidgets('default name, edited name, exact command and terminal', (
      tester,
    ) async {
      final chats = <String?>[];
      final h = await _pump(
        tester,
        (c, r) => _newChatButton(c, r, chats, folder: '/home/me/my app'),
      );
      await tester.tap(find.text('New chat'));
      await _settle(tester);
      await tester.tap(find.text('Start for Claude app'));
      await _settle(tester);
      final field = find.byKey(const ValueKey('claude-app-name'));
      expect(tester.widget<TextField>(field).controller!.text, 'my app');
      await tester.enterText(field, "it's \$(rm -rf /)");
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('start-claude-app')));
      await _settle(tester);
      expect(h.host.lastCreateCwd, '/home/me/my app');
      expect(h.host.inputs.single['terminalId'], 'shell-1');
      expect(
        h.host.inputs.single['data'],
        "exec claude remote-control --name='it'\\''s \$(rm -rf /)'\r",
      );
      // The shell's terminal under the banner.
      expect(find.byType(ClaudeAppSessionScreen), findsOneWidget);
      expect(find.text("it's \$(rm -rf /)"), findsOneWidget);
      expect(find.text('Running'), findsOneWidget);
      expect(find.byKey(const ValueKey('open-claude-app')), findsOneWidget);
      expect(chats, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('claude-app-sessions:pc'), contains('shell-1'));
    });

    testWidgets('an empty name cannot start', (tester) async {
      final h = await _pump(
        tester,
        (c, r) => _newChatButton(c, r, [], folder: '/home/me/demo'),
      );
      await tester.tap(find.text('New chat'));
      await _settle(tester);
      await tester.tap(find.text('Start for Claude app'));
      await _settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('claude-app-name')),
        ' \n ',
      );
      await tester.pump();
      final start = tester.widget<FilledButton>(
        find.byKey(const ValueKey('start-claude-app')),
      );
      expect(start.onPressed, isNull);
      expect(h.host.calls, isNot(contains('terminal.create')));
    });

    testWidgets('Windows folders cannot start for the Claude app', (
      tester,
    ) async {
      await _pump(
        tester,
        (c, r) => _newChatButton(c, r, [], folder: 'C:/Users/me/demo'),
      );
      await tester.tap(find.text('New chat'));
      await _settle(tester);
      expect(find.text('Needs a Linux or macOS PC.'), findsOneWidget);
      await tester.tap(find.text('Start for Claude app'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('claude-app-name')), findsNothing);
    });
  });

  group('banner', () {
    const session = ClaudeAppSession(
      terminalId: 'shell-1',
      name: 'demo',
      cwd: '/home/me/demo',
      startedAt: 1,
    );

    Future<_Harness> openScreen(
      WidgetTester tester, {
      bool installed = true,
      ClaudeAppHost? host,
    }) async {
      final h = host ?? ClaudeAppHost();
      h.shells.putIfAbsent('shell-1', () => 'running');
      SharedPreferences.setMockInitialValues({
        'claude-app-sessions:pc':
            '[{"terminalId":"shell-1","name":"demo","cwd":"/home/me/demo","startedAt":1}]',
      });
      return _pump(
        tester,
        (c, r) => const ClaudeAppSessionScreen(session: session),
        host: h,
        installed: installed,
      );
    }

    testWidgets('Open Claude launches the app', (tester) async {
      final h = await openScreen(tester);
      expect(find.text('demo'), findsOneWidget);
      expect(find.text('/home/me/demo'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('open-claude-app')));
      await _settle(tester);
      expect(h.launches, [1]);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('Claude app not installed says so', (tester) async {
      final h = await openScreen(tester, installed: false);
      await tester.tap(find.byKey(const ValueKey('open-claude-app')));
      await tester.pump();
      expect(h.launches, [1]);
      expect(find.textContaining("isn't installed"), findsOneWidget);
    });

    testWidgets('Stop asks first, then ends the shell', (tester) async {
      final h = await openScreen(tester);
      await tester.tap(find.byKey(const ValueKey('stop-claude-app')));
      await _settle(tester);
      expect(find.text('Stop "demo"?'), findsOneWidget);
      await tester.tap(find.text('Keep running'));
      await _settle(tester);
      expect(h.host.calls, isNot(contains('terminal.kill')));
      await tester.tap(find.byKey(const ValueKey('stop-claude-app')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('confirm-stop-claude-app')));
      await _settle(tester);
      expect(h.host.calls, contains('terminal.kill'));
      expect(h.host.shells['shell-1'], 'exited');
      expect(find.text('Ended'), findsOneWidget);
      final stop = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('stop-claude-app')),
      );
      expect(stop.onPressed, isNull);
    });

    testWidgets('a shell exit event turns the banner to Ended', (
      tester,
    ) async {
      final h = await openScreen(tester);
      expect(find.text('Running'), findsOneWidget);
      h.host.shells['shell-1'] = 'exited';
      h.host.emit('terminal-exit', {'terminalId': 'shell-1', 'exitCode': 0});
      await _settle(tester);
      expect(find.text('Ended'), findsOneWidget);
      expect(find.text('Running'), findsNothing);
    });

    for (final (size, scale) in [
      (const Size(320, 640), 1.3),
      (const Size(412, 915), 2.0),
    ]) {
      testWidgets('banner and choice fit at $size × ${scale}x text', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        final h = ClaudeAppHost()..shells['shell-1'] = 'running';
        await _pump(
          tester,
          (c, r) => const ClaudeAppSessionScreen(session: session),
          host: h,
          size: size,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        final open = tester.getSize(
          find.byKey(const ValueKey('open-claude-app')),
        );
        expect(open.height, greaterThanOrEqualTo(48));
        final rect = tester.getRect(
          find.byKey(const ValueKey('stop-claude-app')),
        );
        expect(rect.right, lessThanOrEqualTo(size.width));

        await tester.pumpWidget(const SizedBox());
        await _pump(
          tester,
          (c, r) => _newChatButton(c, r, [], folder: '/home/me/demo'),
          host: h,
          size: size,
          textScale: scale,
        );
        await tester.tap(find.text('New chat'));
        await _settle(tester);
        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(find.byKey(const ValueKey('choice-claude-app'))).height,
          greaterThanOrEqualTo(48),
        );
        await tester.tap(find.text('Start for Claude app'));
        await _settle(tester);
        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(find.byKey(const ValueKey('start-claude-app'))).height,
          greaterThanOrEqualTo(48),
        );

        await tester.pumpWidget(const SizedBox());
        SharedPreferences.setMockInitialValues({
          'claude-app-sessions:pc':
              '[{"terminalId":"shell-1","name":"a rather long session name that will not fit","cwd":"/home/me/projects/deeply/nested/folder/demo","startedAt":1}]',
        });
        await _pump(
          tester,
          (c, r) => const CustomScrollView(slivers: [ClaudeAppLiveSection()]),
          host: h,
          size: size,
          textScale: scale,
        );
        await _settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(ClaudeAppSessionCard), findsOneWidget);
      });
    }
  });

  group('Live', () {
    Future<_Harness> live(
      WidgetTester tester,
      Map<String, String> shells,
      String records,
    ) async {
      SharedPreferences.setMockInitialValues({
        'claude-app-sessions:pc': records,
      });
      final h = ClaudeAppHost()..shells.addAll(shells);
      final harness = await _pump(
        tester,
        (c, r) => const CustomScrollView(slivers: [ClaudeAppLiveSection()]),
        host: h,
      );
      await _settle(tester);
      return harness;
    }

    const two =
        '[{"terminalId":"shell-1","name":"alpha","cwd":"/home/me/alpha","startedAt":2},'
        '{"terminalId":"shell-2","name":"beta","cwd":"/home/me/beta","startedAt":1},'
        '{"terminalId":"gone","name":"old","cwd":"/home/me/old","startedAt":0}]';

    testWidgets('lists running and ended shells; forgets missing ones', (
      tester,
    ) async {
      await live(tester, {'shell-1': 'running', 'shell-2': 'exited'}, two);
      expect(find.text('ON PC FOR CLAUDE APP'), findsOneWidget);
      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('/home/me/alpha'), findsOneWidget);
      expect(find.text('Running for Claude app'), findsOneWidget);
      expect(find.text('beta'), findsOneWidget);
      expect(find.text('Ended'), findsOneWidget);
      expect(find.text('old'), findsNothing);
      expect(
        find.bySemanticsLabel(
          RegExp(r'^Running for Claude app · alpha · /home/me/alpha'),
        ),
        findsOneWidget,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('claude-app-sessions:pc'), isNot(contains('gone')));
      // Ended rows can be removed from this phone's list.
      await tester.tap(find.byKey(const ValueKey('claude-app-dismiss:shell-2')));
      await _settle(tester);
      expect(find.text('beta'), findsNothing);
    });

    testWidgets('after a host restart nothing reads Running', (tester) async {
      await live(tester, {}, two);
      expect(find.text('Running for Claude app'), findsNothing);
      expect(find.text('ON PC FOR CLAUDE APP'), findsNothing);
    });

    testWidgets('tap opens the terminal with the banner', (tester) async {
      await live(tester, {'shell-1': 'running'}, two);
      await tester.tap(find.text('alpha'));
      await _settle(tester);
      expect(find.byType(ClaudeAppSessionScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('open-claude-app')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('claude-app-terminal:shell-1')),
        findsOneWidget,
      );
    });

    testWidgets('Stop from the list asks first', (tester) async {
      final h = await live(tester, {'shell-1': 'running'}, two);
      await tester.tap(find.byKey(const ValueKey('claude-app-stop:shell-1')));
      await _settle(tester);
      expect(find.text('Stop "alpha"?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('confirm-stop-claude-app')));
      await _settle(tester);
      expect(h.host.calls, contains('terminal.kill'));
      expect(find.text('Running for Claude app'), findsNothing);
      expect(find.text('Ended'), findsOneWidget);
    });

    testWidgets('stopping a shell the host already lost is not an error', (
      tester,
    ) async {
      final h = await live(tester, {'shell-1': 'running'}, two);
      h.host.shells.remove('shell-1');
      await tester.tap(find.byKey(const ValueKey('claude-app-stop:shell-1')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('confirm-stop-claude-app')));
      await _settle(tester);
      expect(find.textContaining('Could not stop'), findsNothing);
      expect(find.text('alpha'), findsNothing);
    });
  });
}
