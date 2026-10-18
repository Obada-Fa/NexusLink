import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexuslink/src/rpc/models.dart';
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
    await prefs.toggleFavourite('editor');
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
    await restored.toggleFavourite('editor');
    expect(LauncherPreferences(store, 'pc-one').favourites, isEmpty);
  });

  testWidgets('PC menu shows running apps and long-press actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appsProvider.overrideWith(TestApps.new),
          windowsProvider.overrideWith(TestWindows.new),
          appSessionsProvider.overrideWith(TestSessions.new),
        ],
        child: const MaterialApp(home: LauncherScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Document'), findsOneWidget);
    await tester.longPress(find.text('Editor'));
    await tester.pumpAndSettle();
    expect(find.text('Close app'), findsOneWidget);
    expect(find.text('Restart app'), findsOneWidget);
    await tester.tap(find.text('Add to favourites'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2. Favourites / most used'));
    await tester.pumpAndSettle();
    expect(find.text('FAVOURITES'), findsOneWidget);
    expect(find.text('Editor'), findsNWidgets(2));
    await tester.longPress(find.text('Browser'));
    await tester.pumpAndSettle();
    final close = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('Close app'),
        matching: find.byType(ListTile),
      ),
    );
    expect(close.enabled, isFalse);
    expect(tester.takeException(), isNull);
  });
}
