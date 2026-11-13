import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/session/target.dart';
import 'package:nexuslink/src/shell/capabilities.dart';
import 'package:nexuslink/src/shell/module.dart';
import 'package:nexuslink/src/shell/module_registry.dart';
import 'package:nexuslink/src/shell/home_art.dart';
import 'package:nexuslink/src/shell/tiles.dart';
import 'package:nexuslink/src/theme/nexus_theme.dart';

import 'fakes.dart';

ModuleContext ctxFor(SavedTarget t, Set<String> reachable) => ModuleContext(
  target: t,
  capabilities: capabilitiesOf(t),
  reachable: reachable,
);

void main() {
  final remote = FakeModule(id: 'remote', title: 'Remote');
  final modules = [...nexusLinkModules, remote];

  test('paired and reachable → normal tile', () {
    final tiles = homeTiles(
      modules,
      ctxFor(hubTarget(), {UtilityIds.nexuslink, UtilityIds.remote}),
      platform: TargetPlatform.android,
    );
    expect(tiles.map((t) => t.module.id), [
      'desktop',
      'files',
      'agents',
      'terminal',
      'remote',
    ]);
    expect(tiles.every((t) => t.status == TileStatus.ready), isTrue);
  });

  test('paired but unreachable → offline; others stay normal', () {
    final tiles = homeTiles(
      modules,
      ctxFor(hubTarget(), {UtilityIds.nexuslink}),
      platform: TargetPlatform.android,
    );
    final byId = {for (final t in tiles) t.module.id: t.status};
    expect(byId['remote'], TileStatus.offline);
    expect(byId['desktop'], TileStatus.ready);
  });

  test('unpaired Remote remains discoverable as setup', () {
    final tiles = homeTiles(
      modules,
      ctxFor(hubTarget(utilities: {UtilityIds.nexuslink}), {
        UtilityIds.nexuslink,
      }),
      platform: TargetPlatform.android,
    );
    expect(
      tiles.singleWhere((t) => t.module.id == 'remote').status,
      TileStatus.setup,
    );
  });

  test('before the first probe, or while NexusLink dials → checking', () {
    final ctx = ctxFor(hubTarget(), const {});
    expect(tileStatus(remote, ctx, probedOnce: false), TileStatus.checking);
    expect(
      tileStatus(moduleRegistry.first, ctx, nexusLinkConnecting: true),
      TileStatus.checking,
    );
    // Connecting NexusLink says nothing about Remote.
    expect(
      tileStatus(remote, ctx, nexusLinkConnecting: true),
      TileStatus.offline,
    );
  });

  testWidgets('offline tile is dimmed and labelled', (tester) async {
    final ctx = ctxFor(hubTarget(), {UtilityIds.nexuslink});
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: nexusTheme(),
        home: Scaffold(
          body: Row(
            children: [
              for (final s in [TileStatus.ready, TileStatus.offline])
                SizedBox(
                  width: 190,
                  child: ModuleTile(
                    tile: HomeTile(remote, s),
                    ctx: ctx,
                    onTap: () => taps++,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Offline'), findsOneWidget);
    final opacities = tester
        .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
        .map((o) => o.opacity)
        .toList();
    expect(opacities, [1.0, 0.5]);
    await tester.tap(find.text('Offline'));
    expect(taps, 1, reason: 'offline tiles still tap (to explain)');
  });

  testWidgets('a PC icon replaces the drawn art; a bad one falls back', (
    tester,
  ) async {
    final ctx = ctxFor(hubTarget(), {UtilityIds.nexuslink});
    // 1×1 transparent PNG.
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
    Future<void> pump(String? icon) => tester.pumpWidget(
      MaterialApp(
        theme: nexusTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 190,
            child: ModuleTile(
              tile: HomeTile(remote, TileStatus.ready),
              ctx: ctx,
              onTap: () {},
              pcIcon: icon,
            ),
          ),
        ),
      ),
    );
    await pump(png);
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(HomeShortcutArt), findsNothing);
    await pump('not-an-icon');
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(find.byType(HomeShortcutArt), findsOneWidget);
    await pump(null);
    expect(find.byType(HomeShortcutArt), findsOneWidget);
  });
}
