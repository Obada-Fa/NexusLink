// One entry per app: windows, phone sessions and agent apps grouped, with
// the same tap behaviour everywhere.

import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/monitor/monitor_models.dart';
import 'package:nexuslink/src/rpc/models.dart';
import 'package:nexuslink/src/state/app_groups.dart';

WindowInfo win(String id, String title, {String cls = '', String? appId}) =>
    WindowInfo(
      windowId: id,
      title: title,
      wmClass: cls,
      desktop: 0,
      appId: appId,
    );

AppSessionInfo session(String id, String appId, String name) => AppSessionInfo(
  sessionId: id,
  appId: appId,
  name: name,
  display: ':9',
  width: 400,
  height: 800,
  dpr: 2,
  status: 'running',
);

AgentApp agent(
  String id, {
  String? appId,
  String name = 'Claude',
  String kind = 'desktop',
  String state = 'active',
  List<String> windows = const [],
}) => AgentApp({
  'id': id,
  'appId': appId ?? id,
  'name': name,
  'kind': kind,
  'state': state,
  'windows': [
    for (final w in windows) {'id': w, 'title': name},
  ],
  'actions': ['focus', 'restart', 'quit', 'kill'],
});

final firefox = AppInfo(appId: 'firefox', name: 'Firefox', wmClass: 'firefox');
final files = AppInfo(appId: 'org.gnome.Nautilus', name: 'Files');
final chrome = AppInfo(appId: 'nexus.chrome', name: 'Chrome');

void main() {
  test(
    'windows of one app become one entry; one window resumes, two choose',
    () {
      final r = groupRunning(
        apps: [firefox, files],
        windows: [
          win('1', 'Inbox — Mozilla Firefox', cls: 'Navigator.firefox'),
          win('2', 'Docs — Mozilla Firefox', cls: 'Navigator.firefox'),
          win(
            '3',
            'Home',
            cls: 'org.gnome.Nautilus',
            appId: 'org.gnome.Nautilus',
          ),
        ],
        sessions: const [],
      );
      expect(r.apps.map((e) => e.name), ['Firefox', 'Files']);
      final ff = r.apps.first;
      expect(ff.detail, '2 windows');
      final action = openActionFor(ff);
      expect(action, isA<ChooseItem>());
      expect((action as ChooseItem).items.map((i) => i.title), [
        'Inbox — Mozilla Firefox',
        'Docs — Mozilla Firefox',
      ]);
      final one = openActionFor(r.apps[1]);
      expect(one, isA<ResumeItem>());
      expect(r.apps[1].detail, 'Home');
    },
  );

  test('a closed app launches', () {
    final r = groupRunning(
      apps: [firefox],
      windows: const [],
      sessions: const [],
    );
    final entries = drawerApps(apps: [firefox], running: r);
    expect(entries.single.running, isFalse);
    expect(openActionFor(entries.single), isA<LaunchApp>());
  });

  test('a phone session joins the app and is offered first in the choice', () {
    final r = groupRunning(
      apps: [chrome],
      windows: [win('9', 'News', appId: 'nexus.chrome')],
      sessions: [session('s1', 'nexus.chrome', 'Chrome')],
    );
    final e = r.apps.single;
    expect(e.detail, '1 window · 1 on your phone');
    final items = (openActionFor(e) as ChooseItem).items;
    expect(items.first, isA<SessionItem>());
    expect(items.last.title, 'News');
  });

  test('a lone phone session resumes directly', () {
    final r = groupRunning(
      apps: [chrome],
      windows: const [],
      sessions: [session('s1', 'nexus.chrome', 'Chrome')],
    );
    expect(openActionFor(r.apps.single), isA<ResumeItem>());
    expect(r.apps.single.detail, 'On your phone');
  });

  test('a window with no known app is kept, listed by its title', () {
    final r = groupRunning(
      apps: [firefox],
      windows: [win('7', 'Untitled — scratch', cls: '')],
      sessions: const [],
    );
    expect(r.apps, isEmpty);
    expect(r.unidentified.single.name, 'Untitled — scratch');
    expect(r.unidentified.single.identified, isFalse);
    expect(openActionFor(r.unidentified.single), isA<ResumeItem>());
    expect(r.count, 1);
  });

  test('an unknown app id groups its windows under the id', () {
    final r = groupRunning(
      apps: const [],
      windows: [
        win('1', 'A', cls: 'my-tool', appId: 'my-tool'),
        win('2', 'B', cls: 'my-tool', appId: 'my-tool'),
      ],
      sessions: const [],
    );
    expect(r.apps.single.key, 'id:my-tool');
    expect(r.apps.single.windows, hasLength(2));
  });

  test('agent apps attach by window, show stuck, and CLI agents are '
      'in terminals', () {
    final claude = AppInfo(appId: 'claude-desktop', name: 'Claude');
    final r = groupRunning(
      apps: [claude],
      windows: [win('0x1', 'Claude', cls: 'Claude', appId: 'claude-desktop')],
      sessions: const [],
      agents: [
        agent('claude-desktop', state: 'stuck', windows: ['0x1']),
        agent('codex-desktop', name: 'Codex', windows: ['0x9']),
        agent(
          'claude-code:1',
          appId: 'claude-code',
          name: 'Claude Code',
          kind: 'cli',
        ),
      ],
    );
    final c = r.apps.firstWhere((e) => e.name == 'Claude');
    expect(c.stuck, isTrue);
    expect(c.windows, hasLength(1));
    // Codex reports a window the window list doesn't have: still listed.
    final codex = r.apps.firstWhere((e) => e.name == 'Codex');
    expect(codex.running, isTrue);
    expect(openActionFor(codex), isA<ShowInfo>());
    expect(r.terminals.single.name, 'Claude Code');
  });

  test('the drawer adds startable agent apps and sorts by name', () {
    final r = groupRunning(
      apps: [firefox],
      windows: const [],
      sessions: const [],
    );
    final d = drawerApps(
      apps: [firefox],
      running: r,
      launchers: [
        AgentLauncher({'appId': 'cursor', 'name': 'Cursor', 'running': false}),
        AgentLauncher({'appId': 'firefox', 'name': 'Firefox'}),
      ],
    );
    expect(d.map((e) => e.name), ['Cursor', 'Firefox']);
    expect(d.first.agentLauncher, 'cursor');
    expect(openActionFor(d.first), isA<LaunchApp>());
  });
}
