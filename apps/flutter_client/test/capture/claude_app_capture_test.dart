// Phone-sized PNG captures of "Start on PC" with real fonts, for visual
// review. Skipped unless CAPTURE_DIR is set:
//   CAPTURE_DIR=/tmp/caps flutter test test/capture/claude_app_capture_test.dart

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/chats/chat_library_screen.dart';
import 'package:nexuslink/src/chats/chat_repository.dart';
import 'package:nexuslink/src/claude_app/claude_app_session_screen.dart';
import 'package:nexuslink/src/claude_app/claude_app_sessions.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:nexuslink/src/theme/nexus_theme.dart';
import 'package:nexuslink/src/workspace/terminal_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat_library_test.dart' show FakeRepository;
import '../claude_app_test.dart' show ClaudeAppHost;

final _dir = Platform.environment['CAPTURE_DIR'];

Future<void> _font(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final bytes = File(p).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

Future<void> _loadFonts() async {
  final flutter = File(
    Platform.resolvedExecutable,
  ).parent.parent.parent.parent.parent.parent.path;
  final material = '$flutter/bin/cache/artifacts/material_fonts';
  await _font('Roboto', [
    for (final w in ['Regular', 'Medium', 'Bold', 'Black'])
      '$material/Roboto-$w.ttf',
  ]);
  await _font('MaterialIcons', ['$material/MaterialIcons-Regular.otf']);
  await _font('monospace', [
    '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
    '/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf',
  ]);
}

/// The first screen of `claude remote-control`, as recorded in the live check.
const _claudeOutput =
    'me@pc:~/projects/demo\$ exec claude remote-control --name=\'demo\'\r\n'
    '\r\nRemote Control starts Claude Code sessions in this folder, driven '
    'from your other devices:\r\n  /home/me/projects/demo\r\n\r\n'
    'Quick safety check: is this a project you created or one you trust? '
    'Sessions started here can read, edit, and execute files.\r\n'
    'Trust /home/me/projects/demo? [y/N] y\r\n'
    '\x1b[32m✔\x1b[0m Connected · demo\r\n'
    '    Capacity: 0/32 · New sessions will be created in the current '
    'directory\r\n'
    'Continue coding in the Claude mobile app or https://claude.ai/code\r\n';

class _CaptureHost extends ClaudeAppHost {
  @override
  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 10),
  ]) async {
    if (method == 'terminal.attach') {
      emit('terminal-output', {
        'terminalId': params['terminalId'],
        'seq': 1,
        'data': _claudeOutput,
      });
    }
    return super.request(method, params, timeout);
  }
}

void main() {
  final key = GlobalKey();

  Future<void> settle(WidgetTester tester, [int frames = 12]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await settle(tester);
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_dir/$name.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  setUpAll(() async {
    if (_dir != null) await _loadFonts();
  });

  testWidgets('capture Start on PC', skip: _dir == null, (tester) async {
    SharedPreferences.setMockInitialValues({
      'claude-app-sessions:pc':
          '[{"terminalId":"shell-1","name":"demo","cwd":"/home/me/projects/demo","startedAt":1}]',
    });
    tester.view.physicalSize = const Size(412, 915) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final host = _CaptureHost()..shells['shell-1'] = 'running';
    final repository = TerminalRepository()..bind(host);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: ProviderScope(
          overrides: [
            activeClientProvider.overrideWithValue(host),
            connectionStatusProvider.overrideWithValue(RpcStatus.connected),
            chatRepositoryProvider.overrideWithValue(FakeRepository()),
            terminalRepositoryProvider.overrideWithValue(repository),
            claudeAppLauncherProvider.overrideWithValue(() async => true),
          ],
          child: MaterialApp(
            theme: nexusTheme(),
            debugShowCheckedModeBanner: false,
            home: const ChatLibraryScreen(),
          ),
        ),
      ),
    );
    await shot(tester, '01-agents-live');

    await tester.tap(find.byKey(const ValueKey('new-chat')));
    await settle(tester);
    await tester.tap(find.text('demo').last); // the folder picker suggestion
    await shot(tester, '02-choice');
    await tester.tap(find.text('Start for Claude app'));
    await shot(tester, '03-name');
    await tester.tap(find.byKey(const ValueKey('start-claude-app')));
    await settle(tester);
    await shot(tester, '04-terminal-banner');
    await tester.tap(find.byKey(const ValueKey('stop-claude-app')));
    await shot(tester, '05-stop-confirm');
    expect(find.byType(ClaudeAppSessionScreen), findsOneWidget);
  });
}
