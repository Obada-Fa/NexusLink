import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexuslink/src/rpc/models.dart';
import 'package:nexuslink/src/pc/app_actions.dart';
import 'package:nexuslink/src/rpc/rpc_client.dart';
import 'package:nexuslink/src/session/target.dart';
import 'package:nexuslink/src/shell/home_dock.dart';
import 'package:nexuslink/src/state/connection.dart' as conn;
import 'package:nexuslink/src/state/launcher.dart';
import 'package:nexuslink/src/state/launcher_preferences.dart';

class Host extends RpcClient {
  Host() : super('ws://pc:45678/rpc');
  @override
  bool supports(String feature) => feature == 'apps.list';
  @override
  void Function() subscribe(
    String topic,
    void Function(Map<String, dynamic>) cb,
  ) => () {};
  @override
  Future<List<dynamic>> requestList(
    String method, [
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 10),
  ]) async => [];
}

class Connected extends conn.ConnectionNotifier {
  Connected(this.host);
  final Host host;
  @override
  conn.ConnectionState build() => conn.ConnectionState(
    client: host,
    hostUrl: host.wsUrl,
    status: RpcStatus.connected,
  );
}

class Apps extends AppsNotifier {
  @override
  AsyncValue<List<AppInfo>> build() =>
      AsyncData([AppInfo(appId: 'editor', name: 'Editor')]);
}

class Windows extends WindowsNotifier {
  @override
  AsyncValue<List<WindowInfo>> build() => AsyncData([
    WindowInfo(
      windowId: '1',
      title: 'My document',
      wmClass: 'editor',
      desktop: 0,
      appId: 'editor',
    ),
  ]);
  @override
  Future<void> refresh() async {}
}

class TwoWindows extends Windows {
  @override
  AsyncValue<List<WindowInfo>> build() => AsyncData([
    for (final id in ['1', '2'])
      WindowInfo(
        windowId: id,
        title: 'Document $id',
        wmClass: 'editor',
        desktop: 0,
        appId: 'editor',
      ),
  ]);
}

class Sessions extends AppSessionsNotifier {
  @override
  AsyncValue<List<AppSessionInfo>> build() => const AsyncData([]);
  @override
  Future<void> refresh() async {}
}

SavedTarget target(String host) => SavedTarget(
  id: host,
  name: 'My PC',
  utilities: {
    UtilityIds.nexuslink: UtilityLink(
      utility: UtilityIds.nexuslink,
      port: 45678,
      wsUrl: host,
      pairedAt: DateTime(2026),
    ),
  },
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<void> mount(
    WidgetTester tester, {
    bool visible = true,
    String? selected,
    double scale = 1,
  }) async {
    final host = Host();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conn.connectionProvider.overrideWith(() => Connected(host)),
          appsProvider.overrideWith(Apps.new),
          windowsProvider.overrideWith(Windows.new),
          appSessionsProvider.overrideWith(Sessions.new),
        ],
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              bottomNavigationBar: HomeDock(
                target: target(selected ?? host.wsUrl),
                visible: visible,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('dock hides for another PC or when Home is invisible', (
    tester,
  ) async {
    await mount(tester, visible: false);
    expect(find.byKey(const ValueKey('home-dock')), findsNothing);
    await mount(tester, selected: 'ws://other:45678/rpc');
    expect(find.byKey(const ValueKey('home-dock')), findsNothing);
  });
  testWidgets('pin picker saves pins and Running includes grouped windows', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('home-pin-apps')));
    await tester.pumpAndSettle();
    expect(find.text('Pin apps'), findsOneWidget);
    await tester.tap(find.text('Editor'));
    await tester.pumpAndSettle();
    final store = await SharedPreferences.getInstance();
    expect(
      LauncherPreferences(store, 'ws://pc:45678/rpc').favourites,
      contains('editor'),
    );
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dock-app-editor')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-running')));
    await tester.pumpAndSettle();
    expect(find.text('My document'), findsOneWidget);
  });
  testWidgets('dock handles narrow screens at large text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester, scale: 2);
    expect(find.byKey(const ValueKey('home-running')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('route visibility keeps chooser and long-press actions alive', (
    tester,
  ) async {
    final host = Host();
    final store = await SharedPreferences.getInstance();
    await LauncherPreferences(
      store,
      host.wsUrl,
    ).toggleFavourite(AppInfo(appId: 'editor', name: 'Editor'));
    debugViewerBuilder = (target) =>
        Scaffold(body: Text('Viewing ${target.windowId}'));
    addTearDown(() => debugViewerBuilder = null);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conn.connectionProvider.overrideWith(() => Connected(host)),
          appsProvider.overrideWith(Apps.new),
          windowsProvider.overrideWith(TwoWindows.new),
          appSessionsProvider.overrideWith(Sessions.new),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              bottomNavigationBar: HomeDock(
                target: target(host.wsUrl),
                visible: ModalRoute.isCurrentOf(context) ?? false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dock-app-editor')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('choose-window')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-dock')), findsNothing);
    await tester.tap(find.text('Document 2'));
    await tester.pumpAndSettle();
    expect(find.text('Viewing 2'), findsOneWidget);
    Navigator.of(tester.element(find.text('Viewing 2'))).pop();
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const ValueKey('dock-app-editor')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-dock')), findsNothing);
    await tester.tap(find.text('Remove from favourites'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dock-app-editor')), findsNothing);
    expect(LauncherPreferences(store, host.wsUrl).favourites, isEmpty);
  });
}
