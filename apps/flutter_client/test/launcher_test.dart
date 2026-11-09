import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexuslink/src/pc/app_actions.dart';
import 'package:nexuslink/src/rpc/models.dart';
import 'package:nexuslink/src/screens/mirror_screen.dart';
import 'package:nexuslink/src/screens/launcher_screen.dart';
import 'package:nexuslink/src/state/launcher.dart';
import 'package:nexuslink/src/state/launcher_preferences.dart';

final testApps = [
  AppInfo(appId: 'editor', name: 'Editor'),
  AppInfo(appId: 'browser', name: 'Browser'),
];

class TestApps extends AppsNotifier {
  @override
  AsyncValue<List<AppInfo>> build() => AsyncData(testApps);
}

class TestWindows extends WindowsNotifier {
  @override
  AsyncValue<List<WindowInfo>> build() => AsyncData([
    WindowInfo(
      windowId: '0x123',
      title: 'Document',
      wmClass: 'editor',
      desktop: 0,
      appId: 'editor',
    ),
  ]);
}

class TestSessions extends AppSessionsNotifier {
  @override
  AsyncValue<List<AppSessionInfo>> build() => const AsyncData([]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('favourites and usage persist and are isolated per PC', () async {
    final store = await SharedPreferences.getInstance();
    final prefs = LauncherPreferences(store, 'pc-one');
    await prefs.toggleFavourite(testApps.first);
    await prefs.recordUse('editor');
    await prefs.recordUse('browser');
    await prefs.recordUse('browser');
    final restored = LauncherPreferences(store, 'pc-one');
    expect(restored.favourites, {'editor'});
    expect(restored.mostUsed(testApps).map((app) => app.appId), [
      'browser',
      'editor',
    ]);
    expect(LauncherPreferences(store, 'pc-two').favourites, isEmpty);
    expect(LauncherPreferences(store, 'pc-two').mostUsed(testApps), isEmpty);
    await restored.toggleFavourite(testApps.first);
    expect(LauncherPreferences(store, 'pc-one').favourites, isEmpty);
  });

  test(
    'recent apps use recency, and default favourites can be removed',
    () async {
      final store = await SharedPreferences.getInstance();
      final prefs = LauncherPreferences(store, 'pc-one');
      await prefs.recordUse('browser');
      await prefs.recordUse('browser');
      await prefs.recordUse('editor');
      expect(
        LauncherPreferences(
          store,
          'pc-one',
        ).recentlyUsed(testApps).map((a) => a.appId),
        ['editor', 'browser'],
      );
      for (final name in LauncherPreferences.defaultFavourites) {
        final app = AppInfo(appId: name, name: name);
        expect(prefs.isFavourite(app), isTrue);
        await prefs.toggleFavourite(app);
        expect(LauncherPreferences(store, 'pc-one').isFavourite(app), isFalse);
        await prefs.toggleFavourite(app);
        expect(prefs.isFavourite(app), isTrue);
      }
    },
  );

  testWidgets('Apps searches the drawer and saves favourites to Desktop', (
    tester,
  ) async {
    await tester.pumpWidget(_launcher());
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('Apps'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Editor');
    await tester.pumpAndSettle();
    expect(find.text('Browser'), findsNothing);
    await tester.tap(find.byTooltip('Actions for Editor'));
    await tester.pumpAndSettle();
    expect(find.text('App info'), findsOneWidget);
    await tester.tap(find.text('Add to favourites'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Desktop'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fav-editor')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('one tap behaviour: two windows choose by title, Back returns '
      'to the same tab and search; one window resumes; closed launches; a '
      'phone session and an unknown window are reachable', (tester) async {
    final opened = <MirrorTarget>[];
    debugViewerBuilder = (t) {
      opened.add(t);
      return Scaffold(
        appBar: AppBar(title: const Text('Viewer')),
        body: Text('viewing ${t.windowId ?? t.sessionId ?? t.appId}'),
      );
    };
    addTearDown(() => debugViewerBuilder = null);
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      _launcher(
        apps: [firefox, editor, files, chrome],
        windows: [
          WindowInfo(
            windowId: 'w1',
            title: 'Inbox — Mozilla Firefox',
            wmClass: 'Navigator.firefox',
            desktop: 0,
          ),
          WindowInfo(
            windowId: 'w2',
            title: 'Docs — Mozilla Firefox',
            wmClass: 'Navigator.firefox',
            desktop: 0,
          ),
          WindowInfo(
            windowId: 'w3',
            title: 'Document',
            wmClass: 'editor',
            desktop: 0,
            appId: 'editor',
          ),
          WindowInfo(
            windowId: 'w4',
            title: 'scratch.txt',
            wmClass: '',
            desktop: 0,
          ),
        ],
        sessions: [
          AppSessionInfo(
            sessionId: 's1',
            appId: 'nexus.chrome',
            name: 'Chrome',
            display: ':9',
            width: 400,
            height: 800,
            dpr: 2,
            status: 'running',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // Favourite Firefox from its menu in Apps, after a search.
    await tester.tap(find.text('Apps'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'fire');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Actions for Firefox'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to favourites'));
    await tester.pumpAndSettle();

    // Tap it: two windows → choose by title.
    await tester.tap(find.text('Firefox'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('choose-window')), findsOneWidget);
    expect(find.text('Inbox — Mozilla Firefox'), findsOneWidget);
    await tester.tap(find.text('Docs — Mozilla Firefox'));
    await tester.pumpAndSettle();
    expect(find.text('viewing w2'), findsOneWidget);
    // Back: same tab, same search.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('fire'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    // From Desktop, the favourite does the same.
    await tester.tap(find.text('Desktop'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fav-firefox')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('choose-window')), findsOneWidget);
    await tester.tap(find.text('Inbox — Mozilla Firefox'));
    await tester.pumpAndSettle();
    expect(find.text('viewing w1'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Resume a different app from Running: one window → straight in.
    await tester.tap(find.text('Running'));
    await tester.pumpAndSettle();
    expect(find.text('2 windows'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('running-editor')));
    await tester.pumpAndSettle();
    expect(find.text('viewing w3'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('2 windows'), findsOneWidget);

    // A phone session resumes the session.
    await tester.tap(find.byKey(const ValueKey('running-nexus.chrome')));
    await tester.pumpAndSettle();
    expect(find.text('viewing s1'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // A window no app was found for is listed by title and opens.
    expect(find.text('Other windows'), findsOneWidget);
    await tester.tap(find.text('scratch.txt'));
    await tester.pumpAndSettle();
    expect(find.text('viewing w4'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // A closed app launches.
    await tester.tap(find.text('Apps'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Files');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app-org.gnome.Nautilus')));
    await tester.pumpAndSettle();
    expect(find.text('viewing org.gnome.Nautilus'), findsOneWidget);
    expect(opened.last.appId, 'org.gnome.Nautilus');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a running app offers Restart and Quit from its one menu', (
    tester,
  ) async {
    await tester.pumpWidget(_launcher());
    await tester.pumpAndSettle();
    expect(find.text('Open desktop'), findsOneWidget);
    await tester.tap(find.text('Running'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Actions for Editor'));
    await tester.pumpAndSettle();
    expect(find.text('App info'), findsOneWidget);
    expect(find.text('Quit'), findsOneWidget);
    expect(find.text('Restart'), findsOneWidget);
    await tester.tap(find.text('Restart'));
    await tester.pumpAndSettle();
    expect(find.text('Restart Editor?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

final firefox = AppInfo(appId: 'firefox', name: 'Firefox', wmClass: 'firefox');
final editor = AppInfo(appId: 'editor', name: 'Editor');
final files = AppInfo(appId: 'org.gnome.Nautilus', name: 'Files');
final chrome = AppInfo(appId: 'nexus.chrome', name: 'Chrome');

class _Apps extends AppsNotifier {
  _Apps(this.list);
  final List<AppInfo> list;
  @override
  AsyncValue<List<AppInfo>> build() => AsyncData(list);
}

class _Windows extends WindowsNotifier {
  _Windows(this.list);
  final List<WindowInfo> list;
  @override
  AsyncValue<List<WindowInfo>> build() => AsyncData(list);
}

class _Sessions extends AppSessionsNotifier {
  _Sessions(this.list);
  final List<AppSessionInfo> list;
  @override
  AsyncValue<List<AppSessionInfo>> build() => AsyncData(list);
}

Widget _launcher({
  List<AppInfo>? apps,
  List<WindowInfo>? windows,
  List<AppSessionInfo> sessions = const [],
}) => ProviderScope(
  overrides: [
    if (apps == null)
      appsProvider.overrideWith(TestApps.new)
    else
      appsProvider.overrideWith(() => _Apps(apps)),
    if (windows == null)
      windowsProvider.overrideWith(TestWindows.new)
    else
      windowsProvider.overrideWith(() => _Windows(windows)),
    appSessionsProvider.overrideWith(() => _Sessions(sessions)),
  ],
  child: const MaterialApp(home: LauncherScreen()),
);
