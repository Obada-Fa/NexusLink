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

  testWidgets(
    'PC menu expands, searches, and saves favourites without a nested dock',
    (tester) async {
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
      expect(find.text('Recently opened'), findsOneWidget);
      expect(find.text('PC status'), findsOneWidget);
      expect(find.text('Agents'), findsNothing);
      expect(find.text('Terminal'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('Apps'));
      await tester.pumpAndSettle();
      expect(find.text('Favourites'), findsOneWidget);
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'Editor');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Add to favourites'));
      await tester.tap(find.byTooltip('Add to favourites'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Remove from favourites'), findsOneWidget);
      expect(find.text('Browser'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
