// Phone-sized PNG captures of the sub-agent strip, agent view and Ultra Code
// chooser with real fonts, for visual review. Skipped unless CAPTURE_DIR is
// set:
//   CAPTURE_DIR=/tmp/caps flutter test test/capture/subagents_capture_test.dart

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/theme/nexus_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../subagent_screen_test.dart'
    show SubagentHost, frames, pumpChat, stored;
import '../subagents_test.dart' show foreground, fgId;

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

Map<String, dynamic> _record(
  String id,
  String name, {
  String status = 'running',
  bool background = true,
  String type = 'general-purpose',
  int depth = 1,
  String? parent,
}) => {
  'agentId': id,
  'refId': 'spawn-$id',
  'agentName': name,
  'agentType': type,
  'agentDepth': depth,
  'agentParentId': ?parent,
  'agentBackground': background,
  'agentStatus': status,
};

/// A turn that fans out to three background agents: two still running, one
/// done.
final _fanOut = <Map<String, dynamic>>[
  {
    'kind': 'user',
    'text':
        'Review the auth module, the payment flow and the test gaps in '
        'parallel.',
  },
  {'kind': 'status', 'text': 'ready'},
  {
    'kind': 'text',
    'text': 'I’ll split this into three agents so they run in parallel.',
  },
  for (final (id, name, type) in [
    ('auth', 'Review auth module', 'Explore'),
    ('pay', 'Trace payment flow', 'general-purpose'),
    ('tests', 'Find untested paths', 'Explore'),
  ]) ...[
    {
      'kind': 'tool-start',
      'toolName': 'Agent',
      'refId': 'spawn-$id',
      'toolInput': '{"description":"$name"}',
    },
    {
      'kind': 'agent-start',
      ..._record(id, name, type: type),
      'agentPrompt':
          'You are reviewing the NexusLink repository. $name: read the '
          'relevant files under apps/desktop/src and apps/flutter_client/lib, '
          'note every place where a session token is created, checked or '
          'stored, and report concrete risks with file and line references. '
          'Do not change any files.',
    },
    {
      'kind': 'tool-end',
      'refId': 'spawn-$id',
      'toolOutput': 'Async agent launched successfully.',
    },
  ],
  {
    'kind': 'tool-start',
    'toolName': 'Grep',
    'refId': 'auth-grep',
    'agentId': 'auth',
    'toolInput': '{"pattern":"sessionToken","path":"apps/desktop/src"}',
  },
  {
    'kind': 'tool-end',
    'refId': 'auth-grep',
    'agentId': 'auth',
    'toolOutput': '14 matches in 6 files',
  },
  {
    'kind': 'tool-start',
    'toolName': 'Read',
    'refId': 'auth-read',
    'agentId': 'auth',
    'toolInput': '{"file_path":"apps/desktop/src/server/security.ts"}',
  },
  {
    'kind': 'text',
    'agentId': 'auth',
    'text':
        'Tokens are compared with `===` in `checkPairing`; the rest of the '
        'module uses a constant-time compare. Reading `security.ts` next.',
  },
  {
    'kind': 'agent-update',
    ..._record('auth', 'Review auth module', type: 'Explore'),
    'text': 'Reading security.ts',
    'toolName': 'Read',
  },
  {
    'kind': 'agent-update',
    ..._record('pay', 'Trace payment flow'),
    'text': 'Running bun test payments',
    'toolName': 'Bash',
  },
  {
    'kind': 'agent-end',
    ..._record(
      'tests',
      'Find untested paths',
      status: 'completed',
      type: 'Explore',
    ),
    'text':
        'Three paths have no tests: token refresh after a host restart, '
        'pairing with an expired QR code, and the audio engine stop path.',
  },
  {
    'kind': 'text',
    'text': 'Two agents are still working. I’ll summarize when they finish.',
  },
  {'kind': 'result', 'text': ''},
];

void main() {
  final key = GlobalKey();

  Future<void> shot(WidgetTester tester, String name) async {
    await frames(tester, 10);
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

  Widget wrap(Widget app) => RepaintBoundary(key: key, child: app);

  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    // Drafts (e.g. a typed slash command) must not leak into the next shot.
    SharedPreferences.setMockInitialValues({});
  }

  setUpAll(() async {
    if (_dir != null) await _loadFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('capture sub-agents', skip: _dir == null, (tester) async {
    await pumpChat(
      tester,
      SubagentHost(history: stored(_fanOut), runningAgents: 2),
      theme: nexusTheme(),
      wrap: wrap,
    );
    await shot(tester, '01-chat-strip');

    await tester.tap(find.byKey(const ValueKey('subagent-chip-auth')));
    await shot(tester, '02-agent-running');
    await done(tester);

    await pumpChat(
      tester,
      SubagentHost(history: stored(foreground)),
      theme: nexusTheme(),
      wrap: wrap,
    );
    await tester.tap(find.byKey(const ValueKey('subagent-chip-$fgId')));
    await shot(tester, '03-agent-foreground-done');
    await done(tester);

    await pumpChat(
      tester,
      SubagentHost(history: stored(foreground)),
      theme: nexusTheme(),
      wrap: wrap,
    );
    await tester.enterText(find.byType(TextField).last, '/thinking');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await shot(tester, '04-thinking-ultra-code');
    await done(tester);

    const names = [
      'launcher',
      'desktop',
      'audio',
      'mirror',
      'terminal',
      'pairing',
      'chat',
      'monitor',
      'arena',
      'files',
      'settings',
      'remote',
    ];
    Map<String, dynamic> worker(int i, {String status = 'running'}) => _record(
      'w$i',
      'Port ${names[i]} tests',
      status: status,
      // Two agents started by the audio agent.
      depth: i == 3 || i == 4 ? 2 : 1,
      parent: i == 3 || i == 4 ? 'w2' : null,
    );
    final many = <Map<String, dynamic>>[
      {'kind': 'user', 'text': 'Port every screen test to the new harness.'},
      for (var i = 0; i < 12; i++) {'kind': 'agent-start', ...worker(i)},
      for (final i in [0, 1, 5])
        {
          'kind': 'agent-update',
          ...worker(i),
          'text': 'Running flutter test test/${names[i]}_test.dart',
          'toolName': 'Bash',
        },
      for (final (i, status) in [
        (6, 'completed'),
        (7, 'failed'),
        (8, 'stopped'),
      ])
        {
          'kind': 'agent-end',
          ...worker(i, status: status),
          'text': status == 'failed' ? 'flutter test exited with 1' : 'Done.',
        },
      {'kind': 'result', 'text': ''},
    ];
    await pumpChat(
      tester,
      SubagentHost(history: stored(many), runningAgents: 9),
      theme: nexusTheme(),
      wrap: wrap,
    );
    await shot(tester, '05-strip-12-agents');
    await tester.drag(
      find.byKey(const ValueKey('subagent-strip-scroll')),
      const Offset(-600, 0),
    );
    await shot(tester, '06-strip-12-scrolled');
    await tester.tap(find.byKey(const ValueKey('subagent-strip-all')));
    await shot(tester, '07-all-agents');
    await done(tester);

    // Large text: the strip grows instead of clipping.
    tester.platformDispatcher.textScaleFactorTestValue = 1.35;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpChat(
      tester,
      SubagentHost(history: stored(_fanOut), runningAgents: 2),
      theme: nexusTheme(),
      wrap: wrap,
    );
    await shot(tester, '08-chat-strip-large-text');
    await done(tester);
  });
}
